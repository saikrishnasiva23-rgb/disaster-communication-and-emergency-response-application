from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Header, Query, Response, status

from app.api.deps import (
    CurrentUser,
    DbSession,
    PaginationDep,
    PriorityDep,
    RescuerUser,
    SettingsDep,
)
from app.core.errors import InvalidInputError
from app.domain import emergency_types
from app.domain.enums import EmergencyStatus, PriorityLevel
from app.schemas.common import (
    ApiResponse,
    ClientId,
    Latitude,
    Longitude,
    UTCTimestamp,
    error_responses,
)
from app.schemas.emergency import (
    AssignmentPublic,
    EmergencyAcknowledge,
    EmergencyAssign,
    EmergencyCreate,
    EmergencyDetail,
    EmergencyPublic,
    EmergencyResolve,
    EmergencyTypePublic,
    EmergencyUpdate,
    LocationIn,
    LocationPublic,
    StatusHistoryPublic,
)
from app.services import assignment_service
from app.services import emergency_service as es

router = APIRouter(prefix="/emergencies", tags=["Emergencies"])

def _public(emergency, distance_km: float | None = None) -> EmergencyPublic:  # noqa: ANN001
    item = EmergencyPublic.model_validate(emergency)
    item.distance_km = distance_km
    return item


def _type_filter(value: str | None) -> str | None:
    if value is None:
        return None
    try:
        return emergency_types.normalize(value)
    except ValueError as exc:
        raise InvalidInputError(str(exc), code="UNKNOWN_EMERGENCY_TYPE") from exc


@router.get(
    "/types",
    response_model=ApiResponse[list[EmergencyTypePublic]],
    summary="Supported emergency types",
)
async def list_types() -> ApiResponse[list[EmergencyTypePublic]]:
    """Codes accepted in `emergency_type`. Labels and common aliases
    (e.g. "Medical Emergency", "Trapped") are also accepted on input."""
    return ApiResponse(
        data=[
            EmergencyTypePublic(code=t.code, label=t.label, life_threatening=t.life_threatening)
            for t in emergency_types.all_types()
        ]
    )


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=ApiResponse[EmergencyPublic],
    summary="Report an emergency (idempotent)",
    responses={
        200: {"description": "Same emergency already received; existing record returned"},
        **error_responses(401, 403, 409, 422),
    },
)
async def create_emergency(
    body: EmergencyCreate,
    user: CurrentUser,
    session: DbSession,
    settings: SettingsDep,
    priority: PriorityDep,
    response: Response,
    idempotency_key: Annotated[
        ClientId | None,
        Header(description="Optional; same meaning as `client_emergency_id`."),
    ] = None,
) -> ApiResponse[EmergencyPublic]:
    """Creates the emergency and computes its priority server-side.

    **Idempotent:** send the BLE SOS packet id as `client_emergency_id`.
    Resending it returns the existing record (HTTP 200) instead of creating
    a duplicate; the same id with *different* content is rejected with 409
    `IDEMPOTENCY_CONFLICT`.

    GPS is optional -- omit `location` when the phone had no fix. The server
    never invents coordinates."""
    emergency, created = await es.submit_emergency(
        session, body, user, priority, settings, idempotency_key=idempotency_key
    )
    if not created:
        response.status_code = status.HTTP_200_OK
    return ApiResponse(
        data=_public(emergency),
        message="Emergency received." if created
        else "Already received; returning the existing emergency.",
    )


@router.get(
    "",
    response_model=ApiResponse[list[EmergencyPublic]],
    summary="List emergencies (Affected Person: only their own)",
    responses=error_responses(401, 422),
)
async def list_emergencies(
    user: CurrentUser,
    session: DbSession,
    pagination: PaginationDep,
    status_: Annotated[list[EmergencyStatus] | None, Query(alias="status")] = None,
    priority: Annotated[list[PriorityLevel] | None, Query()] = None,
    emergency_type: Annotated[str | None, Query(alias="type")] = None,
    team_id: uuid.UUID | None = None,
    active_only: bool = False,
    since: UTCTimestamp | None = Query(default=None, description="occurred_at >= since"),
    until: UTCTimestamp | None = Query(default=None, description="occurred_at <= until"),
    min_lat: Latitude | None = None,
    max_lat: Latitude | None = None,
    min_lon: Longitude | None = None,
    max_lon: Longitude | None = None,
    origin_device_id: ClientId | None = None,
) -> ApiResponse[list[EmergencyPublic]]:
    """Sorted by priority (CRITICAL first), then newest. Filter by status,
    priority, type, team, time range, or a region (`min_lat`..`max_lon`
    bounding box -- all four together)."""
    region = (min_lat, max_lat, min_lon, max_lon)
    bbox = None
    if any(v is not None for v in region):
        if any(v is None for v in region):
            raise InvalidInputError(
                "A region needs all of min_lat, max_lat, min_lon and max_lon.",
                code="INCOMPLETE_REGION",
            )
        if min_lat > max_lat or min_lon > max_lon:  # type: ignore[operator]
            raise InvalidInputError("Region minimums must not exceed maximums.",
                                    code="INVALID_REGION")
        bbox = region
    filters = es.EmergencyFilters(
        statuses=status_ or [],
        priorities=priority or [],
        emergency_type=_type_filter(emergency_type),
        assigned_team_id=team_id,
        active_only=active_only,
        since=since,
        until=until,
        bbox=bbox,  # type: ignore[arg-type]
        origin_device_id=origin_device_id,
    )
    rows, total = await es.list_emergencies(
        session, user, filters, page=pagination.page, page_size=pagination.page_size
    )
    return ApiResponse(data=[_public(e) for e in rows], meta=pagination.meta(total))


@router.get(
    "/nearby",
    response_model=ApiResponse[list[EmergencyPublic]],
    summary="Emergencies within a radius (Rescue Team / Admin)",
    responses=error_responses(401, 403, 422),
)
async def nearby(
    user: RescuerUser,
    session: DbSession,
    latitude: Latitude,
    longitude: Longitude,
    radius_km: Annotated[float, Query(gt=0, le=500)] = 10,
    active_only: bool = True,
    status_: Annotated[list[EmergencyStatus] | None, Query(alias="status")] = None,
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
) -> ApiResponse[list[EmergencyPublic]]:
    """Great-circle (haversine) distance, nearest first. Emergencies without
    a GPS fix are not included (they have no position to measure)."""
    hits = await es.nearby(
        session, user, latitude=latitude, longitude=longitude, radius_km=radius_km,
        filters=es.EmergencyFilters(statuses=status_ or [], active_only=active_only),
        limit=limit,
    )
    return ApiResponse(data=[_public(e, d) for e, d in hits], meta={"count": len(hits)})


@router.get(
    "/{emergency_id}",
    response_model=ApiResponse[EmergencyDetail],
    summary="Emergency details with location, status and assignment history",
    responses=error_responses(401, 403, 404),
)
async def get_emergency(
    emergency_id: uuid.UUID, user: CurrentUser, session: DbSession
) -> ApiResponse[EmergencyDetail]:
    emergency = await es.get_emergency(session, emergency_id, user, detail=True)
    return ApiResponse(data=EmergencyDetail.model_validate(emergency))


@router.patch(
    "/{emergency_id}",
    response_model=ApiResponse[EmergencyPublic],
    summary="Update details, cancel, or reject",
    responses=error_responses(401, 403, 404, 409, 422),
)
async def update_emergency(
    emergency_id: uuid.UUID,
    body: EmergencyUpdate,
    user: CurrentUser,
    session: DbSession,
    priority: PriorityDep,
) -> ApiResponse[EmergencyPublic]:
    """Descriptive changes re-run the priority classifier. `status` accepts
    only CANCELLED (reporter or rescuer) and REJECTED (rescuer)."""
    emergency = await es.get_emergency(session, emergency_id, user, for_update=True)
    await es.update_emergency(session, emergency, body, user, priority)
    await session.commit()
    return ApiResponse(data=_public(emergency), message="Emergency updated.")


@router.post(
    "/{emergency_id}/acknowledge",
    response_model=ApiResponse[EmergencyPublic],
    summary="Cloud acknowledgement (Rescue Team / Admin)",
    responses=error_responses(401, 403, 404, 409),
)
async def acknowledge(
    emergency_id: uuid.UUID,
    user: RescuerUser,
    session: DbSession,
    body: EmergencyAcknowledge | None = None,
) -> ApiResponse[EmergencyPublic]:
    """Marks the emergency ACKNOWLEDGED in the cloud. Idempotent. This is
    separate from the BLE ACK, which the rescue console sends to the phone
    directly and which never depends on this server."""
    emergency = await es.get_emergency(session, emergency_id, user, for_update=True)
    changed = await es.acknowledge(session, emergency, user, notes=body.notes if body else None)
    await session.commit()
    return ApiResponse(
        data=_public(emergency),
        message="Emergency acknowledged." if changed else "Already acknowledged.",
    )


@router.post(
    "/{emergency_id}/assign",
    response_model=ApiResponse[AssignmentPublic],
    summary="Assign to a rescue team (Rescue Team / Admin)",
    responses=error_responses(401, 403, 404, 409, 422),
)
async def assign(
    emergency_id: uuid.UUID, body: EmergencyAssign, user: RescuerUser, session: DbSession
) -> ApiResponse[AssignmentPublic]:
    """A RECEIVED emergency is acknowledged automatically first. Assigning
    to a different team cancels the previous assignment. Assigning to the
    current team again is a no-op."""
    emergency = await es.get_emergency(session, emergency_id, user, for_update=True)
    assignment, changed = await assignment_service.assign(
        session, emergency, body.team_id, user, notes=body.notes
    )
    await session.commit()
    return ApiResponse(
        data=AssignmentPublic.model_validate(assignment),
        message="Team assigned." if changed else "Already assigned to this team.",
    )


@router.post(
    "/{emergency_id}/unassign",
    response_model=ApiResponse[EmergencyPublic],
    summary="Return an ASSIGNED emergency to ACKNOWLEDGED (Rescue Team / Admin)",
    responses=error_responses(401, 403, 404, 409),
)
async def unassign(
    emergency_id: uuid.UUID,
    user: RescuerUser,
    session: DbSession,
    body: EmergencyAcknowledge | None = None,
) -> ApiResponse[EmergencyPublic]:
    emergency = await es.get_emergency(session, emergency_id, user, for_update=True)
    await assignment_service.unassign(session, emergency, user, reason=body.notes if body else None)
    await session.commit()
    return ApiResponse(data=_public(emergency), message="Team unassigned.")


@router.post(
    "/{emergency_id}/accept",
    response_model=ApiResponse[EmergencyPublic],
    summary="Assigned team accepts: status becomes IN_PROGRESS",
    responses=error_responses(401, 403, 404, 409),
)
async def accept(
    emergency_id: uuid.UUID, user: RescuerUser, session: DbSession
) -> ApiResponse[EmergencyPublic]:
    emergency = await es.get_emergency(session, emergency_id, user, for_update=True)
    _, changed = await assignment_service.accept(session, emergency, user)
    await session.commit()
    return ApiResponse(
        data=_public(emergency),
        message="Assignment accepted; rescue in progress." if changed else "Already accepted.",
    )


@router.post(
    "/{emergency_id}/resolve",
    response_model=ApiResponse[EmergencyPublic],
    summary="Resolve an IN_PROGRESS emergency with an outcome",
    responses=error_responses(401, 403, 404, 409, 422),
)
async def resolve(
    emergency_id: uuid.UUID, body: EmergencyResolve, user: RescuerUser, session: DbSession
) -> ApiResponse[EmergencyPublic]:
    emergency = await es.get_emergency(session, emergency_id, user, for_update=True)
    await assignment_service.resolve(
        session, emergency, user, outcome=body.outcome, notes=body.resolution_notes
    )
    await session.commit()
    return ApiResponse(data=_public(emergency), message="Emergency resolved.")


@router.post(
    "/{emergency_id}/locations",
    status_code=status.HTTP_201_CREATED,
    response_model=ApiResponse[LocationPublic],
    summary="Add a GPS update",
    responses=error_responses(401, 403, 404, 409, 422),
)
async def add_location(
    emergency_id: uuid.UUID,
    body: LocationIn,
    user: CurrentUser,
    session: DbSession,
    settings: SettingsDep,
) -> ApiResponse[LocationPublic]:
    """Appends to the location history. A late-arriving older fix is kept
    in history but does not replace a newer current position."""
    emergency = await es.get_emergency(session, emergency_id, user, for_update=True)
    entry = await es.add_location(session, emergency, body, user, settings)
    await session.commit()
    return ApiResponse(data=LocationPublic.model_validate(entry), message="Location recorded.")


@router.get(
    "/{emergency_id}/locations",
    response_model=ApiResponse[list[LocationPublic]],
    summary="GPS history (oldest first)",
    responses=error_responses(401, 403, 404),
)
async def list_locations(
    emergency_id: uuid.UUID, user: CurrentUser, session: DbSession
) -> ApiResponse[list[LocationPublic]]:
    emergency = await es.get_emergency(session, emergency_id, user, detail=True)
    return ApiResponse(data=[LocationPublic.model_validate(x) for x in emergency.locations])


@router.get(
    "/{emergency_id}/history",
    response_model=ApiResponse[list[StatusHistoryPublic]],
    summary="Status history (oldest first)",
    responses=error_responses(401, 403, 404),
)
async def status_history(
    emergency_id: uuid.UUID, user: CurrentUser, session: DbSession
) -> ApiResponse[list[StatusHistoryPublic]]:
    emergency = await es.get_emergency(session, emergency_id, user, detail=True)
    return ApiResponse(
        data=[StatusHistoryPublic.model_validate(h) for h in emergency.status_history]
    )

