import hashlib
import hmac
import json
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .db import get_db
from .models import User


@dataclass(frozen=True)
class ServiceIdentity:
    """Identity bound to a Vault-managed, hash-only service token."""

    name: str
    subject: str
    username: str
    display_name: str
    email: str | None
    expires_at: datetime | None


def _username(value: str | None, subject: str) -> str:
    value = (value or "").strip().lower()
    value = re.sub(r"[^a-z0-9_-]+", "_", value).strip("_-")
    if len(value) < 2:
        value = "user"
    suffix = hashlib.sha256(subject.encode()).hexdigest()[:10]
    return f"{value[:48]}_{suffix}"


def _parse_expiry(value: Any) -> datetime | None:
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, tz=timezone.utc)
    parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _configured_service_tokens() -> list[tuple[str, str, ServiceIdentity]]:
    """Parse the JSON token map without ever materializing a plaintext token."""
    settings = get_settings()
    raw = ""
    if settings.service_tokens_file:
        try:
            raw = Path(settings.service_tokens_file).read_text(encoding="utf-8").strip()
        except (FileNotFoundError, IsADirectoryError, PermissionError):
            pass
    # Local development and older deployments can continue using envFrom.
    if not raw:
        raw = settings.service_tokens_json.strip()
    if not raw:
        return []
    try:
        document = json.loads(raw)
    except (TypeError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="service authentication is misconfigured") from exc

    if isinstance(document, dict):
        entries = [(str(name), value) for name, value in document.items()]
    elif isinstance(document, list):
        entries = [(str(value.get("name", "")), value) for value in document if isinstance(value, dict)]
    else:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="service authentication is misconfigured")

    configured: list[tuple[str, str, ServiceIdentity]] = []
    subjects: set[str] = set()
    usernames: set[str] = set()
    for name, value in entries:
        if not name or not isinstance(value, dict):
            continue
        token_hash = str(value.get("token_hash", "")).strip().lower()
        subject = str(value.get("subject") or f"service:{name}").strip()
        username = str(value.get("username", "")).strip()
        display_name = str(value.get("display_name") or username or name).strip()
        if not re.fullmatch(r"[a-zA-Z0-9_-]{2,64}", username):
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="service authentication is misconfigured")
        if not re.fullmatch(r"[0-9a-f]{64}", token_hash) or not subject.startswith("service:"):
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="service authentication is misconfigured")
        try:
            expires_at = _parse_expiry(value.get("expires_at"))
        except (TypeError, ValueError, OverflowError) as exc:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="service authentication is misconfigured") from exc
        if expires_at is None or subject in subjects or username in usernames:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="service authentication is misconfigured")
        subjects.add(subject)
        usernames.add(username)
        configured.append((name, token_hash, ServiceIdentity(
            name=name,
            subject=subject,
            username=username,
            display_name=display_name[:128],
            email=str(value["email"]).strip()[:320] if value.get("email") else None,
            expires_at=expires_at,
        )))
    return configured


def _service_identity_from_authorization(authorization: str | None) -> ServiceIdentity | None:
    if not authorization:
        return None
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid service authorization")
    presented_hash = hashlib.sha256(token.strip().encode("utf-8")).hexdigest()
    now = datetime.now(timezone.utc)
    for _, token_hash, identity in _configured_service_tokens():
        if hmac.compare_digest(presented_hash, token_hash):
            if identity.expires_at and identity.expires_at <= now:
                raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="service token expired")
            return identity
    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid service token")


async def _resolve_user(
    *,
    db: AsyncSession,
    subject: str | None,
    forwarded_user: str | None,
    forwarded_email: str | None,
    preferred_username: str | None,
    dev_user_id: str | None,
    service_identity: ServiceIdentity | None,
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

    if service_identity:
        user = await db.scalar(select(User).where(User.sso_subject == service_identity.subject))
        if user:
            if user.status != "active":
                raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="service user is inactive")
            return user.id
        if not settings.service_auto_provision:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="service user is not registered")
        user = User(
            sso_subject=service_identity.subject,
            username=service_identity.username,
            display_name=service_identity.display_name,
            email=service_identity.email,
        )
        db.add(user)
        try:
            await db.commit()
        except IntegrityError:
            await db.rollback()
            user = await db.scalar(select(User).where(User.sso_subject == service_identity.subject))
            if not user:
                raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="service user could not be provisioned")
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
    authorization: str | None = Header(default=None),
    x_auth_request_sub: str | None = Header(default=None),
    x_forwarded_user: str | None = Header(default=None),
    x_forwarded_email: str | None = Header(default=None),
    x_forwarded_preferred_username: str | None = Header(default=None),
    x_hublog_user_id: str | None = Header(default=None),
    db: AsyncSession = Depends(get_db),
) -> uuid.UUID:
    service_identity = _service_identity_from_authorization(authorization)
    user_id = await _resolve_user(
        db=db,
        # oauth2-proxy's standard X-Forwarded-User is the configured OIDC
        # userIDClaim (sub); keep it as a compatibility fallback.
        subject=x_auth_request_sub or x_forwarded_user,
        forwarded_user=x_forwarded_user,
        forwarded_email=x_forwarded_email,
        preferred_username=x_forwarded_preferred_username,
        dev_user_id=x_hublog_user_id,
        service_identity=service_identity,
        required=True,
    )
    assert user_id is not None
    return user_id


async def optional_user_id(
    authorization: str | None = Header(default=None),
    x_auth_request_sub: str | None = Header(default=None),
    x_forwarded_user: str | None = Header(default=None),
    x_forwarded_email: str | None = Header(default=None),
    x_forwarded_preferred_username: str | None = Header(default=None),
    x_hublog_user_id: str | None = Header(default=None),
    db: AsyncSession = Depends(get_db),
) -> uuid.UUID | None:
    service_identity = _service_identity_from_authorization(authorization)
    return await _resolve_user(
        db=db,
        subject=x_auth_request_sub or x_forwarded_user,
        forwarded_user=x_forwarded_user,
        forwarded_email=x_forwarded_email,
        preferred_username=x_forwarded_preferred_username,
        dev_user_id=x_hublog_user_id,
        service_identity=service_identity,
        required=False,
    )
