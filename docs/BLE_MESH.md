# Bluetooth Multi-Hop Mesh: Architecture and Physical Test Plan

This covers the BLE emergency path between affected Android phones and the
Windows rescue laptop. It includes multi-hop relaying, the reverse ACK path,
store-and-forward, and cloud sync from the laptop.

> **Verification status, stated honestly.** Everything below is implemented.
> These parts are verified on this computer:
>
> - static analysis passes;
> - 118 Flutter tests pass. They include 30 multi-hop **logic** tests that run
>   real `MeshNode` instances (1 to 5 phones plus a laptop) over a *simulated*
>   radio, and channel tests of the Android peripheral transport against a
>   *mocked* native side;
> - the Android APK and the Windows app build;
> - the laptop's cloud sync works against the real FastAPI backend.
>
> The physical Bluetooth tests at the end (A–H) still have to be run on the
> two phones and the laptop. **Physical BLE behaviour is not verified until
> they pass.**

## 1. Topology

```
LOCAL EMERGENCY PATH (no internet needed)          CLOUD SYNC PATH (when online)

 📱 Phone A ──BLE──▶ 📱 Phone B ──BLE──▶ 💻 Laptop ──HTTPS──▶ ☁ FastAPI ──▶ PostgreSQL
 (origin)   ◀──ACK── (relay)    ◀──ACK── (rescue)
            ◀─STATUS─           ◀─STATUS─
```

- **Every Android phone is BOTH roles at the same time.** It is a
  peripheral (native Kotlin `MeshGattServer.kt`: advertises and accepts
  connections) **and** a central (`flutter_blue_plus`: scans and connects).
  No phone is permanently "server" or "client". Data flows both ways over
  every link, whichever side opened it.
- **Up to 4 phones per mesh.** A phone links with at most 3 other phones;
  a 5th phone is refused with "Mesh full". Rescue laptops never count
  toward the limit.
- **One link per pair of phones.** The phone with the lower advertisement
  tag connects; the other connects itself only if no link exists after
  20 s. This halves the radio connections the phones need.
- **The Windows laptop** is a central only (`flutter_ble_central`, WinRT).
  It connects to every phone in range and is the destination.
- **Any topology the radios allow** works, for example:
  - a chain: P1 ↔ P2 ↔ P3 ↔ P4 ↔ Laptop
  - a square: P1 ↔ P2, P1 ↔ P3, P2 ↔ P4, P3 ↔ P4, P4 ↔ Laptop

  No device needs to reach every other device directly.

| Setting | What the phone does |
|---|---|
| Relay forwarding ON (default) | Carries other phones' SOS toward the Rescue Team and their ACK and STATUS back. |
| Relay forwarding OFF | Still advertises, scans and connects; sends its own SOS and receives its own ACK; does not carry other phones' packets. |

**No internet is involved anywhere on this path.** It uses no HTTP,
WebSocket or cloud, and works with Wi-Fi and mobile data off. A logic test
fails if the mesh path opens any HTTP client.

## 2. Advertise → Scan → Connect → GATT

**Advertise.** The main packet holds flags plus the 128-bit service UUID
`bf27730d-860a-4e09-889c-2d8b6a9e0fe7`, which is 21 of the 31 bytes. There is
no device name, because that caused `ADVERTISE_FAILED_DATA_TOO_LARGE` on the
OPPO. The **scan response** carries manufacturer data under company id `0xFFFF`:

| Bytes | Content |
|---|---|
| 1 | protocol version |
| 1 | flags (relay-capable) |
| 4 | tag: the first 4 bytes of SHA-256(device id) |

Scanners use the tag to avoid opening a second link to a phone they are
already linked with.

**Scan.** Scanners filter by the service UUID and ignore everything else. They
rate-limit duplicate sightings to one every 2 s, and restart the scan after
Bluetooth goes off and on.

**Connect.** Every link has its own state machine:

```
DISCOVERED → CONNECTING → CONNECTED → SERVICE_DISCOVERY → READY
                                   ↘ ERROR / DISCONNECTING → DISCONNECTED
```

A link becomes **READY** only when all of these hold:

- the service and the DATA notify and DATA write characteristics were found
  with the right properties;
- the notification subscription (CCCD) was written;
- on the phone's side, the central actually subscribed to DATA.

A device that is only discovered is never shown as connected. The HELLO
exchange then gives the peer's app-level **device id**, its **role**
(`affected`, `relay` or `rescue`) and its **name**.

**GATT layout.** One service, no duplicates:

| Characteristic | UUID | Properties | Carries |
|---|---|---|---|
| DATA notify | `6e400003-…` | notify, read | SOS, HELLO, MESSAGE (peripheral → central) |
| DATA write | `6e400002-…` | write, write without response | SOS (relay push), HELLO (central → peripheral) |
| ACK | `bf277310-…` | write, notify | ACK and STATUS, both directions |
| CONTROL | `bf277311-…` | read, notify | this node's status JSON (role, relay, version, queue) |

A peer without the ACK characteristic (an older build) gets ACKs on the DATA
characteristics instead.

**Framing.** Each frame is `[0xB1][message id][index][count] + payload`. Frames
are sized to each link's negotiated MTU (MTU − 3), or 20 bytes if no MTU was
exchanged. They are reassembled separately for each link and each channel.

## 3. Packet (protocol v3)

`SosPacket.toTransportJson()` sends these fields:

| Field | Meaning |
|---|---|
| `id` | packetId; the dedup and ACK key everywhere |
| `mid` | messageId |
| `senderId` | origin device id |
| `deviceName` | origin device name |
| `timestamp` | when the SOS was created |
| `latitude`, `longitude` | the origin's real fix |
| `acc` | GPS accuracy |
| `fixAt` | when the fix was taken |
| `message`, `emergencyType`, `numberOfPeople`, `injured`, `priority` | the SOS content |
| `ttl`, `maxHops`, `hopCount` | hop control |
| `path` | every relay id, oldest first |
| `relayedBy`, `relayedByName` | the current relay (currentRelayDeviceId) |
| `dst` | destination; RESCUE_LAPTOP by default |
| `ra` | requires ACK; true by default |
| `protocolVersion` | wire version |
| `mac` | authentication tag, see below |

**Integrity.** `mac` is an HMAC-SHA256 tag, truncated to 128 bits. It covers
every field the origin owns: id, origin, timestamp, GPS, type, people,
injured, message and the hop limit. Relays change only the hop fields (hops,
path, ttl and current relay), which are not covered.

**Never changed by a relay:** origin id, name, message and **GPS**. The
laptop always sees the origin's coordinates.

## 4. ACK levels and delivery states

| Message | Sent by | Meaning |
|---|---|---|
| Hop ACK (`k: HOP`, `fwd: true` or `false`) | relay | "I have it" (custody). `fwd: false` means "I cannot forward it" (hop limit). |
| Rescue ACK (`k: RESCUE`, signed) | laptop, after it has **stored** the SOS | "The Rescue Team has it". Relays forward it hop by hop back to the origin. |
| STATUS (signed) | laptop workflow | ASSIGNED, IN_PROGRESS or RESCUED, routed back the same way. |

States on the origin phone only move forward:

```
CREATED → QUEUED → SENT_TO_RELAY → RELAYED → RECEIVED_BY_RESCUE → ACKNOWLEDGED
                                                        (FAILED only if not confirmed within 48 h)
```

- `RELAYED` (a hop ACK) is shown as "received by a relay phone". It is **not**
  the Rescue Team's confirmation.
- A rescue ACK that is missing, unsigned or forged never produces
  `RECEIVED_BY_RESCUE`.

## 5. Routing, dedup, hop control, store-and-forward

**Next hop.** The next hop is a directly linked rescue laptop if there is
one; otherwise every relay-mode phone. These are never chosen:

- the origin itself;
- any relay already on the path;
- the device the packet came from;
- relays that already took custody.

**Reverse path.** Each relay remembers which peers the packet came from, by
**device id** and not by BLE address. It forwards the ACK and STATUS there,
and retries until they are delivered, including after a reconnect under a new
address.

**Dedup.** Packet ids are kept for 48 h and survive a restart. A duplicate is
hop-ACKed again (the sender is retrying) and is **never forwarded twice**.

**Hop limit.** A relay does not forward when `hopCount ≥ maxHops` or
`ttl ≤ 0`. The default limit is 5 and the maximum is 16.

**Store-and-forward.** These stores are atomic JSON documents in the app
support directory, so a restart loses nothing:

| Store | Contents |
|---|---|
| Origin outbox | the phone's own SOS and their delivery state |
| Relay custody store | packets held for forwarding, plus pending reverse messages |
| Laptop inbox | every SOS received, with ACK and STATUS delivery state |
| Audit chain | the tamper-evident log |

**Retries:**

- The origin retries each target after 8 s, then 16 s, then 32 s, then every 60 s.
- A next hop that already took custody is re-sent the SOS every 90 s until the
  rescue ACK arrives. This recovers lost reverse ACKs.
- A newly READY link gets all pending packets immediately.

**Validation.** These packets are rejected:

- missing id, origin or timestamp;
- a timestamp more than 2 h in the future or more than 48 h old;
- out-of-range or incomplete GPS;
- a hop count above the limit;
- a ttl or path that is too long;
- a message longer than 1000 characters;
- a bad MAC;
- an unknown message type.

## 6. Cloud sync (laptop only)

- Every SOS the laptop stores is queued in `CloudSyncService`, and so is every
  status change.
- When the laptop is online, the service logs in with the console account
  (JWT, kept in memory only). It posts to `/api/v1/sync/emergencies` and
  `/api/v1/sync/status`.
- Retries are idempotent: the cloud answers `duplicate` and never creates a
  second record.
- A phone that has internet may also post directly to the legacy endpoint
  with the same packet id. The server merges that record with the laptop's.
- Without internet, the BLE path is unaffected and the queue waits on disk.

## 7. Logs (Network Log screen)

Tags are `[BLE]`, `[RELAY]`, `[RESCUE]`, `[SOS]`, `[SYNC]` and `[STORE]`. The
logged steps include:

- Advertising started, Scan started, Device discovered, Connecting, Connected,
  GATT services discovered, Communication ready;
- Packet received, Packet validated, Duplicate detected, Packet queued,
  Forwarding packet, Forward successful;
- SOS received, ACK generated, ACK forwarded;
- Upload queued, Upload successful.

Logs never contain message text, coordinates, passwords or tokens. Phones
open the log from **Network Log** in "More tools". The laptop opens it from
the network icon in the top bar.

## 8. Physical test plan (two to four Android phones and the Windows laptop)

For 3 or 4 phones, repeat **C** and **D** with the phones placed in a
chain (P1 near P2 only, P2 near P3, and so on, with only the last phone
near the laptop). The laptop's case must show the **first** phone as the
original sender, with the full relay path. The ACK must come back to P1.

**Prepare:**

1. Install the same build on both phones (`flutter build apk --debug`, then
   `adb install -r build\app\outputs\flutter-apk\app-debug.apk`).
2. Allow **Nearby devices** (and Location, for GPS).
3. Keep both phone screens on.
4. On the laptop, run the Windows app and log in as the Rescue Team.
5. Use the **Network Log** screens to check each step.

| Test | Setup | Expected (and where to look) |
|---|---|---|
| **A** Phone 1 ↔ Phone 2 | Both phones open the Affected screen, with relay forwarding ON (the default). On the laptop, turn **Auto-connect off**, or press **Disconnect** on Phone 1's tile. | One phone's log shows Scan started, Device discovered, Connecting, Connected, GATT services discovered, Communication ready, then Peer identified. Both **Mesh Network** cards show the other phone as a Relay phone, linked in one direction only (one link per pair). |
| **B** Phone 2 ↔ Laptop | As A; the laptop is connected to Phone 2. | Laptop tile for Phone 2 shows LINK: READY and RELAY PHONE. Phone 2's card shows CONNECTED -- READY TO SEND SOS. |
| **C** Phone 1 → Phone 2 → Laptop | Phone 1 sends an SOS. | Phone 1 goes SOS SENT → RECEIVED BY A RELAY PHONE → RECEIVED BY THE RESCUE TEAM. The laptop case says "Original sender: Phone 1, Relayed through: Phone 2 (1 hop)" and shows **Phone 1's** coordinates. Phone 2's log shows the relay lines. |
| **D** Laptop → Phone 2 → Phone 1 | On the laptop, press ASSIGN RESCUE on that case. | Phone 1 shows RESCUE TEAM ACKNOWLEDGED and "Rescue Team update: ASSIGNED". Phone 2's log shows "STATUS ASSIGNED forwarded upstream". |
| **E** Disconnect / reconnect | During C: turn Bluetooth off on Phone 2 for 20 s, then on. Separately, walk Phone 1 out of range and back. | Links go DISCONNECTED, then reconnect by themselves. Queued packets and ACKs are delivered after the reconnect, and Phone 1 still ends at RECEIVED BY THE RESCUE TEAM. |
| **F** Duplicate | Put both phones in range of the laptop **and** each other (Auto-connect on), then send from Phone 1. | Exactly **one** case on the laptop. "Duplicate SOS ... re-sending ACK" or "Duplicate detected" appears in the logs. |
| **G** Internet unavailable | Disconnect the laptop from the network, then run C. | BLE works exactly as before. The Cloud sync tile shows Offline (queued) with 1 or more pending. |
| **H** Cloud reconnect | Reconnect the network with the backend running. The cloud account must have the same Rescue ID and password as the console login. | The Cloud sync tile shows Up to date, and the SOS appears in the backend (`/docs` → `GET /api/v1/emergencies`) with `source: BLE_RELAY` and `hop_count: 1`. Assigned statuses sync too. |

Record any failure as it happens: copy the Network Log (copy icon) from each
device.

## 9. Known limits, to check on the devices

- **Background operation.** Android may still pause BLE when the app is
  backgrounded. The connected-device foreground service is meant to prevent
  that, but OEM power managers (ColorOS, MIUI) can override it. Keep screens
  on for the demo.
- **Simultaneous peripheral and central roles.** Running both at once, and the
  number of simultaneous links, depend on the phone's Bluetooth chip. Both
  target phones advertise support, but this is unverified until tests A to C
  pass.
- **Windows links.** WinRT keeps several GATT links at once (the console caps
  auto-connects at 8). The real limit depends on the laptop's adapter.
- **Shared key.** The MAC uses one key shared by every build (set it with
  `--dart-define=MESH_NETWORK_KEY=…`; otherwise a labelled demo key is used).
  It blocks foreign or modified packets, but anyone who extracts the key can
  forge messages. Per-device signatures would be the upgrade.
- **Cloud credentials.** The cloud account must exist with the same Rescue ID
  and password as the console's local login. Otherwise the Cloud sync tile
  shows Login failed, and BLE is unaffected.
