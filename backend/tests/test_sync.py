from __future__ import annotations

from datetime import UTC, datetime, timedelta

from tests.conftest import create_emergency, error_code, sos


def _item(client_id: str, **extra):
    body = sos(client_id, **extra)
    return body


def _upload(client, actor, items, device_id="console-1"):
    response = client.post("/api/v1/sync/emergencies", json={"device_id": device_id, "items": items},
                           headers=actor.headers)
    assert response.status_code == 200, response.text
    return response.json()["data"]


def test_upload_mixed_batch_and_retry(client, rescuer, affected):
    create_emergency(client, rescuer, client_id="existing-1")
    future = (datetime.now(UTC) + timedelta(days=2)).isoformat()
    items = [
        _item("new-1", origin_device_id="phone-1", sender_display_name="OPPO"),
        _item("existing-1"),
        _item("existing-1-changed"),
        _item("bad-time", occurred_at=future),
    ]
    items[2]["client_emergency_id"] = "existing-1"
    items[2]["people_count"] = 7
    result = _upload(client, rescuer, items)
    outcomes = [r["result"] for r in result["results"]]
    assert outcomes == ["created", "duplicate", "conflict", "invalid"]
    assert result["counts"]["created"] == 1 and result["counts"]["invalid"] == 1
    assert result["results"][3]["error"]["code"] == "INVALID_TIMESTAMP"
    assert result["results"][2]["error"]["code"] == "IDEMPOTENCY_CONFLICT"

    retry = _upload(client, rescuer, items[:2])
    assert [r["result"] for r in retry["results"]] == ["duplicate", "duplicate"]
    assert retry["results"][0]["emergency_id"] == result["results"][0]["emergency_id"]

    listing = client.get("/api/v1/emergencies?page_size=200", headers=rescuer.headers).json()
    assert listing["meta"]["total"] == 2  # nothing duplicated, nothing lost
    flagged = [e for e in listing["data"] if e["client_emergency_id"] == "existing-1"][0]
    assert flagged["sync_state"] == "CONFLICT" and flagged["people_count"] == 1  # original kept

    devices = client.get("/api/v1/devices", headers=rescuer.headers).json()["data"]
    assert any(d["client_device_id"] == "console-1" and d["last_sync_at"] for d in devices)


def test_upload_requires_client_ids_and_respects_batch_limit(client, rescuer, settings):
    body = sos()
    body.pop("client_emergency_id")
    missing = client.post("/api/v1/sync/emergencies", json={"items": [body]}, headers=rescuer.headers)
    assert missing.status_code == 422
    too_many = [_item(f"bulk-{i}") for i in range(settings.sync_batch_limit + 1)]
    response = client.post("/api/v1/sync/emergencies", json={"items": too_many}, headers=rescuer.headers)
    assert response.status_code == 422 and error_code(response) == "BATCH_TOO_LARGE"


def test_pull_with_cursor_returns_every_change_once(client, rescuer):
    ids = {create_emergency(client, rescuer)["id"] for _ in range(5)}
    seen, cursor, pages = [], None, 0
    while True:
        url = "/api/v1/sync/emergencies?limit=2" + (f"&cursor={cursor}" if cursor else "")
        data = client.get(url, headers=rescuer.headers).json()["data"]
        seen += [e["id"] for e in data["items"]]
        pages += 1
        cursor = data["next_cursor"] or cursor
        if not data["has_more"]:
            break
    assert pages == 3 and len(seen) == len(set(seen)) == 5 and set(seen) == ids

    # Caught up: nothing new with the saved cursor...
    empty = client.get(f"/api/v1/sync/emergencies?cursor={cursor}", headers=rescuer.headers).json()["data"]
    assert empty["items"] == [] and empty["next_cursor"] is None
    # ...until something changes.
    changed = sorted(ids)[0]
    client.post(f"/api/v1/emergencies/{changed}/acknowledge", headers=rescuer.headers)
    later = client.get(f"/api/v1/sync/emergencies?cursor={cursor}", headers=rescuer.headers).json()["data"]
    assert [e["id"] for e in later["items"]] == [changed]
    assert later["items"][0]["status"] == "ACKNOWLEDGED"


def test_pull_rejects_bad_cursor_and_scopes_affected(client, rescuer, affected):
    bad = client.get("/api/v1/sync/emergencies?cursor=%%%garbage", headers=rescuer.headers)
    assert bad.status_code == 422 and error_code(bad) == "INVALID_CURSOR"
    create_emergency(client, rescuer)
    mine = create_emergency(client, affected)
    items = client.get("/api/v1/sync/emergencies", headers=affected.headers).json()["data"]["items"]
    assert [e["id"] for e in items] == [mine["id"]]


def _status(update_id, status, when, **extra):
    return {"update_id": update_id, "status": status, "changed_at": when.isoformat(), **extra}


def test_status_sync_replays_in_order_and_is_idempotent(client, rescuer, team, affected):
    e = create_emergency(client, affected, client_id="offline-flow")
    t = datetime.now(UTC)
    items = [  # deliberately out of order; the server replays by changed_at
        _status("u3", "IN_PROGRESS", t + timedelta(seconds=3), emergency_id=e["id"]),
        _status("u1", "ACKNOWLEDGED", t + timedelta(seconds=1), client_emergency_id="offline-flow"),
        _status("u2", "ASSIGNED", t + timedelta(seconds=2), emergency_id=e["id"], team_id=team["id"]),
        _status("u4", "RESOLVED", t + timedelta(seconds=4), emergency_id=e["id"], outcome="RESCUED"),
        _status("u5", "CANCELLED", t, client_emergency_id="does-not-exist"),
    ]
    first = client.post("/api/v1/sync/status", json={"device_id": "console-1", "items": items},
                        headers=rescuer.headers).json()["data"]
    assert [r["update_id"] for r in first["results"]] == ["u3", "u1", "u2", "u4", "u5"]
    assert {r["update_id"]: r["result"] for r in first["results"]} == {
        "u1": "applied", "u2": "applied", "u3": "applied", "u4": "applied", "u5": "not_found"}
    detail = client.get(f"/api/v1/emergencies/{e['id']}", headers=rescuer.headers).json()["data"]
    assert detail["status"] == "RESOLVED"
    assert all(h["via"] == "SYNC" for h in detail["status_history"][2:])

    retry = client.post("/api/v1/sync/status", json={"items": items[:4]}, headers=rescuer.headers).json()["data"]
    assert {r["result"] for r in retry["results"]} == {"duplicate"}


def test_stale_offline_update_is_a_conflict_not_an_overwrite(client, rescuer, team, affected):
    e = create_emergency(client, affected)
    long_ago = datetime.now(UTC) - timedelta(minutes=30)
    client.post(f"/api/v1/emergencies/{e['id']}/assign", json={"team_id": team["id"]},
                headers=rescuer.headers)
    stale = client.post("/api/v1/sync/status", json={"items": [
        _status("stale-1", "CANCELLED", long_ago, emergency_id=e["id"])]},
        headers=rescuer.headers).json()["data"]["results"][0]
    assert stale["result"] == "conflict" and stale["current_status"] == "ASSIGNED"
    assert stale["error"]["code"] == "STALE_UPDATE"
    status_now = client.get(f"/api/v1/emergencies/{e['id']}", headers=rescuer.headers).json()["data"]["status"]
    assert status_now == "ASSIGNED"


def test_status_sync_validation(client, rescuer, affected, team):
    e = create_emergency(client, affected)
    now = datetime.now(UTC)
    results = client.post("/api/v1/sync/status", json={"items": [
        _status("v1", "RESOLVED", now, emergency_id=e["id"], outcome="RESCUED"),  # invalid transition
        _status("v2", "ASSIGNED", now + timedelta(seconds=1), emergency_id=e["id"]),  # no team
        _status("v3", "RECEIVED", now + timedelta(seconds=2), emergency_id=e["id"]),
        _status("v4", "ACKNOWLEDGED", now + timedelta(days=3), emergency_id=e["id"]),  # future
    ]}, headers=rescuer.headers).json()["data"]["results"]
    by_id = {r["update_id"]: r for r in results}
    assert by_id["v1"]["result"] == "conflict"
    assert by_id["v1"]["error"]["code"] == "INVALID_STATUS_TRANSITION"
    assert by_id["v2"]["result"] == "invalid" and by_id["v2"]["error"]["code"] == "TEAM_REQUIRED"
    assert by_id["v3"]["result"] == "invalid" and by_id["v3"]["error"]["code"] == "INVALID_SYNC_STATUS"
    assert by_id["v4"]["result"] == "invalid"

    # Affected persons may only cancel their own emergency.
    own = client.post("/api/v1/sync/status", json={"items": [
        _status("a1", "ACKNOWLEDGED", now + timedelta(seconds=5), emergency_id=e["id"]),
        _status("a2", "CANCELLED", now + timedelta(seconds=6), emergency_id=e["id"]),
    ]}, headers=affected.headers).json()["data"]["results"]
    assert [r["result"] for r in own] == ["invalid", "applied"]


def test_offline_change_made_before_the_upload_is_not_stale(client, rescuer, team):
    """A console assigns a team while offline, and only later uploads the SOS
    and the change: the server's RECEIVED (stamped at upload) must not make
    the earlier offline change look stale."""
    handled_offline_at = datetime.now(UTC) - timedelta(minutes=10)
    _upload(client, rescuer, [_item("offline-first", occurred_at=(
        handled_offline_at - timedelta(minutes=5)).isoformat())])
    result = client.post("/api/v1/sync/status", json={"items": [
        _status("of-1", "ASSIGNED", handled_offline_at, client_emergency_id="offline-first",
                team_id=team["id"])]}, headers=rescuer.headers).json()["data"]["results"][0]
    assert result["result"] == "applied", result
