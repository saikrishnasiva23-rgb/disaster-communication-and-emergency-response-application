from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

from app.domain.enums import DevicePlatform, DeviceType
from app.schemas.common import ClientId, ORMModel


class DeviceRegister(BaseModel):
    """Registers (or re-registers) a device by its stable client id.
    Idempotent: registering the same id again updates it."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "client_device_id": "affected-3f9a2b1c",
                    "device_type": "AFFECTED_PHONE",
                    "platform": "ANDROID",
                    "device_name": "OPPO A5 Pro 5G",
                    "app_version": "1.0.0",
                }
            ]
        }
    )

    client_device_id: ClientId
    device_type: DeviceType
    platform: DevicePlatform
    device_name: str | None = Field(default=None, max_length=120)
    app_version: str | None = Field(default=None, max_length=32)


class DeviceUpdate(BaseModel):
    device_name: str | None = Field(default=None, max_length=120)
    app_version: str | None = Field(default=None, max_length=32)
    last_status: str | None = Field(default=None, max_length=32)
    is_active: bool | None = Field(
        default=None, description="Administrators only (deactivate a device)."
    )


class DevicePublic(ORMModel):
    id: uuid.UUID
    client_device_id: str
    user_id: uuid.UUID | None
    device_type: DeviceType
    platform: DevicePlatform
    device_name: str | None
    app_version: str | None
    registered_at: datetime
    last_sync_at: datetime | None
    last_seen_at: datetime | None
    last_status: str | None
    is_active: bool
