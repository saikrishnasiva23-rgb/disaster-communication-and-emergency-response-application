from __future__ import annotations

from datetime import UTC, datetime, timedelta

from tests.conftest import create_emergency, error_code, sos


def test_create_emergency_with_gps(client, affected):
    response = client.post("/api/v1/emergencies", json=sos("ble-001"), headers=affected.headers)
    assert response.status_code == 201
    body = response.json()
    assert body["success"] is True and body["message"] == "Emergency received."
    e = body["data"]
    assert e["client_emergency_id"] == "ble-001"
    assert e["status"] == "RECEIVED"
    assert e["latitude"] == 11.9416 and e["longitude"] == 79.8083
    assert e["location_available"] is True
    assert e["priority"] in {"LOW", "MEDIUM", "HIGH", "CRITICAL"}
    assert 0 <= e["priority_score"] <= 1 and e["priority_reason"]
    assert e["source"] == "MOBILE_APP" and e["sender_user_id"] == affected.id
    assert e["cloud_acknowledged_at"] is None


def test_emergency_without_gps_is_stored_without_coordinates(client, affected):
    e = create_emergency(client, affected, location=None)
    assert e["latitude"] is None and e["longitude"] is None
    assert e["location_available"] is False
    detail = client.get(f"/api/v1/emergencies/{e['id']}", headers=affected.headers).json()["data"]
    assert detail["locations"] == []


def test_gps_validation(client, affected):
    for bad in ({"latitude": 90.5, "longitude": 10}, {"latitude": -91, "longitude": 10},
                {"latitude": 10, "longitude": 180.01}, {"latitude": 10, "longitude": -181},
                {"latitude": 10}, {"latitude": "north", "longitude": 1}):
        response = client.post("/api/v1/emergencies", json=sos(location=bad), headers=affected.headers)
        assert response.status_code == 422, bad
        assert error_code(response) == "VALIDATION_ERROR"
    edge = create_emergency(client, affected, location={"latitude": -90, "longitude": 180})
    assert (edge["latitude"], edge["longitude"]) == (-90, 180)


def test_nan_coordinates_rejected(client, affected):
    raw = ('{"client_emergency_id":"nan-1","emergency_type":"FIRE",'
           '"location":{"latitude":NaN,"longitude":1}}')
    response = client.post("/api/v1/emergencies", content=raw,
                           headers={**affected.headers, "Content-Type": "application/json"})
    assert response.status_code == 422


def test_emergency_types_and_aliases(client, affected):
    types = client.get("/api/v1/emergencies/types").json()["data"]
    codes = {t["code"] for t in types}
    assert {"FLOOD", "EARTHQUAKE", "CYCLONE", "LANDSLIDE", "FIRE", "MEDICAL",
            "TRAPPED_PERSON", "MISSING_PERSON", "OTHER"} <= codes
    assert create_emergency(client, affected, emergency_type="Medical Emergency")["emergency_type"] == "MEDICAL"
    assert create_emergency(client, affected, emergency_type="trapped")["emergency_type"] == "TRAPPED_PERSON"
    bad = client.post("/api/v1/emergencies", json=sos(emergency_type="ALIENS"), headers=affected.headers)
    assert bad.status_code == 422


def test_idempotent_resubmission(client, affected):
    first = client.post("/api/v1/emergencies", json=sos("dup-1"), headers=affected.headers)
    again = client.post("/api/v1/emergencies", json=sos("dup-1"), headers=affected.headers)
    assert first.status_code == 201 and again.status_code == 200
    assert first.json()["data"]["id"] == again.json()["data"]["id"]
    assert again.json()["data"]["sync_count"] == 2
    listing = client.get("/api/v1/emergencies", headers=affected.headers).json()
    assert listing["meta"]["total"] == 1


def test_same_id_with_different_content_conflicts(client, affected):
    create_emergency(client, affected, client_id="dup-2")
    response = client.post("/api/v1/emergencies", json=sos("dup-2", people_count=9),
                           headers=affected.headers)
    assert response.status_code == 409 and error_code(response) == "IDEMPOTENCY_CONFLICT"


def test_idempotency_key_header(client, affected):
    body = sos()
    body.pop("client_emergency_id")
    headers = {**affected.headers, "Idempotency-Key": "hdr-key-1"}
    one = client.post("/api/v1/emergencies", json=body, headers=headers)
    two = client.post("/api/v1/emergencies", json=body, headers=headers)
    assert (one.status_code, two.status_code) == (201, 200)
    assert one.json()["data"]["client_emergency_id"] == "hdr-key-1"
    mismatch = client.post("/api/v1/emergencies", json=sos("other-id"), headers=headers)
    assert mismatch.status_code == 422 and error_code(mismatch) == "IDEMPOTENCY_KEY_MISMATCH"


def test_server_generates_id_when_client_sends_none(client, affected):
    body = sos()
    body.pop("client_emergency_id")
    a = client.post("/api/v1/emergencies", json=body, headers=affected.headers).json()["data"]
    b = client.post("/api/v1/emergencies", json=body, headers=affected.headers).json()["data"]
    assert a["client_emergency_id"].startswith("srv-") and a["id"] != b["id"]


def test_timestamp_validation(client, affected):
    future = (datetime.now(UTC) + timedelta(days=1)).isoformat()
    response = client.post("/api/v1/emergencies", json=sos(occurred_at=future), headers=affected.headers)
    assert response.status_code == 422 and error_code(response) == "INVALID_TIMESTAMP"
    ancient = client.post("/api/v1/emergencies", json=sos(occurred_at="1999-01-01T00:00:00Z"),
                          headers=affected.headers)
    assert ancient.status_code == 422
    naive = create_emergency(client, affected, occurred_at="2026-01-02T03:04:05")
    assert naive["occurred_at"].startswith("2026-01-02T03:04:05")


def test_affected_person_sees_only_own_emergencies(client, affected, admin):
    from tests.conftest import Actor, auth

    other = client.post("/api/v1/auth/register", json={"username": "other_person", "password": "other-pass-1"})
    other_actor = Actor(other.json()["data"]["user"]["id"], "other_person",
                        auth(other.json()["data"]["access_token"]))
    mine = create_emergency(client, affected)
    theirs = create_emergency(client, other_actor)

    ids = {e["id"] for e in client.get("/api/v1/emergencies", headers=affected.headers).json()["data"]}
    assert ids == {mine["id"]}
    denied = client.get(f"/api/v1/emergencies/{theirs['id']}", headers=affected.headers)
    assert denied.status_code == 403
    all_ids = {e["id"] for e in client.get("/api/v1/emergencies", headers=admin.headers).json()["data"]}
    assert {mine["id"], theirs["id"]} <= all_ids


def test_rescuer_upload_from_ble_records_origin_device(client, rescuer):
    e = create_emergency(client, rescuer, origin_device_id="phone-abc", sender_display_name="OPPO A5",
                         local_ble_acknowledged=True)
    assert e["source"] == "BLE" and e["origin_client_device_id"] == "phone-abc"
    assert e["sender_display_name"] == "OPPO A5" and e["local_ble_acknowledged"] is True
    assert e["cloud_acknowledged_at"] is None  # BLE ACK and cloud ACK stay separate
    relayed = create_emergency(client, rescuer, hop_count=1, relayed_by_device_id="relay-1",
                               origin_device_id="phone-def")
    assert relayed["source"] == "BLE_RELAY"


def test_affected_cannot_claim_another_users_device(client, affected, admin):
    create_emergency(client, affected, origin_device_id="phone-owned")
    other = client.post("/api/v1/auth/register", json={"username": "thief", "password": "thief-pass-1"})
    headers = {"Authorization": f"Bearer {other.json()['data']['access_token']}"}
    response = client.post("/api/v1/emergencies", json=sos(origin_device_id="phone-owned"), headers=headers)
    assert response.status_code == 403


def test_list_filters_and_ordering(client, rescuer):
    low = create_emergency(client, rescuer, emergency_type="OTHER", injured=False, location=None)
    critical = create_emergency(client, rescuer, emergency_type="TRAPPED_PERSON", trapped=True,
                                people_count=12, severity=5)
    data = client.get("/api/v1/emergencies", headers=rescuer.headers).json()["data"]
    assert data[0]["id"] == critical["id"]  # highest priority first
    only_other = client.get("/api/v1/emergencies?type=OTHER", headers=rescuer.headers).json()["data"]
    assert [e["id"] for e in only_other] == [low["id"]]
    by_priority = client.get(f"/api/v1/emergencies?priority={critical['priority']}",
                             headers=rescuer.headers).json()["data"]
    assert critical["id"] in {e["id"] for e in by_priority}
    region = client.get("/api/v1/emergencies?min_lat=11&max_lat=12&min_lon=79&max_lon=80",
                        headers=rescuer.headers).json()["data"]
    assert low["id"] not in {e["id"] for e in region}  # no GPS -> not in any region
    partial = client.get("/api/v1/emergencies?min_lat=11", headers=rescuer.headers)
    assert partial.status_code == 422 and error_code(partial) == "INCOMPLETE_REGION"
    page = client.get("/api/v1/emergencies?page=1&page_size=1", headers=rescuer.headers).json()
    assert len(page["data"]) == 1 and page["meta"]["has_next"] is True


def test_nearby_query(client, rescuer):
    near = create_emergency(client, rescuer, location={"latitude": 11.9420, "longitude": 79.8090})
    farther = create_emergency(client, rescuer, location={"latitude": 11.9800, "longitude": 79.8083})
    create_emergency(client, rescuer, location={"latitude": 13.0827, "longitude": 80.2707})  # ~150 km
    create_emergency(client, rescuer, location=None)
    response = client.get("/api/v1/emergencies/nearby?latitude=11.9416&longitude=79.8083&radius_km=10",
                          headers=rescuer.headers)
    hits = response.json()["data"]
    assert [h["id"] for h in hits] == [near["id"], farther["id"]]
    assert hits[0]["distance_km"] < hits[1]["distance_km"] < 10
    too_big = client.get("/api/v1/emergencies/nearby?latitude=0&longitude=0&radius_km=900",
                         headers=rescuer.headers)
    assert too_big.status_code == 422


def test_patch_updates_and_reprioritizes(client, affected):
    e = create_emergency(client, affected, emergency_type="OTHER", injured=False)
    response = client.patch(f"/api/v1/emergencies/{e['id']}",
                            json={"trapped": True, "people_count": 10, "severity": 5},
                            headers=affected.headers)
    assert response.status_code == 200
    updated = response.json()["data"]
    assert updated["people_count"] == 10
    order = ["LOW", "MEDIUM", "HIGH", "CRITICAL"]
    assert order.index(updated["priority"]) > order.index(e["priority"])
    empty = client.patch(f"/api/v1/emergencies/{e['id']}", json={}, headers=affected.headers)
    assert empty.status_code == 422


def test_patch_status_rules(client, affected, rescuer):
    e = create_emergency(client, affected)
    workflow = client.patch(f"/api/v1/emergencies/{e['id']}", json={"status": "IN_PROGRESS"},
                            headers=rescuer.headers)
    assert workflow.status_code == 422 and error_code(workflow) == "USE_WORKFLOW_ENDPOINT"
    reject = client.patch(f"/api/v1/emergencies/{e['id']}", json={"status": "REJECTED"},
                          headers=affected.headers)
    assert reject.status_code == 403
    cancel = client.patch(f"/api/v1/emergencies/{e['id']}",
                          json={"status": "CANCELLED", "status_reason": "Found safety"},
                          headers=affected.headers)
    assert cancel.status_code == 200 and cancel.json()["data"]["status"] == "CANCELLED"
    closed = client.patch(f"/api/v1/emergencies/{e['id']}", json={"description": "x"},
                          headers=affected.headers)
    assert closed.status_code == 409 and error_code(closed) == "EMERGENCY_CLOSED"


def test_location_updates_keep_history_and_never_move_backwards(client, affected):
    e = create_emergency(client, affected, occurred_at=(datetime.now(UTC) - timedelta(minutes=30)).isoformat())
    newer = {"latitude": 11.95, "longitude": 79.81, "accuracy_m": 5,
             "recorded_at": (datetime.now(UTC) - timedelta(minutes=5)).isoformat()}
    older = {"latitude": 11.90, "longitude": 79.70,
             "recorded_at": (datetime.now(UTC) - timedelta(minutes=20)).isoformat()}
    assert client.post(f"/api/v1/emergencies/{e['id']}/locations", json=newer,
                       headers=affected.headers).status_code == 201
    assert client.post(f"/api/v1/emergencies/{e['id']}/locations", json=older,
                       headers=affected.headers).status_code == 201
    current = client.get(f"/api/v1/emergencies/{e['id']}", headers=affected.headers).json()["data"]
    assert (current["latitude"], current["longitude"]) == (11.95, 79.81)
    history = client.get(f"/api/v1/emergencies/{e['id']}/locations", headers=affected.headers).json()["data"]
    assert len(history) == 3
    assert [h["latitude"] for h in history] == sorted(
        [h["latitude"] for h in history], key=lambda lat: [11.9416, 11.90, 11.95].index(lat)
    )
    bad = client.post(f"/api/v1/emergencies/{e['id']}/locations",
                      json={"latitude": 100, "longitude": 0}, headers=affected.headers)
    assert bad.status_code == 422


def test_unknown_emergency_is_404(client, rescuer):
    response = client.get("/api/v1/emergencies/00000000-0000-0000-0000-000000000000",
                          headers=rescuer.headers)
    assert response.status_code == 404 and error_code(response) == "EMERGENCY_NOT_FOUND"
    malformed = client.get("/api/v1/emergencies/not-a-uuid", headers=rescuer.headers)
    assert malformed.status_code == 422
