from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import create_app
from tests.conftest import error_code, make_settings


def test_health_reports_database_and_no_secrets(client, settings):
    for path in ("/health", "/api/v1/health"):
        response = client.get(path)
        assert response.status_code == 200
        data = response.json()["data"]
        assert data["status"] == "healthy" and data["database"] == "connected"
        assert data["version"] and data["environment"] == "testing"
        text = response.text
        assert settings.jwt_secret.get_secret_value() not in text
        assert "sqlite" not in text.lower() and "test.db" not in text


def test_health_degrades_when_database_is_unreachable(tmp_path):
    settings = make_settings(tmp_path, database_url=f"sqlite:///{(tmp_path / 'missing' / 'x.db').as_posix()}")
    with TestClient(create_app(settings)) as client:
        response = client.get("/health")
        assert response.status_code == 503
        body = response.json()
        assert body["success"] is False and body["data"]["database"] == "unavailable"
        login = client.post("/api/v1/auth/login", json={"username": "a", "password": "b"})
        assert login.status_code == 503 and error_code(login) == "DATABASE_UNAVAILABLE"


def test_error_envelope_and_request_id(client):
    missing = client.get("/api/v1/nope")
    assert missing.status_code == 404 and error_code(missing) == "NOT_FOUND"
    assert missing.json()["error"]["request_id"] == missing.headers["x-request-id"]
    wrong_method = client.delete("/api/v1/emergencies/types")
    assert wrong_method.status_code == 405 and error_code(wrong_method) == "METHOD_NOT_ALLOWED"
    echoed = client.get("/health", headers={"X-Request-ID": "trace-123"})
    assert echoed.headers["x-request-id"] == "trace-123"
    unsafe = client.get("/health", headers={"X-Request-ID": "bad id<script>"})
    assert unsafe.headers["x-request-id"] != "bad id<script>"


def test_malformed_json_is_a_validation_error(client, affected):
    response = client.post("/api/v1/emergencies", content="{not json",
                           headers={**affected.headers, "Content-Type": "application/json"})
    assert response.status_code == 422 and error_code(response) == "VALIDATION_ERROR"


def test_security_headers(client):
    headers = client.get("/health").headers
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["x-frame-options"] == "DENY"


def test_unexpected_errors_are_hidden(tmp_path, monkeypatch):
    from app.services import emergency_service

    async def boom(*args, **kwargs):
        raise RuntimeError("secret internal detail")

    monkeypatch.setattr(emergency_service, "list_emergencies", boom)
    with TestClient(create_app(make_settings(tmp_path)), raise_server_exceptions=False) as client:
        token = client.post("/api/v1/auth/login",
                            json={"username": "admin", "password": "admin-test-password"}).json()["data"]["access_token"]
        response = client.get("/api/v1/emergencies", headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 500 and error_code(response) == "INTERNAL_ERROR"
        assert "secret internal detail" not in response.text


def test_openapi_documents_the_api(client):
    spec = client.get("/openapi.json").json()
    paths = spec["paths"]
    for path in ("/api/v1/auth/login", "/api/v1/emergencies", "/api/v1/emergencies/{emergency_id}/assign",
                 "/api/v1/sync/emergencies", "/api/v1/sync/status", "/api/v1/audit/verify",
                 "/api/v1/rescue-teams", "/api/v1/devices", "/health"):
        assert path in paths, path
    assert "HTTPBearer" in spec["components"]["securitySchemes"]
    assert client.get("/docs").status_code == 200 and client.get("/redoc").status_code == 200


def test_cors_is_off_by_default_and_configurable(tmp_path, client):
    assert "access-control-allow-origin" not in client.get(
        "/health", headers={"Origin": "https://evil.example"}).headers
    settings = make_settings(tmp_path, cors_origins="https://dashboard.example")
    with TestClient(create_app(settings)) as cors_client:
        allowed = cors_client.get("/health", headers={"Origin": "https://dashboard.example"})
        assert allowed.headers["access-control-allow-origin"] == "https://dashboard.example"
        denied = cors_client.get("/health", headers={"Origin": "https://evil.example"})
        assert "access-control-allow-origin" not in denied.headers


def test_health_supports_head(client):
    assert client.head("/health").status_code == 200
