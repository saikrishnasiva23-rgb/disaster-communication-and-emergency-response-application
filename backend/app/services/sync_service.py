"""Offline synchronisation.

Uploads are processed item by item, each in its own transaction: one bad
item never loses the others, and a retried batch returns the same result
per item (created -> duplicate) without creating anything twice."""

from __future__ import annotations

import base64
import binascii
import uuid
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import (
    AppError,
    AuthorizationError,
    ConflictError,
    InvalidInputError,
    InvalidTransitionError,
    NotFoundError,
)
from app.db.models import Emergency, EmergencyStatusHistory, SyncRecord, User
from app.db.types import utcnow
from app.domain.enums import (
    AssignmentStatus,
    ChangeVia,
    EmergencyStatus,
    SyncState,
    UserRole,
)
from app.domain.lifecycle import ensure_transition
from app.schemas.sync import (
    SyncCounts,
    SyncEmergenciesRequest,
    SyncItemResult,
    SyncStatusItem,
    SyncStatusRequest,
    SyncStatusResult,
)
from app.services import assignment_service, audit_service, device_service
from app.services import emergency_service as es
from app.services.priority_service import PriorityService


def _error(exc: AppError) -> dict:
    return {"code": exc.code, "message": exc.message}


async def _reset(session: AsyncSession, actor: User) -> None:
    await session.rollback()
    await session.refresh(actor)


async def _start(
    session: AsyncSession, actor: User, device_id: str | None, kind: str, count: int
) -> uuid.UUID:
    device = await device_service.touch_sync(session, device_id, actor)
    record = SyncRecord(
        user_id=actor.id,
        device_id=device.id if device else None,
        kind=kind,
        item_count=count,
        started_at=utcnow(),
    )
    session.add(record)
    await session.commit()
    return record.id


async def _finish(
    session: AsyncSession, record_id: uuid.UUID, counts: SyncCounts, actor: User, action: str
) -> None:
    # Re-read: a per-item rollback in between expires loaded instances.
    record = await session.get(SyncRecord, record_id, populate_existing=True)
    if record is None:  # pragma: no cover -- committed in _start
        return
    record.created_count = counts.created
    record.applied_count = counts.applied
    record.duplicate_count = counts.duplicate
    record.conflict_count = counts.conflict
    record.invalid_count = counts.invalid + counts.not_found
    record.finished_at = utcnow()
    await audit_service.record(
        session, action=action, entity_type="sync", entity_id=record.id, actor=actor,
        details=counts.model_dump(),
    )
    await session.commit()


async def upload_emergencies(
    session: AsyncSession,
    request: SyncEmergenciesRequest,
    actor: User,
    priority_service: PriorityService,
    settings: Settings,
) -> tuple[list[SyncItemResult], SyncCounts]:
    record_id = await _start(
        session, actor, request.device_id, "EMERGENCY_UPLOAD", len(request.items)
    )
    results: list[SyncItemResult] = []
    counts = SyncCounts()

    for item in request.items:
        client_id = item.client_emergency_id
        try:
            emergency, created = await es.submit_emergency(
                session, item, actor, priority_service, settings, via=ChangeVia.SYNC,
            )
        except ConflictError as exc:
            await _reset(session, actor)
            await _flag_conflict(session, client_id, actor)
            counts.conflict += 1
            results.append(SyncItemResult(client_emergency_id=client_id, result="conflict",
                                          error=_error(exc)))
            continue
        except AppError as exc:
            await _reset(session, actor)
            counts.invalid += 1
            results.append(SyncItemResult(client_emergency_id=client_id, result="invalid",
                                          error=_error(exc)))
            continue

        if created:
            counts.created += 1
        else:
            counts.duplicate += 1
        results.append(
            SyncItemResult(
                client_emergency_id=client_id,
                result="created" if created else "duplicate",
                emergency_id=emergency.id,
                status=emergency.status,
            )
        )

    await _finish(session, record_id, counts, actor, "SYNC_UPLOAD")
    return results, counts


async def _flag_conflict(session: AsyncSession, client_id: str, actor: User) -> None:
    """Keeps the stored record untouched but marks it so a rescuer can see
    that a device sent different content under the same id."""
    existing = await es.get_by_client_id(session, client_id)
    if existing is None or not es.can_view(actor, existing):
        return
    existing.sync_state = SyncState.CONFLICT
    await audit_service.record(
        session, action="SYNC_CONFLICT", entity_type="emergency", entity_id=existing.id,
        actor=actor, details={"client_emergency_id": client_id},
    )
    await session.commit()


async def _find(session: AsyncSession, item: SyncStatusItem) -> Emergency | None:
    if item.emergency_id is not None:
        return await session.get(Emergency, item.emergency_id, populate_existing=True)
    return await es.get_by_client_id(session, item.client_emergency_id or "")


async def _apply(
    session: AsyncSession, emergency: Emergency, item: SyncStatusItem, actor: User
) -> None:
    target = item.status
    kwargs = {
        "via": ChangeVia.SYNC,
        "client_changed_at": item.changed_at,
        "client_update_id": item.update_id,
    }
    if actor.role == UserRole.AFFECTED_PERSON and target != EmergencyStatus.CANCELLED:
        raise AuthorizationError("You can only cancel your own emergency.")

    if target == EmergencyStatus.ACKNOWLEDGED:
        if emergency.status == EmergencyStatus.ASSIGNED:
            await assignment_service.unassign(session, emergency, actor, reason=item.reason, **kwargs)
        else:
            ensure_transition(emergency.status, target)
            await es.acknowledge(session, emergency, actor, notes=item.reason, **kwargs)
    elif target == EmergencyStatus.ASSIGNED:
        if item.team_id is None:
            raise InvalidInputError("team_id is required for ASSIGNED.", code="TEAM_REQUIRED")
        await assignment_service.assign(session, emergency, item.team_id, actor,
                                        notes=item.reason, **kwargs)
    elif target == EmergencyStatus.IN_PROGRESS:
        await assignment_service.accept(session, emergency, actor, **kwargs)
    elif target == EmergencyStatus.RESOLVED:
        if item.outcome is None:
            raise InvalidInputError("outcome is required for RESOLVED.", code="OUTCOME_REQUIRED")
        await assignment_service.resolve(session, emergency, actor, outcome=item.outcome,
                                         notes=item.resolution_notes or item.reason, **kwargs)
    else:  # CANCELLED / REJECTED
        ensure_transition(emergency.status, target)
        await es.close_assignment(session, emergency, AssignmentStatus.CANCELLED)
        await es.transition(session, emergency, target, actor, reason=item.reason, **kwargs)


async def apply_status_updates(
    session: AsyncSession, request: SyncStatusRequest, actor: User, settings: Settings
) -> tuple[list[SyncStatusResult], SyncCounts]:
    record_id = await _start(
        session, actor, request.device_id, "STATUS_UPLOAD", len(request.items)
    )
    results: list[SyncStatusResult] = []
    counts = SyncCounts()

    # Oldest first, so changes made offline replay in the order they happened.
    for item in sorted(request.items, key=lambda i: i.changed_at):
        result = await _apply_one(session, item, actor, settings)
        setattr(counts, result.result, getattr(counts, result.result) + 1)
        results.append(result)

    await _finish(session, record_id, counts, actor, "SYNC_STATUS")
    order = {item.update_id: index for index, item in enumerate(request.items)}
    results.sort(key=lambda r: order.get(r.update_id, 0))
    return results, counts


async def _apply_one(
    session: AsyncSession, item: SyncStatusItem, actor: User, settings: Settings
) -> SyncStatusResult:
    seen = await session.scalar(
        select(EmergencyStatusHistory.emergency_id).where(
            EmergencyStatusHistory.client_update_id == item.update_id
        )
    )
    emergency = await _find(session, item)
    if emergency is None or not es.can_view(actor, emergency):
        return SyncStatusResult(update_id=item.update_id, result="not_found")

    def outcome(result: str, error: dict | None = None) -> SyncStatusResult:
        return SyncStatusResult(
            update_id=item.update_id, result=result, emergency_id=emergency.id,
            current_status=emergency.status, server_changed_at=emergency.status_changed_at,
            error=error,
        )

    if seen is not None:
        return outcome("duplicate")
    if item.changed_at > utcnow() + timedelta(minutes=settings.max_clock_skew_minutes):
        return outcome(
            "invalid",
            {"code": "INVALID_TIMESTAMP", "message": "changed_at is in the future."},
        )
    if item.status in (EmergencyStatus.CREATED, EmergencyStatus.RECEIVED):
        return outcome(
            "invalid",
            {"code": "INVALID_SYNC_STATUS", "message": f"{item.status} is set by the server."},
        )
    if emergency.status == item.status:
        return outcome("duplicate")
    if (
        emergency.status not in (EmergencyStatus.CREATED, EmergencyStatus.RECEIVED)
        and emergency.status_changed_at > item.changed_at
    ):
        # The server already has newer workflow progress (another console,
        # or the web). Last-writer-wins would silently lose it, so report
        # instead. CREATED/RECEIVED are the server's own intake steps, made
        # when the SOS was uploaded -- often AFTER a console handled it
        # offline -- so they never make an offline update stale.
        return outcome(
            "conflict",
            {"code": "STALE_UPDATE",
             "message": "The emergency changed on the server after this update was made."},
        )

    emergency_id = emergency.id
    try:
        await _apply(session, emergency, item, actor)
        if emergency.status != item.status:
            # e.g. a same-team re-assignment that changed nothing.
            raise ConflictError(
                f"The update had no effect; the emergency is {emergency.status}.",
                code="NO_EFFECT",
            )
        await session.commit()
    except (InvalidTransitionError, ConflictError) as exc:
        await _reset(session, actor)
        emergency = await session.get(Emergency, emergency_id, populate_existing=True)
        return outcome("conflict", _error(exc))
    except (AuthorizationError, InvalidInputError, NotFoundError) as exc:
        await _reset(session, actor)
        emergency = await session.get(Emergency, emergency_id, populate_existing=True)
        return outcome("invalid", _error(exc))
    return outcome("applied")


# -- pull ------------------------------------------------------------------

def encode_cursor(emergency: Emergency) -> str:
    raw = f"{emergency.updated_at.isoformat()}|{emergency.id}".encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        stamp, ident = base64.urlsafe_b64decode(padded).decode().split("|", 1)
        value = datetime.fromisoformat(stamp)
        return value, uuid.UUID(ident)
    except (ValueError, binascii.Error, UnicodeDecodeError) as exc:
        raise InvalidInputError("Invalid sync cursor.", code="INVALID_CURSOR") from exc


async def pull(
    session: AsyncSession,
    actor: User,
    *,
    cursor: str | None,
    since: datetime | None,
    limit: int,
) -> tuple[list[Emergency], str | None, bool]:
    query = es._apply_filters(select(Emergency), es.EmergencyFilters(), actor)
    if cursor:
        updated_at, last_id = decode_cursor(cursor)
        query = query.where(es.keyset_filter(updated_at, last_id))
    elif since is not None:
        query = query.where(Emergency.updated_at >= since)
    rows = list(
        (
            await session.scalars(
                query.order_by(Emergency.updated_at, Emergency.id).limit(limit + 1)
            )
        ).all()
    )
    has_more = len(rows) > limit
    rows = rows[:limit]
    return rows, (encode_cursor(rows[-1]) if rows else None), has_more
