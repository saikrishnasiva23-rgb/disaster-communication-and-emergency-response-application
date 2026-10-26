from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field

from app.schemas.common import ORMModel


class AuditEntryPublic(ORMModel):
    sequence: int
    event_id: uuid.UUID
    timestamp: datetime
    actor_user_id: uuid.UUID | None
    actor_label: str
    action: str
    entity_type: str
    entity_id: str | None
    details: dict[str, Any] = Field(serialization_alias="metadata")
    previous_hash: str
    current_hash: str


class AuditVerifyResult(BaseModel):
    valid: bool
    entries_checked: int
    head_sequence: int
    head_hash: str
    first_invalid_sequence: int | None = None
    reason: str | None = None
    verified_at: datetime
    note: str = (
        "Tamper-evident SHA-256 hash chain stored in this server's database. "
        "It detects modification, deletion or reordering of logged events; it is "
        "not a decentralized blockchain network."
    )
