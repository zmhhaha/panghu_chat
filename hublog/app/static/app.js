const state = {
  me: null,
  posts: [],
  users: new Map(),
  feedScope: "all",
  cursor: null,
  profilePosts: [],
  profileCursor: null,
  profileLoading: false,
  profileLoaded: false,
  comments: new Map(),
  notifications: [],
  notificationCursor: null,
  notificationsLoaded: false,
  notificationsLoading: false,
  notificationsOpen: false,
  unreadNotificationCount: 0,
  mode: "short",
  loading: false,
  feedRequestVersion: 0,
};

const elements = {
  composeForm: document.querySelector("#compose-form"),
  content: document.querySelector("#post-content"),
  title: document.querySelector("#post-title"),
  tags: document.querySelector("#post-tags"),
  visibility: document.querySelector("#post-visibility"),
  publish: document.querySelector("#publish-button"),
  feedList: document.querySelector("#feed-list"),
  feedTitle: document.querySelector("#feed-title"),
  feedStatus: document.querySelector("#feed-status"),
  loadMore: document.querySelector("#load-more"),
  feedScopeButtons: [...document.querySelectorAll("[data-feed-scope]")],
  notificationsButton: document.querySelector("#notifications-button"),
  notificationsBadge: document.querySelector("#notifications-badge"),
  notificationsPanel: document.querySelector("#notifications-panel"),
  notificationsList: document.querySelector("#notifications-list"),
  notificationsStatus: document.querySelector("#notifications-status"),
  notificationsMarkAll: document.querySelector("#notifications-mark-all"),
  notificationWrap: document.querySelector("#notification-wrap"),
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

function notificationActor(notification) {
  return state.users.get(notification.actor_id) || {
    id: notification.actor_id,
    username: "unknown",
    display_name: "虎博用户",
  };
}

function notificationMessage(notification) {
  const actor = notificationActor(notification);
  if (notification.notification_type === "follow") return `${actor.display_name} 关注了你`;
  if (notification.notification_type === "reply") return `${actor.display_name} 回复了你的评论`;
  return `${actor.display_name} 评论了你的虎博`;
}

function renderNotificationBadge() {
  const count = state.unreadNotificationCount;
  elements.notificationsBadge.textContent = count > 99 ? "99+" : String(count);
  elements.notificationsBadge.classList.toggle("is-hidden", count < 1);
  elements.notificationsButton.setAttribute("aria-label", count ? `通知，${count} 条未读` : "通知");
}

function renderNotifications() {
  renderNotificationBadge();
  elements.notificationsPanel.classList.toggle("is-hidden", !state.notificationsOpen);
  elements.notificationsButton.setAttribute("aria-expanded", String(state.notificationsOpen));
  elements.notificationsStatus.textContent = state.notificationsLoading ? "正在加载" : "";
  elements.notificationsMarkAll.disabled = state.notificationsLoading || state.unreadNotificationCount < 1;
  elements.notificationsList.replaceChildren();
  if (!state.notifications.length && !state.notificationsLoading) {
    const empty = document.createElement("p");
    empty.className = "notifications-empty";
    empty.textContent = "暂时没有新通知";
    elements.notificationsList.append(empty);
    return;
  }
  const fragment = document.createDocumentFragment();
  state.notifications.forEach((notification) => {
    const actor = notificationActor(notification);
    const item = document.createElement("button");
    item.className = "notification-item";
    item.type = "button";
    item.classList.toggle("is-unread", !notification.read_at);
    item.dataset.notificationId = notification.id;
    item.append(createAvatar(actor, "avatar-notification"));
    const body = document.createElement("span");
    body.className = "notification-body";
    const message = document.createElement("span");
    message.className = "notification-message";
    message.textContent = notificationMessage(notification);
    const time = document.createElement("time");
    time.className = "notification-time";
    time.dateTime = notification.created_at;
    time.textContent = dateFormatter.format(new Date(notification.created_at));
    body.append(message, time);
    item.append(body);
    item.addEventListener("click", () => openNotification(notification));
    fragment.append(item);
  });
  elements.notificationsList.append(fragment);
}

async function loadNotifications({ silent = false } = {}) {
  if (state.notificationsLoading) return;
  state.notificationsLoading = true;
  renderNotifications();
  try {
    const page = await api("/api/v1/notifications?limit=30");
    await hydrateUsers(page.items);
    state.notifications = page.items;
    state.notificationCursor = page.next_cursor;
    state.unreadNotificationCount = page.unread_count ?? state.notifications.filter((item) => !item.read_at).length;
    state.notificationsLoaded = true;
  } catch (error) {
    if (!silent) showToast(error.message, true);
  } finally {
    state.notificationsLoading = false;
    renderNotifications();
  }
}

async function markNotificationRead(notification) {
  if (notification.read_at) return;
  await api(`/api/v1/notifications/${notification.id}/read`, { method: "POST" });
  notification.read_at = new Date().toISOString();
  state.unreadNotificationCount = Math.max(0, state.unreadNotificationCount - 1);
  renderNotifications();
}

async function openNotification(notification) {
  try {
    await markNotificationRead(notification);
    if (!notification.post_id) {
      showToast(notificationMessage(notification));
      return;
    }
    const post = state.posts.find((item) => item.id === notification.post_id) ||
      await api(`/api/v1/posts/${notification.post_id}`);
    await hydrateUsers([post]);
    state.feedScope = "all";
    state.cursor = null;
    state.posts = [post, ...state.posts.filter((item) => item.id !== post.id)];
    state.notificationsOpen = false;
    renderNotifications();
    renderFeed();
    navigateTo("feed");
    window.requestAnimationFrame(() => {
      const article = document.querySelector(`.post[data-post-id="${post.id}"]`);
      article?.scrollIntoView({ behavior: "smooth", block: "center" });
      article?.classList.add("post-highlight");
      window.setTimeout(() => article?.classList.remove("post-highlight"), 1800);
    });
  } catch (error) {
    showToast(error.message, true);
  }
}

async function markAllNotificationsRead() {
  if (!state.unreadNotificationCount || elements.notificationsMarkAll.disabled) return;
  elements.notificationsMarkAll.disabled = true;
  try {
    await api("/api/v1/notifications/read-all", { method: "POST" });
    const now = new Date().toISOString();
    state.notifications.forEach((notification) => { if (!notification.read_at) notification.read_at = now; });
    state.unreadNotificationCount = 0;
    renderNotifications();
  } catch (error) {
    showToast(error.message, true);
    renderNotifications();
  }
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
  const ids = [...new Set(posts.flatMap((post) => [post.author_id, post.reply_to_user_id, post.actor_id].filter(Boolean)))].filter((id) => !state.users.has(id));
  await Promise.all(ids.map(async (id) => {
    try {
      state.users.set(id, await api(`/api/v1/users/${id}`));
    } catch {
      state.users.set(id, { id, username: "unknown", display_name: "虎博用户" });
    }
  }));
}

function updateFollowButton(button, user) {
  const following = Boolean(user?.is_following);
  button.textContent = following ? "已关注" : "关注";
  button.classList.toggle("is-following", following);
  button.setAttribute("aria-pressed", String(following));
  button.title = following ? `取消关注 @${user.username}` : `关注 @${user.username}`;
}

function refreshFollowButtons(userId) {
  const user = state.users.get(userId);
  if (!user) return;
  document.querySelectorAll(`[data-follow-user-id="${userId}"]`).forEach((button) => updateFollowButton(button, user));
}

async function toggleFollow(userId, button) {
  const user = state.users.get(userId);
  if (!user || userId === state.me?.id || button.disabled) return;
  const following = Boolean(user.is_following);
  button.disabled = true;
  try {
    await api(`/api/v1/users/${userId}/follow`, { method: following ? "DELETE" : "POST" });
    user.is_following = !following;
    user.follower_count = Math.max(0, (user.follower_count || 0) + (following ? -1 : 1));
    refreshFollowButtons(userId);
    if (following && state.feedScope === "following") {
      state.posts = state.posts.filter((post) => post.author_id !== userId);
      renderFeed();
    }
    showToast(following ? `已取消关注 @${user.username}` : `已关注 @${user.username}`);
  } catch (error) {
    showToast(error.message, true);
  } finally {
    button.disabled = false;
    updateFollowButton(button, user);
  }
}

function createAvatar(user, className = "avatar-post") {
  const avatar = document.createElement("span");
  avatar.className = `avatar ${className}`;
  avatar.textContent = initials(user);
  avatar.style.backgroundColor = avatarColor(user.id);
  return avatar;
}


function commentsFor(postId, totalCount) {
  if (!state.comments.has(postId)) {
    state.comments.set(postId, {
      items: [],
      totalCount: Number.isInteger(totalCount) ? totalCount : 0,
      cursor: null,
      expanded: false,
      loaded: false,
      loading: false,
      submitting: false,
      deleting: new Set(),
      replyingTo: null,
      error: null,
    });
  }
  const model = state.comments.get(postId);
  if (Number.isInteger(totalCount)) model.totalCount = totalCount;
  return model;
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
  if (comment.reply_to_user_id) {
    const replyTarget = state.users.get(comment.reply_to_user_id) || { username: "unknown" };
    const target = document.createElement("span");
    target.className = "reply-target";
    target.textContent = `回复 @${replyTarget.username}：`;
    content.append(target);
  }
  content.append(document.createTextNode(comment.content));
  body.append(header, content);

  const actions = document.createElement("div");
  actions.className = "comment-row-actions";
  const reply = document.createElement("button");
  reply.className = "comment-reply";
  reply.type = "button";
  reply.title = "回复评论";
  reply.setAttribute("aria-label", "回复评论");
  reply.innerHTML = '<svg aria-hidden="true"><use href="#icon-reply"/></svg><span>回复</span>';
  reply.addEventListener("click", () => replyToComment(comment.post_id, comment));
  actions.append(reply);

  if (state.me?.id === comment.author_id) {
    const remove = document.createElement("button");
    remove.className = "comment-delete";
    remove.type = "button";
    remove.title = "删除评论";
    remove.setAttribute("aria-label", "删除评论");
    remove.disabled = model.deleting.has(comment.id);
    remove.innerHTML = '<svg aria-hidden="true"><use href="#icon-trash"/></svg>';
    remove.addEventListener("click", () => deleteComment(comment.post_id, comment.id));
    actions.append(remove);
  }
  body.append(actions);
  row.append(body);
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
  const replyContext = document.createElement("div");
  replyContext.className = "comment-reply-context is-hidden";
  const replyLabel = document.createElement("span");
  replyLabel.className = "comment-reply-label";
  const cancelReply = document.createElement("button");
  cancelReply.className = "comment-reply-cancel";
  cancelReply.type = "button";
  cancelReply.title = "取消回复";
  cancelReply.setAttribute("aria-label", "取消回复");
  cancelReply.innerHTML = '<svg aria-hidden="true"><use href="#icon-x"/></svg>';
  cancelReply.addEventListener("click", () => clearReply(postId));
  replyContext.append(replyLabel, cancelReply);
  form.append(replyContext);
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
  count.textContent = String(model.totalCount);
  section.classList.toggle("is-hidden", !model.expanded);
  if (!model.expanded) return;

  const status = section.querySelector(".comment-status");
  if (model.loading && !model.loaded) status.textContent = "正在加载";
  else if (model.error) status.textContent = "加载失败";
  else if (!model.totalCount) status.textContent = "还没有评论";
  else status.textContent = `${model.totalCount} 条`;

  const list = section.querySelector(".comment-list");
  list.replaceChildren(...model.items.map((comment) => createCommentRow(comment, model)));

  const more = section.querySelector(".comment-more");
  more.classList.toggle("is-hidden", !model.error && !model.cursor);
  more.disabled = model.loading;
  more.textContent = model.error ? "重试" : "加载更早评论";

  const replyContext = section.querySelector(".comment-reply-context");
  const replyLabel = section.querySelector(".comment-reply-label");
  const replyTarget = model.replyingTo && (state.users.get(model.replyingTo.author_id) || { username: "unknown" });
  replyContext.classList.toggle("is-hidden", !model.replyingTo);
  replyLabel.textContent = model.replyingTo ? `回复 @${replyTarget.username}` : "";
  const input = section.querySelector(".comment-input");
  const submit = section.querySelector(".comment-submit");
  input.placeholder = model.replyingTo ? `回复 @${replyTarget.username}` : "写下评论";
  const commentDisabled = !model.loaded || model.loading || model.submitting;
  input.disabled = commentDisabled;
  submit.disabled = commentDisabled;
  submit.classList.toggle("is-loading", model.submitting);
}


function adjustCommentCount(postId, delta) {
  const model = commentsFor(postId);
  model.totalCount = Math.max(0, model.totalCount + delta);
  for (const posts of [state.posts, state.profilePosts]) {
    const post = posts.find((item) => item.id === postId);
    if (post) post.comment_count = Math.max(0, (post.comment_count || 0) + delta);
  }
}


function replyToComment(postId, comment) {
  const model = commentsFor(postId);
  model.replyingTo = comment;
  refreshCommentThreads(postId);
  const input = [...document.querySelectorAll(`.post[data-post-id="${postId}"] .comment-input`)]
    .find((candidate) => candidate.getClientRects().length);
  input?.focus();
}


function clearReply(postId) {
  commentsFor(postId).replyingTo = null;
  refreshCommentThreads(postId);
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
    model.totalCount = page.total_count ?? model.totalCount;
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
      body: JSON.stringify({ content, parent_comment_id: model.replyingTo?.id || null }),
    });
    await hydrateUsers([comment]);
    model.items = [comment, ...model.items.filter((item) => item.id !== comment.id)];
    adjustCommentCount(postId, 1);
    model.replyingTo = null;
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
    adjustCommentCount(postId, -1);
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
  commentsFor(post.id, post.comment_count || 0);
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
  if (state.me?.id !== post.author_id && user.username !== "unknown") {
    const follow = document.createElement("button");
    follow.className = "follow-button";
    follow.type = "button";
    follow.dataset.followUserId = post.author_id;
    follow.addEventListener("click", () => toggleFollow(post.author_id, follow));
    updateFollowButton(follow, user);
    header.append(follow);
  }
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
  const emptyText = state.feedScope === "following" ? "关注用户后，这里会显示他们的虎博" : "这里还没有虎博。";
  renderPostList(elements.feedList, state.posts, emptyText);
  elements.feedTitle.textContent = state.feedScope === "following" ? "关注流" : "全部虎博";
  elements.feedScopeButtons.forEach((button) => {
    const active = button.dataset.feedScope === state.feedScope;
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-selected", String(active));
  });
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
  const requestVersion = ++state.feedRequestVersion;
  state.loading = true;
  elements.refresh.classList.add("is-spinning");
  elements.feedStatus.textContent = "正在加载";
  try {
    const params = new URLSearchParams({ limit: "20" });
    if (state.feedScope === "following") params.set("scope", "following");
    if (append && state.cursor) params.set("cursor", state.cursor);
    const query = `?${params.toString()}`;
    const page = await api(`/api/v1/feed${query}`);
    if (requestVersion !== state.feedRequestVersion) return;
    await hydrateUsers(page.items);
    state.posts = append ? [...state.posts, ...page.items] : page.items;
    state.cursor = page.next_cursor;
    renderFeed();
  } catch (error) {
    if (requestVersion !== state.feedRequestVersion) return;
    elements.feedStatus.textContent = "加载失败";
    showToast(error.message, true);
  } finally {
    if (requestVersion === state.feedRequestVersion) {
      state.loading = false;
      elements.refresh.classList.remove("is-spinning");
    }
  }
}

function setFeedScope(scope) {
  if (scope !== "all" && scope !== "following") return;
  if (state.feedScope === scope && state.posts.length) return;
  state.feedRequestVersion += 1;
  state.loading = false;
  state.feedScope = scope;
  state.posts = [];
  state.cursor = null;
  renderFeed();
  loadFeed();
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
    await Promise.all([loadFeed(), loadNotifications()]);
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
elements.feedScopeButtons.forEach((button) => button.addEventListener("click", () => setFeedScope(button.dataset.feedScope)));
elements.notificationsButton.addEventListener("click", (event) => {
  event.stopPropagation();
  state.notificationsOpen = !state.notificationsOpen;
  renderNotifications();
  if (state.notificationsOpen && !state.notificationsLoaded) loadNotifications();
});
elements.notificationsMarkAll.addEventListener("click", markAllNotificationsRead);
document.addEventListener("click", (event) => {
  if (state.notificationsOpen && !elements.notificationWrap.contains(event.target)) {
    state.notificationsOpen = false;
    renderNotifications();
  }
});
document.querySelectorAll("[data-mode]").forEach((button) => button.addEventListener("click", () => setMode(button.dataset.mode)));
document.querySelectorAll(".nav-item").forEach((link) => link.addEventListener("click", (event) => {
  event.preventDefault();
  navigateTo(link.hash.slice(1));
}));
window.addEventListener("hashchange", () => setRoute(routeFromHash()));

setRoute(routeFromHash());
bootstrap();
window.setInterval(() => {
  if (document.visibilityState === "visible" && state.me) loadNotifications({ silent: true });
}, 45000);
