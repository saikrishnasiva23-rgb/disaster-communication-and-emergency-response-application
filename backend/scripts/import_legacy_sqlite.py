"""Imports rows from the old Flask server's SQLite file (rescue_requests.db)
into the new database, so no previously received request is lost.

Idempotent: row N becomes emergency `legacy-import-N`; re-running skips rows
already imported. Priority is recomputed by the current classifier. The old
table had no timestamps, so `occurred_at` is the import time (stated in the
status reason).

    python scripts/import_legacy_sqlite.py [path/to/rescue_requests.db]
"""

from __future__ import annotations

import asyncio
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.core.config import get_settings  # noqa: E402
from app.db.database import create_engine, create_session_factory  # noqa: E402
from app.db.models import ensure_roles  # noqa: E402
from app.domain import emergency_types  # noqa: E402
from app.domain.enums import ChangeVia, EmergencySource  # noqa: E402
from app.schemas.emergency import EmergencyCreate, LocationIn  # noqa: E402
from app.services import audit_service  # noqa: E402
from app.services import emergency_service as es  # noqa: E402
from app.services.priority_service import (  # noqa: E402
    PriorityService,
    RandomForestDemoClassifier,
)


def _valid_coords(lat: object, lon: object) -> bool:
    try:
        return -90 <= float(lat) <= 90 and -180 <= float(lon) <= 180  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return False


async def main(path: Path) -> None:
    if not path.exists():
        sys.exit(f"Not found: {path}")
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    rows = connection.execute("SELECT * FROM rescue_requests ORDER BY id").fetchall()
    connection.close()

    settings = get_settings()
    engine = create_engine(settings)
    factory = create_session_factory(engine)
    priority = PriorityService(model=RandomForestDemoClassifier())
    await priority.warm_up()

    imported = skipped = 0
    async with factory() as session:
        await ensure_roles(session)
        await audit_service.ensure_chain_head(session)
        await session.commit()
        for row in rows:
            client_id = f"legacy-import-{row['id']}"
            if await es.get_by_client_id(session, client_id):
                skipped += 1
                continue
            try:
                etype = emergency_types.normalize(row["emergency_type"] or "OTHER")
            except ValueError:
                etype = "OTHER"
            lat, lon = row["latitude"], row["longitude"]
            data = EmergencyCreate(
                client_emergency_id=client_id,
                emergency_type=etype,
                description=row["message"] or None,
                people_count=max(1, int(row["number_of_people"] or 1)),
                injured=str(row["injured"] or "").strip().lower() == "yes",
                sender_display_name=row["name"] or None,
                location=LocationIn(latitude=float(lat), longitude=float(lon))
                if _valid_coords(lat, lon)
                else None,
            )
            emergency = await es._create(  # noqa: SLF001 -- deliberate system import path
                session, data, None, priority, settings, client_id,
                es.fingerprint(data, client_id), via=ChangeVia.SYSTEM,
                source=EmergencySource.LEGACY_API, actor_label="legacy-import",
            )
            emergency.status_reason = (
                f"Imported from rescue_requests.db row {row['id']}; the old server "
                "stored no timestamps, so occurred_at is the import time."
            )
            await session.commit()
            imported += 1
    await engine.dispose()
    print(f"Imported {imported}, already present {skipped}, total rows {len(rows)}.")


if __name__ == "__main__":
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "rescue_requests.db"
    asyncio.run(main(target))
