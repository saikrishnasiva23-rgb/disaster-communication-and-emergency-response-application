from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated, Any, Generic, TypeVar

from pydantic import AfterValidator, BaseModel, ConfigDict, Field

T = TypeVar("T")


class ApiResponse(BaseModel, Generic[T]):
    success: bool = True
    data: T | None = None
    message: str | None = None
    meta: dict[str, Any] | None = None


class ErrorInfo(BaseModel):
    code: str = Field(examples=["INVALID_STATUS_TRANSITION"])
    message: str = Field(examples=["An emergency cannot move from RESOLVED to ASSIGNED."])
    details: Any | None = None
    request_id: str | None = None


class ErrorResponse(BaseModel):
    success: bool = False
    error: ErrorInfo


class PageMeta(BaseModel):
    total: int
    page: int
    page_size: int
    has_next: bool


class ORMModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


def _as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


# Naive timestamps are interpreted as UTC; everything is stored in UTC.
UTCTimestamp = Annotated[datetime, AfterValidator(_as_utc)]

Latitude = Annotated[
    float, Field(ge=-90, le=90, allow_inf_nan=False, description="WGS84 latitude")
]
Longitude = Annotated[
    float, Field(ge=-180, le=180, allow_inf_nan=False, description="WGS84 longitude")
]

ClientId = Annotated[
    str,
    Field(
        min_length=1,
        max_length=64,
        pattern=r"^[A-Za-z0-9_.:\-]+$",
        description="Stable client-generated identifier (letters, digits, _ . : -).",
    ),
]


def error_responses(*codes: int) -> dict[int | str, dict[str, Any]]:
    """OpenAPI documentation for the standard error envelope."""
    descriptions = {
        400: "Bad request",
        401: "Missing, invalid or expired access token",
        403: "Authenticated but not allowed to do this",
        404: "Resource not found",
        409: "Conflict (duplicate, idempotency mismatch or invalid status transition)",
        422: "Validation error",
        429: "Too many attempts",
        503: "Database temporarily unavailable",
    }
    return {
        code: {"model": ErrorResponse, "description": descriptions.get(code, "Error")}
        for code in codes
    }
