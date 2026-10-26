from __future__ import annotations

import uuid

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import AuthorizationError, ConflictError, NotFoundError
from app.db.models import Device, User
from app.db.types import utcnow
from app.domain.enums import DevicePlatform, DeviceType, UserRole
from app.schemas.device import DeviceRegister, DeviceUpdate
from app.services import audit_service


async def get_by_client_id(session: AsyncSession, client_device_id: str) -> Device | None:
    return await session.scalar(
        select(Device).where(Device.client_device_id == client_device_id)
    )


def _can_manage(device: Device, actor: User) -> bool:
    return actor.role == UserRole.ADMIN or device.user_id == actor.id


async def register(
    session: AsyncSession, data: DeviceRegister, actor: User
) -> tuple[Device, bool]:
    device = await get_by_client_id(session, data.client_device_id)
    now = utcnow()

    if device is None:
        device = Device(
            client_device_id=data.client_device_id,
            user_id=actor.id,
            device_type=data.device_type,
            platform=data.platform,
            device_name=data.device_name,
            app_version=data.app_version,
            registered_at=now,
            last_seen_at=now,
        )
        session.add(device)
        await session.flush()
        await audit_service.record(
            session,
            action="DEVICE_REGISTERED",
            entity_type="device",
            entity_id=device.id,
            actor=actor,
            details={"platform": data.platform, "device_type": data.device_type},
        )
        return device, True

    if device.user_id is not None and not _can_manage(device, actor):
        raise ConflictError(
            "This device id is registered to another account.",
            code="DEVICE_OWNED_BY_ANOTHER_USER",
        )
    if device.user_id is None:
        # A device first seen via a rescue console's BLE upload is claimed by
        # the account that registers it.
        device.user_id = actor.id
    device.device_type = data.device_type
    device.platform = data.platform
    if data.device_name is not None:
        device.device_name = data.device_name
    if data.app_version is not None:
        device.app_version = data.app_version
    device.last_seen_at = now
    device.is_active = True
    await session.flush()
    await audit_service.record(
        session,
        action="DEVICE_UPDATED",
        entity_type="device",
        entity_id=device.id,
        actor=actor,
        details={"re_registered": True},
    )
    return device, False


async def resolve_origin_device(
    session: AsyncSession,
    client_device_id: str,
    *,
    display_name: str | None,
    actor: User,
) -> Device:
    """The phone an emergency came from. Created on first sight so the same
    phone links all its emergencies, identified by its stable app id."""
    device = await get_by_client_id(session, client_device_id)
    if device is None:
        device = Device(
            client_device_id=client_device_id,
            user_id=actor.id if actor.role == UserRole.AFFECTED_PERSON else None,
            device_type=DeviceType.AFFECTED_PHONE,
            platform=DevicePlatform.ANDROID
            if actor.role == UserRole.AFFECTED_PERSON
            else DevicePlatform.OTHER,
            device_name=display_name,
            last_seen_at=utcnow(),
        )
        session.add(device)
        await session.flush()
        return device

    if actor.role == UserRole.AFFECTED_PERSON:
        if device.user_id not in (None, actor.id):
            raise AuthorizationError(
                "origin_device_id belongs to another account.",
                code="DEVICE_OWNED_BY_ANOTHER_USER",
            )
        device.user_id = actor.id
    if display_name and not device.device_name:
        device.device_name = display_name
    device.last_seen_at = utcnow()
    return device


async def touch_sync(
    session: AsyncSession, client_device_id: str | None, actor: User
) -> Device | None:
    if not client_device_id:
        return None
    device = await get_by_client_id(session, client_device_id)
    now = utcnow()
    if device is None:
        is_rescue = actor.role in (UserRole.RESCUE_TEAM, UserRole.ADMIN)
        device = Device(
            client_device_id=client_device_id,
            user_id=actor.id,
            device_type=DeviceType.RESCUE_CONSOLE if is_rescue else DeviceType.AFFECTED_PHONE,
            platform=DevicePlatform.OTHER,
            registered_at=now,
        )
        session.add(device)
    elif device.user_id not in (None, actor.id) and actor.role != UserRole.ADMIN:
        raise AuthorizationError(
            "device_id belongs to another account.", code="DEVICE_OWNED_BY_ANOTHER_USER"
        )
    device.last_sync_at = now
    device.last_seen_at = now
    device.last_status = "SYNCED"
    await session.flush()
    return device


async def list_devices(
    session: AsyncSession, actor: User, *, page: int, page_size: int
) -> tuple[list[Device], int]:
    query = select(Device)
    count = select(func.count()).select_from(Device)
    if actor.role != UserRole.ADMIN:
        query = query.where(Device.user_id == actor.id)
        count = count.where(Device.user_id == actor.id)
    total = int(await session.scalar(count) or 0)
    rows = (
        await session.scalars(
            query.order_by(Device.registered_at.desc())
            .offset((page - 1) * page_size)
            .limit(page_size)
        )
    ).all()
    return list(rows), total


async def get_device(session: AsyncSession, device_id: uuid.UUID, actor: User) -> Device:
    device = await session.get(Device, device_id)
    if device is None:
        raise NotFoundError("Device not found.", code="DEVICE_NOT_FOUND")
    if not _can_manage(device, actor):
        raise AuthorizationError("You cannot access this device.")
    return device


async def update_device(
    session: AsyncSession, device: Device, patch: DeviceUpdate, actor: User
) -> Device:
    changes = patch.model_dump(exclude_unset=True)
    if "is_active" in changes and actor.role != UserRole.ADMIN:
        raise AuthorizationError("Only an administrator can (de)activate devices.")
    for field, value in changes.items():
        setattr(device, field, value)
    device.last_seen_at = utcnow()
    await session.flush()
    await audit_service.record(
        session,
        action="DEVICE_UPDATED",
        entity_type="device",
        entity_id=device.id,
        actor=actor,
        details={"fields": sorted(changes)},
    )
    return device
