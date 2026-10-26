from __future__ import annotations

import logging

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text

from app.schemas.common import ApiResponse
from app.schemas.health import HealthResponse

logger = logging.getLogger("app.health")

router = APIRouter(tags=["Health"])


@router.get(
    "/health",
    response_model=ApiResponse[HealthResponse],
    summary="Liveness and database connectivity",
    responses={503: {"model": ApiResponse[HealthResponse], "description": "Database unavailable"}},
)
async def health(request: Request) -> JSONResponse:
    """200 when the database answers, 503 otherwise -- suitable for load
    balancer / platform health checks. Reveals no configuration or secrets."""
    settings = request.app.state.settings
    database = "connected"
    try:
        async with request.app.state.session_factory() as session:
            await session.execute(text("SELECT 1"))
    except Exception as exc:  # noqa: BLE001 -- any failure means "unavailable"
        logger.warning("health_db_unavailable", extra={"error_type": type(exc).__name__})
        database = "unavailable"

    healthy = database == "connected"
    body = HealthResponse(
        status="healthy" if healthy else "degraded",
        database=database,
        version=settings.app_version,
        environment=settings.environment,
        services={
            "api": "up",
            "priority": request.app.state.priority_service.describe()["classifier"],
            "ble": "not handled by the cloud (device-to-device only)",
        },
    )
    return JSONResponse(
        status_code=200 if healthy else 503,
        content=ApiResponse(success=healthy, data=body).model_dump(mode="json"),
    )


@router.head("/health", include_in_schema=False)
async def health_head(request: Request) -> JSONResponse:
    """Some platform monitors probe with HEAD; same status code as GET."""
    return await health(request)
