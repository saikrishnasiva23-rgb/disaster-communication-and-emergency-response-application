from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.domain.enums import EmergencyStatus, ResolutionOutcome
from app.schemas.common import ClientId, UTCTimestamp
from app.schemas.emergency import EmergencyCreate, EmergencyPublic


class SyncEmergencyItem(EmergencyCreate):
    """An emergency recorded offline. `client_emergency_id` is REQUIRED here so
    that retries are recognised."""

    client_emergency_id: ClientId  # type: ignore[assignment]


class SyncEmergenciesRequest(BaseModel):
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "device_id": "rescue-console-01",
                    "items": [
                        {
                            "client_emergency_id": "3f9a2b-1727701234567890",
                            "emergency_type": "MEDICAL",
                            "occurred_at": "2026-09-30T10:32:05Z",
                            "location": {"latitude": 11.9416, "longitude": 79.8083},
                            "origin_device_id": "affected-3f9a2b1c",
                            "sender_display_name": "OPPO A5 Pro 5G",
                            "source": "BLE",
                        }
                    ],
                }
            ]
        }
    )

    device_id: ClientId | None = Field(
        default=None, description="Client id of the uploading device (updates its last-sync time)."
    )
    items: list[SyncEmergencyItem] = Field(min_length=1, max_length=1000)


SyncItemOutcome = Literal["created", "duplicate", "conflict", "invalid"]


class SyncItemResult(BaseModel):
    client_emergency_id: str
    result: SyncItemOutcome
    emergency_id: uuid.UUID | None = None
    status: EmergencyStatus | None = None
    error: dict | None = None


class SyncCounts(BaseModel):
    created: int = 0
    duplicate: int = 0
    conflict: int = 0
    invalid: int = 0
    applied: int = 0
    not_found: int = 0


class SyncEmergenciesResponse(BaseModel):
    results: list[SyncItemResult]
    counts: SyncCounts
    server_time: datetime


class SyncStatusItem(BaseModel):
    """A status change a client made while offline (e.g. the rescue console's
    workflow). Applied only if it is still a valid, non-conflicting change."""

    update_id: ClientId = Field(description="Client-generated idempotency key for this change.")
    emergency_id: uuid.UUID | None = None
    client_emergency_id: ClientId | None = None
    status: EmergencyStatus
    changed_at: UTCTimestamp = Field(description="When the change happened on the client.")
    reason: str | None = Field(default=None, max_length=1000)
    team_id: uuid.UUID | None = Field(default=None, description="Required for ASSIGNED.")
    outcome: ResolutionOutcome | None = Field(default=None, description="Required for RESOLVED.")
    resolution_notes: str | None = Field(default=None, max_length=2000)

    @model_validator(mode="after")
    def _target(self) -> "SyncStatusItem":
        if self.emergency_id is None and self.client_emergency_id is None:
            raise ValueError("Give emergency_id or client_emergency_id.")
        return self


class SyncStatusRequest(BaseModel):
    device_id: ClientId | None = None
    items: list[SyncStatusItem] = Field(min_length=1, max_length=1000)


SyncStatusOutcome = Literal["applied", "duplicate", "conflict", "invalid", "not_found"]


class SyncStatusResult(BaseModel):
    update_id: str
    result: SyncStatusOutcome
    emergency_id: uuid.UUID | None = None
    current_status: EmergencyStatus | None = None
    server_changed_at: datetime | None = None
    error: dict | None = None


class SyncStatusResponse(BaseModel):
    results: list[SyncStatusResult]
    counts: SyncCounts
    server_time: datetime


class SyncPullResponse(BaseModel):
    items: list[EmergencyPublic]
    next_cursor: str | None = Field(
        description="Opaque position after the last returned item. Pass it back as "
        "`cursor` for the next page -- and later, to fetch only newer changes. Null "
        "when nothing was returned (keep using your previous cursor)."
    )
    has_more: bool = Field(description="True if another page is available right now.")
    server_time: datetime
