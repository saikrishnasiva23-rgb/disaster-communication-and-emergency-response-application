from __future__ import annotations

import uuid

from fastapi import APIRouter, Query, status
from sqlalchemy import select

from app.api.deps import AdminUser, DbSession, PaginationDep, RescuerUser
from app.core.errors import AuthorizationError
from app.db.models import EmergencyAssignment, RescueTeam, RescueTeamMember
from app.domain.enums import TeamStatus, UserRole
from app.schemas.common import ApiResponse, error_responses
from app.schemas.emergency import AssignmentPublic
from app.schemas.rescue_team import (
    TeamCreate,
    TeamMemberAdd,
    TeamMemberPublic,
    TeamPublic,
    TeamUpdate,
)
from app.services import team_service

router = APIRouter(prefix="/rescue-teams", tags=["Rescue Teams"])

_MEMBER_EDITABLE = {"status", "current_latitude", "current_longitude"}


async def _public(session, teams: list[RescueTeam]) -> list[TeamPublic]:  # noqa: ANN001
    loads = await team_service.workloads(session, [t.id for t in teams])
    result = []
    for team in teams:
        item = TeamPublic.model_validate(team)
        item.active_assignments = loads.get(team.id, 0)
        result.append(item)
    return result


@router.get(
    "",
    response_model=ApiResponse[list[TeamPublic]],
    summary="List rescue teams with current workload",
    responses=error_responses(401, 403),
)
async def list_teams(
    _: RescuerUser, session: DbSession, team_status: TeamStatus | None = Query(None, alias="status")
) -> ApiResponse[list[TeamPublic]]:
    teams = await team_service.list_teams(session, status=team_status)
    return ApiResponse(data=await _public(session, teams))


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=ApiResponse[TeamPublic],
    summary="Create a rescue team (admin)",
    responses=error_responses(401, 403, 409, 422),
)
async def create_team(body: TeamCreate, admin: AdminUser, session: DbSession) -> ApiResponse[TeamPublic]:
    team = await team_service.create_team(session, body, admin)
    await session.commit()
    return ApiResponse(data=(await _public(session, [team]))[0], message="Team created.")


@router.get(
    "/{team_id}",
    response_model=ApiResponse[TeamPublic],
    summary="Get a rescue team",
    responses=error_responses(401, 403, 404),
)
async def get_team(team_id: uuid.UUID, _: RescuerUser, session: DbSession) -> ApiResponse[TeamPublic]:
    team = await team_service.get_team(session, team_id)
    return ApiResponse(data=(await _public(session, [team]))[0])


@router.patch(
    "/{team_id}",
    response_model=ApiResponse[TeamPublic],
    summary="Update a team (admin; members may update status and location)",
    responses=error_responses(401, 403, 404, 409, 422),
)
async def update_team(
    team_id: uuid.UUID, body: TeamUpdate, user: RescuerUser, session: DbSession
) -> ApiResponse[TeamPublic]:
    team = await team_service.get_team(session, team_id)
    if user.role != UserRole.ADMIN:
        is_member = await session.scalar(
            select(RescueTeamMember.id).where(
                RescueTeamMember.team_id == team.id, RescueTeamMember.user_id == user.id
            )
        )
        if not is_member:
            raise AuthorizationError("Only team members or an admin can update this team.")
        if body.model_fields_set - _MEMBER_EDITABLE:
            raise AuthorizationError(
                "Team members can only update status and current location.",
                details={"allowed_fields": sorted(_MEMBER_EDITABLE)},
            )
    team = await team_service.update_team(session, team, body, user)
    await session.commit()
    return ApiResponse(data=(await _public(session, [team]))[0], message="Team updated.")


@router.post(
    "/{team_id}/members",
    status_code=status.HTTP_201_CREATED,
    response_model=ApiResponse[TeamMemberPublic],
    summary="Add a member (admin)",
    responses=error_responses(401, 403, 404, 409, 422),
)
async def add_member(
    team_id: uuid.UUID, body: TeamMemberAdd, admin: AdminUser, session: DbSession
) -> ApiResponse[TeamMemberPublic]:
    team = await team_service.get_team(session, team_id)
    member = await team_service.add_member(session, team, body, admin)
    await session.commit()
    return ApiResponse(data=TeamMemberPublic.model_validate(member), message="Member added.")


@router.delete(
    "/{team_id}/members/{user_id}",
    response_model=ApiResponse[None],
    summary="Remove a member (admin)",
    responses=error_responses(401, 403, 404),
)
async def remove_member(
    team_id: uuid.UUID, user_id: uuid.UUID, admin: AdminUser, session: DbSession
) -> ApiResponse[None]:
    team = await team_service.get_team(session, team_id)
    await team_service.remove_member(session, team, user_id, admin)
    await session.commit()
    return ApiResponse(message="Member removed.")


@router.get(
    "/{team_id}/assignments",
    response_model=ApiResponse[list[AssignmentPublic]],
    summary="Assignment history of a team (newest first)",
    responses=error_responses(401, 403, 404),
)
async def team_assignments(
    team_id: uuid.UUID, _: RescuerUser, session: DbSession, pagination: PaginationDep
) -> ApiResponse[list[AssignmentPublic]]:
    await team_service.get_team(session, team_id)
    rows = (
        await session.scalars(
            select(EmergencyAssignment)
            .where(EmergencyAssignment.team_id == team_id)
            .order_by(EmergencyAssignment.assigned_at.desc())
            .offset((pagination.page - 1) * pagination.page_size)
            .limit(pagination.page_size)
        )
    ).all()
    return ApiResponse(data=[AssignmentPublic.model_validate(a) for a in rows])
