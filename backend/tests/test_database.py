"""Migrations, constraints and configuration."""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.migration import MigrationContext
from pydantic import ValidationError
from sqlalchemy import create_engine

from app.core.config import Settings, normalize_database_url
from app.db import models  # noqa: F401
from app.db.database import Base

BACKEND = Path(__file__).resolve().parents[1]
TABLES = {"users", "roles", "devices", "rescue_teams", "rescue_team_members", "emergencies",
          "emergency_locations", "emergency_assignments", "emergency_status_history",
          "audit_logs", "audit_chain_head", "sync_records"}


def _alembic(db: Path) -> Config:
    config = Config(str(BACKEND / "alembic.ini"))
    config.attributes["database_url"] = f"sqlite:///{db.as_posix()}"
    config.attributes["configure_logger"] = False
    return config


def test_migrations_upgrade_match_models_and_downgrade(tmp_path):
    db = tmp_path / "migrated.db"
    config = _alembic(db)
    command.upgrade(config, "head")

    engine = create_engine(f"sqlite:///{db.as_posix()}")
    with engine.connect() as conn:
        diff = compare_metadata(MigrationContext.configure(conn, opts={"compare_type": True}),
                                Base.metadata)
    engine.dispose()
    assert diff == [], diff

    with sqlite3.connect(db) as conn:
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert TABLES <= tables
        assert {r[0] for r in conn.execute("SELECT code FROM roles")} == {
            "AFFECTED_PERSON", "RESCUE_TEAM", "ADMIN"}
        assert conn.execute("SELECT last_sequence, last_hash FROM audit_chain_head").fetchone() == (0, "0" * 64)

    command.downgrade(config, "base")
    with sqlite3.connect(db) as conn:
        left = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert left & TABLES == set()


def test_app_runs_on_migrated_database(tmp_path):
    from fastapi.testclient import TestClient

    from app.main import create_app
    from tests.conftest import make_settings

    db = tmp_path / "test.db"
    command.upgrade(_alembic(db), "head")
    with TestClient(create_app(make_settings(tmp_path, auto_create_tables=False))) as client:
        assert client.get("/health").status_code == 200
        login = client.post("/api/v1/auth/login",
                            json={"username": "admin", "password": "admin-test-password"})
        assert login.status_code == 200


def test_database_constraints(tmp_path):
    db = tmp_path / "c.db"
    command.upgrade(_alembic(db), "head")
    conn = sqlite3.connect(db)
    conn.execute("PRAGMA foreign_keys=ON")
    user = ("00000000000000000000000000000001", "u1", "h", "AFFECTED_PERSON", 1,
            "2026-01-01", "2026-01-01")
    insert = ("INSERT INTO users (id, username, password_hash, role, is_active, created_at, "
              "updated_at) VALUES (?,?,?,?,?,?,?)")
    conn.execute(insert, user)
    with pytest.raises(sqlite3.IntegrityError):  # unique username
        conn.execute(insert, ("00000000000000000000000000000002", *user[1:]))
    with pytest.raises(sqlite3.IntegrityError):  # role must exist
        conn.execute(insert, ("00000000000000000000000000000003", "u3", "h", "SUPERUSER", 1,
                              "2026-01-01", "2026-01-01"))
    conn.close()


def test_url_normalisation():
    assert normalize_database_url("postgres://u:p@h:5432/d") == "postgresql+asyncpg://u:p@h:5432/d"
    assert normalize_database_url("postgresql://u:p@h/d?sslmode=require") == \
        "postgresql+asyncpg://u:p@h/d?ssl=require"
    assert normalize_database_url("sqlite:///./x.db") == "sqlite+aiosqlite:///./x.db"


def test_production_settings_are_strict():
    with pytest.raises(ValidationError):
        Settings(_env_file=None, environment="production", jwt_secret="short",
                 database_url="postgresql://u:p@h/d")
    with pytest.raises(ValidationError):
        Settings(_env_file=None, environment="production", jwt_secret="x" * 40,
                 database_url="sqlite:///./prod.db")
    ok = Settings(_env_file=None, environment="production", jwt_secret="x" * 40,
                  database_url="postgresql://u:p@h/d")
    assert ok.legacy_enabled is False and ok.is_production
    dev = Settings(_env_file=None, environment="development")
    assert dev.jwt_secret_is_ephemeral and len(dev.jwt_secret.get_secret_value()) >= 32
    assert "x" * 40 not in repr(ok)  # secrets are masked in repr/logs
