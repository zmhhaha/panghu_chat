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
    created_at: datetime
    updated_at: datetime


class FeedPage(BaseModel):
    items: list[PostRead]
    next_cursor: str | None
    limit: int


class CommentCreate(BaseModel):
    content: str = Field(min_length=1, max_length=2_000)

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
    content: str
    status: str
    version: int
    created_at: datetime
    updated_at: datetime


class CommentPage(BaseModel):
    items: list[CommentRead]
    next_cursor: str | None
    limit: int
