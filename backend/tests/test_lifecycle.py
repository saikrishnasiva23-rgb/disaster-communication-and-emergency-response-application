from __future__ import annotations

import pytest

from app.core.errors import InvalidTransitionError
from app.domain.enums import EmergencyStatus as S
from app.domain.lifecycle import ALLOWED_TRANSITIONS, TERMINAL_STATUSES, ensure_transition
from tests.conftest import add_member, create_emergency, create_team, create_user, error_code


def test_transition_table_invariants():
    assert set(ALLOWED_TRANSITIONS) == set(S)
    for status in TERMINAL_STATUSES:
        assert ALLOWED_TRANSITIONS[status] == frozenset()
    for status in set(S) - TERMINAL_STATUSES:
        assert S.CANCELLED in ALLOWED_TRANSITIONS[status]
    ensure_transition(S.RECEIVED, S.ACKNOWLEDGED)
    with pytest.raises(InvalidTransitionError):
        ensure_transition(S.RECEIVED, S.RESOLVED)
    with pytest.raises(InvalidTransitionError):
        ensure_transition(S.RESOLVED, S.ASSIGNED)


def test_full_rescue_workflow(client, affected, rescuer, team):
    e = create_emergency(client, affected)
    eid = e["id"]
    url = f"/api/v1/emergencies/{eid}"

    ack = client.post(f"{url}/acknowledge", json={"notes": "seen"}, headers=rescuer.headers)
    assert ack.status_code == 200 and ack.json()["data"]["status"] == "ACKNOWLEDGED"
    assert ack.json()["data"]["cloud_acknowledged_at"] is not None
    again = client.post(f"{url}/acknowledge", headers=rescuer.headers)
    assert again.status_code == 200 and again.json()["message"] == "Already acknowledged."

    assign = client.post(f"{url}/assign", json={"team_id": team["id"]}, headers=rescuer.headers)
    assert assign.status_code == 200 and assign.json()["data"]["status"] == "ASSIGNED"
    teams = client.get("/api/v1/rescue-teams", headers=rescuer.headers).json()["data"]
    assert teams[0]["status"] == "BUSY" and teams[0]["active_assignments"] == 1

    accept = client.post(f"{url}/accept", headers=rescuer.headers)
    assert accept.status_code == 200 and accept.json()["data"]["status"] == "IN_PROGRESS"

    resolve = client.post(f"{url}/resolve", json={"outcome": "RESCUED", "resolution_notes": "Safe"},
                          headers=rescuer.headers)
    data = resolve.json()["data"]
    assert data["status"] == "RESOLVED" and data["resolution_outcome"] == "RESCUED"
    assert data["resolved_at"] is not None

    team_after = client.get(f"/api/v1/rescue-teams/{team['id']}", headers=rescuer.headers).json()["data"]
    assert team_after["status"] == "AVAILABLE" and team_after["active_assignments"] == 0

    detail = client.get(url, headers=affected.headers).json()["data"]
    assert [h["to_status"] for h in detail["status_history"]] == [
        "CREATED", "RECEIVED", "ACKNOWLEDGED", "ASSIGNED", "IN_PROGRESS", "RESOLVED"]
    assert [a["status"] for a in detail["assignments"]] == ["COMPLETED"]

    history = client.get(f"/api/v1/rescue-teams/{team['id']}/assignments",
                         headers=rescuer.headers).json()["data"]
    assert len(history) == 1 and history[0]["completed_at"] is not None


def test_assign_auto_acknowledges_received(client, affected, rescuer, team):
    e = create_emergency(client, affected)
    client.post(f"/api/v1/emergencies/{e['id']}/assign", json={"team_id": team["id"]}, headers=rescuer.headers)
    detail = client.get(f"/api/v1/emergencies/{e['id']}", headers=rescuer.headers).json()["data"]
    assert detail["status"] == "ASSIGNED" and detail["cloud_acknowledged_at"] is not None
    assert [h["to_status"] for h in detail["status_history"]][-2:] == ["ACKNOWLEDGED", "ASSIGNED"]
    same = client.post(f"/api/v1/emergencies/{e['id']}/assign", json={"team_id": team["id"]},
                       headers=rescuer.headers)
    assert same.status_code == 200 and same.json()["message"] == "Already assigned to this team."


def test_invalid_transitions_are_rejected(client, affected, rescuer, team):
    e = create_emergency(client, affected)
    url = f"/api/v1/emergencies/{e['id']}"
    resolve = client.post(f"{url}/resolve", json={"outcome": "RESCUED"}, headers=rescuer.headers)
    assert resolve.status_code == 409 and error_code(resolve) == "INVALID_STATUS_TRANSITION"
    assert resolve.json()["error"]["details"]["current_status"] == "RECEIVED"
    accept = client.post(f"{url}/accept", headers=rescuer.headers)
    assert accept.status_code == 409 and error_code(accept) == "NOT_ASSIGNED"
    unassign = client.post(f"{url}/unassign", headers=rescuer.headers)
    assert unassign.status_code == 409
    # Nothing changed after the rejected attempts.
    detail = client.get(url, headers=rescuer.headers).json()["data"]
    assert detail["status"] == "RECEIVED" and len(detail["status_history"]) == 2


def test_closed_emergency_cannot_be_reopened(client, affected, rescuer, team):
    e = create_emergency(client, affected)
    url = f"/api/v1/emergencies/{e['id']}"
    client.patch(url, json={"status": "REJECTED", "status_reason": "duplicate"}, headers=rescuer.headers)
    for path, body in (("assign", {"team_id": team["id"]}), ("accept", None),
                       ("resolve", {"outcome": "OTHER"})):
        response = client.post(f"{url}/{path}", json=body, headers=rescuer.headers)
        assert response.status_code == 409, path
    ack = client.post(f"{url}/acknowledge", headers=rescuer.headers)
    assert ack.status_code == 409


def test_only_assigned_team_members_accept_and_resolve(client, admin, affected, rescuer, team):
    outsider = create_user(client, admin, "RESCUE_TEAM")
    e = create_emergency(client, affected)
    url = f"/api/v1/emergencies/{e['id']}"
    client.post(f"{url}/assign", json={"team_id": team["id"]}, headers=rescuer.headers)
    assert client.post(f"{url}/accept", headers=outsider.headers).status_code == 403
    assert client.post(f"{url}/accept", headers=affected.headers).status_code == 403
    assert client.post(f"{url}/accept", headers=rescuer.headers).status_code == 200
    denied = client.post(f"{url}/resolve", json={"outcome": "RESCUED"}, headers=outsider.headers)
    assert denied.status_code == 403
    assert client.post(f"{url}/resolve", json={"outcome": "RESCUED"}, headers=admin.headers).status_code == 200


def test_reassignment_and_handover(client, admin, affected, rescuer, team):
    bravo_member = create_user(client, admin, "RESCUE_TEAM")
    bravo = create_team(client, admin, "Bravo")
    add_member(client, admin, bravo["id"], bravo_member)
    e = create_emergency(client, affected)
    url = f"/api/v1/emergencies/{e['id']}"
    client.post(f"{url}/assign", json={"team_id": team["id"]}, headers=rescuer.headers)
    client.post(f"{url}/accept", headers=rescuer.headers)
    # IN_PROGRESS -> ASSIGNED (handover to another team)
    moved = client.post(f"{url}/assign", json={"team_id": bravo["id"]}, headers=rescuer.headers)
    assert moved.status_code == 200
    detail = client.get(url, headers=rescuer.headers).json()["data"]
    assert detail["status"] == "ASSIGNED" and detail["assigned_team_id"] == bravo["id"]
    assert [a["status"] for a in detail["assignments"]] == ["CANCELLED", "ASSIGNED"]
    teams = {t["name"]: t for t in client.get("/api/v1/rescue-teams", headers=rescuer.headers).json()["data"]}
    assert teams["Alpha"]["status"] == "AVAILABLE" and teams["Bravo"]["status"] == "BUSY"
    # The previous team can no longer accept.
    assert client.post(f"{url}/accept", headers=rescuer.headers).status_code == 403
    assert client.post(f"{url}/accept", headers=bravo_member.headers).status_code == 200


def test_unassign_returns_to_acknowledged(client, affected, rescuer, team):
    e = create_emergency(client, affected)
    url = f"/api/v1/emergencies/{e['id']}"
    client.post(f"{url}/assign", json={"team_id": team["id"]}, headers=rescuer.headers)
    response = client.post(f"{url}/unassign", json={"notes": "team diverted"}, headers=rescuer.headers)
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["status"] == "ACKNOWLEDGED" and data["assigned_team_id"] is None


def test_offline_team_cannot_be_assigned(client, admin, affected, rescuer, team):
    client.patch(f"/api/v1/rescue-teams/{team['id']}", json={"status": "OFFLINE"}, headers=rescuer.headers)
    e = create_emergency(client, affected)
    response = client.post(f"/api/v1/emergencies/{e['id']}/assign", json={"team_id": team["id"]},
                           headers=rescuer.headers)
    assert response.status_code == 409 and error_code(response) == "TEAM_UNAVAILABLE"
    missing = client.post(f"/api/v1/emergencies/{e['id']}/assign",
                          json={"team_id": "00000000-0000-0000-0000-000000000000"},
                          headers=rescuer.headers)
    assert missing.status_code == 404


def test_cancel_releases_the_team(client, affected, rescuer, team):
    e = create_emergency(client, affected)
    url = f"/api/v1/emergencies/{e['id']}"
    client.post(f"{url}/assign", json={"team_id": team["id"]}, headers=rescuer.headers)
    cancel = client.patch(url, json={"status": "CANCELLED"}, headers=affected.headers)
    assert cancel.status_code == 200
    team_now = client.get(f"/api/v1/rescue-teams/{team['id']}", headers=rescuer.headers).json()["data"]
    assert team_now["status"] == "AVAILABLE"
    detail = client.get(url, headers=rescuer.headers).json()["data"]
    assert detail["assignments"][0]["status"] == "CANCELLED"


def test_every_status_change_is_audited(client, admin, affected, rescuer, team):
    e = create_emergency(client, affected)
    url = f"/api/v1/emergencies/{e['id']}"
    client.post(f"{url}/assign", json={"team_id": team["id"]}, headers=rescuer.headers)
    client.post(f"{url}/accept", headers=rescuer.headers)
    client.post(f"{url}/resolve", json={"outcome": "RESCUED"}, headers=rescuer.headers)
    entries = client.get(f"/api/v1/audit?entity_id={e['id']}&page_size=200", headers=admin.headers).json()["data"]
    actions = [x["action"] for x in reversed(entries)]
    assert actions.count("STATUS_CHANGED") == 4  # ACK, ASSIGNED, IN_PROGRESS, RESOLVED
    for expected in ("EMERGENCY_CREATED", "PRIORITY_CALCULATED", "EMERGENCY_ACKNOWLEDGED",
                     "TEAM_ASSIGNED", "ASSIGNMENT_ACCEPTED", "EMERGENCY_RESOLVED"):
        assert expected in actions
