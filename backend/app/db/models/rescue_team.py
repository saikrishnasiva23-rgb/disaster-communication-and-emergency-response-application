from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Boolean, Float, ForeignKey, String, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.database import Base
from app.db.types import JSONType, UTCDateTime, utcnow


class RescueTeam(Base):
    __tablename__ = "rescue_teams"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(120), unique=True)
    status: Mapped[str] = mapped_column(String(16), default="AVAILABLE", index=True)
    capabilities: Mapped[list[str]] = mapped_column(JSONType, default=list)
    contact_phone: Mapped[str | None] = mapped_column(String(32), nullable=True)
    base_latitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    base_longitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    current_latitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    current_longitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    location_updated_at: Mapped[datetime | None] = mapped_column(
        UTCDateTime, nullable=True
    )
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        UTCDateTime, default=utcnow, onupdate=utcnow
    )

    members: Mapped[list["RescueTeamMember"]] = relationship(
        back_populates="team", cascade="all, delete-orphan", lazy="selectin"
    )


class RescueTeamMember(Base):
    __tablename__ = "rescue_team_members"
    # One team per rescuer keeps "which team am I on" unambiguous for
    # accept/resolve authorization.
    __table_args__ = (UniqueConstraint("user_id"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    team_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("rescue_teams.id", ondelete="CASCADE"), index=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE")
    )
    member_role: Mapped[str] = mapped_column(String(16), default="MEMBER")
    joined_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

    team: Mapped[RescueTeam] = relationship(back_populates="members")
