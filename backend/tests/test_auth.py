from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta

import jwt

from tests.conftest import PASSWORD, auth, create_user, error_code, login


def test_register_creates_affected_person_and_token_works(client):
    response = client.post(
        "/api/v1/auth/register",
        json={"username": "Priya_K", "password": PASSWORD, "role": "ADMIN"},
    )
    assert response.status_code == 201
    data = response.json()["data"]
    # Self-registration can never pick a privileged role.
    assert data["user"]["role"] == "AFFECTED_PERSON"
    assert data["user"]["username"] == "priya_k"
    assert data["token_type"] == "bearer" and data["expires_in"] > 0
    assert "password" not in response.text and "password_hash" not in response.text

    me = client.get("/api/v1/auth/me", headers=auth(data["access_token"]))
    assert me.status_code == 200 and me.json()["data"]["username"] == "priya_k"


def test_duplicate_username_is_rejected(client, affected):
    response = client.post(
        "/api/v1/auth/register", json={"username": affected.username, "password": PASSWORD}
    )
    assert response.status_code == 409 and error_code(response) == "USERNAME_TAKEN"


def test_register_validation(client):
    short = client.post("/api/v1/auth/register", json={"username": "ab", "password": "x"})
    assert short.status_code == 422 and error_code(short) == "VALIDATION_ERROR"
    fields = {d["field"] for d in short.json()["error"]["details"]}
    assert {"username", "password"} <= fields
    # The rejected password is never echoed back.
    assert '"x"' not in short.text


def test_login_by_username_or_email(client, admin):
    client.post(
        "/api/v1/users",
        json={"username": "mail_user", "email": "Mail@Example.org", "password": PASSWORD},
        headers=admin.headers,
    )
    assert login(client, "mail@example.org")
    assert login(client, "MAIL_USER")


def test_wrong_password_and_unknown_user_look_identical(client, affected):
    wrong = client.post("/api/v1/auth/login", json={"username": affected.username, "password": "nope-nope"})
    unknown = client.post("/api/v1/auth/login", json={"username": "ghost", "password": "nope-nope"})
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json()["error"]["message"] == unknown.json()["error"]["message"]
    assert error_code(wrong) == error_code(unknown) == "INVALID_CREDENTIALS"
    assert wrong.headers["www-authenticate"] == "Bearer"


def test_missing_invalid_and_tampered_tokens(client, affected):
    missing = client.get("/api/v1/emergencies")
    assert missing.status_code == 401 and error_code(missing) == "NOT_AUTHENTICATED"

    garbage = client.get("/api/v1/emergencies", headers=auth("not-a-jwt"))
    assert garbage.status_code == 401 and error_code(garbage) == "INVALID_TOKEN"

    token = affected.headers["Authorization"].split()[1]
    tampered = token[:-2] + ("AA" if token[-2:] != "AA" else "BB")
    bad_sig = client.get("/api/v1/emergencies", headers=auth(tampered))
    assert bad_sig.status_code == 401 and error_code(bad_sig) == "INVALID_TOKEN"


def test_expired_token(client, settings, affected):
    past = datetime.now(UTC) - timedelta(hours=2)
    token = jwt.encode(
        {"sub": affected.id, "role": "AFFECTED_PERSON", "type": "access",
         "iat": int(past.timestamp()), "exp": int((past + timedelta(minutes=5)).timestamp())},
        settings.jwt_secret.get_secret_value(),
        algorithm="HS256",
    )
    response = client.get("/api/v1/auth/me", headers=auth(token))
    assert response.status_code == 401 and error_code(response) == "TOKEN_EXPIRED"


def test_token_signed_with_other_secret_or_none_alg_is_rejected(client, affected):
    now = datetime.now(UTC)
    claims = {"sub": affected.id, "role": "ADMIN", "type": "access",
              "iat": int(now.timestamp()), "exp": int((now + timedelta(hours=1)).timestamp())}
    forged = jwt.encode(claims, "some-other-secret-that-is-long-enough!!", algorithm="HS256")
    assert client.get("/api/v1/auth/me", headers=auth(forged)).status_code == 401
    unsigned = jwt.encode(claims, key=None, algorithm="none")
    assert client.get("/api/v1/auth/me", headers=auth(unsigned)).status_code == 401


def test_deactivated_user_loses_access_immediately(client, admin):
    user = create_user(client, admin, "RESCUE_TEAM")
    assert client.get("/api/v1/auth/me", headers=user.headers).status_code == 200
    client.patch(f"/api/v1/users/{user.id}", json={"is_active": False}, headers=admin.headers)
    response = client.get("/api/v1/auth/me", headers=user.headers)
    assert response.status_code == 401
    relogin = client.post("/api/v1/auth/login", json={"username": user.username, "password": PASSWORD})
    assert relogin.status_code == 401


def test_login_rate_limit(client, affected):
    body = {"username": affected.username, "password": "wrong-password"}
    codes = [client.post("/api/v1/auth/login", json=body).status_code for _ in range(6)]
    assert codes[:5] == [401] * 5 and codes[5] == 429
    limited = client.post("/api/v1/auth/login", json=body)
    assert error_code(limited) == "RATE_LIMITED" and int(limited.headers["retry-after"]) > 0


def test_role_based_access_control(client, admin, affected, rescuer):
    assert client.get("/api/v1/users", headers=affected.headers).status_code == 403
    assert client.get("/api/v1/users", headers=rescuer.headers).status_code == 403
    assert client.get("/api/v1/users", headers=admin.headers).status_code == 200
    forbidden = client.post("/api/v1/rescue-teams", json={"name": "X Team"}, headers=rescuer.headers)
    assert forbidden.status_code == 403 and error_code(forbidden) == "FORBIDDEN"
    assert client.get("/api/v1/rescue-teams", headers=affected.headers).status_code == 403
    assert client.get("/api/v1/emergencies/nearby?latitude=1&longitude=1",
                      headers=affected.headers).status_code == 403


def test_users_cannot_escalate_their_own_role(client, affected):
    response = client.patch(
        f"/api/v1/users/{affected.id}", json={"role": "ADMIN"}, headers=affected.headers
    )
    assert response.status_code == 403
    ok = client.patch(f"/api/v1/users/{affected.id}", json={"full_name": "New Name"},
                      headers=affected.headers)
    assert ok.status_code == 200 and ok.json()["data"]["role"] == "AFFECTED_PERSON"


def test_passwords_and_tokens_are_not_logged(client, caplog):
    caplog.set_level(logging.DEBUG)
    secret_password = "very-secret-password-42"
    response = client.post("/api/v1/auth/register",
                           json={"username": "logcheck", "password": secret_password})
    token = response.json()["data"]["access_token"]
    client.get("/api/v1/auth/me", headers=auth(token))
    client.post("/api/v1/auth/login", json={"username": "logcheck", "password": "wrong-one-1"})
    logged = "\n".join(r.getMessage() + str(r.__dict__) for r in caplog.records)
    assert secret_password not in logged
    assert token not in logged


def test_audit_records_logins(client, admin, affected):
    client.post("/api/v1/auth/login", json={"username": affected.username, "password": "bad-password"})
    actions = [e["action"] for e in client.get("/api/v1/audit?page_size=200", headers=admin.headers).json()["data"]]
    assert "LOGIN_FAILED" in actions and "LOGIN_SUCCEEDED" in actions and "USER_REGISTERED" in actions
