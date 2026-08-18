import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator


class UserCreate(BaseModel):
    username: str = Field(min_length=2, max_length=64, pattern=r"^[a-zA-Z0-9_\-]+$")
    display_name: str = Field(min_length=1, max_length=128)
    email: str | None = Field(default=None, max_length=320)


class UserRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    username: str
    display_name: str
    email: str | None
    avatar_url: str | None
    bio: str | None
    status: str
    created_at: datetime
    follower_count: int = 0
    following_count: int = 0
    is_following: bool = False


class UserRelationshipRead(BaseModel):
    following: bool
    follower_count: int
    following_count: int


class PostCreate(BaseModel):
    post_type: str = Field(default="short", pattern=r"^(short|article)$")
    visibility: str = Field(default="public", pattern=r"^(public|followers|private)$")
    title: str | None = Field(default=None, max_length=300)
    content: str = Field(min_length=1, max_length=200_000)
    tags: list[str] = Field(default_factory=list, max_length=20)


class PostRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    author_id: uuid.UUID
    post_type: str
    status: str
    visibility: str
    title: str | None
    content: str
    tags: list[str]
    version: int
    comment_count: int
    created_at: datetime
    updated_at: datetime


class FeedPage(BaseModel):
    items: list[PostRead]
    next_cursor: str | None
    limit: int


class CommentCreate(BaseModel):
    content: str = Field(min_length=1, max_length=2_000)
    parent_comment_id: uuid.UUID | None = None

    @field_validator("content")
    @classmethod
    def content_must_not_be_blank(cls, value: str) -> str:
        content = value.strip()
        if not content:
            raise ValueError("comment content cannot be blank")
        return content


class CommentRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    post_id: uuid.UUID
    author_id: uuid.UUID
    parent_comment_id: uuid.UUID | None
    reply_to_user_id: uuid.UUID | None
    content: str
    status: str
    version: int
    created_at: datetime
    updated_at: datetime


class CommentPage(BaseModel):
    items: list[CommentRead]
    next_cursor: str | None
    limit: int
    total_count: int


class NotificationRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    recipient_id: uuid.UUID
    actor_id: uuid.UUID
    notification_type: str
    post_id: uuid.UUID | None
    comment_id: uuid.UUID | None
    data: dict
    read_at: datetime | None
    created_at: datetime


class NotificationPage(BaseModel):
    items: list[NotificationRead]
    next_cursor: str | None
    limit: int
    unread_count: int
