import hashlib
import re
import uuid

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .db import get_db
from .models import User


def _username(value: str | None, subject: str) -> str:
    value = (value or "").strip().lower()
    value = re.sub(r"[^a-z0-9_-]+", "_", value).strip("_-")
    if len(value) < 2:
        value = "user"
    suffix = hashlib.sha256(subject.encode()).hexdigest()[:10]
    return f"{value[:48]}_{suffix}"


async def _resolve_user(
    *,
    db: AsyncSession,
    subject: str | None,
    forwarded_user: str | None,
    forwarded_email: str | None,
    preferred_username: str | None,
    dev_user_id: str | None,
    required: bool,
) -> uuid.UUID | None:
    settings = get_settings()

    if settings.allow_dev_auth and dev_user_id:
        try:
            user_id = uuid.UUID(dev_user_id)
        except ValueError as exc:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid development user identity") from exc
        user = await db.get(User, user_id)
        if not user:
            user = User(
                id=user_id,
                username=f"dev_{str(user_id).replace('-', '')[:12]}",
                display_name="Development User",
            )
            db.add(user)
            await db.commit()
        if user.status != "active":
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="user is inactive")
        return user.id

    if not subject:
        if required:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="SSO authentication required")
        return None

    user = await db.scalar(select(User).where(User.sso_subject == subject))
    if user:
        if user.status != "active":
            if required:
                raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="user is inactive")
            return None
        return user.id

    if not settings.sso_auto_provision:
        if required:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="SSO user is not registered")
        return None

    # An existing unbound account may be linked by a verified SSO email.
    if forwarded_email:
        user = await db.scalar(select(User).where(User.email == forwarded_email))
        if user and user.sso_subject is None:
            if user.status != "active":
                raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="user is inactive")
            user.sso_subject = subject
            await db.commit()
            return user.id

    source_name = preferred_username or (forwarded_email.split("@", 1)[0] if forwarded_email else None) or forwarded_user
    user = User(
        sso_subject=subject,
        username=_username(source_name, subject),
        display_name=(preferred_username or source_name or "Hublog User")[:128],
        email=forwarded_email,
    )
    db.add(user)
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        # Concurrent first requests can race; the unique SSO subject resolves that safely.
        user = await db.scalar(select(User).where(User.sso_subject == subject))
        if not user:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="SSO account could not be provisioned")
    return user.id


async def current_user_id(
    x_auth_request_sub: str | None = Header(default=None),
    x_forwarded_user: str | None = Header(default=None),
    x_forwarded_email: str | None = Header(default=None),
    x_forwarded_preferred_username: str | None = Header(default=None),
    x_hublog_user_id: str | None = Header(default=None),
    db: AsyncSession = Depends(get_db),
) -> uuid.UUID:
    user_id = await _resolve_user(
        db=db,
        # oauth2-proxy's standard X-Forwarded-User is the configured OIDC
        # userIDClaim (sub); keep it as a compatibility fallback.
        subject=x_auth_request_sub or x_forwarded_user,
        forwarded_user=x_forwarded_user,
        forwarded_email=x_forwarded_email,
        preferred_username=x_forwarded_preferred_username,
        dev_user_id=x_hublog_user_id,
        required=True,
    )
    assert user_id is not None
    return user_id


async def optional_user_id(
    x_auth_request_sub: str | None = Header(default=None),
    x_forwarded_user: str | None = Header(default=None),
    x_forwarded_email: str | None = Header(default=None),
    x_forwarded_preferred_username: str | None = Header(default=None),
    x_hublog_user_id: str | None = Header(default=None),
    db: AsyncSession = Depends(get_db),
) -> uuid.UUID | None:
    return await _resolve_user(
        db=db,
        subject=x_auth_request_sub or x_forwarded_user,
        forwarded_user=x_forwarded_user,
        forwarded_email=x_forwarded_email,
        preferred_username=x_forwarded_preferred_username,
        dev_user_id=x_hublog_user_id,
        required=False,
    )
