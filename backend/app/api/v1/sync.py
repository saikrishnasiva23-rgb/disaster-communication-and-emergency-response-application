from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query

from app.api.deps import CurrentUser, DbSession, PriorityDep, SettingsDep
from app.core.errors import InvalidInputError
from app.db.types import utcnow
from app.schemas.common import ApiResponse, UTCTimestamp, error_responses
from app.schemas.emergency import EmergencyPublic
from app.schemas.sync import (
    SyncEmergenciesRequest,
    SyncEmergenciesResponse,
    SyncPullResponse,
    SyncStatusRequest,
    SyncStatusResponse,
)
from app.services import sync_service

router = APIRouter(prefix="/sync", tags=["Offline Sync"])


def _check_batch(count: int, settings: SettingsDep) -> None:
    if count > settings.sync_batch_limit:
        raise InvalidInputError(
            f"At most {settings.sync_batch_limit} items per request; split the batch.",
            code="BATCH_TOO_LARGE",
            details={"max_items": settings.sync_batch_limit, "received": count},
        )


@router.post(
    "/emergencies",
    response_model=ApiResponse[SyncEmergenciesResponse],
    summary="Upload emergencies recorded offline (idempotent, retry-safe)",
    responses=error_responses(401, 422),
)
async def upload(
    body: SyncEmergenciesRequest,
    user: CurrentUser,
    session: DbSession,
    settings: SettingsDep,
    priority: PriorityDep,
) -> ApiResponse[SyncEmergenciesResponse]:
    """Each item gets its own result: `created`, `duplicate` (already on the
    server -- safe to mark as synced), `conflict` (same id, different
    content; the server copy is kept and flagged) or `invalid`.

    Items are committed one by one, so a failed request can simply be
    retried in full."""
    _check_batch(len(body.items), settings)
    results, counts = await sync_service.upload_emergencies(
        session, body, user, priority, settings
    )
    return ApiResponse(
        data=SyncEmergenciesResponse(results=results, counts=counts, server_time=utcnow()),
        message=f"{counts.created} created, {counts.duplicate} duplicate, "
        f"{counts.conflict} conflict, {counts.invalid} invalid.",
    )


@router.get(
    "/emergencies",
    response_model=ApiResponse[SyncPullResponse],
    summary="Download changes since a cursor (incremental sync)",
    responses=error_responses(401, 422),
)
async def pull(
    user: CurrentUser,
    session: DbSession,
    settings: SettingsDep,
    cursor: Annotated[str | None, Query(max_length=200)] = None,
    since: Annotated[UTCTimestamp | None, Query(description="Used only without a cursor.")] = None,
    limit: Annotated[int | None, Query(ge=1, le=1000)] = None,
) -> ApiResponse[SyncPullResponse]:
    """Returns emergencies ordered by last change. Store `next_cursor` and
    pass it back to get only what changed after it. Affected Persons only
    receive their own emergencies."""
    page_size = min(limit or settings.sync_batch_limit, settings.sync_batch_limit)
    rows, next_cursor, has_more = await sync_service.pull(
        session, user, cursor=cursor, since=since, limit=page_size
    )
    return ApiResponse(
        data=SyncPullResponse(
            items=[EmergencyPublic.model_validate(e) for e in rows],
            next_cursor=next_cursor,
            has_more=has_more,
            server_time=utcnow(),
        )
    )


@router.post(
    "/status",
    response_model=ApiResponse[SyncStatusResponse],
    summary="Upload status changes made offline",
    responses=error_responses(401, 422),
)
async def upload_status(
    body: SyncStatusRequest, user: CurrentUser, session: DbSession, settings: SettingsDep
) -> ApiResponse[SyncStatusResponse]:
    """Replayed oldest first. Each `update_id` is applied at most once.
    A change older than the server's latest status change for that emergency
    is reported as `conflict` (not applied), so newer work is never
    overwritten by a stale offline device."""
    _check_batch(len(body.items), settings)
    results, counts = await sync_service.apply_status_updates(session, body, user, settings)
    return ApiResponse(
        data=SyncStatusResponse(results=results, counts=counts, server_time=utcnow()),
        message=f"{counts.applied} applied, {counts.duplicate} duplicate, "
        f"{counts.conflict} conflict, {counts.invalid} invalid, {counts.not_found} not found.",
    )
