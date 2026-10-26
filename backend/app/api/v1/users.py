from __future__ import annotations

import uuid

from fastapi import APIRouter, Query, status

from app.api.deps import AdminUser, CurrentUser, DbSession, PaginationDep
from app.core.errors import AuthorizationError
from app.domain.enums import UserRole
from app.schemas.common import ApiResponse, error_responses
from app.schemas.user import UserCreate, UserPublic, UserUpdate
from app.services import user_service

router = APIRouter(prefix="/users", tags=["Users"])


@router.get(
    "",
    response_model=ApiResponse[list[UserPublic]],
    summary="List users (admin)",
    responses=error_responses(401, 403),
)
async def list_users(
    _: AdminUser,
    session: DbSession,
    pagination: PaginationDep,
    role: UserRole | None = Query(default=None),
) -> ApiResponse[list[UserPublic]]:
    users, total = await user_service.list_users(
        session, role=role, page=pagination.page, page_size=pagination.page_size
    )
    return ApiResponse(
        data=[UserPublic.model_validate(u) for u in users], meta=pagination.meta(total)
    )


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=ApiResponse[UserPublic],
    summary="Create a user of any role (admin)",
    responses=error_responses(401, 403, 409, 422),
)
async def create_user(
    body: UserCreate, admin: AdminUser, session: DbSession
) -> ApiResponse[UserPublic]:
    user = await user_service.create_user(
        session,
        username=body.username,
        password=body.password,
        role=body.role,
        email=body.email,
        full_name=body.full_name,
        phone=body.phone,
        actor=admin,
    )
    await session.commit()
    return ApiResponse(data=UserPublic.model_validate(user), message="User created.")


@router.get(
    "/{user_id}",
    response_model=ApiResponse[UserPublic],
    summary="Get a user (admin, or yourself)",
    responses=error_responses(401, 403, 404),
)
async def get_user(
    user_id: uuid.UUID, actor: CurrentUser, session: DbSession
) -> ApiResponse[UserPublic]:
    if actor.role != UserRole.ADMIN and actor.id != user_id:
        raise AuthorizationError("You can only view your own account.")
    user = await user_service.require_user(session, user_id)
    return ApiResponse(data=UserPublic.model_validate(user))


@router.patch(
    "/{user_id}",
    response_model=ApiResponse[UserPublic],
    summary="Update a user (admin: anything; yourself: profile and password)",
    responses=error_responses(401, 403, 404, 409, 422),
)
async def update_user(
    user_id: uuid.UUID, body: UserUpdate, actor: CurrentUser, session: DbSession
) -> ApiResponse[UserPublic]:
    if actor.role != UserRole.ADMIN:
        if actor.id != user_id:
            raise AuthorizationError("You can only update your own account.")
        if body.model_fields_set & {"role", "is_active"}:
            raise AuthorizationError("Only an administrator can change role or status.")
    user = await user_service.require_user(session, user_id)
    user = await user_service.update_user(session, user, body, actor)
    await session.commit()
    return ApiResponse(data=UserPublic.model_validate(user), message="User updated.")
