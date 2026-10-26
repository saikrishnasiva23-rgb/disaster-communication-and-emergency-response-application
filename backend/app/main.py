"""FastAPI application factory.

Run locally:   uvicorn app.main:app --reload
In a container the entrypoint runs `alembic upgrade head` first, then
uvicorn on 0.0.0.0:$PORT."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import __version__
from app.api import health, legacy
from app.api.v1 import audit, auth, devices, emergencies, priority, rescue_teams, sync, users
from app.core.config import Settings, get_settings
from app.core.errors import register_exception_handlers
from app.core.logging import RequestLoggingMiddleware, SecurityHeadersMiddleware, setup_logging
from app.core.rate_limit import SlidingWindowRateLimiter
from app.db import models  # noqa: F401 -- registers every table on Base.metadata
from app.db.database import Base, create_engine, create_session_factory
from app.domain import emergency_types
from app.services import audit_service, user_service
from app.services.priority_service import PriorityService, RandomForestDemoClassifier

logger = logging.getLogger("app")

API_PREFIX = "/api/v1"

DESCRIPTION = """
Cloud backend for the **AI-Enabled Decentralized Disaster Communication
Network**.

* Phones and the rescue console talk to each other over **BLE without this
  server**. The cloud adds persistence, coordination between rescue teams,
  and offline sync; BLE keeps working when it is unreachable.
* Authenticate with `POST /api/v1/auth/login`, then send
  `Authorization: Bearer <token>`.
* Every response uses one envelope: `{"success": true, "data": ..., "message": ...}`
  or `{"success": false, "error": {"code": ..., "message": ...}}`.
* The audit log is a tamper-evident SHA-256 **hash chain** (verify with
  `GET /api/v1/audit/verify`) -- not a decentralized blockchain network.
"""


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    setup_logging(settings)
    emergency_types.register_extra_codes(settings.extra_emergency_type_list)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        engine = create_engine(settings)
        app.state.engine = engine
        app.state.session_factory = create_session_factory(engine)
        try:
            if settings.auto_create_tables:
                async with engine.begin() as conn:
                    await conn.run_sync(Base.metadata.create_all)
            async with app.state.session_factory() as session:
                await models.ensure_roles(session)
                await audit_service.ensure_chain_head(session)
                await session.commit()
                await user_service.bootstrap_admin(session, settings)
        except Exception:
            # Keep serving: /health reports the database as unavailable
            # instead of the process crash-looping.
            logger.exception("startup_database_init_failed")
        await app.state.priority_service.warm_up()
        if settings.jwt_secret_is_ephemeral:
            logger.warning(
                "jwt_secret_ephemeral",
                extra={"hint": "Set JWT_SECRET; tokens will not survive a restart."},
            )
        logger.info(
            "startup_complete",
            extra={"environment": settings.environment, "version": settings.app_version,
                   "legacy_api": settings.legacy_enabled},
        )
        try:
            yield
        finally:
            await engine.dispose()
            logger.info("shutdown_complete")

    app = FastAPI(
        title=settings.app_name,
        version=__version__,
        description=DESCRIPTION,
        lifespan=lifespan,
        docs_url="/docs",
        redoc_url="/redoc",
        openapi_url="/openapi.json",
    )
    app.state.settings = settings
    app.state.priority_service = PriorityService(model=RandomForestDemoClassifier())
    app.state.auth_limiter = SlidingWindowRateLimiter(
        settings.rate_limit_auth_attempts, settings.rate_limit_auth_window_seconds
    )

    register_exception_handlers(app)
    if settings.cors_origin_list:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origin_list,
            allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
            allow_headers=["Authorization", "Content-Type", "Idempotency-Key", "X-Request-ID"],
            expose_headers=["X-Request-ID", "Retry-After"],
        )
    app.add_middleware(SecurityHeadersMiddleware)
    app.add_middleware(RequestLoggingMiddleware)

    app.include_router(health.router)
    app.include_router(health.router, prefix=API_PREFIX)
    for module in (auth, users, devices, emergencies, rescue_teams, sync, audit, priority):
        app.include_router(module.router, prefix=API_PREFIX)
    if settings.legacy_enabled:
        app.include_router(legacy.router)

    @app.get("/", include_in_schema=False)
    async def root() -> dict[str, object]:
        return {
            "success": True,
            "data": {"name": settings.app_name, "version": __version__,
                     "docs": "/docs", "health": "/health", "api": API_PREFIX},
        }

    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn

    s = get_settings()
    uvicorn.run("app.main:app", host=s.host, port=s.port, proxy_headers=True)
