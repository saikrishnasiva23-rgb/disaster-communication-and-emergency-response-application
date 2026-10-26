"""Extensible emergency-type registry.

Types are validated strings, not a database enum, so adding one is a
registry/config change (EXTRA_EMERGENCY_TYPES) rather than a migration.
Aliases accept the labels the existing Flutter app already sends."""

from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass(frozen=True)
class EmergencyTypeInfo:
    code: str
    label: str
    life_threatening: bool
    aliases: tuple[str, ...] = ()


_BUILTIN: tuple[EmergencyTypeInfo, ...] = (
    EmergencyTypeInfo("FLOOD", "Flood", True, ("Flood Emergency",)),
    EmergencyTypeInfo("EARTHQUAKE", "Earthquake", True),
    EmergencyTypeInfo("CYCLONE", "Cyclone", True),
    EmergencyTypeInfo("LANDSLIDE", "Landslide", True),
    EmergencyTypeInfo("FIRE", "Fire", True, ("Fire Emergency",)),
    EmergencyTypeInfo(
        "MEDICAL", "Medical", False, ("Medical Emergency", "Injury")
    ),
    EmergencyTypeInfo("TRAPPED_PERSON", "Trapped person", True, ("Trapped", "Trapped Person")),
    EmergencyTypeInfo("MISSING_PERSON", "Missing person", False, ("Missing",)),
    EmergencyTypeInfo("OTHER", "Other", False, ("General Emergency", "General")),
)

_REGISTRY: dict[str, EmergencyTypeInfo] = {}
_LOOKUP: dict[str, str] = {}


def _key(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


def register(info: EmergencyTypeInfo) -> None:
    _REGISTRY[info.code] = info
    for name in (info.code, info.label, *info.aliases):
        _LOOKUP[_key(name)] = info.code


def register_extra_codes(codes: list[str]) -> None:
    for raw in codes:
        code = re.sub(r"[^A-Z0-9_]", "_", raw.strip().upper())
        if code and code not in _REGISTRY:
            register(EmergencyTypeInfo(code, code.replace("_", " ").title(), False))


for _info in _BUILTIN:
    register(_info)


def normalize(value: str) -> str:
    """Returns the canonical code for a type code/label/alias, or raises
    ValueError listing the valid codes."""
    code = _LOOKUP.get(_key(value or ""))
    if code is None:
        raise ValueError(
            f"Unknown emergency type '{value}'. Valid types: {', '.join(all_codes())}"
        )
    return code


def info(code: str) -> EmergencyTypeInfo:
    return _REGISTRY.get(code) or EmergencyTypeInfo(code, code.title(), False)


def all_codes() -> list[str]:
    return list(_REGISTRY)


def all_types() -> list[EmergencyTypeInfo]:
    return list(_REGISTRY.values())
