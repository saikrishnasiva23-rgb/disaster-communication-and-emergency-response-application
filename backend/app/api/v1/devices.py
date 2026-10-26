from __future__ import annotations

import uuid

from fastapi import APIRouter, Response, status

from app.api.deps import CurrentUser, DbSession, PaginationDep
from app.schemas.common import ApiResponse, error_responses
from app.schemas.device import DevicePublic, DeviceRegister, DeviceUpdate
from app.services import device_service

router = APIRouter(prefix="/devices", tags=["Devices"])


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=ApiResponse[DevicePublic],
    summary="Register (or re-register) this device",
    responses={200: {"description": "Already registered; updated"},
               **error_responses(401, 409, 422)},
)
async def register_device(
    body: DeviceRegister, user: CurrentUser, session: DbSession, response: Response
) -> ApiResponse[DevicePublic]:
    """Idempotent on `client_device_id`: 201 the first time, 200 afterwards."""
    device, created = await device_service.register(session, body, user)
    await session.commit()
    if not created:
        response.status_code = status.HTTP_200_OK
    return ApiResponse(
        data=DevicePublic.model_validate(device),
        message="Device registered." if created else "Device already registered; updated.",
    )


@router.get(
    "",
    response_model=ApiResponse[list[DevicePublic]],
    summary="List your devices (admin: all devices)",
    responses=error_responses(401),
)
async def list_devices(
    user: CurrentUser, session: DbSession, pagination: PaginationDep
) -> ApiResponse[list[DevicePublic]]:
    devices, total = await device_service.list_devices(
        session, user, page=pagination.page, page_size=pagination.page_size
    )
    return ApiResponse(
        data=[DevicePublic.model_validate(d) for d in devices], meta=pagination.meta(total)
    )


@router.get(
    "/{device_id}",
    response_model=ApiResponse[DevicePublic],
    summary="Get a device",
    responses=error_responses(401, 403, 404),
)
async def get_device(
    device_id: uuid.UUID, user: CurrentUser, session: DbSession
) -> ApiResponse[DevicePublic]:
    device = await device_service.get_device(session, device_id, user)
    return ApiResponse(data=DevicePublic.model_validate(device))


@router.patch(
    "/{device_id}",
    response_model=ApiResponse[DevicePublic],
    summary="Update a device",
    responses=error_responses(401, 403, 404, 422),
)
async def update_device(
    device_id: uuid.UUID, body: DeviceUpdate, user: CurrentUser, session: DbSession
) -> ApiResponse[DevicePublic]:
    device = await device_service.get_device(session, device_id, user)
    device = await device_service.update_device(session, device, body, user)
    await session.commit()
    return ApiResponse(data=DevicePublic.model_validate(device), message="Device updated.")
