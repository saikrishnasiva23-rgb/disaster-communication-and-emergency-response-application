from __future__ import annotations

import hashlib
import json
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, case, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.config import Settings
from app.core.errors import (
    AuthorizationError,
    ConflictError,
    InvalidInputError,
    NotFoundError,
)
from app.db.models import (
    Emergency,
    EmergencyAssignment,
    EmergencyLocation,
    EmergencyStatusHistory,
    User,
)
from app.db.types import utcnow
from app.domain.enums import (
    ACTIVE_ASSIGNMENT_STATUSES,
    AssignmentStatus,
    ChangeVia,
    EmergencySource,
    EmergencyStatus,
    PriorityLevel,
    UserRole,
)
from app.domain.lifecycle import ACTIVE_STATUSES, TERMINAL_STATUSES, ensure_transition
from app.schemas.emergency import EmergencyCreate, EmergencyUpdate, LocationIn
from app.services import audit_service, device_service, team_service
from app.services.priority_service import PriorityInput, PriorityService
from app.utils.geo import bounding_box, haversine_km

RESCUER_ROLES = (UserRole.RESCUE_TEAM, UserRole.ADMIN)
_OLDEST_PLAUSIBLE = datetime(2000, 1, 1, tzinfo=UTC)
_PRIORITY_FIELDS = {"emergency_type", "people_count", "injured", "trapped", "severity",
                    "description", "injury_details"}


def is_rescuer(user: User) -> bool:
    return user.role in RESCUER_ROLES


def can_view(user: User, emergency: Emergency) -> bool:
    return is_rescuer(user) or user.id in (emergency.sender_user_id, emergency.reporter_user_id)


def fingerprint(data: EmergencyCreate, client_id: str) -> str:
    """Identity of a submission's content. A resend of the same SOS matches;
    a *different* emergency reusing the same id does not (-> 409)."""
    loc = data.location
    core = {
        "id": client_id,
        "type": data.emergency_type,
        "description": (data.description or "").strip(),
        "people": data.people_count,
        "injured": data.injured,
        "trapped": data.trapped,
        "severity": data.severity,
        "occurred_at": data.occurred_at.replace(microsecond=0).isoformat()
        if data.occurred_at
        else None,
        "lat": round(loc.latitude, 5) if loc else None,
        "lon": round(loc.longitude, 5) if loc else None,
        "origin": data.origin_device_id,
    }
    return hashlib.sha256(json.dumps(core, sort_keys=True).encode()).hexdigest()


def priority_input_of(obj: Emergency | EmergencyCreate) -> PriorityInput:
    return PriorityInput(
        emergency_type=obj.emergency_type,
        people_count=obj.people_count,
        injured=obj.injured,
        trapped=obj.trapped,
        severity=obj.severity,
        description=obj.description,
        injury_details=obj.injury_details,
    )


async def get_by_client_id(session: AsyncSession, client_id: str) -> Emergency | None:
    return await session.scalar(
        select(Emergency).where(Emergency.client_emergency_id == client_id)
    )


async def get_emergency(
    session: AsyncSession,
    emergency_id: uuid.UUID,
    actor: User,
    *,
    detail: bool = False,
    for_update: bool = False,
) -> Emergency:
    query = select(Emergency).where(Emergency.id == emergency_id)
    if detail:
        query = query.options(
            selectinload(Emergency.locations),
            selectinload(Emergency.status_history),
            selectinload(Emergency.assignments),
        )
    if for_update:
        query = query.with_for_update()
    emergency = await session.scalar(query.execution_options(populate_existing=True))
    if emergency is None:
        raise NotFoundError("Emergency not found.", code="EMERGENCY_NOT_FOUND")
    if not can_view(actor, emergency):
        raise AuthorizationError("You cannot access this emergency.")
    return emergency


def _default_source(data: EmergencyCreate, actor: User) -> EmergencySource:
    if actor.role == UserRole.AFFECTED_PERSON:
        return EmergencySource.MOBILE_APP
    if data.source:
        return data.source
    if data.hop_count > 0:
        return EmergencySource.BLE_RELAY
    if data.origin_device_id:
        return EmergencySource.BLE
    return EmergencySource.RESCUE_MANUAL


def _check_timestamp(value: datetime, settings: Settings, field_name: str) -> None:
    now = utcnow()
    if value > now + timedelta(minutes=settings.max_clock_skew_minutes):
        raise InvalidInputError(
            f"{field_name} is in the future; check the device clock.",
            code="INVALID_TIMESTAMP",
            details={"field": field_name, "server_time": now.isoformat()},
        )
    if value < _OLDEST_PLAUSIBLE:
        raise InvalidInputError(
            f"{field_name} is implausibly old; check the device clock.",
            code="INVALID_TIMESTAMP",
            details={"field": field_name},
        )


def _add_history(
    emergency: Emergency,
    *,
    from_status: str | None,
    to_status: str,
    actor: User | None,
    when: datetime,
    reason: str | None = None,
    via: ChangeVia = ChangeVia.API,
    client_changed_at: datetime | None = None,
    client_update_id: str | None = None,
    session: AsyncSession,
) -> None:
    session.add(
        EmergencyStatusHistory(
            emergency_id=emergency.id,
            from_status=from_status,
            to_status=to_status,
            changed_by_user_id=actor.id if actor else None,
            changed_at=when,
            reason=reason,
            via=via,
            client_changed_at=client_changed_at,
            client_update_id=client_update_id,
        )
    )


async def _create(
    session: AsyncSession,
    data: EmergencyCreate,
    actor: User | None,
    priority_service: PriorityService,
    settings: Settings,
    client_id: str,
    payload_hash: str,
    *,
    via: ChangeVia,
    source: EmergencySource | None,
    actor_label: str | None = None,
) -> Emergency:
    """`actor` is None only for the unauthenticated legacy endpoint."""
    now = utcnow()
    occurred_at = data.occurred_at or now
    _check_timestamp(occurred_at, settings, "occurred_at")
    if data.location and data.location.recorded_at:
        _check_timestamp(data.location.recorded_at, settings, "location.recorded_at")
    if data.local_ble_acknowledged_at:
        _check_timestamp(data.local_ble_acknowledged_at, settings, "local_ble_acknowledged_at")

    affected = actor is not None and actor.role == UserRole.AFFECTED_PERSON
    sender_user_id = actor.id if affected else None
    device = None
    if data.origin_device_id and actor is not None:
        device = await device_service.resolve_origin_device(
            session, data.origin_device_id, display_name=data.sender_display_name, actor=actor
        )
        if sender_user_id is None and device.user_id is not None:
            sender_user_id = device.user_id

    result = await priority_service.classify(priority_input_of(data))

    emergency = Emergency(
        id=uuid.uuid4(),
        client_emergency_id=client_id,
        payload_hash=payload_hash,
        reporter_user_id=actor.id if actor else None,
        sender_user_id=sender_user_id,
        sender_device_id=device.id if device else None,
        origin_client_device_id=data.origin_device_id,
        sender_display_name=data.sender_display_name
        or (device.device_name if device else None)
        or (actor.full_name if affected else None),
        relayed_by_client_device_id=data.relayed_by_device_id,
        relayed_by_name=data.relayed_by_name,
        hop_count=data.hop_count,
        emergency_type=data.emergency_type,
        description=data.description,
        people_count=data.people_count,
        injured=data.injured,
        trapped=data.trapped,
        severity=data.severity,
        injury_details=data.injury_details,
        latitude=data.location.latitude if data.location else None,
        longitude=data.location.longitude if data.location else None,
        occurred_at=occurred_at,
        received_at=now,
        created_at=now,
        updated_at=now,
        priority=result.priority,
        priority_score=result.score,
        priority_reason=result.reason,
        priority_model=result.model,
        client_priority=data.client_priority,
        status=EmergencyStatus.RECEIVED,
        status_changed_at=now,
        source=source or _default_source(data, actor),  # type: ignore[arg-type]
        sync_state="SYNCED",
        sync_count=1,
        first_synced_at=now,
        last_synced_at=now,
        local_ble_acknowledged=data.local_ble_acknowledged,
        local_ble_acknowledged_at=data.local_ble_acknowledged_at,
    )
    session.add(emergency)

    # CREATED carries the client's time (clamped so history stays in order
    # even when the phone clock runs slightly ahead).
    _add_history(emergency, from_status=None, to_status=EmergencyStatus.CREATED, actor=actor,
                 when=min(occurred_at, now - timedelta(microseconds=1)), via=via,
                 client_changed_at=occurred_at, session=session)
    _add_history(emergency, from_status=EmergencyStatus.CREATED,
                 to_status=EmergencyStatus.RECEIVED, actor=actor, when=now, via=via,
                 session=session)
    if data.location:
        session.add(
            EmergencyLocation(
                emergency_id=emergency.id,
                device_id=device.id if device else None,
                latitude=data.location.latitude,
                longitude=data.location.longitude,
                accuracy_m=data.location.accuracy_m,
                altitude_m=data.location.altitude_m,
                recorded_at=data.location.recorded_at or occurred_at,
                received_at=now,
                submitted_by_user_id=actor.id if actor else None,
            )
        )
    await session.flush()

    await audit_service.record(
        session, action="EMERGENCY_CREATED", entity_type="emergency", entity_id=emergency.id,
        actor=actor, actor_label=actor_label,
        details={
            "client_emergency_id": client_id,
            "type": emergency.emergency_type,
            "source": emergency.source,
            "via": via,
            "has_location": data.location is not None,
        },
    )
    await audit_service.record(
        session, action="PRIORITY_CALCULATED", entity_type="emergency", entity_id=emergency.id,
        actor=actor, actor_label=actor_label,
        details={"priority": result.priority, "score": result.score, "model": result.model},
    )
    return emergency


async def create_legacy(
    session: AsyncSession,
    data: EmergencyCreate,
    priority_service: PriorityService,
    settings: Settings,
) -> tuple[Emergency, bool]:
    """The old Flask `/api/rescue-request` had no auth. Builds before
    protocol v3 sent no id, so each call is a new emergency (as before).
    Newer phones send their BLE packet id as `clientEmergencyId`: then the
    call is idempotent and the rescue laptop's later cloud sync of the same
    SOS is recognised as the same emergency, never a second record.
    Returns (emergency, created)."""
    client_id = data.client_emergency_id or f"legacy-{uuid.uuid4().hex}"
    existing = await get_by_client_id(session, client_id)
    if existing is not None:
        return existing, False
    try:
        emergency = await _create(
            session, data, None, priority_service, settings, client_id,
            fingerprint(data, client_id), via=ChangeVia.API,
            source=EmergencySource.LEGACY_API, actor_label="legacy-api",
        )
        await session.commit()
        return emergency, True
    except IntegrityError:
        await session.rollback()
        existing = await get_by_client_id(session, client_id)
        if existing is None:
            raise
        return existing, False


async def _resubmission(
    session: AsyncSession,
    existing: Emergency,
    payload_hash: str,
    data: EmergencyCreate,
    actor: User,
    via: ChangeVia,
) -> Emergency:
    if existing.payload_hash != payload_hash:
        raise ConflictError(
            "An emergency with this client_emergency_id already exists with "
            "different content.",
            code="IDEMPOTENCY_CONFLICT",
            details={"client_emergency_id": existing.client_emergency_id},
        )
    if not can_view(actor, existing):
        raise ConflictError(
            "This client_emergency_id is already in use.", code="IDEMPOTENCY_CONFLICT"
        )
    now = utcnow()
    existing.sync_count += 1
    existing.last_synced_at = now
    if data.local_ble_acknowledged and not existing.local_ble_acknowledged:
        existing.local_ble_acknowledged = True
        existing.local_ble_acknowledged_at = data.local_ble_acknowledged_at or now
    await session.flush()
    await audit_service.record(
        session, action="EMERGENCY_RESUBMITTED", entity_type="emergency",
        entity_id=existing.id, actor=actor,
        details={"sync_count": existing.sync_count, "via": via},
    )
    return existing


async def submit_emergency(
    session: AsyncSession,
    data: EmergencyCreate,
    actor: User,
    priority_service: PriorityService,
    settings: Settings,
    *,
    idempotency_key: str | None = None,
    via: ChangeVia = ChangeVia.API,
    source: EmergencySource | None = None,
) -> tuple[Emergency, bool]:
    """Idempotent create, committed. Returns (emergency, created).

    The unique constraint on client_emergency_id is the final arbiter: if two
    identical submissions race, the loser's insert fails, is rolled back, and
    it returns the winner's record -- never a duplicate."""
    if (
        data.client_emergency_id
        and idempotency_key
        and data.client_emergency_id != idempotency_key
    ):
        raise InvalidInputError(
            "Idempotency-Key header and client_emergency_id disagree.",
            code="IDEMPOTENCY_KEY_MISMATCH",
        )
    client_id = data.client_emergency_id or idempotency_key or f"srv-{uuid.uuid4().hex}"
    payload_hash = fingerprint(data, client_id)

    existing = await get_by_client_id(session, client_id)
    if existing is not None:
        emergency = await _resubmission(session, existing, payload_hash, data, actor, via)
        await session.commit()
        return emergency, False

    try:
        emergency = await _create(
            session, data, actor, priority_service, settings, client_id, payload_hash,
            via=via, source=source,
        )
        await session.commit()
        return emergency, True
    except IntegrityError:
        await session.rollback()
        # A rollback expires every loaded instance; reload the actor before use.
        await session.refresh(actor)
        existing = await get_by_client_id(session, client_id)
        if existing is None:
            raise
        emergency = await _resubmission(session, existing, payload_hash, data, actor, via)
        await session.commit()
        return emergency, False


@dataclass
class EmergencyFilters:
    statuses: list[EmergencyStatus] = field(default_factory=list)
    priorities: list[PriorityLevel] = field(default_factory=list)
    emergency_type: str | None = None
    assigned_team_id: uuid.UUID | None = None
    active_only: bool = False
    since: datetime | None = None
    until: datetime | None = None
    bbox: tuple[float, float, float, float] | None = None
    origin_device_id: str | None = None


_PRIORITY_ORDER = case(
    {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1}, value=Emergency.priority, else_=0
)


def _apply_filters(query, filters: EmergencyFilters, actor: User):  # noqa: ANN001, ANN202
    if not is_rescuer(actor):
        query = query.where(
            or_(Emergency.sender_user_id == actor.id, Emergency.reporter_user_id == actor.id)
        )
    if filters.statuses:
        query = query.where(Emergency.status.in_(filters.statuses))
    if filters.active_only:
        query = query.where(Emergency.status.in_(ACTIVE_STATUSES))
    if filters.priorities:
        query = query.where(Emergency.priority.in_(filters.priorities))
    if filters.emergency_type:
        query = query.where(Emergency.emergency_type == filters.emergency_type)
    if filters.assigned_team_id:
        query = query.where(Emergency.assigned_team_id == filters.assigned_team_id)
    if filters.since:
        query = query.where(Emergency.occurred_at >= filters.since)
    if filters.until:
        query = query.where(Emergency.occurred_at <= filters.until)
    if filters.origin_device_id:
        query = query.where(Emergency.origin_client_device_id == filters.origin_device_id)
    if filters.bbox:
        min_lat, max_lat, min_lon, max_lon = filters.bbox
        query = query.where(
            Emergency.latitude.between(min_lat, max_lat),
            Emergency.longitude.between(min_lon, max_lon),
        )
    return query


async def list_emergencies(
    session: AsyncSession, actor: User, filters: EmergencyFilters, *, page: int, page_size: int
) -> tuple[list[Emergency], int]:
    base = _apply_filters(select(Emergency), filters, actor)
    total = int(
        await session.scalar(select(func.count()).select_from(base.subquery())) or 0
    )
    rows = (
        await session.scalars(
            base.order_by(_PRIORITY_ORDER.desc(), Emergency.received_at.desc(), Emergency.id)
            .offset((page - 1) * page_size)
            .limit(page_size)
        )
    ).all()
    return list(rows), total


async def nearby(
    session: AsyncSession,
    actor: User,
    *,
    latitude: float,
    longitude: float,
    radius_km: float,
    filters: EmergencyFilters,
    limit: int,
) -> list[tuple[Emergency, float]]:
    filters.bbox = bounding_box(latitude, longitude, radius_km)
    rows = (await session.scalars(_apply_filters(select(Emergency), filters, actor))).all()
    hits = []
    for emergency in rows:
        if emergency.latitude is None or emergency.longitude is None:
            continue
        distance = haversine_km(latitude, longitude, emergency.latitude, emergency.longitude)
        if distance <= radius_km:
            hits.append((emergency, round(distance, 3)))
    hits.sort(key=lambda hit: (hit[1], -PriorityLevel(hit[0].priority).rank))
    return hits[:limit]


async def transition(
    session: AsyncSession,
    emergency: Emergency,
    target: EmergencyStatus,
    actor: User | None,
    *,
    reason: str | None = None,
    via: ChangeVia = ChangeVia.API,
    client_changed_at: datetime | None = None,
    client_update_id: str | None = None,
) -> None:
    """The only place an emergency's status changes: validates the
    lifecycle, records history and writes the audit entry."""
    previous = emergency.status
    ensure_transition(previous, target)
    now = utcnow()
    emergency.status = target
    emergency.status_changed_at = now
    if reason is not None:
        emergency.status_reason = reason
    emergency.updated_at = now
    _add_history(
        emergency, from_status=previous, to_status=target, actor=actor, when=now,
        reason=reason, via=via, client_changed_at=client_changed_at,
        client_update_id=client_update_id, session=session,
    )
    await session.flush()
    await audit_service.record(
        session, action="STATUS_CHANGED", entity_type="emergency", entity_id=emergency.id,
        actor=actor,
        details={"from": previous, "to": target, "reason": reason, "via": via},
    )


async def active_assignment(
    session: AsyncSession, emergency_id: uuid.UUID
) -> EmergencyAssignment | None:
    return await session.scalar(
        select(EmergencyAssignment)
        .where(
            EmergencyAssignment.emergency_id == emergency_id,
            EmergencyAssignment.status.in_(ACTIVE_ASSIGNMENT_STATUSES),
        )
        .order_by(EmergencyAssignment.assigned_at.desc())
    )


async def close_assignment(
    session: AsyncSession, emergency: Emergency, status: AssignmentStatus
) -> None:
    assignment = await active_assignment(session, emergency.id)
    if assignment is None:
        return
    now = utcnow()
    assignment.status = status
    if status == AssignmentStatus.COMPLETED:
        assignment.completed_at = now
    else:
        assignment.cancelled_at = now
    await session.flush()
    team = await team_service.get_team(session, assignment.team_id)
    await team_service.refresh_status(session, team)


async def acknowledge(
    session: AsyncSession,
    emergency: Emergency,
    actor: User,
    *,
    notes: str | None = None,
    via: ChangeVia = ChangeVia.API,
    client_changed_at: datetime | None = None,
    client_update_id: str | None = None,
) -> bool:
    """Cloud acknowledgement. Idempotent: returns False if already
    acknowledged. (The local BLE ACK is separate and never depends on this.)"""
    if emergency.cloud_acknowledged_at is not None:
        return False
    await transition(
        session, emergency, EmergencyStatus.ACKNOWLEDGED, actor, reason=notes, via=via,
        client_changed_at=client_changed_at, client_update_id=client_update_id,
    )
    emergency.cloud_acknowledged_at = utcnow()
    emergency.acknowledged_by_user_id = actor.id
    await session.flush()
    await audit_service.record(
        session, action="EMERGENCY_ACKNOWLEDGED", entity_type="emergency",
        entity_id=emergency.id, actor=actor, details={"via": via},
    )
    return True


async def update_emergency(
    session: AsyncSession,
    emergency: Emergency,
    patch: EmergencyUpdate,
    actor: User,
    priority_service: PriorityService,
) -> Emergency:
    changes = patch.model_dump(exclude_unset=True)
    target = changes.pop("status", None)
    reason = changes.pop("status_reason", None)

    if emergency.status in TERMINAL_STATUSES:
        raise ConflictError(
            f"This emergency is {emergency.status} and can no longer be changed.",
            code="EMERGENCY_CLOSED",
        )

    owner = actor.id in (emergency.sender_user_id, emergency.reporter_user_id)
    if not is_rescuer(actor):
        if not owner:
            raise AuthorizationError("You cannot change this emergency.")
        if target not in (None, EmergencyStatus.CANCELLED):
            raise AuthorizationError("You can only cancel your own emergency.")

    if target is not None and target not in (EmergencyStatus.CANCELLED, EmergencyStatus.REJECTED):
        raise InvalidInputError(
            "Use POST /acknowledge, /assign, /accept or /resolve for this status change.",
            code="USE_WORKFLOW_ENDPOINT",
            details={"status": target},
        )
    if target == EmergencyStatus.REJECTED and not is_rescuer(actor):
        raise AuthorizationError("Only the Rescue Team can reject an emergency.")

    if target is not None:
        ensure_transition(emergency.status, target)

    for name, value in changes.items():
        setattr(emergency, name, value)
    emergency.updated_at = utcnow()
    await session.flush()

    if changes:
        await audit_service.record(
            session, action="EMERGENCY_UPDATED", entity_type="emergency",
            entity_id=emergency.id, actor=actor, details={"fields": sorted(changes)},
        )
    if _PRIORITY_FIELDS & changes.keys():
        await reprioritize(session, emergency, actor, priority_service)

    if target is not None:
        await close_assignment(session, emergency, AssignmentStatus.CANCELLED)
        await transition(session, emergency, target, actor, reason=reason)
    return emergency


async def reprioritize(
    session: AsyncSession, emergency: Emergency, actor: User | None,
    priority_service: PriorityService,
) -> None:
    result = await priority_service.classify(priority_input_of(emergency))
    emergency.priority = result.priority
    emergency.priority_score = result.score
    emergency.priority_reason = result.reason
    emergency.priority_model = result.model
    await session.flush()
    await audit_service.record(
        session, action="PRIORITY_CALCULATED", entity_type="emergency",
        entity_id=emergency.id, actor=actor,
        details={"priority": result.priority, "score": result.score, "model": result.model},
    )


async def add_location(
    session: AsyncSession, emergency: Emergency, location: LocationIn, actor: User,
    settings: Settings,
) -> EmergencyLocation:
    if emergency.status in TERMINAL_STATUSES:
        raise ConflictError("This emergency is closed.", code="EMERGENCY_CLOSED")
    recorded_at = location.recorded_at or utcnow()
    _check_timestamp(recorded_at, settings, "recorded_at")

    latest = await session.scalar(
        select(func.max(EmergencyLocation.recorded_at)).where(
            EmergencyLocation.emergency_id == emergency.id
        )
    )
    entry = EmergencyLocation(
        emergency_id=emergency.id,
        device_id=emergency.sender_device_id,
        latitude=location.latitude,
        longitude=location.longitude,
        accuracy_m=location.accuracy_m,
        altitude_m=location.altitude_m,
        recorded_at=recorded_at,
        received_at=utcnow(),
        submitted_by_user_id=actor.id,
    )
    session.add(entry)
    # An older fix arriving late (offline sync) is kept in history but does
    # not move the "current" position backwards.
    if latest is None or recorded_at >= latest:
        emergency.latitude = location.latitude
        emergency.longitude = location.longitude
    emergency.updated_at = utcnow()
    await session.flush()
    await audit_service.record(
        session, action="LOCATION_RECEIVED", entity_type="emergency", entity_id=emergency.id,
        actor=actor,
        details={"accuracy_m": location.accuracy_m, "is_latest": latest is None or recorded_at >= latest},
    )
    return entry


def keyset_filter(updated_at: datetime, last_id: uuid.UUID):  # noqa: ANN201
    return or_(
        Emergency.updated_at > updated_at,
        and_(Emergency.updated_at == updated_at, Emergency.id > last_id),
    )
