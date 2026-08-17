import base64
import binascii
import logging
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import and_, delete, exists, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .auth import current_user_id, optional_user_id
from .config import get_settings
from .db import get_db, init_schema, ping_db
from .models import Comment, Follow, OutboxEvent, Post, User
from .redis_bus import ping_redis
from .schemas import CommentCreate, CommentPage, CommentRead, FeedPage, PostCreate, PostRead, UserRead

logger = logging.getLogger("hublog")
settings = get_settings()
static_dir = Path(__file__).resolve().parent / "static"


@asynccontextmanager
async def lifespan(_: FastAPI):
    if settings.auto_create_schema:
        await init_schema()
    yield


app = FastAPI(title="Hublog API", version=settings.app_version, lifespan=lifespan)
app.mount("/assets", StaticFiles(directory=static_dir), name="assets")


@app.get("/", include_in_schema=False)
async def web_app():
    return FileResponse(static_dir / "index.html")


def cursor_value(value: str | None) -> tuple[datetime, uuid.UUID] | None:
    if not value:
        return None
    try:
        raw = base64.urlsafe_b64decode(value.encode()).decode()
        timestamp, post_id = raw.split("|", 1)
        return datetime.fromisoformat(timestamp).astimezone(timezone.utc), uuid.UUID(post_id)
    except (ValueError, UnicodeError, binascii.Error) as exc:
        raise HTTPException(status_code=400, detail="invalid cursor") from exc


def next_cursor(value: datetime, post_id: uuid.UUID) -> str:
    raw = f"{value.astimezone(timezone.utc).isoformat()}|{post_id}"
    return base64.urlsafe_b64encode(raw.encode()).decode()


async def post_page(*, conditions: list, cursor: str | None, limit: int, db: AsyncSession) -> FeedPage:
    query_conditions = list(conditions)
    before = cursor_value(cursor)
    if before:
        timestamp, post_id = before
        query_conditions.append(or_(Post.created_at < timestamp, and_(Post.created_at == timestamp, Post.id < post_id)))
    rows = (await db.scalars(
        select(Post)
        .where(and_(*query_conditions))
        .order_by(Post.created_at.desc(), Post.id.desc())
        .limit(limit + 1)
    )).all()
    has_more = len(rows) > limit
    items = rows[:limit]
    return FeedPage(
        items=items,
        next_cursor=next_cursor(items[-1].created_at, items[-1].id) if has_more and items else None,
        limit=limit,
    )


async def visible_post(post_id: uuid.UUID, me: uuid.UUID | None, db: AsyncSession) -> Post:
    post = await db.scalar(select(Post).where(Post.id == post_id, Post.status == "published"))
    if not post:
        raise HTTPException(status_code=404, detail="post not found")
    if post.visibility == "private" and post.author_id != me:
        raise HTTPException(status_code=404, detail="post not found")
    if post.visibility == "followers" and post.author_id != me:
        if not me:
            raise HTTPException(status_code=404, detail="post not found")
        allowed = await db.scalar(select(exists().where(
            Follow.follower_id == me,
            Follow.followee_id == post.author_id,
            Follow.status == "active",
        )))
        if not allowed:
            raise HTTPException(status_code=404, detail="post not found")
    return post


async def comment_page(*, post_id: uuid.UUID, cursor: str | None, limit: int, db: AsyncSession) -> CommentPage:
    conditions = [Comment.post_id == post_id, Comment.status == "published"]
    before = cursor_value(cursor)
    if before:
        timestamp, comment_id = before
        conditions.append(or_(Comment.created_at < timestamp, and_(Comment.created_at == timestamp, Comment.id < comment_id)))
    rows = (await db.scalars(
        select(Comment)
        .where(and_(*conditions))
        .order_by(Comment.created_at.desc(), Comment.id.desc())
        .limit(limit + 1)
    )).all()
    has_more = len(rows) > limit
    items = rows[:limit]
    return CommentPage(
        items=items,
        next_cursor=next_cursor(items[-1].created_at, items[-1].id) if has_more and items else None,
        limit=limit,
    )


@app.middleware("http")
async def request_context(request: Request, call_next):
    request_id = request.headers.get("X-Request-Id", str(uuid.uuid4()))
    response: Response = await call_next(request)
    response.headers["X-Request-Id"] = request_id
    return response


@app.get("/health/live")
async def live():
    return {"status": "ok", "service": settings.app_name, "version": settings.app_version}


@app.get("/health/ready")
async def ready():
    checks = {}
    try:
        await ping_db()
        checks["postgres"] = "ok"
    except Exception as exc:  # readiness should return a useful diagnostic without exposing internals
        logger.warning("postgres readiness failed: %s", exc)
        checks["postgres"] = "failed"
    try:
        await ping_redis()
        checks["redis"] = "ok"
    except Exception as exc:
        logger.warning("redis readiness failed: %s", exc)
        checks["redis"] = "failed"
    if any(value != "ok" for value in checks.values()):
        raise HTTPException(status_code=503, detail={"status": "not_ready", "checks": checks})
    return {"status": "ok", "checks": checks}


@app.get("/api/v1/auth/session", response_model=UserRead)
async def auth_session(me: uuid.UUID = Depends(current_user_id), db: AsyncSession = Depends(get_db)):
    user = await db.get(User, me)
    if not user:
        raise HTTPException(status_code=404, detail="user not found")
    return user


@app.get("/api/v1/users/{user_id}", response_model=UserRead)
async def get_user(user_id: uuid.UUID, db: AsyncSession = Depends(get_db)):
    user = await db.get(User, user_id)
    if not user or user.status != "active":
        raise HTTPException(status_code=404, detail="user not found")
    return user


@app.post("/api/v1/users/{user_id}/follow", status_code=204)
async def follow_user(user_id: uuid.UUID, me: uuid.UUID = Depends(current_user_id), db: AsyncSession = Depends(get_db)):
    if user_id == me:
        raise HTTPException(status_code=400, detail="cannot follow yourself")
    if not await db.get(User, user_id):
        raise HTTPException(status_code=404, detail="user not found")
    record = await db.scalar(select(Follow).where(Follow.follower_id == me, Follow.followee_id == user_id))
    if record:
        record.status = "active"
    else:
        db.add(Follow(follower_id=me, followee_id=user_id))
    await db.commit()


@app.delete("/api/v1/users/{user_id}/follow", status_code=204)
async def unfollow_user(user_id: uuid.UUID, me: uuid.UUID = Depends(current_user_id), db: AsyncSession = Depends(get_db)):
    await db.execute(delete(Follow).where(Follow.follower_id == me, Follow.followee_id == user_id))
    await db.commit()


@app.post("/api/v1/posts", response_model=PostRead, status_code=201)
async def create_post(payload: PostCreate, me: uuid.UUID = Depends(current_user_id), db: AsyncSession = Depends(get_db)):
    if not await db.get(User, me):
        raise HTTPException(status_code=404, detail="user not found")
    post = Post(author_id=me, **payload.model_dump())
    db.add(post)
    await db.flush()
    db.add(OutboxEvent(event_type="PostPublished", aggregate_id=post.id, aggregate_version=post.version, payload={"post_id": str(post.id), "author_id": str(me)}))
    await db.commit()
    await db.refresh(post)
    return post


@app.get("/api/v1/posts/{post_id}", response_model=PostRead)
async def get_post(post_id: uuid.UUID, me: uuid.UUID | None = Depends(optional_user_id), db: AsyncSession = Depends(get_db)):
    return await visible_post(post_id, me, db)


@app.get("/api/v1/posts/{post_id}/comments", response_model=CommentPage)
async def get_comments(post_id: uuid.UUID, cursor: str | None = Query(default=None), limit: int = Query(default=20, ge=1, le=100), me: uuid.UUID | None = Depends(optional_user_id), db: AsyncSession = Depends(get_db)):
    await visible_post(post_id, me, db)
    return await comment_page(post_id=post_id, cursor=cursor, limit=limit, db=db)


@app.post("/api/v1/posts/{post_id}/comments", response_model=CommentRead, status_code=201)
async def create_comment(post_id: uuid.UUID, payload: CommentCreate, me: uuid.UUID = Depends(current_user_id), db: AsyncSession = Depends(get_db)):
    await visible_post(post_id, me, db)
    comment = Comment(post_id=post_id, author_id=me, content=payload.content)
    db.add(comment)
    await db.flush()
    db.add(OutboxEvent(
        event_type="CommentPublished",
        aggregate_id=comment.id,
        aggregate_version=comment.version,
        payload={"comment_id": str(comment.id), "post_id": str(post_id), "author_id": str(me)},
    ))
    await db.commit()
    await db.refresh(comment)
    return comment


@app.delete("/api/v1/comments/{comment_id}", status_code=204)
async def delete_comment(comment_id: uuid.UUID, me: uuid.UUID = Depends(current_user_id), db: AsyncSession = Depends(get_db)):
    comment = await db.get(Comment, comment_id)
    if not comment or comment.status != "published" or comment.author_id != me:
        raise HTTPException(status_code=404, detail="comment not found")
    comment.status = "deleted"
    comment.deleted_at = datetime.now(timezone.utc)
    comment.version += 1
    db.add(OutboxEvent(
        event_type="CommentDeleted",
        aggregate_id=comment.id,
        aggregate_version=comment.version,
        payload={"comment_id": str(comment.id), "post_id": str(comment.post_id), "author_id": str(me)},
    ))
    await db.commit()


@app.delete("/api/v1/posts/{post_id}", status_code=204)
async def delete_post(post_id: uuid.UUID, me: uuid.UUID = Depends(current_user_id), db: AsyncSession = Depends(get_db)):
    post = await db.get(Post, post_id)
    if not post or post.author_id != me:
        raise HTTPException(status_code=404, detail="post not found")
    post.status = "deleted"
    post.deleted_at = datetime.now(timezone.utc)
    post.version += 1
    db.add(OutboxEvent(event_type="PostDeleted", aggregate_id=post.id, aggregate_version=post.version, payload={"post_id": str(post.id), "author_id": str(me)}))
    await db.commit()


@app.get("/api/v1/me/posts", response_model=FeedPage)
async def my_posts(cursor: str | None = Query(default=None), limit: int = Query(default=20, ge=1, le=settings.feed_max_limit), me: uuid.UUID = Depends(current_user_id), db: AsyncSession = Depends(get_db)):
    return await post_page(
        conditions=[Post.status == "published", Post.author_id == me],
        cursor=cursor,
        limit=limit,
        db=db,
    )


@app.get("/api/v1/feed", response_model=FeedPage)
async def feed(cursor: str | None = Query(default=None), limit: int = Query(default=20, ge=1, le=settings.feed_max_limit), me: uuid.UUID | None = Depends(optional_user_id), db: AsyncSession = Depends(get_db)):
    visibility = [Post.visibility == "public"]
    if me:
        visibility.extend([
            and_(Post.visibility == "private", Post.author_id == me),
            and_(Post.visibility == "followers", or_(
                Post.author_id == me,
                exists().where(Follow.follower_id == me, Follow.followee_id == Post.author_id, Follow.status == "active"),
            )),
        ])
    return await post_page(
        conditions=[Post.status == "published", or_(*visibility)],
        cursor=cursor,
        limit=limit,
        db=db,
    )
