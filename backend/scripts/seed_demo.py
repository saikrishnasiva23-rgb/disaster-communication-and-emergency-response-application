"""DEMO / DEVELOPMENT DATA ONLY -- refuses to run when ENVIRONMENT=production.

Creates (idempotently; existing records are left alone):
  * 1 admin            demo_admin
  * 2 rescue users     dis_comm (Alpha team leader), demo_rescuer_bravo
  * 2 rescue teams     "DEMO Alpha Rescue Unit", "DEMO Bravo Medical Unit"
  * 2 affected users   demo_affected_1, demo_affected_2
  * 2 devices          an Android phone and the Windows rescue console
  * 3 sample emergencies (descriptions start with "[DEMO]"), created through
    the normal services, so their priority and audit entries are genuine.

Passwords are never hard-coded: all demo accounts get DEMO_PASSWORD from the
environment, or a random one that is printed once.

    python scripts/seed_demo.py            (after `alembic upgrade head`)
"""

from __future__ import annotations

import asyncio
import os
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import select  # noqa: E402

from app.core.config import get_settings  # noqa: E402
from app.db.database import create_engine, create_session_factory  # noqa: E402
from app.db.models import RescueTeam, User, ensure_roles  # noqa: E402
from app.domain.enums import (  # noqa: E402
    DevicePlatform,
    DeviceType,
    EmergencySource,
    TeamMemberRole,
    UserRole,
)
from app.schemas.device import DeviceRegister  # noqa: E402
from app.schemas.emergency import EmergencyCreate, LocationIn  # noqa: E402
from app.schemas.rescue_team import TeamCreate, TeamMemberAdd  # noqa: E402
from app.services import (  # noqa: E402
    assignment_service,
    audit_service,
    device_service,
    team_service,
    user_service,
)
from app.services import emergency_service as es  # noqa: E402
from app.services.priority_service import (  # noqa: E402
    PriorityService,
    RandomForestDemoClassifier,
)

USERS = [
    ("demo_admin", UserRole.ADMIN, "DEMO Administrator"),
    ("dis_comm", UserRole.RESCUE_TEAM, "DEMO Rescue Leader (Alpha)"),
    ("demo_rescuer_bravo", UserRole.RESCUE_TEAM, "DEMO Rescuer (Bravo)"),
    ("demo_affected_1", UserRole.AFFECTED_PERSON, "DEMO Affected Person 1"),
    ("demo_affected_2", UserRole.AFFECTED_PERSON, "DEMO Affected Person 2"),
]


async def _user(session, username: str, role: UserRole, name: str, password: str) -> User:  # noqa: ANN001
    existing = await user_service.get_by_login(session, username)
    if existing:
        print(f"  = user {username} exists (left unchanged)")
        return existing
    user = await user_service.create_user(
        session, username=username, password=password, role=role, full_name=name
    )
    print(f"  + user {username} ({role})")
    return user


async def _team(session, name: str, caps: list[str], lat: float, lon: float, admin: User) -> RescueTeam:  # noqa: ANN001
    existing = await session.scalar(select(RescueTeam).where(RescueTeam.name == name))
    if existing:
        print(f"  = team {name} exists")
        return existing
    team = await team_service.create_team(
        session,
        TeamCreate(name=name, capabilities=caps, base_latitude=lat, base_longitude=lon),
        admin,
    )
    print(f"  + team {name}")
    return team


async def main() -> None:
    settings = get_settings()
    if settings.is_production:
        sys.exit("Refusing to seed demo data: ENVIRONMENT=production.")

    password = os.environ.get("DEMO_PASSWORD") or ""
    generated = not password
    if generated:
        password = secrets.token_urlsafe(12)
    if len(password) < 8:
        sys.exit("DEMO_PASSWORD must be at least 8 characters.")

    engine = create_engine(settings)
    factory = create_session_factory(engine)
    priority = PriorityService(model=RandomForestDemoClassifier())
    await priority.warm_up()

    async with factory() as session:
        await ensure_roles(session)
        await audit_service.ensure_chain_head(session)

        print("Users:")
        users = {u: await _user(session, u, r, n, password) for u, r, n in USERS}
        admin, alpha_lead = users["demo_admin"], users["dis_comm"]

        print("Teams:")
        alpha = await _team(session, "DEMO Alpha Rescue Unit", ["WATER_RESCUE", "FIRST_AID"],
                            11.9416, 79.8083, admin)
        bravo = await _team(session, "DEMO Bravo Medical Unit", ["MEDICAL", "AMBULANCE"],
                            11.9350, 79.8300, admin)
        for team, user, role in [(alpha, alpha_lead, TeamMemberRole.LEADER),
                                 (bravo, users["demo_rescuer_bravo"], TeamMemberRole.MEMBER)]:
            if await team_service.team_of_user(session, user.id) is None:
                await team_service.add_member(
                    session, team, TeamMemberAdd(user_id=user.id, member_role=role), admin
                )
                print(f"  + {user.username} -> {team.name}")

        print("Devices:")
        await device_service.register(
            session,
            DeviceRegister(client_device_id="demo-android-phone-01",
                           device_type=DeviceType.AFFECTED_PHONE,
                           platform=DevicePlatform.ANDROID, device_name="DEMO Android Phone"),
            users["demo_affected_1"],
        )
        await device_service.register(
            session,
            DeviceRegister(client_device_id="demo-windows-console-01",
                           device_type=DeviceType.RESCUE_CONSOLE,
                           platform=DevicePlatform.WINDOWS, device_name="DEMO Rescue Laptop"),
            alpha_lead,
        )
        await session.commit()
        print("  + demo-android-phone-01, demo-windows-console-01")

        print("Emergencies:")
        samples = [
            (users["demo_affected_1"], EmergencyCreate(
                client_emergency_id="demo-sos-0001", emergency_type="FLOOD",
                description="[DEMO] Water entering the ground floor, family of four",
                people_count=4, injured=False, trapped=True, severity=4,
                location=LocationIn(latitude=11.9401, longitude=79.8120, accuracy_m=15),
                origin_device_id="demo-android-phone-01")),
            (alpha_lead, EmergencyCreate(
                client_emergency_id="demo-sos-0002", emergency_type="MEDICAL",
                description="[DEMO] Received over BLE; elderly man with chest pain",
                people_count=1, injured=True, severity=5,
                location=LocationIn(latitude=11.9372, longitude=79.8261, accuracy_m=8),
                origin_device_id="demo-ble-phone-02", sender_display_name="DEMO Redmi Phone",
                source=EmergencySource.BLE, local_ble_acknowledged=True)),
            (users["demo_affected_2"], EmergencyCreate(
                client_emergency_id="demo-sos-0003", emergency_type="OTHER",
                description="[DEMO] No GPS fix available -- sent without a location",
                people_count=2)),
        ]
        created = []
        for actor, data in samples:
            emergency, new = await es.submit_emergency(session, data, actor, priority, settings)
            created.append(emergency)
            print(f"  {'+' if new else '='} {data.client_emergency_id} "
                  f"{emergency.emergency_type} {emergency.priority} {emergency.status}")

        second = created[1]
        if second.assigned_team_id is None and second.status == "RECEIVED":
            await assignment_service.assign(session, second, bravo.id, alpha_lead,
                                            notes="[DEMO] nearest medical unit")
            await session.commit()
            print(f"  ~ {second.client_emergency_id} assigned to {bravo.name}")

    await engine.dispose()
    print()
    print("DEMO DATA ONLY. Accounts:", ", ".join(u for u, _, _ in USERS))
    if generated:
        print(f"Generated password for all demo accounts (shown once): {password}")
    else:
        print("Password: the DEMO_PASSWORD you provided.")


if __name__ == "__main__":
    asyncio.run(main())
