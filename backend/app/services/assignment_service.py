"""Rescue team assignment workflow:

    assign  -> ASSIGNED     (auto-acknowledges a RECEIVED emergency first)
    accept  -> IN_PROGRESS  (a member of the assigned team accepts)
    resolve -> RESOLVED     (with an outcome; the assignment is COMPLETED)

Reassigning an emergency to another team cancels the previous assignment,
so an emergency has at most one active assignment at a time."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import AuthorizationError, ConflictError, InvalidTransitionError
from app.db.models import Emergency, EmergencyAssignment, RescueTeamMember, User
from app.db.types import utcnow
from app.domain.enums import (
    AssignmentStatus,
    ChangeVia,
    EmergencyStatus,
    ResolutionOutcome,
    TeamStatus,
    UserRole,
)
from app.domain.lifecycle import TERMINAL_STATUSES
from app.services import audit_service, team_service
from app.services.emergency_service import (
    acknowledge,
    active_assignment,
    close_assignment,
    transition,
)


def _ensure_open(emergency: Emergency) -> None:
    if emergency.status in TERMINAL_STATUSES:
        raise ConflictError(
            f"This emergency is {emergency.status} and can no longer be changed.",
            code="EMERGENCY_CLOSED",
        )


async def _is_member(session: AsyncSession, user: User, team_id) -> bool:  # noqa: ANN001
    return bool(
        await session.scalar(
            select(RescueTeamMember.id).where(
                RescueTeamMember.team_id == team_id, RescueTeamMember.user_id == user.id
            )
        )
    )


async def assign(
    session: AsyncSession,
    emergency: Emergency,
    team_id,  # noqa: ANN001
    actor: User,
    *,
    notes: str | None = None,
    via: ChangeVia = ChangeVia.API,
    client_changed_at: datetime | None = None,
    client_update_id: str | None = None,
) -> tuple[EmergencyAssignment, bool]:
    """Returns (assignment, changed). Assigning to the team that already
    holds it is a no-op, so retries are safe."""
    _ensure_open(emergency)
    team = await team_service.get_team(session, team_id)
    current = await active_assignment(session, emergency.id)
    if current is not None and current.team_id == team.id:
        return current, False

    if not team.is_active or team.status == TeamStatus.OFFLINE:
        raise ConflictError(
            f"Team '{team.name}' is {'inactive' if not team.is_active else 'OFFLINE'} "
            "and cannot take assignments.",
            code="TEAM_UNAVAILABLE",
        )

    if emergency.status in (EmergencyStatus.CREATED, EmergencyStatus.RECEIVED):
        if emergency.status == EmergencyStatus.CREATED:
            await transition(session, emergency, EmergencyStatus.RECEIVED, actor, via=via)
        await acknowledge(session, emergency, actor, via=via)

    if current is not None:
        await close_assignment(session, emergency, AssignmentStatus.CANCELLED)
        await audit_service.record(
            session, action="TEAM_UNASSIGNED", entity_type="emergency",
            entity_id=emergency.id, actor=actor,
            details={"team_id": current.team_id, "reason": "reassigned"},
        )

    assignment = EmergencyAssignment(
        emergency_id=emergency.id,
        team_id=team.id,
        assigned_by_user_id=actor.id,
        status=AssignmentStatus.ASSIGNED,
        notes=notes,
        assigned_at=utcnow(),
    )
    session.add(assignment)
    emergency.assigned_team_id = team.id
    await session.flush()

    # ACKNOWLEDGED -> ASSIGNED, or the IN_PROGRESS -> ASSIGNED handover.
    if emergency.status != EmergencyStatus.ASSIGNED:
        await transition(
            session, emergency, EmergencyStatus.ASSIGNED, actor, reason=notes, via=via,
            client_changed_at=client_changed_at, client_update_id=client_update_id,
        )
    await team_service.refresh_status(session, team)
    await session.flush()
    await audit_service.record(
        session, action="TEAM_ASSIGNED", entity_type="emergency", entity_id=emergency.id,
        actor=actor, details={"team_id": team.id, "team_name": team.name, "via": via},
    )
    return assignment, True


async def unassign(
    session: AsyncSession,
    emergency: Emergency,
    actor: User,
    *,
    reason: str | None = None,
    via: ChangeVia = ChangeVia.API,
    client_changed_at: datetime | None = None,
    client_update_id: str | None = None,
) -> None:
    """ASSIGNED -> ACKNOWLEDGED: the team gives the job back before starting."""
    _ensure_open(emergency)
    if emergency.status != EmergencyStatus.ASSIGNED:
        raise InvalidTransitionError(
            f"Only an ASSIGNED emergency can be unassigned (it is {emergency.status}).",
            details={"current_status": emergency.status},
        )
    current = await active_assignment(session, emergency.id)
    await close_assignment(session, emergency, AssignmentStatus.CANCELLED)
    emergency.assigned_team_id = None
    await transition(
        session, emergency, EmergencyStatus.ACKNOWLEDGED, actor, reason=reason, via=via,
        client_changed_at=client_changed_at, client_update_id=client_update_id,
    )
    await audit_service.record(
        session, action="TEAM_UNASSIGNED", entity_type="emergency", entity_id=emergency.id,
        actor=actor,
        details={"team_id": current.team_id if current else None, "reason": reason},
    )


async def accept(
    session: AsyncSession,
    emergency: Emergency,
    actor: User,
    *,
    via: ChangeVia = ChangeVia.API,
    client_changed_at: datetime | None = None,
    client_update_id: str | None = None,
) -> tuple[EmergencyAssignment, bool]:
    _ensure_open(emergency)
    assignment = await active_assignment(session, emergency.id)
    if assignment is None:
        raise ConflictError("This emergency is not assigned to a team.", code="NOT_ASSIGNED")
    if actor.role != UserRole.ADMIN and not await _is_member(session, actor, assignment.team_id):
        raise AuthorizationError("Only a member of the assigned team can accept it.")
    if assignment.status == AssignmentStatus.ACCEPTED:
        return assignment, False

    assignment.status = AssignmentStatus.ACCEPTED
    assignment.accepted_at = utcnow()
    await transition(
        session, emergency, EmergencyStatus.IN_PROGRESS, actor, via=via,
        client_changed_at=client_changed_at, client_update_id=client_update_id,
    )
    await audit_service.record(
        session, action="ASSIGNMENT_ACCEPTED", entity_type="emergency",
        entity_id=emergency.id, actor=actor, details={"team_id": assignment.team_id},
    )
    return assignment, True


async def resolve(
    session: AsyncSession,
    emergency: Emergency,
    actor: User,
    *,
    outcome: ResolutionOutcome,
    notes: str | None = None,
    via: ChangeVia = ChangeVia.API,
    client_changed_at: datetime | None = None,
    client_update_id: str | None = None,
) -> Emergency:
    if emergency.status == EmergencyStatus.RESOLVED:
        raise ConflictError("This emergency is already resolved.", code="EMERGENCY_CLOSED")
    _ensure_open(emergency)
    if emergency.status != EmergencyStatus.IN_PROGRESS:
        # Surfaces the standard INVALID_STATUS_TRANSITION error.
        await transition(session, emergency, EmergencyStatus.RESOLVED, actor)

    assignment = await active_assignment(session, emergency.id)
    if (
        actor.role != UserRole.ADMIN
        and assignment is not None
        and not await _is_member(session, actor, assignment.team_id)
    ):
        raise AuthorizationError("Only a member of the assigned team can resolve it.")

    await transition(
        session, emergency, EmergencyStatus.RESOLVED, actor, reason=notes, via=via,
        client_changed_at=client_changed_at, client_update_id=client_update_id,
    )
    emergency.resolved_at = utcnow()
    emergency.resolved_by_user_id = actor.id
    emergency.resolution_outcome = outcome
    emergency.resolution_notes = notes
    await close_assignment(session, emergency, AssignmentStatus.COMPLETED)
    await session.flush()
    await audit_service.record(
        session, action="EMERGENCY_RESOLVED", entity_type="emergency", entity_id=emergency.id,
        actor=actor, details={"outcome": outcome, "via": via},
    )
    return emergency
