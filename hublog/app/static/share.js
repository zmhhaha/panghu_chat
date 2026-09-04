const shareId = decodeURIComponent(window.location.pathname.split("/").filter(Boolean).pop() || "");
const shareState = { post: null, comments: [], cursor: null, loadingMore: false };
const shareElements = {
  card: document.querySelector("#share-card"),
  status: document.querySelector("#share-status"),
  commentsStatus: document.querySelector("#comments-status"),
  commentList: document.querySelector("#comment-list"),
  commentMore: document.querySelector("#comment-more"),
  loginLink: document.querySelector("#login-link"),
  loginHint: document.querySelector(".share-login-hint"),
  commentForm: document.querySelector("#comment-form"),
  commentContent: document.querySelector("#comment-content"),
};

const dateFormatter = new Intl.DateTimeFormat("zh-CN", {
  month: "short",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});

function setShareError(message) {
  shareElements.card.replaceChildren();
  const error = document.createElement("div");
  error.className = "share-error";
  error.textContent = message;
  shareElements.card.append(error);
  shareElements.commentsStatus.textContent = "暂不可用";
}

async function requestJson(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    ...options,
    headers: {
      Accept: "application/json",
      ...(options.body ? { "Content-Type": "application/json" } : {}),
      ...(options.headers || {}),
    },
  });
  const contentType = response.headers.get("content-type") || "";
  const payload = contentType.includes("application/json") ? await response.json() : null;
  if (!response.ok) {
    const detail = typeof payload?.detail === "string" ? payload.detail : `请求失败 (${response.status})`;
    throw new Error(detail);
  }
  return payload;
}

function initials(user) {
  return Array.from((user?.display_name || user?.username || "虎").trim()).slice(0, 1).join("").toUpperCase();
}

function avatar(user, className = "share-avatar") {
  const node = document.createElement("span");
  node.className = className;
  node.textContent = initials(user);
  return node;
}

function renderShare(data) {
  const post = data.post;
  shareState.post = post;
  shareElements.status.textContent = "公开分享";
  shareElements.card.replaceChildren();

  const header = document.createElement("div");
  header.className = "share-post-header";
  header.append(avatar(post.author, "share-avatar share-avatar-large"));
  const identity = document.createElement("div");
  identity.className = "share-post-identity";
  const name = document.createElement("strong");
  name.textContent = post.author.display_name;
  const username = document.createElement("span");
  username.textContent = `@${post.author.username}`;
  const time = document.createElement("time");
  time.dateTime = post.created_at;
  time.textContent = dateFormatter.format(new Date(post.created_at));
  identity.append(name, username, time);
  header.append(identity);
  shareElements.card.append(header);

  if (post.title) {
    const title = document.createElement("h1");
    title.textContent = post.title;
    shareElements.card.append(title);
  }
  const content = document.createElement("p");
  content.className = "share-post-content";
  content.textContent = post.content;
  shareElements.card.append(content);
  if (post.tags?.length) {
    const tags = document.createElement("div");
    tags.className = "share-post-tags";
    post.tags.forEach((tagValue) => {
      const tag = document.createElement("span");
      tag.textContent = `#${tagValue}`;
      tags.append(tag);
    });
    shareElements.card.append(tags);
  }
  const meta = document.createElement("div");
  meta.className = "share-post-meta";
  meta.textContent = `${post.comment_count || 0} 条评论`;
  shareElements.card.append(meta);
}

function renderComments() {
  shareElements.commentList.replaceChildren();
  if (!shareState.comments.length) {
    const empty = document.createElement("p");
    empty.className = "share-comments-empty";
    empty.textContent = "还没有评论";
    shareElements.commentList.append(empty);
  } else {
    const fragment = document.createDocumentFragment();
    shareState.comments.forEach((comment) => {
      const row = document.createElement("article");
      row.className = "share-comment-row";
      row.append(avatar(comment.author));
      const body = document.createElement("div");
      body.className = "share-comment-body";
      const heading = document.createElement("div");
      heading.className = "share-comment-heading";
      const name = document.createElement("strong");
      name.textContent = comment.author.display_name;
      const username = document.createElement("span");
      username.textContent = `@${comment.author.username}`;
      const time = document.createElement("time");
      time.dateTime = comment.created_at;
      time.textContent = dateFormatter.format(new Date(comment.created_at));
      heading.append(name, username, time);
      const content = document.createElement("p");
      content.textContent = comment.content;
      body.append(heading, content);
      row.append(body);
      fragment.append(row);
    });
    shareElements.commentList.append(fragment);
  }
  shareElements.commentMore.classList.toggle("is-hidden", !shareState.cursor);
  shareElements.commentsStatus.textContent = shareState.comments.length ? `${shareState.comments.length} 条已载入` : "暂无评论";
}

async function loadComments({ append = false } = {}) {
  if (!shareState.post || shareState.loadingMore) return;
  if (append && !shareState.cursor) return;
  shareState.loadingMore = true;
  const query = append ? `?limit=20&cursor=${encodeURIComponent(shareState.cursor)}` : "?limit=20";
  try {
    const page = await requestJson(`/api/v1/shares/${encodeURIComponent(shareId)}/comments${query}`);
    const existing = new Set(shareState.comments.map((comment) => comment.id));
    shareState.comments = append
      ? [...shareState.comments, ...page.items.filter((comment) => !existing.has(comment.id))]
      : page.items;
    shareState.cursor = page.next_cursor;
    renderComments();
  } catch (error) {
    shareElements.commentsStatus.textContent = "评论加载失败";
    if (!append) {
      const failure = document.createElement("p");
      failure.className = "share-comments-empty";
      failure.textContent = error.message;
      shareElements.commentList.replaceChildren(failure);
    }
  } finally {
    shareState.loadingMore = false;
  }
}

function loginReturnPath() {
  return `${window.location.pathname}${window.location.search}`;
}

async function loadSession() {
  try {
    const response = await fetch("/api/v1/auth/session", {
      credentials: "same-origin",
      redirect: "manual",
      headers: { Accept: "application/json" },
    });
    if (!response.ok || !(response.headers.get("content-type") || "").includes("application/json")) return;
    await response.json();
    shareElements.loginHint.classList.add("is-hidden");
    shareElements.loginLink.classList.add("is-hidden");
    shareElements.commentForm.classList.remove("is-hidden");
  } catch {
    // A protected request becomes a redirect for anonymous visitors.
  }
}

async function submitComment(event) {
  event.preventDefault();
  const content = shareElements.commentContent.value.trim();
  if (!content || !shareState.post) return;
  const submit = shareElements.commentForm.querySelector("button");
  submit.disabled = true;
  try {
    await requestJson(`/api/v1/posts/${encodeURIComponent(shareState.post.id)}/comments`, {
      method: "POST",
      body: JSON.stringify({ content, parent_comment_id: null }),
    });
    shareElements.commentContent.value = "";
    shareState.cursor = null;
    await loadComments();
  } catch (error) {
    window.alert(error.message);
  } finally {
    submit.disabled = false;
  }
}

async function bootstrapShare() {
  if (!shareId) {
    setShareError("分享链接无效");
    return;
  }
  shareElements.loginLink.href = `/oauth2/start?rd=${encodeURIComponent(loginReturnPath())}`;
  try {
    const data = await requestJson(`/api/v1/shares/${encodeURIComponent(shareId)}`);
    renderShare(data);
    await loadComments();
    await loadSession();
  } catch (error) {
    setShareError("分享不存在、已过期、已撤销或原虎博已不可见");
  }
}

shareElements.commentMore.addEventListener("click", () => loadComments({ append: true }));
shareElements.commentForm.addEventListener("submit", submitComment);
bootstrapShare();
