import uuid

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .db import get_db
from .models import User


async def current_user_id(
    x_auth_request_user: str | None = Header(default=None),
    x_auth_request_email: str | None = Header(default=None),
    x_hublog_user_id: str | None = Header(default=None),
    db: AsyncSession = Depends(get_db),
) -> uuid.UUID:
    settings = get_settings()
    raw = x_hublog_user_id if settings.allow_dev_auth else (x_auth_request_user or x_auth_request_email)
    if not raw:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="authentication required")
    try:
        identity = uuid.UUID(raw)
        user = await db.get(User, identity)
    except ValueError:
        user = await db.scalar(select(User).where(or_(User.username == raw, User.email == raw)))
    if not user or user.status != "active":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="unknown or inactive user")
    return user.id


async def optional_user_id(
    x_auth_request_user: str | None = Header(default=None),
    x_auth_request_email: str | None = Header(default=None),
    x_hublog_user_id: str | None = Header(default=None),
    db: AsyncSession = Depends(get_db),
) -> uuid.UUID | None:
    settings = get_settings()
    raw = x_hublog_user_id if settings.allow_dev_auth else (x_auth_request_user or x_auth_request_email)
    if not raw:
        return None
    try:
        identity = uuid.UUID(raw)
        user = await db.get(User, identity)
    except ValueError:
        user = await db.scalar(select(User).where(or_(User.username == raw, User.email == raw)))
    return user.id if user and user.status == "active" else None
