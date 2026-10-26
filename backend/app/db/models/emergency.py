from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    Uuid,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.database import Base
from app.db.types import UTCDateTime, utcnow


class Emergency(Base):
    __tablename__ = "emergencies"
    __table_args__ = (
        Index("ix_emergencies_lat_lon", "latitude", "longitude"),
        Index("ix_emergencies_updated_id", "updated_at", "id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)

    # Client-generated id / idempotency key (e.g. the BLE SosPacket.id).
    # Unique: a resend of the same SOS can never create a second record.
    client_emergency_id: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    payload_hash: Mapped[str] = mapped_column(String(64))

    reporter_user_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), nullable=True, index=True
    )
    sender_user_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), nullable=True, index=True
    )
    sender_device_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("devices.id", ondelete="SET NULL"), nullable=True, index=True
    )
    origin_client_device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    sender_display_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    relayed_by_client_device_id: Mapped[str | None] = mapped_column(
        String(64), nullable=True
    )
    relayed_by_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    hop_count: Mapped[int] = mapped_column(Integer, default=0)

    emergency_type: Mapped[str] = mapped_column(String(40), index=True)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    people_count: Mapped[int] = mapped_column(Integer, default=1)
    injured: Mapped[bool] = mapped_column(Boolean, default=False)
    trapped: Mapped[bool] = mapped_column(Boolean, default=False)
    severity: Mapped[int | None] = mapped_column(Integer, nullable=True)
    injury_details: Mapped[str | None] = mapped_column(Text, nullable=True)

    # Latest known position (full history in emergency_locations). Null when
    # the phone had no GPS fix -- never a made-up coordinate.
    latitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    longitude: Mapped[float | None] = mapped_column(Float, nullable=True)

    occurred_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    received_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    # Bumped on every change -- drives incremental sync (GET /sync/emergencies).
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, onupdate=utcnow)

    priority: Mapped[str] = mapped_column(String(16), index=True)
    priority_score: Mapped[float] = mapped_column(Float, default=0.0)
    priority_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    priority_model: Mapped[str | None] = mapped_column(String(64), nullable=True)
    client_priority: Mapped[str | None] = mapped_column(String(16), nullable=True)

    status: Mapped[str] = mapped_column(String(20), index=True)
    status_changed_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    status_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    source: Mapped[str] = mapped_column(String(20), index=True)

    sync_state: Mapped[str] = mapped_column(String(16), default="SYNCED")
    sync_count: Mapped[int] = mapped_column(Integer, default=1)
    first_synced_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    last_synced_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

    assigned_team_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid,
        ForeignKey("rescue_teams.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )

    # Cloud acknowledgement (HTTPS) -- deliberately separate from the local
    # BLE ACK, which the rescue console may only *report* here.
    cloud_acknowledged_at: Mapped[datetime | None] = mapped_column(
        UTCDateTime, nullable=True
    )
    acknowledged_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    local_ble_acknowledged: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    local_ble_acknowledged_at: Mapped[datetime | None] = mapped_column(
        UTCDateTime, nullable=True
    )

    resolved_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    resolved_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    resolution_outcome: Mapped[str | None] = mapped_column(String(24), nullable=True)
    resolution_notes: Mapped[str | None] = mapped_column(Text, nullable=True)

    locations: Mapped[list["EmergencyLocation"]] = relationship(
        back_populates="emergency",
        cascade="all, delete-orphan",
        order_by="EmergencyLocation.recorded_at",
        lazy="raise",
    )
    status_history: Mapped[list["EmergencyStatusHistory"]] = relationship(
        back_populates="emergency",
        cascade="all, delete-orphan",
        order_by="EmergencyStatusHistory.changed_at",
        lazy="raise",
    )
    assignments: Mapped[list["EmergencyAssignment"]] = relationship(
        back_populates="emergency",
        cascade="all, delete-orphan",
        order_by="EmergencyAssignment.assigned_at",
        lazy="raise",
    )


class EmergencyLocation(Base):
    __tablename__ = "emergency_locations"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    emergency_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("emergencies.id", ondelete="CASCADE"), index=True
    )
    device_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("devices.id", ondelete="SET NULL"), nullable=True
    )
    latitude: Mapped[float] = mapped_column(Float)
    longitude: Mapped[float] = mapped_column(Float)
    accuracy_m: Mapped[float | None] = mapped_column(Float, nullable=True)
    altitude_m: Mapped[float | None] = mapped_column(Float, nullable=True)
    recorded_at: Mapped[datetime] = mapped_column(UTCDateTime)
    received_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    submitted_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )

    emergency: Mapped[Emergency] = relationship(back_populates="locations")


class EmergencyStatusHistory(Base):
    __tablename__ = "emergency_status_history"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    emergency_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("emergencies.id", ondelete="CASCADE"), index=True
    )
    from_status: Mapped[str | None] = mapped_column(String(20), nullable=True)
    to_status: Mapped[str] = mapped_column(String(20))
    changed_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    changed_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    client_changed_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    via: Mapped[str] = mapped_column(String(10), default="API")
    # Idempotency key of an offline status update (POST /sync/status), so a
    # retried upload is recognised instead of applied twice.
    client_update_id: Mapped[str | None] = mapped_column(
        String(64), unique=True, nullable=True
    )

    emergency: Mapped[Emergency] = relationship(back_populates="status_history")


class EmergencyAssignment(Base):
    __tablename__ = "emergency_assignments"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    emergency_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("emergencies.id", ondelete="CASCADE"), index=True
    )
    team_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("rescue_teams.id", ondelete="RESTRICT"), index=True
    )
    assigned_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    status: Mapped[str] = mapped_column(String(16), index=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    assigned_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    accepted_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    completed_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    cancelled_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)

    emergency: Mapped[Emergency] = relationship(back_populates="assignments")
