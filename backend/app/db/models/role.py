from __future__ import annotations

from sqlalchemy import String, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import Mapped, mapped_column

from app.db.database import Base
from app.domain.enums import UserRole

ROLE_DESCRIPTIONS = {
    UserRole.AFFECTED_PERSON: "Person in distress; reports and follows their own emergencies.",
    UserRole.RESCUE_TEAM: "Rescue responder; triages, acknowledges, assigns and resolves.",
    UserRole.ADMIN: "Administrator; manages users, teams and the audit log.",
}


class Role(Base):
    """Reference table for users.role (RBAC). The permission rules
    themselves live in code (app/api/deps.py and the services)."""

    __tablename__ = "roles"

    code: Mapped[str] = mapped_column(String(20), primary_key=True)
    description: Mapped[str] = mapped_column(String(200))


async def ensure_roles(session: AsyncSession) -> None:
    existing = set((await session.scalars(select(Role.code))).all())
    for role, description in ROLE_DESCRIPTIONS.items():
        if role.value not in existing:
            session.add(Role(code=role.value, description=description))
    await session.flush()
