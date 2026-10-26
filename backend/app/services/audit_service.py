"""Tamper-evident, blockchain-style audit logging (a SHA-256 hash chain).

Each entry's hash covers its own fields plus the previous entry's hash, so
changing, deleting or reordering any past entry breaks every later link and
`verify_chain` reports where. This is a hash chain in the server database,
not a decentralized blockchain: someone with write access who rewrites the
*entire* chain and head consistently would not be detected locally (the
upgrade path is periodically anchoring the head hash somewhere external)."""

from __future__ import annotations

import hashlib
import json
import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import GENESIS_HASH, AuditChainHead, AuditLog, User
from app.db.types import utcnow


def _jsonable(value: Any) -> Any:
    """Round-trips through JSON so what is hashed is exactly what the JSON
    column returns later (UUIDs/datetimes become strings)."""
    return json.loads(json.dumps(value if value is not None else {}, default=str))


def compute_hash(
    *,
    sequence: int,
    event_id: uuid.UUID,
    timestamp: datetime,
    actor_user_id: uuid.UUID | None,
    actor_label: str,
    action: str,
    entity_type: str,
    entity_id: str | None,
    details: dict[str, Any],
    previous_hash: str,
) -> str:
    payload = {
        "sequence": sequence,
        "event_id": str(event_id),
        "timestamp": timestamp.astimezone(UTC).isoformat(),
        "actor_user_id": str(actor_user_id) if actor_user_id else None,
        "actor_label": actor_label,
        "action": action,
        "entity_type": entity_type,
        "entity_id": entity_id,
        "metadata": details,
        "previous_hash": previous_hash,
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _hash_of(entry: AuditLog) -> str:
    return compute_hash(
        sequence=entry.sequence,
        event_id=entry.event_id,
        timestamp=entry.timestamp,
        actor_user_id=entry.actor_user_id,
        actor_label=entry.actor_label,
        action=entry.action,
        entity_type=entry.entity_type,
        entity_id=entry.entity_id,
        details=entry.details,
        previous_hash=entry.previous_hash,
    )


async def ensure_chain_head(session: AsyncSession) -> None:
    if await session.get(AuditChainHead, 1) is None:
        session.add(AuditChainHead(id=1, last_sequence=0, last_hash=GENESIS_HASH))
        await session.flush()


async def record(
    session: AsyncSession,
    *,
    action: str,
    entity_type: str,
    entity_id: Any = None,
    actor: User | None = None,
    actor_label: str | None = None,
    details: dict[str, Any] | None = None,
) -> AuditLog:
    """Appends one entry inside the caller's transaction, so the audit entry
    commits (or rolls back) atomically with the change it describes.

    The chain-head row is locked (SELECT ... FOR UPDATE on PostgreSQL;
    SQLite serializes writers itself), so concurrent requests append one
    after another instead of forking the chain."""
    head = await session.get(
        AuditChainHead, 1, with_for_update=True, populate_existing=True
    )
    if head is None:
        head = AuditChainHead(id=1, last_sequence=0, last_hash=GENESIS_HASH)
        session.add(head)
        await session.flush()

    entry = AuditLog(
        sequence=head.last_sequence + 1,
        event_id=uuid.uuid4(),
        timestamp=utcnow(),
        actor_user_id=actor.id if actor else None,
        actor_label=actor_label or (actor.username if actor else "system"),
        action=action,
        entity_type=entity_type,
        entity_id=str(entity_id) if entity_id is not None else None,
        details=_jsonable(details),
        previous_hash=head.last_hash,
        current_hash="",
    )
    entry.current_hash = _hash_of(entry)

    head.last_sequence = entry.sequence
    head.last_hash = entry.current_hash
    head.updated_at = entry.timestamp
    session.add(entry)
    await session.flush()
    return entry


async def verify_chain(session: AsyncSession, batch_size: int = 500) -> dict[str, Any]:
    expected_previous = GENESIS_HASH
    expected_sequence = 1
    checked = 0
    last_sequence = 0

    head = await session.get(AuditChainHead, 1, populate_existing=True)
    head_sequence = head.last_sequence if head else 0
    head_hash = head.last_hash if head else GENESIS_HASH

    def invalid(sequence: int | None, reason: str) -> dict[str, Any]:
        return {
            "valid": False,
            "entries_checked": checked,
            "head_sequence": head_sequence,
            "head_hash": head_hash,
            "first_invalid_sequence": sequence,
            "reason": reason,
        }

    while True:
        rows = (
            await session.scalars(
                select(AuditLog)
                .where(AuditLog.sequence > last_sequence)
                .order_by(AuditLog.sequence)
                .limit(batch_size)
                .execution_options(populate_existing=True)
            )
        ).all()
        if not rows:
            break
        for row in rows:
            if row.sequence != expected_sequence:
                return invalid(
                    expected_sequence, "Sequence gap: an audit entry is missing."
                )
            if row.previous_hash != expected_previous:
                return invalid(
                    row.sequence,
                    "previous_hash does not match the preceding entry's hash.",
                )
            if _hash_of(row) != row.current_hash:
                return invalid(
                    row.sequence, "Entry content does not match its stored hash."
                )
            expected_previous = row.current_hash
            expected_sequence += 1
            checked += 1
            last_sequence = row.sequence

    result: dict[str, Any] = {
        "valid": True,
        "entries_checked": checked,
        "head_sequence": head_sequence,
        "head_hash": head_hash,
        "first_invalid_sequence": None,
        "reason": None,
    }
    if head_sequence != checked or head_hash != expected_previous:
        result.update(
            valid=False,
            first_invalid_sequence=checked + 1 if head_sequence > checked else None,
            reason="The chain head does not match the last entry "
            "(entries removed from the end of the log?).",
        )
    return result


async def count_entries(session: AsyncSession) -> int:
    return int(await session.scalar(select(func.count()).select_from(AuditLog)) or 0)
