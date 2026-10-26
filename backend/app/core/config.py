"""Environment-driven configuration. Nothing secret has a hard-coded value."""

from __future__ import annotations

import secrets
from functools import lru_cache
from typing import Literal
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from app import __version__

Environment = Literal["development", "testing", "production"]


def normalize_database_url(url: str) -> str:
    """Map the URL forms hosting platforms hand out onto async SQLAlchemy drivers.

    `postgres://` / `postgresql://` -> `postgresql+asyncpg://`, `sqlite:///` ->
    `sqlite+aiosqlite:///`, and libpq's `sslmode=` (which asyncpg does not
    accept) -> `ssl=`.
    """
    url = url.strip()
    if url.startswith("postgres://"):
        url = "postgresql+asyncpg://" + url[len("postgres://") :]
    elif url.startswith("postgresql://"):
        url = "postgresql+asyncpg://" + url[len("postgresql://") :]
    elif url.startswith("sqlite:///"):
        url = "sqlite+aiosqlite:///" + url[len("sqlite:///") :]

    if url.startswith("postgresql+asyncpg://"):
        parts = urlsplit(url)
        query = [
            ("ssl", value) if key == "sslmode" else (key, value)
            for key, value in parse_qsl(parts.query, keep_blank_values=True)
        ]
        url = urlunsplit(parts._replace(query=urlencode(query)))
    return url


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    app_name: str = "Disaster Communication Cloud Backend"
    app_version: str = __version__
    environment: Environment = "development"

    database_url: str = "sqlite+aiosqlite:///./disaster_dev.db"
    db_echo: bool = False
    db_pool_size: int = Field(default=5, ge=1, le=100)
    db_max_overflow: int = Field(default=10, ge=0, le=200)
    # Creates tables on startup without Alembic -- tests/local convenience
    # only. Production schema changes go through `alembic upgrade head`.
    auto_create_tables: bool = False

    jwt_secret: SecretStr = SecretStr("")
    jwt_algorithm: Literal["HS256", "HS384", "HS512"] = "HS256"
    access_token_expire_minutes: int = Field(default=60, ge=1, le=60 * 24 * 7)

    # Comma-separated list of allowed browser origins. Native Android/Windows
    # clients are not subject to CORS; this only matters for web clients.
    cors_origins: str = ""

    # The Flutter app's existing `/api/rescue-request(s)` endpoints (no auth,
    # like the old Flask server). Defaults to ON in development only.
    legacy_api_enabled: bool | None = None

    rate_limit_auth_attempts: int = Field(default=10, ge=1)
    rate_limit_auth_window_seconds: int = Field(default=300, ge=1)

    # Client clocks drift; an emergency timestamp further in the future than
    # this is rejected as invalid rather than silently trusted.
    max_clock_skew_minutes: int = Field(default=120, ge=1)

    sync_batch_limit: int = Field(default=100, ge=1, le=1000)

    # Optional one-time bootstrap of the first administrator.
    initial_admin_username: str | None = None
    initial_admin_email: str | None = None
    initial_admin_password: SecretStr | None = None

    # Comma-separated extra emergency type codes, e.g. "TSUNAMI,GAS_LEAK".
    extra_emergency_types: str = ""

    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"
    log_json: bool = True

    host: str = "0.0.0.0"
    port: int = Field(default=8000, ge=1, le=65535)

    jwt_secret_is_ephemeral: bool = False

    @field_validator("database_url")
    @classmethod
    def _normalize_url(cls, value: str) -> str:
        return normalize_database_url(value)

    @model_validator(mode="after")
    def _check_environment(self) -> "Settings":
        secret = self.jwt_secret.get_secret_value()
        if self.environment == "production":
            if len(secret) < 32:
                raise ValueError(
                    "JWT_SECRET must be set to at least 32 characters in production."
                )
            if self.database_url.startswith("sqlite"):
                raise ValueError(
                    "Production requires a PostgreSQL DATABASE_URL; SQLite is for "
                    "development and testing only."
                )
        elif not secret:
            # Dev/test only: a random per-process secret. Tokens stop working
            # after a restart, which is the safe failure mode.
            self.jwt_secret = SecretStr(secrets.token_urlsafe(48))
            self.jwt_secret_is_ephemeral = True
        return self

    @property
    def is_production(self) -> bool:
        return self.environment == "production"

    @property
    def is_sqlite(self) -> bool:
        return self.database_url.startswith("sqlite")

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def legacy_enabled(self) -> bool:
        if self.legacy_api_enabled is None:
            return self.environment == "development"
        return self.legacy_api_enabled

    @property
    def extra_emergency_type_list(self) -> list[str]:
        return [t.strip() for t in self.extra_emergency_types.split(",") if t.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
