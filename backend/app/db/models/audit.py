from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import BigInteger, Integer, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.db.database import Base
from app.db.types import JSONType, UTCDateTime, utcnow

GENESIS_HASH = "0" * 64

# SQLite only auto-increments a column declared exactly INTEGER PRIMARY KEY.
_SequenceType = BigInteger().with_variant(Integer(), "sqlite")


class AuditLog(Base):
    """One block of the tamper-evident hash chain.

    current_hash = SHA-256(canonical JSON of this entry's fields, including
    previous_hash). actor_user_id is a plain value, not a foreign key: a
    later user deletion must not rewrite hashed history."""

    __tablename__ = "audit_logs"

    sequence: Mapped[int] = mapped_column(_SequenceType, primary_key=True)
    event_id: Mapped[uuid.UUID] = mapped_column(Uuid, unique=True, default=uuid.uuid4)
    timestamp: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    actor_user_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True, index=True)
    actor_label: Mapped[str] = mapped_column(String(120))
    action: Mapped[str] = mapped_column(String(64), index=True)
    entity_type: Mapped[str] = mapped_column(String(40), index=True)
    entity_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    details: Mapped[dict[str, Any]] = mapped_column("metadata", JSONType, default=dict)
    # Unique: two writers can never both append after the same block, so the
    # chain cannot fork even under concurrency.
    previous_hash: Mapped[str] = mapped_column(String(64), unique=True)
    current_hash: Mapped[str] = mapped_column(String(64), unique=True)


class AuditChainHead(Base):
    """Single row (id=1) holding the chain tip. Appenders lock it with
    SELECT ... FOR UPDATE, serializing appends across processes."""

    __tablename__ = "audit_chain_head"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    last_sequence: Mapped[int] = mapped_column(BigInteger, default=0)
    last_hash: Mapped[str] = mapped_column(String(64), default=GENESIS_HASH)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
