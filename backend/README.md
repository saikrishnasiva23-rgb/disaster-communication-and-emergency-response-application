# Disaster Communication — Cloud Backend

The FastAPI cloud server for the **AI-Enabled Decentralized Disaster
Communication Network**. It stores emergencies, coordinates rescue teams,
syncs data recorded offline, computes emergency priority, and keeps a
tamper-evident audit log.

> The Android phones and the Windows rescue console talk to each other over
> **BLE with no server involved**. This backend is an extra layer on top. When
> it is unreachable, BLE SOS, the BLE ACK and relaying keep working.

- API reference: `/docs` (Swagger UI), `/redoc`, `/openapi.json`
- Flutter integration contract: [docs/API_CONTRACT.md](docs/API_CONTRACT.md)

## Architecture

```
 Android phones ──BLE──▶ Windows rescue console        (no internet needed)
       │                        │
       └─────── HTTPS (optional, when online) ────────▶  FastAPI  ──▶ PostgreSQL
                                                       (this repo)   (SQLite in dev/test)
```

The server is one stateless FastAPI process. It holds no session state, so
more instances can run behind a load balancer. It is layered like this:

| Layer | Folder | Contents |
|---|---|---|
| HTTP | `app/api/` | Routers, dependencies (auth, RBAC, pagination), the legacy Flask-compatible routes |
| Schemas | `app/schemas/` | Pydantic request and response models, and the response envelope |
| Services | `app/services/` | Business logic: emergencies, assignments, sync, audit chain, priority, users, devices, teams |
| Domain | `app/domain/` | Enums, the status lifecycle table, emergency types |
| Database | `app/db/` | SQLAlchemy 2 async models, engine and session, Alembic migrations |
| Core | `app/core/` | Settings (environment variables), security (Argon2id, JWT), errors, logging, rate limiting |

```
backend/
├── app/
│   ├── main.py                 # create_app(): lifespan, middleware, routers
│   ├── api/  deps.py health.py legacy.py  v1/{auth,users,devices,emergencies,rescue_teams,sync,audit,priority}.py
│   ├── core/ config.py security.py errors.py logging.py rate_limit.py
│   ├── db/   database.py types.py models/*.py migrations/{env.py,versions/0001_initial_schema.py}
│   ├── domain/ enums.py lifecycle.py emergency_types.py
│   ├── schemas/ *.py
│   ├── services/ *.py
│   └── utils/geo.py
├── ai/priority_model.py        # the existing demo RandomForest (reused, unchanged)
├── scripts/seed_demo.py  scripts/import_legacy_sqlite.py
├── tests/                      # pytest suite
├── docs/API_CONTRACT.md
├── alembic.ini  requirements.txt  requirements-dev.txt  .env.example
├── Dockerfile  docker-entrypoint.sh  docker-compose.yml
└── legacy_flask_app.py         # the old Flask server, kept for reference (was app.py)
```

## Database schema

There are 12 tables. Primary keys are UUIDs, except `audit_logs.sequence` and
`audit_chain_head.id`. Foreign keys have explicit `ON DELETE` rules, and
constraint names follow a fixed naming convention.

| Table | Purpose | Key constraints |
|---|---|---|
| `roles` | `AFFECTED_PERSON`, `RESCUE_TEAM`, `ADMIN` | PK `code` |
| `users` | accounts, Argon2id password hash | unique `username`, unique `email`, FK `role → roles` |
| `devices` | phones and consoles, by stable client id | unique `client_device_id`, FK user |
| `rescue_teams` | name, `AVAILABLE`/`BUSY`/`OFFLINE`, capabilities, base and current location | unique `name` |
| `rescue_team_members` | user ↔ team, `LEADER`/`MEMBER` | unique `user_id` (one team per user) |
| `emergencies` | the emergency, its priority, status, source, sync state, assigned team, cloud ACK, BLE ACK report, resolution | unique `client_emergency_id` (idempotency); indexes on status, priority, type, time, `(lat, lon)`, `(updated_at, id)` |
| `emergency_locations` | GPS history: lat, lon, accuracy, altitude, recorded/received time, device | FK emergency (cascade) |
| `emergency_status_history` | every transition, with who, when (server and client time), why, and via which path (`API`/`SYNC`/`SYSTEM`) | unique `client_update_id` (offline idempotency) |
| `emergency_assignments` | assignment history: `ASSIGNED`/`ACCEPTED`/`COMPLETED`/`CANCELLED` | FK team (restrict) |
| `audit_logs` | the hash chain | unique `previous_hash`, unique `current_hash`, unique `event_id` |
| `audit_chain_head` | a single row holding the chain tip, locked on every append | |
| `sync_records` | one row per sync request, with counts | |

## Endpoints

All endpoints are under `/api/v1` except the health check and the legacy routes.

| Area | Endpoints |
|---|---|
| Health | `GET /health`, `GET /api/v1/health` |
| Auth | `POST /auth/register`, `POST /auth/login`, `GET /auth/me` |
| Users (admin) | `GET /users`, `POST /users`, `GET /users/{id}`, `PATCH /users/{id}` |
| Devices | `POST /devices`, `GET /devices`, `GET /devices/{id}`, `PATCH /devices/{id}` |
| Emergencies | `GET /emergencies/types`, `POST /emergencies`, `GET /emergencies` (filters: status, priority, type, team_id, active_only, since/until, region box, origin_device_id; pagination), `GET /emergencies/nearby`, `GET /emergencies/{id}`, `PATCH /emergencies/{id}`, `POST /emergencies/{id}/acknowledge`, `/assign`, `/unassign`, `/accept`, `/resolve`, `POST` and `GET /emergencies/{id}/locations`, `GET /emergencies/{id}/history` |
| Rescue teams | `GET` and `POST /rescue-teams`, `GET` and `PATCH /rescue-teams/{id}`, `POST /rescue-teams/{id}/members`, `DELETE /rescue-teams/{id}/members/{user_id}`, `GET /rescue-teams/{id}/assignments` |
| Offline sync | `POST /sync/emergencies`, `GET /sync/emergencies`, `POST /sync/status` |
| Audit | `GET /audit` (admin), `GET /audit/verify` (Rescue Team, Admin) |
| Priority | `POST /priority/classify`, `GET /priority/model` |
| Legacy | `POST /api/rescue-request`, `GET /api/rescue-requests` (old Flask shapes; dev only by default) |

## Configuration

All configuration comes from environment variables or a `.env` file. See
[.env.example](.env.example).

| Variable | Default | Notes |
|---|---|---|
| `ENVIRONMENT` | `development` | `development`, `testing` or `production` |
| `DATABASE_URL` | `sqlite:///./disaster_dev.db` | `postgres://` and `postgresql://` URLs are converted to asyncpg; `sslmode` is mapped to `ssl` |
| `JWT_SECRET` | *(random per process in dev/test)* | **Required, 32+ characters, in production** |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | 60 | |
| `CORS_ORIGINS` | *(none)* | comma-separated browser origins |
| `LEGACY_API_ENABLED` | on in dev only | unauthenticated Flask-compatible routes |
| `AUTO_CREATE_TABLES` | false | only for quick local runs; normally use Alembic |
| `INITIAL_ADMIN_USERNAME` / `_EMAIL` / `_PASSWORD` | — | creates the first admin once |
| `RATE_LIMIT_AUTH_ATTEMPTS` / `_WINDOW_SECONDS` | 10 / 300 | per IP (and username) |
| `MAX_CLOCK_SKEW_MINUTES` | 120 | rejects future client timestamps |
| `SYNC_BATCH_LIMIT` | 100 | |
| `EXTRA_EMERGENCY_TYPES` | — | e.g. `TSUNAMI,GAS_LEAK` |
| `LOG_LEVEL`, `LOG_JSON` | INFO, true | |
| `HOST`, `PORT` | 0.0.0.0, 8000 | |

Production refuses to start without a strong `JWT_SECRET` or with a SQLite URL.

## Run locally (Windows, SQLite)

```bash
cd backend
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements-dev.txt
copy .env.example .env
.venv\Scripts\python -m alembic upgrade head
.venv\Scripts\python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Then open http://127.0.0.1:8000/docs. To use the server from the phones on
the same Wi-Fi, use `http://<laptop-ip>:8000` and allow port 8000 through
Windows Firewall.

To load **demo data**, which is clearly marked and refused in production:

```bash
set DEMO_PASSWORD=choose-a-demo-password
.venv\Scripts\python scripts\seed_demo.py
```

To import the old Flask database (`rescue_requests.db`). This is idempotent:

```bash
.venv\Scripts\python scripts\import_legacy_sqlite.py
```

## Tests

```bash
.venv\Scripts\python -m pytest
```

The suite covers:

- **Auth:** JWT expiry, tampering and `alg:none`; RBAC; rate limiting; no secrets in logs.
- **Emergencies:** GPS validation, NaN coordinates and no-GPS emergencies; idempotency and conflicts; filters; nearby search; locations.
- **Lifecycle:** every transition, invalid transitions, team status, handover.
- **Sync:** mixed batches, retries, cursor paging, stale-update conflicts.
- **Priority:** the rules, the demo model's scope, the safety floor, fallback.
- **Audit chain:** modified, deleted and truncated entries are detected.
- **Health and errors:** health checks, the error envelope, CORS.
- **Legacy compatibility.**
- **Database:** Alembic upgrade with no model drift, then downgrade; database constraints; production config checks.

Each test gets its own temporary SQLite database.

## Docker

```bash
cd backend
set JWT_SECRET=<48+ random characters>
set POSTGRES_PASSWORD=<url-safe password>
docker compose up --build
```

- `docker-entrypoint.sh` runs `alembic upgrade head`, then starts uvicorn on `0.0.0.0:$PORT`. It shuts down gracefully within 20 s.
- Set `RUN_MIGRATIONS=false` when a separate release step runs the migrations.
- The image runs as a non-root user and has a `HEALTHCHECK` on `/health`.
- `POSTGRES_PASSWORD` is placed inside a URL, so use a URL-safe value (letters, digits, `-` and `_`).

## Cloud deployment

The steps below work on any container host, such as Render, Railway, Fly.io,
Azure Container Apps or Google Cloud Run.

1. Create a managed PostgreSQL database. Copy its connection URL into `DATABASE_URL`. You can paste `postgres://…?sslmode=require` as it is.
2. Set `ENVIRONMENT=production` and `JWT_SECRET` (a random value of 32+ characters). Set `CORS_ORIGINS` only if a browser dashboard will call the API.
3. Deploy the `backend/` folder with its Dockerfile. The platform's `PORT` is honoured.
4. Set `FORWARDED_ALLOW_IPS` to the platform's proxy range, or `*` if only the platform's proxy can reach the container. This lets rate limiting see real client IPs.
5. Keep `LEGACY_API_ENABLED` unset (it stays off in production) until the Flutter app moves to `/api/v1`.
6. Create the first admin with `INITIAL_ADMIN_USERNAME` and `INITIAL_ADMIN_PASSWORD` on the first start. Then remove the password variable.
7. Point the platform's health check at `/health`. It returns 200 when healthy and 503 when the database is down.

## What is real, what is a fallback, what is future work

| Component | Status |
|---|---|
| REST API, validation, envelope, RBAC, JWT, Argon2id | **Implemented and tested** |
| Idempotent emergency intake, GPS history, lifecycle, assignments, teams | **Implemented and tested** |
| Offline sync (upload, status replay with conflict detection, cursor download) | **Implemented and tested** |
| Audit log | **Implemented and tested.** A tamper-evident SHA-256 **hash chain** in the database, not a decentralized blockchain. Someone with full database write access who rewrites the whole chain *and* its head consistently would not be detected. The fix would be to periodically anchor the head hash somewhere external. |
| Priority: `RandomForestDemoClassifier` | **Real but demo-grade.** The project's existing scikit-learn RandomForest, trained at startup on **24 hand-labelled examples** using only people, injured and type, for 4 types. It is not trained on real incident data. |
| Priority: `RuleBasedPriorityClassifier` | **Fallback and safety floor.** Transparent rules over every field. Used for untrained types and whenever the model fails, and it can escalate the model's answer but never lower it. |
| Priority: a model trained on real data | **Future work.** Plug it in behind `PriorityClassifier` (`supports()` and `classify()`). |
| Geo queries | Bounding box plus haversine in Python. **PostGIS is optional future work**, for large volumes. |
| Rate limiting | In-process sliding window, per instance. The effective limit is multiplied by the number of replicas. |
| Legacy Flask-compatible routes | Compatibility layer, unauthenticated, dev-only by default. |

## Known limitations

- **Not verified on this machine:** the Docker image build, `docker compose`, and running against a live PostgreSQL server. Neither Docker nor PostgreSQL is installed here. The migration's PostgreSQL DDL was only rendered offline (`alembic upgrade head --sql`), not executed.
- **SQLite is for development and tests only.** Concurrent writes can fail with "database is locked" (surfaced as 503).
- **Audit appends are serialized** through one locked row. That is fine for this scale, but it is a throughput ceiling.
- **Sync cursors** order by application timestamps. Under heavy concurrency, a change that commits late within the same instant could be missed. Re-pulling from an older cursor is always safe, and a periodic full pull with no cursor re-syncs everything.
- An Affected Person can upload only their own SOS. Relayed SOS packets reach the cloud through the rescue console, which uploads with `source: BLE`/`BLE_RELAY`.
- The Flutter app still calls the legacy routes. Moving it to `/api/v1`, and fixing its null-coordinate parsing, is a separate Flutter task.
- This is **not a production certification**. The tests pass, but there has been no load testing, no penetration test and no live PostgreSQL run. Treat it as production-*ready code* that still needs a staging deployment before real emergencies depend on it.
