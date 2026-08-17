const state = {
  me: null,
  posts: [],
  users: new Map(),
  cursor: null,
  profilePosts: [],
  profileCursor: null,
  profileLoading: false,
  profileLoaded: false,
  comments: new Map(),
  mode: "short",
  loading: false,
};

const elements = {
  composeForm: document.querySelector("#compose-form"),
  content: document.querySelector("#post-content"),
  title: document.querySelector("#post-title"),
  tags: document.querySelector("#post-tags"),
  visibility: document.querySelector("#post-visibility"),
  publish: document.querySelector("#publish-button"),
  feedList: document.querySelector("#feed-list"),
  feedStatus: document.querySelector("#feed-status"),
  loadMore: document.querySelector("#load-more"),
  profileFeedList: document.querySelector("#profile-feed-list"),
  profileFeedStatus: document.querySelector("#profile-feed-status"),
  profileLoadMore: document.querySelector("#profile-load-more"),
  refresh: document.querySelector("#refresh-button"),
  toast: document.querySelector("#toast"),
};

const routes = new Set(["feed", "composer", "profile"]);

function routeFromHash() {
  const route = window.location.hash.slice(1);
  return routes.has(route) ? route : "feed";
}

function setRoute(route) {
  const nextRoute = routes.has(route) ? route : "feed";
  document.body.dataset.route = nextRoute;

  document.querySelectorAll(".nav-item").forEach((link) => {
    const isActive = link.hash === `#${nextRoute}`;
    link.classList.toggle("is-active", isActive);
    if (isActive) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });

  window.scrollTo({ top: 0, behavior: "smooth" });
  if (nextRoute === "composer") {
    window.requestAnimationFrame(() => elements.content.focus({ preventScroll: true }));
  }
  if (nextRoute === "profile" && state.me && !state.profileLoaded) loadProfileFeed();
}

function navigateTo(route) {
  const hash = `#${route}`;
  if (window.location.hash !== hash) window.history.pushState(null, "", hash);
  setRoute(route);
}

const visibilityLabels = {
  public: "公开",
  followers: "关注者可见",
  private: "仅自己",
};

const brandMark = "/assets/hublog-mark-v10-cat-mouth-no-whiskers.svg?v=20260817-14";

const dateFormatter = new Intl.DateTimeFormat("zh-CN", {
  month: "short",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});
let postInstanceCounter = 0;

async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    ...options,
    headers: {
      Accept: "application/json",
      ...(options.body ? { "Content-Type": "application/json" } : {}),
      ...(options.headers || {}),
    },
  });

  if (response.status === 204) return null;
  const contentType = response.headers.get("content-type") || "";
  const payload = contentType.includes("application/json") ? await response.json() : null;
  if (!response.ok) {
    const detail = typeof payload?.detail === "string" ? payload.detail : `请求失败 (${response.status})`;
    throw new Error(detail);
  }
  return payload;
}

function initials(user) {
  const value = (user?.display_name || user?.username || "虎").trim();
  return Array.from(value).slice(0, 1).join("").toUpperCase();
}

function avatarColor(userId) {
  const colors = ["#24776d", "#a43c4c", "#526d9b", "#7a5b92", "#8a6430", "#3d7289"];
  let hash = 0;
  for (const character of userId || "hublog") hash = ((hash << 5) - hash + character.charCodeAt(0)) | 0;
  return colors[Math.abs(hash) % colors.length];
}

function updateIdentity() {
  const user = state.me;
  if (!user) return;
  document.querySelector("#header-name").textContent = user.display_name;
  document.querySelector("#profile-name").textContent = user.display_name;
  document.querySelector("#profile-username").textContent = `@${user.username}`;
  document.querySelector("#profile-bio").textContent = user.bio || "朋友之间，认真写点东西。";
  for (const target of [document.querySelector("#header-avatar"), document.querySelector("#profile-avatar")]) {
    target.textContent = initials(user);
    target.style.backgroundColor = avatarColor(user.id);
  }
}

async function hydrateUsers(posts) {
  const ids = [...new Set(posts.map((post) => post.author_id))].filter((id) => !state.users.has(id));
  await Promise.all(ids.map(async (id) => {
    try {
      state.users.set(id, await api(`/api/v1/users/${id}`));
    } catch {
      state.users.set(id, { id, username: "unknown", display_name: "虎博用户" });
    }
  }));
}

function createAvatar(user, className = "avatar-post") {
  const avatar = document.createElement("span");
  avatar.className = `avatar ${className}`;
  avatar.textContent = initials(user);
  avatar.style.backgroundColor = avatarColor(user.id);
  return avatar;
}


function commentsFor(postId) {
  if (!state.comments.has(postId)) {
    state.comments.set(postId, {
      items: [],
      cursor: null,
      expanded: false,
      loaded: false,
      loading: false,
      submitting: false,
      deleting: new Set(),
      error: null,
    });
  }
  return state.comments.get(postId);
}


function createCommentRow(comment, model) {
  const user = state.users.get(comment.author_id) || { id: comment.author_id, username: "unknown", display_name: "虎博用户" };
  const row = document.createElement("div");
  row.className = "comment-row";
  row.dataset.commentId = comment.id;
  row.append(createAvatar(user, "avatar-comment"));

  const body = document.createElement("div");
  body.className = "comment-body";
  const header = document.createElement("div");
  header.className = "comment-header";
  const name = document.createElement("span");
  name.className = "comment-author-name";
  name.textContent = user.display_name;
  const username = document.createElement("span");
  username.className = "comment-username";
  username.textContent = `@${user.username}`;
  const time = document.createElement("time");
  time.className = "comment-time";
  time.dateTime = comment.created_at;
  time.textContent = dateFormatter.format(new Date(comment.created_at));
  header.append(name, username, time);

  const content = document.createElement("p");
  content.className = "comment-content";
  content.textContent = comment.content;
  body.append(header, content);
  row.append(body);

  if (state.me?.id === comment.author_id) {
    const remove = document.createElement("button");
    remove.className = "comment-delete";
    remove.type = "button";
    remove.title = "删除评论";
    remove.setAttribute("aria-label", "删除评论");
    remove.disabled = model.deleting.has(comment.id);
    remove.innerHTML = '<svg aria-hidden="true"><use href="#icon-trash"/></svg>';
    remove.addEventListener("click", () => deleteComment(comment.post_id, comment.id));
    row.append(remove);
  }
  return row;
}


function createCommentThread(postId, instanceId) {
  const section = document.createElement("section");
  section.className = "comment-thread is-hidden";
  section.id = `comments-${instanceId}`;
  section.setAttribute("aria-label", "评论");

  const heading = document.createElement("div");
  heading.className = "comment-thread-heading";
  const title = document.createElement("strong");
  title.textContent = "评论";
  const status = document.createElement("span");
  status.className = "comment-status";
  status.setAttribute("role", "status");
  heading.append(title, status);

  const list = document.createElement("div");
  list.className = "comment-list";
  list.setAttribute("aria-live", "polite");

  const moreWrap = document.createElement("div");
  moreWrap.className = "comment-more-wrap";
  const more = document.createElement("button");
  more.className = "comment-more is-hidden";
  more.type = "button";
  more.addEventListener("click", () => loadComments(postId, { append: commentsFor(postId).loaded }));
  moreWrap.append(more);

  const form = document.createElement("form");
  form.className = "comment-form";
  form.append(createAvatar(state.me, "avatar-comment"));
  const label = document.createElement("label");
  label.className = "sr-only";
  label.htmlFor = `comment-input-${instanceId}`;
  label.textContent = "写下评论";
  const input = document.createElement("textarea");
  input.className = "comment-input";
  input.id = `comment-input-${instanceId}`;
  input.name = "content";
  input.maxLength = 2000;
  input.rows = 1;
  input.placeholder = "写下评论";
  input.required = true;
  const submit = document.createElement("button");
  submit.className = "comment-submit";
  submit.type = "submit";
  submit.title = "发布评论";
  submit.setAttribute("aria-label", "发布评论");
  submit.innerHTML = '<svg aria-hidden="true"><use href="#icon-send"/></svg>';
  form.append(label, input, submit);
  form.addEventListener("submit", (event) => submitComment(event, postId));

  section.append(heading, list, moreWrap, form);
  return section;
}


function renderCommentThread(article, postId) {
  const model = commentsFor(postId);
  const toggle = article.querySelector(".comment-toggle");
  const section = article.querySelector(".comment-thread");
  toggle.classList.toggle("is-active", model.expanded);
  toggle.setAttribute("aria-expanded", String(model.expanded));
  toggle.setAttribute("aria-label", model.expanded ? "收起评论" : "展开评论");
  const count = toggle.querySelector(".comment-count");
  count.textContent = model.loaded && model.items.length ? String(model.items.length) : "";
  section.classList.toggle("is-hidden", !model.expanded);
  if (!model.expanded) return;

  const status = section.querySelector(".comment-status");
  if (model.loading && !model.loaded) status.textContent = "正在加载";
  else if (model.error) status.textContent = "加载失败";
  else if (!model.items.length) status.textContent = "还没有评论";
  else status.textContent = `${model.items.length}${model.cursor ? "+" : ""} 条`;

  const list = section.querySelector(".comment-list");
  list.replaceChildren(...model.items.map((comment) => createCommentRow(comment, model)));

  const more = section.querySelector(".comment-more");
  more.classList.toggle("is-hidden", !model.error && !model.cursor);
  more.disabled = model.loading;
  more.textContent = model.error ? "重试" : "加载更早评论";

  const input = section.querySelector(".comment-input");
  const submit = section.querySelector(".comment-submit");
  const commentDisabled = !model.loaded || model.loading || model.submitting;
  input.disabled = commentDisabled;
  submit.disabled = commentDisabled;
  submit.classList.toggle("is-loading", model.submitting);
}


function refreshCommentThreads(postId) {
  document.querySelectorAll(`.post[data-post-id="${postId}"]`).forEach((article) => renderCommentThread(article, postId));
}


async function toggleComments(postId) {
  const model = commentsFor(postId);
  model.expanded = !model.expanded;
  refreshCommentThreads(postId);
  if (model.expanded && !model.loaded && !model.loading) await loadComments(postId);
}


async function loadComments(postId, { append = false } = {}) {
  const model = commentsFor(postId);
  if (model.loading || (append && !model.cursor && !model.error)) return;
  model.loading = true;
  model.error = null;
  refreshCommentThreads(postId);
  try {
    const query = append && model.cursor ? `?limit=20&cursor=${encodeURIComponent(model.cursor)}` : "?limit=20";
    const page = await api(`/api/v1/posts/${postId}/comments${query}`);
    await hydrateUsers(page.items);
    if (append) {
      const existing = new Set(model.items.map((comment) => comment.id));
      model.items.push(...page.items.filter((comment) => !existing.has(comment.id)));
    } else {
      model.items = page.items;
    }
    model.cursor = page.next_cursor;
    model.loaded = true;
  } catch (error) {
    model.error = error.message;
    showToast(error.message, true);
  } finally {
    model.loading = false;
    refreshCommentThreads(postId);
  }
}


async function submitComment(event, postId) {
  event.preventDefault();
  const model = commentsFor(postId);
  const content = new FormData(event.currentTarget).get("content")?.trim();
  if (!content || model.submitting || !model.loaded) return;
  model.submitting = true;
  refreshCommentThreads(postId);
  try {
    const comment = await api(`/api/v1/posts/${postId}/comments`, {
      method: "POST",
      body: JSON.stringify({ content }),
    });
    await hydrateUsers([comment]);
    model.items = [comment, ...model.items.filter((item) => item.id !== comment.id)];
    document.querySelectorAll(`.post[data-post-id="${postId}"] .comment-input`).forEach((input) => { input.value = ""; });
    showToast("评论已发布");
  } catch (error) {
    showToast(error.message, true);
  } finally {
    model.submitting = false;
    refreshCommentThreads(postId);
  }
}


async function deleteComment(postId, commentId) {
  if (!window.confirm("确定删除这条评论吗？")) return;
  const model = commentsFor(postId);
  if (model.deleting.has(commentId)) return;
  model.deleting.add(commentId);
  refreshCommentThreads(postId);
  try {
    await api(`/api/v1/comments/${commentId}`, { method: "DELETE" });
    model.items = model.items.filter((comment) => comment.id !== commentId);
    showToast("评论已删除");
  } catch (error) {
    showToast(error.message, true);
  } finally {
    model.deleting.delete(commentId);
    refreshCommentThreads(postId);
  }
}


function createPost(post) {
  const user = state.users.get(post.author_id) || { id: post.author_id, username: "unknown", display_name: "虎博用户" };
  const commentInstanceId = `${post.id}-${++postInstanceCounter}`;
  const article = document.createElement("article");
  article.className = "post";
  article.dataset.postId = post.id;

  const header = document.createElement("div");
  header.className = "post-header";
  header.append(createAvatar(user));

  const author = document.createElement("div");
  author.className = "post-author";
  const authorLine = document.createElement("div");
  authorLine.className = "post-author-line";
  const name = document.createElement("span");
  name.className = "post-author-name";
  name.textContent = user.display_name;
  const username = document.createElement("span");
  username.className = "post-username";
  username.textContent = `@${user.username}`;
  const time = document.createElement("time");
  time.className = "post-time";
  time.dateTime = post.created_at;
  time.textContent = dateFormatter.format(new Date(post.created_at));
  authorLine.append(name, username, time);

  const meta = document.createElement("div");
  meta.className = "post-meta";
  const visibility = document.createElement("span");
  visibility.className = "visibility";
  visibility.textContent = visibilityLabels[post.visibility] || post.visibility;
  meta.append(visibility);
  author.append(authorLine, meta);
  header.append(author);
  article.append(header);

  if (post.title) {
    const title = document.createElement("h3");
    title.className = "post-title";
    title.textContent = post.title;
    article.append(title);
  }

  const content = document.createElement("p");
  content.className = "post-content";
  content.textContent = post.content;
  article.append(content);

  if (post.tags?.length) {
    const tags = document.createElement("div");
    tags.className = "post-tags";
    for (const value of post.tags) {
      const tag = document.createElement("span");
      tag.className = "post-tag";
      tag.textContent = `#${value}`;
      tags.append(tag);
    }
    article.append(tags);
  }

  const actions = document.createElement("div");
  actions.className = "post-actions";
  const comments = document.createElement("button");
  comments.className = "post-action comment-toggle";
  comments.type = "button";
  comments.title = "评论";
  comments.setAttribute("aria-controls", `comments-${commentInstanceId}`);
  comments.innerHTML = '<svg aria-hidden="true"><use href="#icon-comment"/></svg><span class="post-action-label">评论</span><span class="comment-count"></span>';
  comments.addEventListener("click", () => toggleComments(post.id));
  actions.append(comments);
  if (state.me?.id === post.author_id) {
    const remove = document.createElement("button");
    remove.className = "post-action post-delete-action";
    remove.type = "button";
    remove.title = "删除动态";
    remove.setAttribute("aria-label", "删除动态");
    remove.innerHTML = '<svg aria-hidden="true"><use href="#icon-trash"/></svg>';
    remove.addEventListener("click", () => deletePost(post.id));
    actions.append(remove);
  }
  article.append(actions);
  article.append(createCommentThread(post.id, commentInstanceId));
  renderCommentThread(article, post.id);
  return article;
}

function renderPostList(target, posts, emptyText) {
  target.replaceChildren();
  if (!posts.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    const image = document.createElement("img");
    image.src = brandMark;
    image.alt = "";
    const text = document.createElement("p");
    text.textContent = emptyText;
    empty.append(image, text);
    target.append(empty);
  } else {
    const fragment = document.createDocumentFragment();
    posts.forEach((post) => fragment.append(createPost(post)));
    target.append(fragment);
  }
}

function renderFeed() {
  renderPostList(elements.feedList, state.posts, "这里还没有虎博。");
  elements.loadMore.classList.toggle("is-hidden", !state.cursor);
  elements.feedStatus.textContent = state.posts.length ? `${state.posts.length} 条` : "暂无虎博";
}

function renderProfileFeed() {
  renderPostList(elements.profileFeedList, state.profilePosts, "你还没有发布虎博。");
  document.querySelector("#loaded-count").textContent = String(state.profilePosts.length);
  elements.profileLoadMore.classList.toggle("is-hidden", !state.profileCursor);
  elements.profileFeedStatus.textContent = state.profilePosts.length ? `${state.profilePosts.length} 条` : "暂无虎博";
}

async function loadFeed({ append = false } = {}) {
  if (state.loading) return;
  state.loading = true;
  elements.refresh.classList.add("is-spinning");
  elements.feedStatus.textContent = "正在加载";
  try {
    const query = append && state.cursor ? `?limit=20&cursor=${encodeURIComponent(state.cursor)}` : "?limit=20";
    const page = await api(`/api/v1/feed${query}`);
    await hydrateUsers(page.items);
    state.posts = append ? [...state.posts, ...page.items] : page.items;
    state.cursor = page.next_cursor;
    renderFeed();
  } catch (error) {
    elements.feedStatus.textContent = "加载失败";
    showToast(error.message, true);
  } finally {
    state.loading = false;
    elements.refresh.classList.remove("is-spinning");
  }
}

async function loadProfileFeed({ append = false } = {}) {
  if (state.profileLoading) return;
  state.profileLoading = true;
  elements.refresh.classList.add("is-spinning");
  elements.profileFeedStatus.textContent = "正在加载";
  try {
    const query = append && state.profileCursor ? `?limit=20&cursor=${encodeURIComponent(state.profileCursor)}` : "?limit=20";
    const page = await api(`/api/v1/me/posts${query}`);
    await hydrateUsers(page.items);
    state.profilePosts = append ? [...state.profilePosts, ...page.items] : page.items;
    state.profileCursor = page.next_cursor;
    state.profileLoaded = true;
    renderProfileFeed();
  } catch (error) {
    elements.profileFeedStatus.textContent = "加载失败";
    showToast(error.message, true);
  } finally {
    state.profileLoading = false;
    elements.refresh.classList.remove("is-spinning");
  }
}

async function publishPost(event) {
  event.preventDefault();
  const content = elements.content.value.trim();
  const title = elements.title.value.trim();
  if (!content) return;
  elements.publish.disabled = true;
  elements.publish.textContent = "发布中";
  try {
    const tags = elements.tags.value.split(/[，,]/).map((tag) => tag.trim().replace(/^#/, "")).filter(Boolean).slice(0, 20);
    const post = await api("/api/v1/posts", {
      method: "POST",
      body: JSON.stringify({
        post_type: state.mode,
        visibility: elements.visibility.value,
        title: state.mode === "article" && title ? title : null,
        content,
        tags,
      }),
    });
    state.users.set(state.me.id, state.me);
    state.posts.unshift(post);
    if (state.profileLoaded) state.profilePosts.unshift(post);
    elements.composeForm.reset();
    setMode("short");
    renderFeed();
    if (state.profileLoaded) renderProfileFeed();
    navigateTo("feed");
    showToast("发布成功");
  } catch (error) {
    showToast(error.message, true);
  } finally {
    elements.publish.disabled = false;
    elements.publish.textContent = "发布";
  }
}

async function deletePost(postId) {
  if (!window.confirm("确定删除这条动态吗？")) return;
  try {
    await api(`/api/v1/posts/${postId}`, { method: "DELETE" });
    state.posts = state.posts.filter((post) => post.id !== postId);
    state.profilePosts = state.profilePosts.filter((post) => post.id !== postId);
    state.comments.delete(postId);
    renderFeed();
    if (state.profileLoaded) renderProfileFeed();
    showToast("已删除");
  } catch (error) {
    showToast(error.message, true);
  }
}

function setMode(mode) {
  state.mode = mode;
  document.querySelectorAll("[data-mode]").forEach((button) => button.classList.toggle("is-active", button.dataset.mode === mode));
  elements.title.classList.toggle("is-hidden", mode !== "article");
  elements.title.required = mode === "article";
  elements.content.placeholder = mode === "article" ? "写下正文" : "记录此刻，分享给朋友们";
}

let toastTimer;
function showToast(message, error = false) {
  window.clearTimeout(toastTimer);
  elements.toast.textContent = message;
  elements.toast.classList.toggle("is-error", error);
  elements.toast.classList.add("is-visible");
  toastTimer = window.setTimeout(() => elements.toast.classList.remove("is-visible"), 2600);
}

async function bootstrap() {
  try {
    state.me = await api("/api/v1/auth/session");
    state.users.set(state.me.id, state.me);
    updateIdentity();
    await loadFeed();
    if (routeFromHash() === "profile") await loadProfileFeed();
  } catch (error) {
    elements.feedStatus.textContent = "初始化失败";
    const failure = document.createElement("div");
    failure.className = "error-state";
    const text = document.createElement("p");
    text.textContent = error.message;
    failure.append(text);
    elements.feedList.replaceChildren(failure);
    showToast(error.message, true);
  }
}

elements.composeForm.addEventListener("submit", publishPost);
elements.loadMore.addEventListener("click", () => loadFeed({ append: true }));
elements.profileLoadMore.addEventListener("click", () => loadProfileFeed({ append: true }));
elements.refresh.addEventListener("click", () => routeFromHash() === "profile" ? loadProfileFeed() : loadFeed());
document.querySelectorAll("[data-mode]").forEach((button) => button.addEventListener("click", () => setMode(button.dataset.mode)));
document.querySelectorAll(".nav-item").forEach((link) => link.addEventListener("click", (event) => {
  event.preventDefault();
  navigateTo(link.hash.slice(1));
}));
window.addEventListener("hashchange", () => setRoute(routeFromHash()));

setRoute(routeFromHash());
bootstrap();
