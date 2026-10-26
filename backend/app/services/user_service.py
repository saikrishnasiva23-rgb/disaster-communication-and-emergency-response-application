from __future__ import annotations

import logging
import uuid

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import AuthenticationError, ConflictError, NotFoundError
from app.core.security import hash_password, password_needs_rehash, verify_password
from app.db.models import User
from app.db.types import utcnow
from app.domain.enums import UserRole
from app.schemas.user import UserUpdate
from app.services import audit_service

logger = logging.getLogger("app.auth")


def _norm(value: str | None) -> str | None:
    return value.strip().lower() if value else None


async def get_user(session: AsyncSession, user_id: uuid.UUID) -> User | None:
    return await session.get(User, user_id)


async def require_user(session: AsyncSession, user_id: uuid.UUID) -> User:
    user = await get_user(session, user_id)
    if user is None:
        raise NotFoundError("User not found.", code="USER_NOT_FOUND")
    return user


async def get_by_login(session: AsyncSession, identifier: str) -> User | None:
    ident = _norm(identifier)
    return await session.scalar(
        select(User).where(or_(User.username == ident, User.email == ident))
    )


async def create_user(
    session: AsyncSession,
    *,
    username: str,
    password: str,
    role: UserRole,
    email: str | None = None,
    full_name: str | None = None,
    phone: str | None = None,
    actor: User | None = None,
    audit_action: str | None = None,
) -> User:
    username_n, email_n = _norm(username), _norm(email)
    if await session.scalar(select(User.id).where(User.username == username_n)):
        raise ConflictError("That username is already taken.", code="USERNAME_TAKEN")
    if email_n and await session.scalar(select(User.id).where(User.email == email_n)):
        raise ConflictError("That email is already registered.", code="EMAIL_TAKEN")

    user = User(
        username=username_n,
        email=email_n,
        full_name=full_name,
        phone=phone,
        password_hash=hash_password(password),
        role=role,
        is_active=True,
    )
    session.add(user)
    await session.flush()
    await audit_service.record(
        session,
        action=audit_action or ("USER_REGISTERED" if actor is None else "USER_CREATED"),
        entity_type="user",
        entity_id=user.id,
        actor=actor or user,
        details={"role": role},
    )
    logger.info("user_created", extra={"user_id": str(user.id), "role": role})
    return user


async def authenticate(session: AsyncSession, identifier: str, password: str) -> User:
    user = await get_by_login(session, identifier)
    # Always runs a full Argon2 verification (against a dummy hash for an
    # unknown user) so response time does not reveal which usernames exist.
    valid = verify_password(password, user.password_hash if user else None)

    if user is None or not valid or not user.is_active:
        await audit_service.record(
            session,
            action="LOGIN_FAILED",
            entity_type="user",
            entity_id=user.id if user else None,
            actor_label="anonymous",
            details={"known_user": user is not None},
        )
        await session.commit()
        logger.info("login_failed", extra={"known_user": user is not None})
        raise AuthenticationError(
            "Invalid username or password.", code="INVALID_CREDENTIALS"
        )

    if password_needs_rehash(user.password_hash):
        user.password_hash = hash_password(password)
    user.last_login_at = utcnow()
    await audit_service.record(
        session, action="LOGIN_SUCCEEDED", entity_type="user", entity_id=user.id, actor=user
    )
    logger.info("login_succeeded", extra={"user_id": str(user.id)})
    return user


async def list_users(
    session: AsyncSession, *, role: UserRole | None, page: int, page_size: int
) -> tuple[list[User], int]:
    query = select(User)
    count = select(func.count()).select_from(User)
    if role:
        query = query.where(User.role == role)
        count = count.where(User.role == role)
    total = int(await session.scalar(count) or 0)
    rows = (
        await session.scalars(
            query.order_by(User.created_at.desc()).offset((page - 1) * page_size).limit(page_size)
        )
    ).all()
    return list(rows), total


async def update_user(
    session: AsyncSession, user: User, patch: UserUpdate, actor: User
) -> User:
    changes = patch.model_dump(exclude_unset=True)
    if "email" in changes and changes["email"]:
        email_n = _norm(changes["email"])
        clash = await session.scalar(
            select(User.id).where(User.email == email_n, User.id != user.id)
        )
        if clash:
            raise ConflictError("That email is already registered.", code="EMAIL_TAKEN")
        changes["email"] = email_n
    if "password" in changes:
        user.password_hash = hash_password(changes.pop("password"))
    for field, value in changes.items():
        setattr(user, field, value)
    await session.flush()
    await audit_service.record(
        session,
        action="USER_UPDATED",
        entity_type="user",
        entity_id=user.id,
        actor=actor,
        details={"fields": sorted(patch.model_fields_set)},
    )
    return user


async def bootstrap_admin(session: AsyncSession, settings: Settings) -> bool:
    """Creates the first administrator from INITIAL_ADMIN_* settings, once.
    Never overwrites an existing account."""
    if not (settings.initial_admin_username and settings.initial_admin_password):
        return False
    if await session.scalar(select(User.id).where(User.role == UserRole.ADMIN)):
        return False
    if await get_by_login(session, settings.initial_admin_username):
        return False
    await create_user(
        session,
        username=settings.initial_admin_username,
        password=settings.initial_admin_password.get_secret_value(),
        email=settings.initial_admin_email,
        role=UserRole.ADMIN,
        full_name="Administrator",
        audit_action="ADMIN_BOOTSTRAPPED",
    )
    await session.commit()
    logger.info("initial_admin_created")
    return True
