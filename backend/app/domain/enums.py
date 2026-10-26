from enum import StrEnum


class UserRole(StrEnum):
    AFFECTED_PERSON = "AFFECTED_PERSON"
    RESCUE_TEAM = "RESCUE_TEAM"
    ADMIN = "ADMIN"


class EmergencyStatus(StrEnum):
    CREATED = "CREATED"
    RECEIVED = "RECEIVED"
    ACKNOWLEDGED = "ACKNOWLEDGED"
    ASSIGNED = "ASSIGNED"
    IN_PROGRESS = "IN_PROGRESS"
    RESOLVED = "RESOLVED"
    CANCELLED = "CANCELLED"
    REJECTED = "REJECTED"


class PriorityLevel(StrEnum):
    LOW = "LOW"
    MEDIUM = "MEDIUM"
    HIGH = "HIGH"
    CRITICAL = "CRITICAL"

    @property
    def rank(self) -> int:
        return _PRIORITY_RANK[self]


_PRIORITY_RANK = {
    PriorityLevel.LOW: 1,
    PriorityLevel.MEDIUM: 2,
    PriorityLevel.HIGH: 3,
    PriorityLevel.CRITICAL: 4,
}


class TeamStatus(StrEnum):
    AVAILABLE = "AVAILABLE"
    BUSY = "BUSY"
    OFFLINE = "OFFLINE"


class TeamMemberRole(StrEnum):
    LEADER = "LEADER"
    MEMBER = "MEMBER"


class AssignmentStatus(StrEnum):
    ASSIGNED = "ASSIGNED"
    ACCEPTED = "ACCEPTED"
    COMPLETED = "COMPLETED"
    CANCELLED = "CANCELLED"


ACTIVE_ASSIGNMENT_STATUSES = (AssignmentStatus.ASSIGNED, AssignmentStatus.ACCEPTED)


class DevicePlatform(StrEnum):
    ANDROID = "ANDROID"
    WINDOWS = "WINDOWS"
    IOS = "IOS"
    WEB = "WEB"
    OTHER = "OTHER"


class DeviceType(StrEnum):
    AFFECTED_PHONE = "AFFECTED_PHONE"
    RESCUE_CONSOLE = "RESCUE_CONSOLE"
    RELAY_NODE = "RELAY_NODE"
    OTHER = "OTHER"


class EmergencySource(StrEnum):
    """How the emergency reached the cloud."""

    MOBILE_APP = "MOBILE_APP"  # affected phone uploaded it itself
    BLE = "BLE"  # received by a rescue console over BLE, then uploaded
    BLE_RELAY = "BLE_RELAY"  # arrived over one or more BLE relay hops
    RESCUE_MANUAL = "RESCUE_MANUAL"  # entered by a rescuer
    LEGACY_API = "LEGACY_API"  # the Flutter app's old /api/rescue-request


class SyncState(StrEnum):
    SYNCED = "SYNCED"
    CONFLICT = "CONFLICT"


class ResolutionOutcome(StrEnum):
    RESCUED = "RESCUED"
    TREATED_ON_SITE = "TREATED_ON_SITE"
    REFERRED = "REFERRED"
    NO_ACTION_NEEDED = "NO_ACTION_NEEDED"
    UNREACHABLE = "UNREACHABLE"
    OTHER = "OTHER"


class ChangeVia(StrEnum):
    API = "API"
    SYNC = "SYNC"
    SYSTEM = "SYSTEM"
