from __future__ import annotations

import sqlite3
import uuid
from datetime import UTC, datetime

from app.db.models import GENESIS_HASH
from app.services.audit_service import compute_hash
from tests.conftest import create_emergency


def _db_path(settings) -> str:
    return settings.database_url.split(":///", 1)[1]


def _verify(client, headers):
    response = client.get("/api/v1/audit/verify", headers=headers)
    assert response.status_code == 200
    return response.json()["data"]


def test_chain_is_valid_and_linked(client, admin, affected):
    create_emergency(client, affected)
    result = _verify(client, admin.headers)
    assert result["valid"] is True and result["entries_checked"] >= 4
    assert "not a decentralized blockchain" in result["note"]
    entries = client.get("/api/v1/audit?page_size=200", headers=admin.headers).json()["data"]
    ordered = list(reversed(entries))
    assert ordered[0]["previous_hash"] == GENESIS_HASH
    for prev, cur in zip(ordered, ordered[1:], strict=False):
        assert cur["previous_hash"] == prev["current_hash"]
        assert cur["sequence"] == prev["sequence"] + 1
    assert "metadata" in entries[0] and "password" not in str(entries)


def test_hash_is_deterministic_and_field_sensitive():
    kwargs = dict(sequence=1, event_id=uuid.UUID(int=1), timestamp=datetime(2026, 1, 1, tzinfo=UTC),
                  actor_user_id=None, actor_label="system", action="X", entity_type="t",
                  entity_id="1", details={"b": 1, "a": 2}, previous_hash=GENESIS_HASH)
    first = compute_hash(**kwargs)
    assert first == compute_hash(**{**kwargs, "details": {"a": 2, "b": 1}})
    assert len(first) == 64
    assert first != compute_hash(**{**kwargs, "action": "Y"})
    assert first != compute_hash(**{**kwargs, "details": {"a": 3, "b": 1}})


def test_modified_entry_is_detected(client, settings, admin, affected):
    create_emergency(client, affected)
    with sqlite3.connect(_db_path(settings)) as conn:
        conn.execute("UPDATE audit_logs SET metadata = '{\"priority\": \"LOW\"}' WHERE sequence = 3")
    result = _verify(client, admin.headers)
    assert result["valid"] is False and result["first_invalid_sequence"] == 3
    assert result["reason"]


def test_deleted_entry_is_detected(client, settings, admin, affected):
    create_emergency(client, affected)
    with sqlite3.connect(_db_path(settings)) as conn:
        conn.execute("DELETE FROM audit_logs WHERE sequence = 2")
    result = _verify(client, admin.headers)
    assert result["valid"] is False and result["first_invalid_sequence"] in (2, 3)


def test_truncated_tail_is_detected(client, settings, admin, affected):
    create_emergency(client, affected)
    with sqlite3.connect(_db_path(settings)) as conn:
        last = conn.execute("SELECT MAX(sequence) FROM audit_logs").fetchone()[0]
        conn.execute("DELETE FROM audit_logs WHERE sequence = ?", (last,))
    assert _verify(client, admin.headers)["valid"] is False


def test_audit_access_control(client, admin, affected, rescuer):
    assert client.get("/api/v1/audit", headers=affected.headers).status_code == 403
    assert client.get("/api/v1/audit", headers=rescuer.headers).status_code == 403
    assert client.get("/api/v1/audit/verify", headers=affected.headers).status_code == 403
    assert client.get("/api/v1/audit/verify", headers=rescuer.headers).status_code == 200


def test_audit_filters(client, admin, affected):
    e = create_emergency(client, affected)
    rows = client.get(f"/api/v1/audit?entity_type=emergency&entity_id={e['id']}",
                      headers=admin.headers).json()["data"]
    assert {r["action"] for r in rows} == {"EMERGENCY_CREATED", "PRIORITY_CALCULATED"}
    by_action = client.get("/api/v1/audit?action=user_registered", headers=admin.headers).json()
    assert by_action["meta"]["total"] == 1
