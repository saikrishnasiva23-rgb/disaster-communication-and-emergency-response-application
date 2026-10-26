# Flutter ↔ Cloud Backend Integration Contract

This is the contract between the Flutter app (Android Affected Person phones and
the Windows Rescue Team console) and the cloud backend. The interactive
reference is `/docs` (Swagger UI) or `/redoc` on a running server, and the
machine-readable schema is `/openapi.json`.

> **BLE never depends on the cloud.** SOS delivery, the BLE ACK, relaying and
> the rescue console's live view all work with no internet connection. The
> cloud is an extra layer. When the cloud is reachable it stores emergencies,
> coordinates teams, and syncs data that was recorded offline. If a cloud call
> fails, the app must carry on with BLE and retry the upload later.

## 1. Base URL, versioning, auth

| Item | Value |
|---|---|
| Base URL | `https://<your-host>` (dev: `http://<laptop-ip>:8000`) |
| API prefix | `/api/v1` |
| Auth | `Authorization: Bearer <access_token>` |
| Content type | `application/json; charset=utf-8` |
| Timestamps | ISO-8601. Send UTC with `Z` or an offset. A naive time is treated as UTC. |

The token comes from `POST /api/v1/auth/login` with `{"username": "...", "password": "..."}`
(`username` may also be an email address). It expires after
`ACCESS_TOKEN_EXPIRE_MINUTES` (default 60). When the server returns 401 with
`TOKEN_EXPIRED`, log in again. Never store the password in plain text on the
device, and never send it over BLE.

Affected Persons can register themselves with `POST /api/v1/auth/register`.
Rescue Team and Admin accounts are created by an admin with `POST /api/v1/users`.

## 2. Response envelope

Success:

```json
{"success": true, "data": {...}, "message": "Emergency received.", "meta": null}
```

List endpoints put pagination in `meta`: `{"total", "page", "page_size", "has_next"}`.

Error:

```json
{"success": false,
 "error": {"code": "INVALID_STATUS_TRANSITION",
           "message": "An emergency cannot move from RESOLVED to ASSIGNED.",
           "details": {"current_status": "RESOLVED", "allowed": []},
           "request_id": "3f2c..."}}
```

Branch on `error.code`, not on `message`. The main codes are:

| HTTP | Codes |
|---|---|
| 401 | `NOT_AUTHENTICATED`, `INVALID_TOKEN`, `TOKEN_EXPIRED`, `INVALID_CREDENTIALS` |
| 403 | `FORBIDDEN`, `DEVICE_OWNED_BY_ANOTHER_USER` |
| 404 | `NOT_FOUND`, `EMERGENCY_NOT_FOUND`, `TEAM_NOT_FOUND`, `USER_NOT_FOUND`, `DEVICE_NOT_FOUND` |
| 409 | `IDEMPOTENCY_CONFLICT`, `INVALID_STATUS_TRANSITION`, `EMERGENCY_CLOSED`, `TEAM_UNAVAILABLE`, `NOT_ASSIGNED`, `USERNAME_TAKEN`, `EMAIL_TAKEN`, `TEAM_NAME_TAKEN` |
| 422 | `VALIDATION_ERROR` (with `details[].field`), `INVALID_TIMESTAMP`, `BATCH_TOO_LARGE`, `INVALID_CURSOR`, `IDEMPOTENCY_KEY_MISMATCH`, `USE_WORKFLOW_ENDPOINT` |
| 429 | `RATE_LIMITED` (with a `Retry-After` header) |
| 503 | `DATABASE_UNAVAILABLE`. Retry later; keep the data queued on the device. |

Every response carries an `X-Request-ID` header. Quote it when you report a
problem.

## 3. Mapping `SosPacket` to `POST /api/v1/emergencies`

| SosPacket (Dart) | Request field | Notes |
|---|---|---|
| `id` | `client_emergency_id` | **Required for retries.** This is the idempotency key. Allowed: `A-Z a-z 0-9 _ . : -`, max 64. |
| `emergencyType` | `emergency_type` | Codes or the app's labels are accepted: `"Medical Emergency"`→`MEDICAL`, `"Fire Emergency"`→`FIRE`, `"Flood Emergency"`→`FLOOD`, `"Trapped Person"`→`TRAPPED_PERSON`, `"Injury"`→`MEDICAL`, `"General Emergency"`→`OTHER`. Full list: `GET /api/v1/emergencies/types`. |
| `message` | `description` | |
| `numberOfPeople` | `people_count` | 1–10000 |
| `injured` | `injured` | boolean |
| — | `trapped` | set `true` for Trapped Person |
| `timestamp` | `occurred_at` | UTC. More than `MAX_CLOCK_SKEW_MINUTES` in the future → 422. |
| `latitude`, `longitude` | `location: {latitude, longitude, accuracy_m?, altitude_m?, recorded_at?}` | **Omit `location` when there was no GPS fix.** Never send 0,0 as a placeholder. The server never invents coordinates. |
| `senderId` | `origin_device_id` | the stable per-install id |
| `senderDisplayName` | `sender_display_name` | e.g. "OPPO A5 Pro 5G" |
| `relayedBy`, `relayedByName` | `relayed_by_device_id`, `relayed_by_name` | |
| `hopCount` | `hop_count` | 0 = direct |
| `priority` | `client_priority` | kept for reference only; the server computes its own priority |
| (console) | `source` | `BLE` or `BLE_RELAY` when the rescue console uploads what it received. The server infers it if omitted. |
| (console) | `local_ble_acknowledged`, `local_ble_acknowledged_at` | tells the server whether the console's BLE ACK reached the phone. Informational only. |

Example (the rescue console uploading an SOS it received over BLE):

```json
POST /api/v1/emergencies
{
  "client_emergency_id": "3f9a2b-1727701234567890",
  "emergency_type": "Trapped Person",
  "description": "Two people trapped on the 2nd floor",
  "people_count": 2, "injured": true, "trapped": true,
  "occurred_at": "2026-09-30T10:32:05Z",
  "location": {"latitude": 11.941612, "longitude": 79.808301, "accuracy_m": 12.5},
  "origin_device_id": "affected-3f9a2b1c",
  "sender_display_name": "OPPO A5 Pro 5G",
  "source": "BLE",
  "local_ble_acknowledged": true
}
```

The server replies **201** for a new emergency. It replies **200** with the
*existing* record when that `client_emergency_id` was already received, so a
retry is always safe. If the same id arrives with different content, the
server replies **409 `IDEMPOTENCY_CONFLICT`** and keeps the original. The
`Idempotency-Key` header is accepted as an alternative to
`client_emergency_id`. If you send both, they must match.

In the response:

- `priority`, `priority_score`, `priority_reason` and `priority_model` are computed by the server.
- `priority_score` is an urgency score from 0 to 1, on one scale for every classifier: LOW <0.25, MEDIUM 0.25–0.5, HIGH 0.5–0.75, CRITICAL ≥0.75.
- `priority_model` names the classifier that produced the priority: `random_forest_demo_v1`, `rule_based_v1`, or both joined with `+`.
- `status` starts at `RECEIVED`.
- `location_available` is `false` when the emergency has no GPS fix.

### The two acknowledgements are separate

| | BLE ACK | Cloud ACK |
|---|---|---|
| Transport | BLE GATT, console → phone | HTTPS, console → server |
| Field | `local_ble_acknowledged` (reported by the console) | `cloud_acknowledged_at` |
| Set by | the console's BLE stack | `POST /emergencies/{id}/acknowledge` or assigning a team |
| Needs internet | no | yes |

The phone's "Help is coming" state must come only from the **BLE ACK**. The
cloud ACK must never replace it.

## 4. Status lifecycle

```
CREATED → RECEIVED → ACKNOWLEDGED → ASSIGNED → IN_PROGRESS → RESOLVED
                 └──────────────┴───────────┴──────────────┴→ CANCELLED
RECEIVED/ACKNOWLEDGED → REJECTED
ASSIGNED → ACKNOWLEDGED (unassign) · IN_PROGRESS → ASSIGNED (handover)
RESOLVED, CANCELLED and REJECTED are final.
```

| Action | Endpoint | Who |
|---|---|---|
| Acknowledge | `POST /emergencies/{id}/acknowledge` | Rescue Team, Admin |
| Assign a team | `POST /emergencies/{id}/assign` `{"team_id"}` | Rescue Team, Admin (a `RECEIVED` emergency is acknowledged automatically) |
| Unassign | `POST /emergencies/{id}/unassign` | Rescue Team, Admin |
| Accept | `POST /emergencies/{id}/accept` | a member of the assigned team, or an Admin → `IN_PROGRESS` |
| Resolve | `POST /emergencies/{id}/resolve` `{"outcome", "resolution_notes"}` | a member of the assigned team, or an Admin |
| Cancel | `PATCH /emergencies/{id}` `{"status": "CANCELLED"}` | the reporter, Rescue Team, Admin |
| Reject | `PATCH /emergencies/{id}` `{"status": "REJECTED"}` | Rescue Team, Admin |
| GPS update | `POST /emergencies/{id}/locations` | the reporter, Rescue Team, Admin |

`outcome` is one of `RESCUED`, `TREATED_ON_SITE`, `REFERRED`,
`NO_ACTION_NEEDED`, `UNREACHABLE` or `OTHER`. Any transition outside this
table returns **409 `INVALID_STATUS_TRANSITION`**, and the emergency is left
unchanged.

## 5. Offline sync

**Upload emergencies:** `POST /api/v1/sync/emergencies`

```json
{"device_id": "rescue-console-01", "items": [ <EmergencyCreate with client_emergency_id>, ... ]}
```

- Each item is processed and committed on its own, and each gets its own `result`:
  - `created`: new.
  - `duplicate`: already on the server. Mark it synced locally.
  - `conflict`: same id, different content. The server copy is kept and flagged `sync_state: CONFLICT`.
  - `invalid`: see `error`.
- A request may hold at most `SYNC_BATCH_LIMIT` items (default 100).
- If the request fails, retry the whole batch. Items that already went through come back as `duplicate`.

**Upload status changes made offline:** `POST /api/v1/sync/status`

```json
{"device_id": "rescue-console-01",
 "items": [{"update_id": "chg-0001", "client_emergency_id": "3f9a2b-...", "status": "ACKNOWLEDGED",
            "changed_at": "2026-09-30T10:35:00Z"},
           {"update_id": "chg-0002", "client_emergency_id": "3f9a2b-...", "status": "ASSIGNED",
            "team_id": "<uuid>", "changed_at": "2026-09-30T10:36:00Z"}]}
```

- The server replays the items oldest first, by `changed_at`.
- Each `update_id` is applied at most once. A retry returns `duplicate`.
- An update older than the server's latest change to that emergency returns `conflict` with `STALE_UPDATE`. It is **not** applied. Newer work is never overwritten by a device that was offline.
- `ASSIGNED` needs `team_id`. `RESOLVED` needs `outcome`.
- An Affected Person can only sync `CANCELLED`.

**Download changes:** `GET /api/v1/sync/emergencies?cursor=<c>&limit=100`

- Returns emergencies ordered by last change, plus `next_cursor` and `has_more`.
- Save `next_cursor` and pass it back next time to get only newer changes.
- When `next_cursor` is `null`, nothing new came back. Keep your previous cursor.
- An Affected Person only receives their own emergencies.

## 6. Devices

`POST /api/v1/devices` registers a device by its stable client id:

```json
{"client_device_id": "affected-3f9a2b1c", "device_type": "AFFECTED_PHONE", "platform": "ANDROID",
 "device_name": "OPPO A5 Pro 5G", "app_version": "1.0.0"}
```

It returns 201 the first time and 200 after that. `device_type` is one of
`AFFECTED_PHONE`, `RESCUE_CONSOLE`, `RELAY_NODE` or `OTHER`. `platform` is one
of `ANDROID`, `WINDOWS`, `IOS`, `WEB` or `OTHER`.

## 7. Compatibility with the current Flutter build

The current app calls the old Flask endpoints (`lib/config/backend_config.dart`):

- `POST /api/rescue-request` with `{name, emergencyType, numberOfPeople, injured: "Yes"|"No", latitude, longitude, message}`
- `GET /api/rescue-requests`

The FastAPI server serves both **with the same request and response shapes**,
so the app works unchanged if `BACKEND_BASE_URL` points at port 8000:

```bash
flutter run --dart-define=BACKEND_BASE_URL=http://<laptop-ip>:8000
```

Differences from the old server:

- Requests without GPS (`latitude`/`longitude` null) are now **accepted and stored without a position**. The old server rejected them.
- `requestId` is now a UUID string, not an integer.
- `confidence` and `priority_score` are still 0–100, but they now carry the server's **urgency score** (`priority_score × 100`), which uses the same scale for every classifier. The old server sent the RandomForest's share of agreeing trees.

These endpoints are **unauthenticated**, like the old server. They are enabled
by default only in `development`, and controlled by `LEGACY_API_ENABLED`. Plan
to move the app to `/api/v1`. That is a Flutter change and is **not** part of
this backend work.

**Known client-side gap (Flutter, not changed here):**
`RescueCase.fromBackendJson` turns a `null` latitude/longitude into `0.0`, so a
request without GPS would show up at 0°,0° in the rescue list. The backend
sends `null` correctly. The fix belongs in the Flutter model, which needs
nullable coordinates.

## 8. What stays on the device

- Everything BLE: advertising, GATT, framing, HELLO/ACK/STATUS, relay, the heartbeat, and the live view in the rescue command center.
- The demo login `dis_comm`, used by the rescue console UI. The cloud account `dis_comm` from `scripts/seed_demo.py` is a separate *cloud* credential whose password is set by `DEMO_PASSWORD`.
