from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.domain import emergency_types
from app.domain.enums import PriorityLevel
from app.schemas.common import Latitude, Longitude


class PriorityRequest(BaseModel):
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "emergency_type": "FLOOD",
                    "people_count": 6,
                    "injured": True,
                    "trapped": False,
                    "severity": 4,
                    "description": "Water rising fast, one person bleeding",
                }
            ]
        }
    )

    emergency_type: str = Field(min_length=2, max_length=40)
    people_count: int = Field(default=1, ge=1, le=10_000)
    injured: bool = False
    trapped: bool = False
    severity: int | None = Field(default=None, ge=1, le=5)
    description: str | None = Field(default=None, max_length=2000)
    injury_details: str | None = Field(default=None, max_length=1000)
    latitude: Latitude | None = None
    longitude: Longitude | None = None
    available_rescue_teams: int | None = Field(default=None, ge=0, le=10_000)
    environmental_risk: float | None = Field(
        default=None, ge=0, le=1, allow_inf_nan=False,
        description="0 (none) - 1 (extreme), e.g. rising water, aftershocks.",
    )

    @field_validator("emergency_type")
    @classmethod
    def validate_emergency_type(cls, value: str) -> str:
        return emergency_types.normalize(value)


class PriorityResult(BaseModel):
    priority: PriorityLevel
    score: float = Field(
        ge=0, le=1,
        description="Urgency on one scale for every classifier: LOW <0.25, MEDIUM "
        "0.25-0.5, HIGH 0.5-0.75, CRITICAL >=0.75.",
    )
    reason: str
    model: str = Field(description="Which classifier produced the result.")
    factors: list[str] = []
