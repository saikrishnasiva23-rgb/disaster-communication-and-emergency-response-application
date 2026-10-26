from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.domain.enums import TeamMemberRole, TeamStatus
from app.schemas.common import Latitude, Longitude, ORMModel

Capability = Annotated[str, Field(min_length=1, max_length=40)]


class TeamCreate(BaseModel):
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "name": "Alpha Rescue Unit",
                    "capabilities": ["WATER_RESCUE", "FIRST_AID"],
                    "contact_phone": "+91 90000 00001",
                    "base_latitude": 11.9416,
                    "base_longitude": 79.8083,
                }
            ]
        }
    )

    name: str = Field(min_length=2, max_length=120)
    capabilities: list[Capability] = Field(default_factory=list, max_length=30)
    contact_phone: str | None = Field(default=None, max_length=32)
    base_latitude: Latitude | None = None
    base_longitude: Longitude | None = None

    @model_validator(mode="after")
    def _paired_base(self) -> "TeamCreate":
        if (self.base_latitude is None) != (self.base_longitude is None):
            raise ValueError("base_latitude and base_longitude must be given together.")
        return self


class TeamUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=120)
    status: TeamStatus | None = None
    capabilities: list[Capability] | None = Field(default=None, max_length=30)
    contact_phone: str | None = Field(default=None, max_length=32)
    current_latitude: Latitude | None = None
    current_longitude: Longitude | None = None

    @model_validator(mode="after")
    def _paired_location(self) -> "TeamUpdate":
        if (self.current_latitude is None) != (self.current_longitude is None):
            raise ValueError(
                "current_latitude and current_longitude must be given together."
            )
        return self


class TeamMemberAdd(BaseModel):
    user_id: uuid.UUID
    member_role: TeamMemberRole = TeamMemberRole.MEMBER


class TeamMemberPublic(ORMModel):
    id: uuid.UUID
    user_id: uuid.UUID
    member_role: TeamMemberRole
    joined_at: datetime


class TeamPublic(ORMModel):
    id: uuid.UUID
    name: str
    status: TeamStatus
    capabilities: list[str]
    contact_phone: str | None
    base_latitude: float | None
    base_longitude: float | None
    current_latitude: float | None
    current_longitude: float | None
    location_updated_at: datetime | None
    is_active: bool
    created_at: datetime
    members: list[TeamMemberPublic] = []
    active_assignments: int = Field(default=0, description="Current workload.")
