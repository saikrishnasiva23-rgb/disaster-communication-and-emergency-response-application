from __future__ import annotations

import uuid
from collections.abc import Callable
from typing import Annotated

from fastapi import Depends, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import AuthenticationError, AuthorizationError
from app.core.security import decode_access_token
from app.db.database import get_db
from app.db.models import User
from app.domain.enums import UserRole
from app.services.priority_service import PriorityService

_bearer = HTTPBearer(
    auto_error=False,
    description="JWT from POST /api/v1/auth/login, sent as `Authorization: Bearer <token>`.",
)


def get_settings_dep(request: Request) -> Settings:
    return request.app.state.settings


def get_priority_service(request: Request) -> PriorityService:
    return request.app.state.priority_service


DbSession = Annotated[AsyncSession, Depends(get_db)]
SettingsDep = Annotated[Settings, Depends(get_settings_dep)]
PriorityDep = Annotated[PriorityService, Depends(get_priority_service)]


async def get_current_user(
    session: DbSession,
    settings: SettingsDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> User:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise AuthenticationError("Missing bearer token.", code="NOT_AUTHENTICATED")
    claims = decode_access_token(credentials.credentials, settings)
    try:
        user_id = uuid.UUID(claims["sub"])
    except (KeyError, ValueError) as exc:
        raise AuthenticationError("The access token is invalid.", code="INVALID_TOKEN") from exc
    user = await session.get(User, user_id)
    # A deactivated or deleted account loses access immediately, even with
    # an unexpired token.
    if user is None or not user.is_active:
        raise AuthenticationError("This account is not active.", code="INVALID_TOKEN")
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


def require_roles(*roles: UserRole) -> Callable[..., object]:
    async def checker(user: CurrentUser) -> User:
        if user.role not in roles:
            raise AuthorizationError(
                "Your role cannot perform this action.",
                details={"required_roles": list(roles), "your_role": user.role},
            )
        return user

    return checker


RescuerUser = Annotated[User, Depends(require_roles(UserRole.RESCUE_TEAM, UserRole.ADMIN))]
AdminUser = Annotated[User, Depends(require_roles(UserRole.ADMIN))]


class Pagination:
    def __init__(
        self,
        page: Annotated[int, Query(ge=1, le=100_000)] = 1,
        page_size: Annotated[int, Query(ge=1, le=200)] = 50,
    ) -> None:
        self.page = page
        self.page_size = page_size

    def meta(self, total: int) -> dict[str, int | bool]:
        return {
            "total": total,
            "page": self.page,
            "page_size": self.page_size,
            "has_next": self.page * self.page_size < total,
        }


PaginationDep = Annotated[Pagination, Depends()]


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"
