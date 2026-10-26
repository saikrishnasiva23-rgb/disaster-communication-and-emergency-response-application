from __future__ import annotations

from fastapi import APIRouter, Request, status

from app.api.deps import CurrentUser, DbSession, SettingsDep, client_ip
from app.core.errors import RateLimitedError
from app.core.security import create_access_token
from app.db.models import User
from app.db.types import utcnow
from app.domain.enums import UserRole
from app.schemas.auth import LoginRequest, RegisterRequest, TokenResponse
from app.schemas.common import ApiResponse, error_responses
from app.schemas.user import UserPublic
from app.services import user_service

router = APIRouter(prefix="/auth", tags=["Authentication"])


def _limit(request: Request, key: str) -> None:
    retry_after = request.app.state.auth_limiter.hit(key)
    if retry_after is not None:
        raise RateLimitedError(
            "Too many attempts. Try again later.",
            headers={"Retry-After": str(int(retry_after) + 1)},
            details={"retry_after_seconds": int(retry_after) + 1},
        )


def _token(user: User, settings: SettingsDep) -> TokenResponse:
    token, expires_at = create_access_token(user_id=user.id, role=user.role, settings=settings)
    return TokenResponse(
        access_token=token,
        expires_at=expires_at,
        expires_in=max(0, int((expires_at - utcnow()).total_seconds())),
        user=UserPublic.model_validate(user),
    )


@router.post(
    "/register",
    status_code=status.HTTP_201_CREATED,
    response_model=ApiResponse[TokenResponse],
    summary="Register an Affected Person account",
    responses=error_responses(409, 422, 429),
)
async def register(
    body: RegisterRequest, request: Request, session: DbSession, settings: SettingsDep
) -> ApiResponse[TokenResponse]:
    """Self-registration always creates an **AFFECTED_PERSON** account.
    Rescue-team and admin accounts are created by an admin (`POST /users`)."""
    _limit(request, f"register:{client_ip(request)}")
    user = await user_service.create_user(
        session,
        username=body.username,
        password=body.password,
        role=UserRole.AFFECTED_PERSON,
        email=body.email,
        full_name=body.full_name,
        phone=body.phone,
    )
    await session.commit()
    return ApiResponse(data=_token(user, settings), message="Account created.")


@router.post(
    "/login",
    response_model=ApiResponse[TokenResponse],
    summary="Log in and receive a JWT access token",
    responses=error_responses(401, 422, 429),
)
async def login(
    body: LoginRequest, request: Request, session: DbSession, settings: SettingsDep
) -> ApiResponse[TokenResponse]:
    """Returns a bearer token. Send it as `Authorization: Bearer <token>`.
    Tokens expire after `ACCESS_TOKEN_EXPIRE_MINUTES`; log in again then."""
    key = f"login:{client_ip(request)}:{body.username.strip().lower()}"
    _limit(request, key)
    user = await user_service.authenticate(session, body.username, body.password)
    await session.commit()
    request.app.state.auth_limiter.reset(key)
    return ApiResponse(data=_token(user, settings), message="Logged in.")


@router.get(
    "/me",
    response_model=ApiResponse[UserPublic],
    summary="The current user",
    responses=error_responses(401),
)
async def me(user: CurrentUser) -> ApiResponse[UserPublic]:
    return ApiResponse(data=UserPublic.model_validate(user))
