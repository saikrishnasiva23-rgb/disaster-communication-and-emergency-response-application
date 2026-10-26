"""Compatibility with the Flutter app's existing calls to the old Flask server
(`legacy_flask_app.py`): same paths, same request and response shapes, so
the app keeps working unchanged while it moves to /api/v1.

Like the old server these endpoints are unauthenticated, so they are
enabled by default only in development (LEGACY_API_ENABLED)."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator
from sqlalchemy import case, select

from app.api.deps import DbSession, PriorityDep, SettingsDep
from app.core.errors import InvalidInputError
from app.db.models import Emergency
from app.domain import emergency_types
from app.domain.enums import EmergencyStatus
from app.schemas.common import ClientId, Latitude, Longitude, UTCTimestamp
from app.schemas.emergency import EmergencyCreate, LocationIn
from app.services import emergency_service as es

router = APIRouter(prefix="/api", tags=["Legacy (Flutter compatibility)"])

_LEGACY_STATUS = {
    EmergencyStatus.CREATED: "Pending",
    EmergencyStatus.RECEIVED: "Pending",
    EmergencyStatus.ACKNOWLEDGED: "Pending",
    EmergencyStatus.ASSIGNED: "Assigned",
    EmergencyStatus.IN_PROGRESS: "In_Progress",
    EmergencyStatus.RESOLVED: "Rescued",
    EmergencyStatus.CANCELLED: "Cancelled",
    EmergencyStatus.REJECTED: "Rejected",
}


# The strings the Flutter app uses (and colour-codes) for these types.
_LEGACY_TYPE_NAMES = {
    "MEDICAL": "Medical Emergency",
    "FIRE": "Fire Emergency",
    "FLOOD": "Flood Emergency",
    "TRAPPED_PERSON": "Trapped Person",
}


def _legacy_type(code: str) -> str:
    return _LEGACY_TYPE_NAMES.get(code) or emergency_types.info(code).label


class LegacyRescueRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    name: str = Field(min_length=1, max_length=120)
    emergencyType: str = Field(min_length=1, max_length=40)  # noqa: N815
    numberOfPeople: int = Field(default=1, ge=1, le=10_000)  # noqa: N815
    injured: bool = False
    # Nullable: the app sends null when the phone had no GPS fix. The old
    # server rejected those; now they are stored without a position rather
    # than lost -- and never given invented coordinates.
    latitude: Latitude | None = None
    longitude: Longitude | None = None
    message: str | None = Field(default=None, max_length=2000)
    # Optional fields sent by protocol-v3 phones (older builds omit them):
    # the BLE packet id makes the call idempotent and lets the laptop's
    # cloud sync of the same SOS match this record.
    clientEmergencyId: ClientId | None = None  # noqa: N815
    occurredAt: UTCTimestamp | None = None  # noqa: N815
    originDeviceId: ClientId | None = None  # noqa: N815
    accuracy: float | None = Field(default=None, ge=0, le=100_000, allow_inf_nan=False)

    @field_validator("injured", mode="before")
    @classmethod
    def _yes_no(cls, value: Any) -> Any:
        if isinstance(value, str):
            return value.strip().lower() in {"yes", "true", "1", "y"}
        return value

    @field_validator("numberOfPeople", mode="before")
    @classmethod
    def _people(cls, value: Any) -> Any:
        return 1 if value in (None, "") else value


def _fail(message: str, status_code: int = 400) -> JSONResponse:
    return JSONResponse(status_code=status_code, content={"success": False, "message": message})


def _title(priority: str) -> str:
    return priority.capitalize()


@router.post("/rescue-request", summary="Old Flask endpoint: submit a rescue request")
async def rescue_request(
    request: Request, session: DbSession, settings: SettingsDep, priority: PriorityDep
) -> JSONResponse:
    try:
        raw = await request.json()
    except ValueError:
        return _fail("No data received")
    if not isinstance(raw, dict) or not raw:
        return _fail("No data received")
    try:
        body = LegacyRescueRequest.model_validate(raw)
    except ValidationError as exc:
        field = exc.errors()[0]["loc"][0] if exc.errors() else "request"
        return _fail(f"Invalid or missing field: {field}")
    if (body.latitude is None) != (body.longitude is None):
        return _fail("latitude and longitude must be given together")
    try:
        emergency_type = emergency_types.normalize(body.emergencyType)
    except ValueError:
        emergency_type = "OTHER"

    try:
        data = EmergencyCreate(
            client_emergency_id=body.clientEmergencyId,
            emergency_type=emergency_type,
            description=body.message,
            people_count=body.numberOfPeople,
            injured=body.injured,
            trapped=emergency_type == "TRAPPED_PERSON",
            sender_display_name=body.name,
            occurred_at=body.occurredAt,
            origin_device_id=body.originDeviceId,
            location=LocationIn(
                latitude=body.latitude, longitude=body.longitude, accuracy_m=body.accuracy
            )
            if body.latitude is not None and body.longitude is not None
            else None,
        )
    except ValidationError as exc:
        field = exc.errors()[0]["loc"][0] if exc.errors() else "request"
        return _fail(f"Invalid or missing field: {field}")
    try:
        emergency, _ = await es.create_legacy(session, data, priority, settings)
    except InvalidInputError as exc:
        return _fail(exc.message)
    return JSONResponse(
        {
            "success": True,
            "message": "Rescue request saved successfully!",
            "requestId": str(emergency.id),
            "priority": _title(emergency.priority),
            "confidence": round(emergency.priority_score * 100, 1),
        }
    )


@router.get("/rescue-requests", summary="Old Flask endpoint: list rescue requests")
async def rescue_requests(session: DbSession) -> JSONResponse:
    rank = case(
        {"CRITICAL": 1, "HIGH": 2, "MEDIUM": 3, "LOW": 4}, value=Emergency.priority, else_=5
    )
    rows = (
        await session.scalars(
            select(Emergency).order_by(rank, Emergency.received_at.desc()).limit(500)
        )
    ).all()
    return JSONResponse(
        {
            "success": True,
            "requests": [
                {
                    "id": str(e.id),
                    "name": e.sender_display_name or "Unknown",
                    "emergency_type": _legacy_type(e.emergency_type),
                    "number_of_people": e.people_count,
                    "injured": "Yes" if e.injured else "No",
                    "latitude": e.latitude,
                    "longitude": e.longitude,
                    "message": e.description or "",
                    "status": _LEGACY_STATUS.get(EmergencyStatus(e.status), "Pending"),
                    "priority_score": round(e.priority_score * 100, 1),
                    "priority_level": _title(e.priority),
                }
                for e in rows
            ],
        }
    )
