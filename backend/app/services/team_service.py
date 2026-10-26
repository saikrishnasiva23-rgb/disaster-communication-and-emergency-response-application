from __future__ import annotations

import uuid

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ConflictError, InvalidInputError, NotFoundError
from app.db.models import EmergencyAssignment, RescueTeam, RescueTeamMember, User
from app.db.types import utcnow
from app.domain.enums import ACTIVE_ASSIGNMENT_STATUSES, TeamStatus, UserRole
from app.schemas.rescue_team import TeamCreate, TeamMemberAdd, TeamUpdate
from app.services import audit_service


async def get_team(session: AsyncSession, team_id: uuid.UUID) -> RescueTeam:
    team = await session.get(RescueTeam, team_id)
    if team is None:
        raise NotFoundError("Rescue team not found.", code="TEAM_NOT_FOUND")
    return team


async def team_of_user(session: AsyncSession, user_id: uuid.UUID) -> RescueTeam | None:
    return await session.scalar(
        select(RescueTeam)
        .join(RescueTeamMember, RescueTeamMember.team_id == RescueTeam.id)
        .where(RescueTeamMember.user_id == user_id)
    )


async def workloads(
    session: AsyncSession, team_ids: list[uuid.UUID]
) -> dict[uuid.UUID, int]:
    if not team_ids:
        return {}
    rows = await session.execute(
        select(EmergencyAssignment.team_id, func.count())
        .where(
            EmergencyAssignment.team_id.in_(team_ids),
            EmergencyAssignment.status.in_(ACTIVE_ASSIGNMENT_STATUSES),
        )
        .group_by(EmergencyAssignment.team_id)
    )
    return {team_id: int(count) for team_id, count in rows.all()}


async def refresh_status(session: AsyncSession, team: RescueTeam) -> None:
    """AVAILABLE <-> BUSY follows the real workload. OFFLINE is only ever set
    (or cleared) explicitly by a person."""
    if team.status == TeamStatus.OFFLINE:
        return
    load = (await workloads(session, [team.id])).get(team.id, 0)
    team.status = TeamStatus.BUSY if load > 0 else TeamStatus.AVAILABLE


async def create_team(session: AsyncSession, data: TeamCreate, actor: User) -> RescueTeam:
    if await session.scalar(select(RescueTeam.id).where(RescueTeam.name == data.name)):
        raise ConflictError("A team with that name already exists.", code="TEAM_NAME_TAKEN")
    team = RescueTeam(
        name=data.name,
        capabilities=[c.strip().upper() for c in data.capabilities],
        contact_phone=data.contact_phone,
        base_latitude=data.base_latitude,
        base_longitude=data.base_longitude,
        status=TeamStatus.AVAILABLE,
        members=[],
    )
    session.add(team)
    await session.flush()
    await audit_service.record(
        session, action="TEAM_CREATED", entity_type="rescue_team", entity_id=team.id,
        actor=actor, details={"name": team.name},
    )
    return team


async def list_teams(
    session: AsyncSession, *, status: TeamStatus | None = None
) -> list[RescueTeam]:
    query = select(RescueTeam).where(RescueTeam.is_active.is_(True))
    if status:
        query = query.where(RescueTeam.status == status)
    return list((await session.scalars(query.order_by(RescueTeam.name))).all())


async def update_team(
    session: AsyncSession, team: RescueTeam, data: TeamUpdate, actor: User
) -> RescueTeam:
    changes = data.model_dump(exclude_unset=True)
    if "name" in changes:
        clash = await session.scalar(
            select(RescueTeam.id).where(RescueTeam.name == changes["name"], RescueTeam.id != team.id)
        )
        if clash:
            raise ConflictError("A team with that name already exists.", code="TEAM_NAME_TAKEN")
    if "capabilities" in changes and changes["capabilities"] is not None:
        changes["capabilities"] = [c.strip().upper() for c in changes["capabilities"]]
    if "current_latitude" in changes:
        team.location_updated_at = utcnow()
    for field, value in changes.items():
        setattr(team, field, value)
    if changes.get("status") in (TeamStatus.AVAILABLE, TeamStatus.BUSY):
        await refresh_status(session, team)
    await session.flush()
    await audit_service.record(
        session, action="TEAM_UPDATED", entity_type="rescue_team", entity_id=team.id,
        actor=actor, details={"fields": sorted(changes), "status": team.status},
    )
    return team


async def add_member(
    session: AsyncSession, team: RescueTeam, data: TeamMemberAdd, actor: User
) -> RescueTeamMember:
    user = await session.get(User, data.user_id)
    if user is None:
        raise NotFoundError("User not found.", code="USER_NOT_FOUND")
    if user.role not in (UserRole.RESCUE_TEAM, UserRole.ADMIN):
        raise InvalidInputError(
            "Only RESCUE_TEAM (or ADMIN) accounts can join a rescue team.",
            code="INVALID_TEAM_MEMBER",
        )
    if await session.scalar(
        select(RescueTeamMember.id).where(RescueTeamMember.user_id == user.id)
    ):
        raise ConflictError("That user already belongs to a team.", code="USER_ALREADY_IN_TEAM")
    member = RescueTeamMember(team_id=team.id, user_id=user.id, member_role=data.member_role)
    session.add(member)
    await session.flush()
    await session.refresh(team, attribute_names=["members"])
    await audit_service.record(
        session, action="TEAM_MEMBER_ADDED", entity_type="rescue_team", entity_id=team.id,
        actor=actor, details={"user_id": user.id, "member_role": data.member_role},
    )
    return member


async def remove_member(
    session: AsyncSession, team: RescueTeam, user_id: uuid.UUID, actor: User
) -> None:
    member = await session.scalar(
        select(RescueTeamMember).where(
            RescueTeamMember.team_id == team.id, RescueTeamMember.user_id == user_id
        )
    )
    if member is None:
        raise NotFoundError("That user is not a member of this team.", code="MEMBER_NOT_FOUND")
    await session.delete(member)
    await session.flush()
    await session.refresh(team, attribute_names=["members"])
    await audit_service.record(
        session, action="TEAM_MEMBER_REMOVED", entity_type="rescue_team", entity_id=team.id,
        actor=actor, details={"user_id": user_id},
    )
