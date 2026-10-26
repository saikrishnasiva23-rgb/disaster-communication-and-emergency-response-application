"""The Flutter app's existing calls to the old Flask server keep working."""

from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import create_app
from tests.conftest import make_settings

OLD_BODY = {  # exactly what SosPacket.toBackendJson() sends
    "name": "OPPO A5 Pro 5G",
    "emergencyType": "Medical Emergency",
    "numberOfPeople": 2,
    "injured": "Yes",
    "latitude": 11.9416,
    "longitude": 79.8083,
    "message": "Need help",
}


def test_legacy_submit_and_list(client, admin):
    response = client.post("/api/rescue-request", json=OLD_BODY)
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True and body["requestId"]
    assert body["priority"] in {"Low", "Medium", "High", "Critical"}
    assert 0 <= body["confidence"] <= 100

    listing = client.get("/api/rescue-requests").json()
    assert listing["success"] is True
    row = listing["requests"][0]
    assert set(row) == {"id", "name", "emergency_type", "number_of_people", "injured", "latitude",
                        "longitude", "message", "status", "priority_score", "priority_level"}
    assert row["name"] == "OPPO A5 Pro 5G" and row["injured"] == "Yes"
    assert row["emergency_type"] == "Medical Emergency" and row["status"] == "Pending"

    # Stored as a normal emergency, visible to the v1 API, audited.
    v1 = client.get("/api/v1/emergencies", headers=admin.headers).json()["data"][0]
    assert v1["source"] == "LEGACY_API" and v1["emergency_type"] == "MEDICAL"


def test_legacy_without_gps_is_kept_with_null_coordinates(client):
    body = {**OLD_BODY, "latitude": None, "longitude": None}
    assert client.post("/api/rescue-request", json=body).json()["success"] is True
    row = client.get("/api/rescue-requests").json()["requests"][0]
    assert row["latitude"] is None and row["longitude"] is None  # never 0,0


def test_legacy_validation_matches_old_shape(client):
    no_name = client.post("/api/rescue-request", json={**OLD_BODY, "name": ""})
    assert no_name.status_code == 400 and no_name.json() == {
        "success": False, "message": "Invalid or missing field: name"}
    empty = client.post("/api/rescue-request", json={})
    assert empty.status_code == 400 and empty.json()["message"] == "No data received"
    bad_lat = client.post("/api/rescue-request", json={**OLD_BODY, "latitude": 123})
    assert bad_lat.status_code == 400
    unknown_type = client.post("/api/rescue-request", json={**OLD_BODY, "emergencyType": "Gas leak"})
    assert unknown_type.status_code == 200


def test_legacy_endpoints_can_be_disabled(tmp_path):
    with TestClient(create_app(make_settings(tmp_path, legacy_api_enabled=False))) as client:
        assert client.post("/api/rescue-request", json=OLD_BODY).status_code == 404
        assert client.get("/api/rescue-requests").status_code == 404


def test_legacy_with_packet_id_is_idempotent_and_matches_laptop_sync(client, rescuer):
    body = {**OLD_BODY, "clientEmergencyId": "abc123-1727700000000000",
            "occurredAt": "2026-09-30T10:00:00Z", "originDeviceId": "affected-1234abcd",
            "accuracy": 8.5}
    first = client.post("/api/rescue-request", json=body).json()
    again = client.post("/api/rescue-request", json=body).json()
    assert first["requestId"] == again["requestId"]
    # The rescue laptop later syncs the same SOS (as it received it over BLE).
    sync = client.post("/api/v1/sync/emergencies", headers=rescuer.headers, json={
        "device_id": "rescue-console-1",
        "items": [{
            "client_emergency_id": "abc123-1727700000000000",
            "emergency_type": "Medical Emergency",
            "description": "Need help",
            "people_count": 2,
            "injured": True,
            "occurred_at": "2026-09-30T10:00:00Z",
            "location": {"latitude": 11.9416, "longitude": 79.8083, "accuracy_m": 8.5},
            "origin_device_id": "affected-1234abcd",
            "sender_display_name": "OPPO A5 Pro 5G",
            "source": "BLE",
            "local_ble_acknowledged": True,
        }],
    }).json()["data"]
    assert sync["results"][0]["result"] == "duplicate"
    assert sync["results"][0]["emergency_id"] == first["requestId"]
