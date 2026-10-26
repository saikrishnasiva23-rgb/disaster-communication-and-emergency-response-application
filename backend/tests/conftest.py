from __future__ import annotations

import itertools
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.core.config import Settings
from app.main import create_app

ADMIN_USER = "admin"
ADMIN_PASSWORD = "admin-test-password"
PASSWORD = "test-password-1"
_counter = itertools.count(1)


def make_settings(tmp_path: Path, **overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "environment": "testing",
        "database_url": f"sqlite:///{(tmp_path / 'test.db').as_posix()}",
        "auto_create_tables": True,
        "jwt_secret": "test-jwt-secret-that-is-long-enough-0123456789",
        "log_json": False,
        "log_level": "WARNING",
        "legacy_api_enabled": True,
        "initial_admin_username": ADMIN_USER,
        "initial_admin_password": ADMIN_PASSWORD,
        "rate_limit_auth_attempts": 5,
    }
    values.update(overrides)
    return Settings(_env_file=None, **values)


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return make_settings(tmp_path)


@pytest.fixture
def client(settings: Settings) -> Iterator[TestClient]:
    with TestClient(create_app(settings)) as test_client:
        yield test_client


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def login(client: TestClient, username: str, password: str = PASSWORD) -> dict[str, str]:
    response = client.post("/api/v1/auth/login", json={"username": username, "password": password})
    assert response.status_code == 200, response.text
    return auth(response.json()["data"]["access_token"])


@dataclass
class Actor:
    id: str
    username: str
    headers: dict[str, str]


@pytest.fixture
def admin(client: TestClient) -> Actor:
    headers = login(client, ADMIN_USER, ADMIN_PASSWORD)
    me = client.get("/api/v1/auth/me", headers=headers).json()["data"]
    return Actor(me["id"], ADMIN_USER, headers)


def create_user(client: TestClient, admin: Actor, role: str, username: str | None = None) -> Actor:
    username = username or f"{role.lower()}_{next(_counter)}"
    response = client.post(
        "/api/v1/users",
        json={"username": username, "password": PASSWORD, "role": role,
              "full_name": username.title()},
        headers=admin.headers,
    )
    assert response.status_code == 201, response.text
    return Actor(response.json()["data"]["id"], username, login(client, username))


def create_team(client: TestClient, admin: Actor, name: str | None = None, **extra: Any) -> dict:
    response = client.post(
        "/api/v1/rescue-teams",
        json={"name": name or f"Team {next(_counter)}", **extra},
        headers=admin.headers,
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]


def add_member(client: TestClient, admin: Actor, team_id: str, user: Actor) -> None:
    response = client.post(
        f"/api/v1/rescue-teams/{team_id}/members", json={"user_id": user.id}, headers=admin.headers
    )
    assert response.status_code == 201, response.text


@pytest.fixture
def rescuer(client: TestClient, admin: Actor) -> Actor:
    return create_user(client, admin, "RESCUE_TEAM")


@pytest.fixture
def team(client: TestClient, admin: Actor, rescuer: Actor) -> dict:
    team = create_team(client, admin, "Alpha")
    add_member(client, admin, team["id"], rescuer)
    return team


@pytest.fixture
def affected(client: TestClient) -> Actor:
    username = f"affected_{next(_counter)}"
    response = client.post(
        "/api/v1/auth/register", json={"username": username, "password": PASSWORD}
    )
    assert response.status_code == 201, response.text
    data = response.json()["data"]
    return Actor(data["user"]["id"], username, auth(data["access_token"]))


def sos(client_id: str | None = None, **overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "client_emergency_id": client_id or f"sos-{next(_counter)}",
        "emergency_type": "MEDICAL",
        "people_count": 1,
        "injured": True,
        "location": {"latitude": 11.9416, "longitude": 79.8083, "accuracy_m": 12.0},
    }
    body.update(overrides)
    return body


def create_emergency(client: TestClient, actor: Actor, **overrides: Any) -> dict:
    response = client.post("/api/v1/emergencies", json=sos(**overrides), headers=actor.headers)
    assert response.status_code == 201, response.text
    return response.json()["data"]


def error_code(response: Any) -> str:
    body = response.json()
    assert body["success"] is False, body
    return body["error"]["code"]
