"""Importing this package registers every model on Base.metadata (used by
create_all and Alembic)."""

from app.db.models.audit import GENESIS_HASH, AuditChainHead, AuditLog
from app.db.models.device import Device
from app.db.models.emergency import (
    Emergency,
    EmergencyAssignment,
    EmergencyLocation,
    EmergencyStatusHistory,
)
from app.db.models.rescue_team import RescueTeam, RescueTeamMember
from app.db.models.role import Role, ensure_roles
from app.db.models.sync import SyncRecord
from app.db.models.user import User

__all__ = [
    "GENESIS_HASH",
    "AuditChainHead",
    "AuditLog",
    "Device",
    "Emergency",
    "EmergencyAssignment",
    "EmergencyLocation",
    "EmergencyStatusHistory",
    "RescueTeam",
    "RescueTeamMember",
    "Role",
    "SyncRecord",
    "User",
    "ensure_roles",
]
