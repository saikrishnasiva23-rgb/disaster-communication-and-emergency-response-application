"""The controlled emergency status lifecycle.

    CREATED -> RECEIVED -> ACKNOWLEDGED -> ASSIGNED -> IN_PROGRESS -> RESOLVED
    (plus CANCELLED / REJECTED from any active state, handover
    IN_PROGRESS -> ASSIGNED, and unassign ASSIGNED -> ACKNOWLEDGED)
"""

from __future__ import annotations

from app.core.errors import InvalidTransitionError
from app.domain.enums import EmergencyStatus as S

ALLOWED_TRANSITIONS: dict[S, frozenset[S]] = {
    S.CREATED: frozenset({S.RECEIVED, S.CANCELLED, S.REJECTED}),
    S.RECEIVED: frozenset({S.ACKNOWLEDGED, S.CANCELLED, S.REJECTED}),
    S.ACKNOWLEDGED: frozenset({S.ASSIGNED, S.CANCELLED, S.REJECTED}),
    S.ASSIGNED: frozenset({S.IN_PROGRESS, S.ACKNOWLEDGED, S.CANCELLED}),
    S.IN_PROGRESS: frozenset({S.RESOLVED, S.ASSIGNED, S.CANCELLED}),
    S.RESOLVED: frozenset(),
    S.CANCELLED: frozenset(),
    S.REJECTED: frozenset(),
}

TERMINAL_STATUSES = frozenset({S.RESOLVED, S.CANCELLED, S.REJECTED})
ACTIVE_STATUSES = frozenset(set(S) - TERMINAL_STATUSES)


def can_transition(current: S, target: S) -> bool:
    return target in ALLOWED_TRANSITIONS[current]


def ensure_transition(current: S | str, target: S | str) -> None:
    current_s, target_s = S(current), S(target)
    if not can_transition(current_s, target_s):
        allowed = sorted(ALLOWED_TRANSITIONS[current_s])
        raise InvalidTransitionError(
            f"An emergency cannot move from {current_s} to {target_s}.",
            details={"current_status": current_s, "allowed": allowed},
        )


def is_active(status: S | str) -> bool:
    return S(status) in ACTIVE_STATUSES
