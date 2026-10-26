from __future__ import annotations

from tests.conftest import create_user, error_code

PHONE = {"client_device_id": "phone-xyz", "device_type": "AFFECTED_PHONE", "platform": "ANDROID",
         "device_name": "Redmi Note 13", "app_version": "1.0.0"}


def test_device_registration_is_idempotent(client, affected):
    first = client.post("/api/v1/devices", json=PHONE, headers=affected.headers)
    second = client.post("/api/v1/devices", json={**PHONE, "app_version": "1.0.1"}, headers=affected.headers)
    assert (first.status_code, second.status_code) == (201, 200)
    assert first.json()["data"]["id"] == second.json()["data"]["id"]
    assert second.json()["data"]["app_version"] == "1.0.1"
    mine = client.get("/api/v1/devices", headers=affected.headers).json()
    assert mine["meta"]["total"] == 1


def test_device_owned_by_someone_else(client, affected, rescuer):
    client.post("/api/v1/devices", json=PHONE, headers=affected.headers)
    clash = client.post("/api/v1/devices", json=PHONE, headers=rescuer.headers)
    assert clash.status_code == 409 and error_code(clash) == "DEVICE_OWNED_BY_ANOTHER_USER"
    device_id = client.get("/api/v1/devices", headers=affected.headers).json()["data"][0]["id"]
    assert client.get(f"/api/v1/devices/{device_id}", headers=rescuer.headers).status_code == 403
    deactivate = client.patch(f"/api/v1/devices/{device_id}", json={"is_active": False},
                              headers=affected.headers)
    assert deactivate.status_code == 403


def test_device_validation(client, affected):
    bad = client.post("/api/v1/devices", json={**PHONE, "client_device_id": "has spaces!"},
                      headers=affected.headers)
    assert bad.status_code == 422
    bad_platform = client.post("/api/v1/devices", json={**PHONE, "platform": "SYMBIAN"},
                               headers=affected.headers)
    assert bad_platform.status_code == 422


def test_team_management(client, admin, rescuer, affected):
    created = client.post("/api/v1/rescue-teams", json={
        "name": "Delta", "capabilities": ["boat", "first_aid"],
        "base_latitude": 11.9, "base_longitude": 79.8}, headers=admin.headers)
    assert created.status_code == 201
    team = created.json()["data"]
    assert team["capabilities"] == ["BOAT", "FIRST_AID"] and team["status"] == "AVAILABLE"

    dup = client.post("/api/v1/rescue-teams", json={"name": "Delta"}, headers=admin.headers)
    assert dup.status_code == 409
    half = client.post("/api/v1/rescue-teams", json={"name": "Echo", "base_latitude": 1},
                       headers=admin.headers)
    assert half.status_code == 422

    not_rescuer = client.post(f"/api/v1/rescue-teams/{team['id']}/members",
                              json={"user_id": affected.id}, headers=admin.headers)
    assert not_rescuer.status_code == 422 and error_code(not_rescuer) == "INVALID_TEAM_MEMBER"
    added = client.post(f"/api/v1/rescue-teams/{team['id']}/members",
                        json={"user_id": rescuer.id, "member_role": "LEADER"}, headers=admin.headers)
    assert added.status_code == 201
    twice = client.post(f"/api/v1/rescue-teams/{team['id']}/members",
                        json={"user_id": rescuer.id}, headers=admin.headers)
    assert twice.status_code == 409

    # Members may report status and location, but not rename the team.
    loc = client.patch(f"/api/v1/rescue-teams/{team['id']}",
                       json={"status": "OFFLINE", "current_latitude": 11.95, "current_longitude": 79.81},
                       headers=rescuer.headers)
    assert loc.status_code == 200
    assert loc.json()["data"]["status"] == "OFFLINE" and loc.json()["data"]["location_updated_at"]
    rename = client.patch(f"/api/v1/rescue-teams/{team['id']}", json={"name": "Mine"},
                          headers=rescuer.headers)
    assert rename.status_code == 403
    outsider = create_user(client, admin, "RESCUE_TEAM")
    assert client.patch(f"/api/v1/rescue-teams/{team['id']}", json={"status": "AVAILABLE"},
                        headers=outsider.headers).status_code == 403

    offline = client.get("/api/v1/rescue-teams?status=OFFLINE", headers=rescuer.headers).json()["data"]
    assert [t["name"] for t in offline] == ["Delta"]
    detail = client.get(f"/api/v1/rescue-teams/{team['id']}", headers=rescuer.headers).json()["data"]
    assert detail["members"][0]["member_role"] == "LEADER"

    removed = client.delete(f"/api/v1/rescue-teams/{team['id']}/members/{rescuer.id}",
                            headers=admin.headers)
    assert removed.status_code == 200
    assert client.get(f"/api/v1/rescue-teams/{team['id']}", headers=admin.headers).json()["data"]["members"] == []
