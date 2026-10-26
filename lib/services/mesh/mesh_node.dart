import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/sos_packet.dart';
import '../ble_protocol.dart';
import '../local_store.dart';
import '../net_log.dart';
import 'mesh_link.dart';

/// What this device is in the network.
enum MeshRole {
  /// Affected-person phone: originates SOS; forwards others' packets only
  /// while RELAY mode is on.
  affected,

  /// Rescue-team endpoint (Windows laptop): final destination; stores every
  /// SOS, then sends the end-to-end ACK and rescue STATUS back.
  rescue,
}

@immutable
class MeshIdentity {
  const MeshIdentity({required this.deviceId, required this.deviceName});

  /// Stable app-level id (never the BLE address).
  final String deviceId;
  final String deviceName;
}

/// The device at the other end of a link, as it introduced itself (HELLO).
@immutable
class PeerInfo {
  const PeerInfo({
    required this.id,
    required this.role,
    required this.name,
    this.relayEnabled = false,
    this.protocolVersion = 1,
    this.capabilities = const {},
  });

  final String id;

  /// [BleProtocol.roleAffected] / [BleProtocol.roleRelay] / [BleProtocol.roleRescue].
  final String role;
  final String name;
  final bool relayEnabled;
  final int protocolVersion;

  /// Packet types the peer announced in its HELLO (empty = older build).
  final Set<String> capabilities;

  bool get isRescue => role == BleProtocol.roleRescue;

  /// An Android phone (affected or relay), as opposed to a rescue endpoint.
  bool get isPhone => !isRescue;
  bool get isRelay => role == BleProtocol.roleRelay;

  /// Can take custody of an SOS (rescue endpoint or relay-mode phone).
  bool get acceptsSos => isRescue || isRelay;
}

/// UI view of one link.
@immutable
class LinkView {
  const LinkView({
    required this.info,
    this.peer,
    this.readyAt,
    this.blocked = false,
  });

  final LinkInfo info;
  final PeerInfo? peer;
  final DateTime? readyAt;

  /// Operator disconnected it; not auto-reconnected.
  final bool blocked;

  String get linkId => info.linkId;
  LinkState get state => info.state;
  bool get isReady => info.isReady;

  /// Ready AND the peer has introduced itself -- usable for routing.
  bool get isIdentified => info.isReady && peer != null;

  /// This device opened the link (it is the GATT client) or the peer did.
  bool get isOutgoing => info.side == LinkSide.central;

  String get displayName => peer?.name ?? info.name ?? 'Unknown device';
}

enum MeshEventType {
  sosCreated,
  sosQueued,
  sosSent,
  hopAckReceived,
  rescueAckReceived,
  statusReceived,
  relayReceived,
  relayDuplicate,
  relayForwarded,
  relayNotForwarded,
  ackForwarded,
  statusForwarded,
  rescueReceived,
  rescueDuplicate,
  rescueAckSent,
  statusSent,
  packetRejected,
  linkReady,
  linkLost,
  storageError,
}

@immutable
class MeshEvent {
  const MeshEvent(this.type, this.detail, {this.packetId, this.peerName, this.at});

  final MeshEventType type;
  final String detail;
  final String? packetId;
  final String? peerName;
  final DateTime? at;
}

// ---------------------------------------------------------------------------
// Persistent records
// ---------------------------------------------------------------------------

Set<String> _set(Object? raw) =>
    raw is List ? raw.whereType<String>().toSet() : <String>{};

Map<String, int> _intMap(Object? raw) => raw is Map
    ? {
        for (final e in raw.entries)
          if (e.key is String && e.value is int) e.key as String: e.value as int,
      }
    : <String, int>{};

DateTime? _date(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

Map<String, Map<String, dynamic>> _jsonMaps(Object? raw) => raw is Map
    ? {
        for (final e in raw.entries)
          if (e.key is String && e.value is Map<String, dynamic>)
            e.key as String: e.value as Map<String, dynamic>,
      }
    : <String, Map<String, dynamic>>{};

Map<String, Set<String>> _setMap(Object? raw) => raw is Map
    ? {
        for (final e in raw.entries)
          if (e.key is String) e.key as String: _set(e.value),
      }
    : <String, Set<String>>{};

/// Per-target send bookkeeping: attempts and last attempt (ms since epoch).
class SendAttempts {
  SendAttempts([Map<String, int>? count, Map<String, int>? last])
      : count = count ?? {},
        last = last ?? {};

  final Map<String, int> count;
  final Map<String, int> last;

  void record(String key, DateTime now) {
    count[key] = (count[key] ?? 0) + 1;
    last[key] = now.millisecondsSinceEpoch;
  }

  /// 8 s, 16 s, 32 s, then every 60 s (or [fixed]).
  bool due(String key, DateTime now, {Duration? fixed}) {
    final lastMs = last[key];
    if (lastMs == null) return true;
    final n = count[key] ?? 1;
    final wait = fixed ??
        Duration(seconds: math.min(60, 8 * (1 << math.min(n - 1, 3))));
    return now.millisecondsSinceEpoch - lastMs >= wait.inMilliseconds;
  }

  int get total => count.values.fold(0, (a, b) => a + b);

  Map<String, dynamic> toJson() => {'count': count, 'last': last};

  static SendAttempts fromJson(Object? raw) => raw is Map
      ? SendAttempts(_intMap(raw['count']), _intMap(raw['last']))
      : SendAttempts();
}

/// An SOS this device created.
class OutboxEntry {
  OutboxEntry({
    required this.packet,
    required this.createdAt,
    this.status = SosStatus.queued,
    this.nextHopRole,
    this.nextHopName,
    Set<String>? custodyBy,
    Set<String>? cannotForward,
    SendAttempts? attempts,
    this.rescueAck,
    this.rescueStatus,
    this.updatedAt,
    this.detail,
  })  : custodyBy = custodyBy ?? {},
        cannotForward = cannotForward ?? {},
        attempts = attempts ?? SendAttempts();

  final SosPacket packet;
  final DateTime createdAt;
  SosStatus status;

  /// Role/name of the device it was last handed to.
  String? nextHopRole;
  String? nextHopName;

  /// Relays that accepted custody (hop ACK).
  final Set<String> custodyBy;

  /// Relays that have it but cannot forward (hop budget).
  final Set<String> cannotForward;
  final SendAttempts attempts;
  Map<String, dynamic>? rescueAck;

  /// Latest rescue-workflow status routed back (e.g. ASSIGNED).
  String? rescueStatus;
  DateTime? updatedAt;
  String? detail;

  int get attemptCount => attempts.total;

  Map<String, dynamic> toJson() => {
        'packet': packet.toJson(),
        'createdAt': createdAt.toIso8601String(),
        'status': status.name,
        'nextHopRole': nextHopRole,
        'nextHopName': nextHopName,
        'custodyBy': custodyBy.toList(),
        'cannotForward': cannotForward.toList(),
        'attempts': attempts.toJson(),
        'rescueAck': rescueAck,
        'rescueStatus': rescueStatus,
        'updatedAt': updatedAt?.toIso8601String(),
        'detail': detail,
      };

  static OutboxEntry? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    try {
      final packet = SosPacket.fromJson(raw['packet'] as Map<String, dynamic>);
      final status = sosStatusFromString(raw['status'] as String? ?? 'queued');
      packet.status = status;
      return OutboxEntry(
        packet: packet,
        createdAt: _date(raw['createdAt']) ?? DateTime.now(),
        status: status,
        nextHopRole: raw['nextHopRole'] as String?,
        nextHopName: raw['nextHopName'] as String?,
        custodyBy: _set(raw['custodyBy']),
        cannotForward: _set(raw['cannotForward']),
        attempts: SendAttempts.fromJson(raw['attempts']),
        rescueAck: raw['rescueAck'] as Map<String, dynamic>?,
        rescueStatus: raw['rescueStatus'] as String?,
        updatedAt: _date(raw['updatedAt']),
        detail: raw['detail'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A packet this relay phone holds (store-and-forward custody).
class RelayEntry {
  RelayEntry({
    required this.packet,
    required this.receivedAt,
    required this.canForward,
    Set<String>? receivedFrom,
    Set<String>? custodyBy,
    Set<String>? cannotForward,
    SendAttempts? attempts,
    this.rescueAck,
    Map<String, Map<String, dynamic>>? statuses,
    Map<String, Set<String>>? upstreamDelivered,
    this.forwardedCount = 0,
  })  : receivedFrom = receivedFrom ?? {},
        custodyBy = custodyBy ?? {},
        cannotForward = cannotForward ?? {},
        attempts = attempts ?? SendAttempts(),
        statuses = statuses ?? {},
        upstreamDelivered = upstreamDelivered ?? {};

  /// As received (relay fields of the previous hop).
  final SosPacket packet;
  final DateTime receivedAt;

  /// False when the hop budget is spent / this phone already relayed it.
  final bool canForward;

  /// Route keys (peer ids) it came from -- the reverse path for ACKs.
  final Set<String> receivedFrom;
  final Set<String> custodyBy;
  final Set<String> cannotForward;
  final SendAttempts attempts;

  /// The Rescue Team's signed end-to-end ACK, once it came back.
  Map<String, dynamic>? rescueAck;

  /// Signed STATUS messages by status value.
  final Map<String, Map<String, dynamic>> statuses;

  /// Which upstream peers already received each reverse message
  /// ('ack' / 'status:ASSIGNED').
  final Map<String, Set<String>> upstreamDelivered;
  int forwardedCount;

  bool get delivered => rescueAck != null;

  Map<String, dynamic> toJson() => {
        'packet': packet.toJson(),
        'receivedAt': receivedAt.toIso8601String(),
        'canForward': canForward,
        'receivedFrom': receivedFrom.toList(),
        'custodyBy': custodyBy.toList(),
        'cannotForward': cannotForward.toList(),
        'attempts': attempts.toJson(),
        'rescueAck': rescueAck,
        'statuses': statuses,
        'upstreamDelivered': {
          for (final e in upstreamDelivered.entries) e.key: e.value.toList(),
        },
        'forwardedCount': forwardedCount,
      };

  static RelayEntry? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    try {
      return RelayEntry(
        packet: SosPacket.fromJson(raw['packet'] as Map<String, dynamic>),
        receivedAt: _date(raw['receivedAt']) ?? DateTime.now(),
        canForward: raw['canForward'] as bool? ?? false,
        receivedFrom: _set(raw['receivedFrom']),
        custodyBy: _set(raw['custodyBy']),
        cannotForward: _set(raw['cannotForward']),
        attempts: SendAttempts.fromJson(raw['attempts']),
        rescueAck: raw['rescueAck'] as Map<String, dynamic>?,
        statuses: _jsonMaps(raw['statuses']),
        upstreamDelivered: _setMap(raw['upstreamDelivered']),
        forwardedCount: raw['forwardedCount'] as int? ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// An SOS stored at the rescue endpoint.
class InboxEntry {
  InboxEntry({
    required this.packet,
    required this.receivedAt,
    required this.authenticated,
    required this.rescueAck,
    Set<String>? arrivedFrom,
    Set<String>? ackDeliveredTo,
    Map<String, Map<String, dynamic>>? statuses,
    Map<String, Set<String>>? statusDeliveredTo,
    this.firstLinkName,
    this.firstLinkPeerId,
  })  : arrivedFrom = arrivedFrom ?? {},
        ackDeliveredTo = ackDeliveredTo ?? {},
        statuses = statuses ?? {},
        statusDeliveredTo = statusDeliveredTo ?? {};

  final SosPacket packet;
  final DateTime receivedAt;

  /// MAC verified (false = older build without a MAC; still accepted).
  final bool authenticated;
  final Map<String, dynamic> rescueAck;

  /// Route keys of the links it arrived on (origin or relays).
  final Set<String> arrivedFrom;
  final Set<String> ackDeliveredTo;
  final Map<String, Map<String, dynamic>> statuses;
  final Map<String, Set<String>> statusDeliveredTo;

  /// The device on the first link it arrived from (origin or last relay).
  final String? firstLinkName;
  final String? firstLinkPeerId;

  bool get ackDelivered => ackDeliveredTo.isNotEmpty;

  /// Some ACK / STATUS has not reached any next device yet.
  bool get hasPendingReverse =>
      !ackDelivered ||
      statuses.keys.any((s) => (statusDeliveredTo[s] ?? const {}).isEmpty);

  Map<String, dynamic> toJson() => {
        'packet': packet.toJson(),
        'receivedAt': receivedAt.toIso8601String(),
        'authenticated': authenticated,
        'rescueAck': rescueAck,
        'arrivedFrom': arrivedFrom.toList(),
        'ackDeliveredTo': ackDeliveredTo.toList(),
        'statuses': statuses,
        'statusDeliveredTo': {
          for (final e in statusDeliveredTo.entries) e.key: e.value.toList(),
        },
        'firstLinkName': firstLinkName,
        'firstLinkPeerId': firstLinkPeerId,
      };

  static InboxEntry? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    try {
      return InboxEntry(
        packet: SosPacket.fromJson(raw['packet'] as Map<String, dynamic>),
        receivedAt: _date(raw['receivedAt']) ?? DateTime.now(),
        authenticated: raw['authenticated'] as bool? ?? false,
        rescueAck: raw['rescueAck'] as Map<String, dynamic>,
        arrivedFrom: _set(raw['arrivedFrom']),
        ackDeliveredTo: _set(raw['ackDeliveredTo']),
        statuses: _jsonMaps(raw['statuses']),
        statusDeliveredTo: _setMap(raw['statusDeliveredTo']),
        firstLinkName: raw['firstLinkName'] as String?,
        firstLinkPeerId: raw['firstLinkPeerId'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A new (or repeated) SOS delivered to the rescue endpoint.
@immutable
class RescueDelivery {
  const RescueDelivery({
    required this.entry,
    required this.linkId,
    required this.linkName,
    required this.isDuplicate,
    this.linkPeer,
  });

  final InboxEntry entry;
  final String linkId;
  final String linkName;
  final PeerInfo? linkPeer;
  final bool isDuplicate;
}

@immutable
class MeshStats {
  const MeshStats({
    this.outboxPending = 0,
    this.relayHeld = 0,
    this.relayAwaitingNextHop = 0,
    this.forwarded = 0,
    this.duplicates = 0,
    this.rejected = 0,
    this.inbox = 0,
    this.readyLinks = 0,
  });

  final int outboxPending;
  final int relayHeld;
  final int relayAwaitingNextHop;
  final int forwarded;
  final int duplicates;
  final int rejected;
  final int inbox;
  final int readyLinks;
}

// ---------------------------------------------------------------------------
// The node
// ---------------------------------------------------------------------------

class _Link {
  _Link(this.transport, this.info);

  final MeshTransport transport;
  LinkInfo info;
  PeerInfo? peer;
  DateTime? readyAt;
  bool helloSent = false;
  final BleFrameReassembler reassembler = BleFrameReassembler();
  final FrameMessageIds frameIds = FrameMessageIds();
  Future<void> chain = Future<void>.value();
}

/// The device's whole BLE messaging logic: one instance per app.
///
/// Roles on the wire:
///   * every node exchanges HELLO when a link becomes READY;
///   * an origin keeps each SOS in a persistent outbox and re-sends the
///     SAME packet (same id) to links that accept SOS until the Rescue
///     Team's authenticated ACK comes back;
///   * a relay validates, dedups, stores (custody), hop-ACKs, forwards --
///     preferring a directly linked rescue endpoint, otherwise other relays
///     -- and routes the rescue ACK / STATUS back to the peers the packet
///     came from (reverse path), retrying until delivered;
///   * the rescue endpoint stores the SOS BEFORE acknowledging it.
///
/// Routing is by app-level peer id (from HELLO), never by BLE address, so a
/// reconnect under a new address keeps the reverse path.
class MeshNode {
  MeshNode({
    required this.role,
    required Future<MeshIdentity> Function() identity,
    MeshAuth? auth,
    DateTime Function()? clock,
    this.persist = true,
    this.storePrefix = 'mesh',
    this.tickInterval = const Duration(seconds: 2),
    this.maxAndroidNodes = 4,
    this.pairGrace = const Duration(seconds: 20),
  })  : _identityLoader = identity,
        _auth = auth ?? MeshAuth.instance,
        _clock = clock ?? DateTime.now;

  final MeshRole role;
  final Future<MeshIdentity> Function() _identityLoader;
  final MeshAuth _auth;
  final DateTime Function() _clock;
  final bool persist;
  final String storePrefix;
  final Duration tickInterval;

  /// Application-level maximum of Android phones in one mesh (this phone
  /// included): a phone links to at most `maxAndroidNodes - 1` others.
  /// Rescue endpoints (laptops) never count.
  final int maxAndroidNodes;

  /// One link per pair of phones: the phone with the lower advertisement
  /// tag connects; the other connects itself only if no link exists after
  /// this grace period (e.g. the lower one's central role failed).
  final Duration pairGrace;

  int get maxAndroidPeers => maxAndroidNodes - 1;

  /// Re-send an SOS whose next hop holds custody but no rescue ACK came
  /// back yet (lost reverse ACK recovery).
  static const Duration repokeInterval = Duration(seconds: 90);
  static const Duration frameTimeout = Duration(seconds: 6);

  MeshIdentity? _identity;
  MeshIdentity get identity =>
      _identity ?? const MeshIdentity(deviceId: 'uninitialized', deviceName: '');
  String get _myId => identity.deviceId;
  String get _myTag => MeshAdvertisement.tagFor(_myId);

  bool _relayEnabled = false;
  bool get relayEnabled => _relayEnabled;

  /// Rescue endpoint / relay: connect to discovered mesh devices
  /// automatically (operator-disconnected devices excepted).
  bool autoConnect = true;

  final Map<String, _Link> _links = {};
  final Map<MeshTransport, List<StreamSubscription<Object?>>> _transportSubs = {};
  final Set<String> _blocked = {};
  final Map<String, int> _firstSeenAt = {};
  bool _meshFullLogged = false;
  final Map<String, int> _connectBackoffMs = {};
  final Map<String, int> _nextConnectAt = {};

  final Map<String, OutboxEntry> _outbox = {};
  final Map<String, RelayEntry> _relay = {};
  final Map<String, InboxEntry> _inbox = {};
  final PacketIdCache _seen = PacketIdCache(capacity: 5000);

  int _forwardedTotal = 0;
  int _duplicatesTotal = 0;
  int _rejectedTotal = 0;

  Timer? _ticker;
  bool _ticking = false;
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _initFuture;

  late final DebouncedDocument _outboxDoc =
      DebouncedDocument('${storePrefix}_outbox', () => {
            'entries': [for (final e in _outbox.values) e.toJson()],
          });
  late final DebouncedDocument _relayDoc =
      DebouncedDocument('${storePrefix}_relay', () => {
            'entries': [for (final e in _relay.values) e.toJson()],
            'forwarded': _forwardedTotal,
            'duplicates': _duplicatesTotal,
          });
  late final DebouncedDocument _inboxDoc =
      DebouncedDocument('${storePrefix}_inbox', () => {
            'entries': [for (final e in _inbox.values) e.toJson()],
          });
  late final DebouncedDocument _seenDoc = DebouncedDocument(
      '${storePrefix}_seen', _seen.toJson,
      delay: const Duration(seconds: 1));

  final ValueNotifier<List<LinkView>> links = ValueNotifier(const []);
  final ValueNotifier<MeshStats> stats = ValueNotifier(const MeshStats());

  final StreamController<MeshEvent> _events = StreamController.broadcast();
  final StreamController<OutboxEntry> _outboxChanges = StreamController.broadcast();
  final StreamController<RescueDelivery> _deliveries = StreamController.broadcast();
  final StreamController<Map<String, dynamic>> _messages = StreamController.broadcast();
  final StreamController<({String packetId, String status, bool delivered})>
      _statusResults = StreamController.broadcast();

  /// Everything that happened (audit log, diagnostics).
  Stream<MeshEvent> get events => _events.stream;

  /// Origin: every change of one of this device's own SOS.
  Stream<OutboxEntry> get outboxChanges => _outboxChanges.stream;

  /// Rescue endpoint: each SOS stored (new) or seen again (duplicate).
  Stream<RescueDelivery> get rescueDeliveries => _deliveries.stream;

  /// Rescue endpoint: MESSAGE packets from affected phones.
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// Rescue endpoint: whether a STATUS reached the next device.
  Stream<({String packetId, String status, bool delivered})> get statusResults =>
      _statusResults.stream;

  List<OutboxEntry> get outbox => List.unmodifiable(_outbox.values);
  OutboxEntry? outboxEntry(String packetId) => _outbox[packetId];
  List<RelayEntry> get relayEntries => List.unmodifiable(_relay.values);
  RelayEntry? relayEntry(String packetId) => _relay[packetId];
  List<InboxEntry> get inbox => List.unmodifiable(_inbox.values);
  InboxEntry? inboxEntry(String packetId) => _inbox[packetId];

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Loads identity and persisted state; starts the retry ticker. Idempotent.
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    _identity = await _identityLoader();
    if (persist) await _load();
    _initialized = true;
    _ticker = Timer.periodic(tickInterval, (_) => _tick());
    _publish();
  }

  Future<void> _load() async {
    final outbox = await LocalStore.read('${storePrefix}_outbox');
    for (final raw in (outbox?['entries'] as List?) ?? const []) {
      final e = OutboxEntry.fromJson(raw);
      if (e != null) _outbox[e.packet.id] = e;
    }
    final relay = await LocalStore.read('${storePrefix}_relay');
    for (final raw in (relay?['entries'] as List?) ?? const []) {
      final e = RelayEntry.fromJson(raw);
      if (e != null) _relay[e.packet.id] = e;
    }
    _forwardedTotal = relay?['forwarded'] as int? ?? 0;
    _duplicatesTotal = relay?['duplicates'] as int? ?? 0;
    final inbox = await LocalStore.read('${storePrefix}_inbox');
    for (final raw in (inbox?['entries'] as List?) ?? const []) {
      final e = InboxEntry.fromJson(raw);
      if (e != null) _inbox[e.packet.id] = e;
    }
    _seen.loadJson(await LocalStore.read('${storePrefix}_seen'));
    if (_outbox.isNotEmpty || _relay.isNotEmpty || _inbox.isNotEmpty) {
      NetLog.store('Restored ${_outbox.length} own SOS, ${_relay.length} relay '
          'packets, ${_inbox.length} rescue records');
    }
  }

  void attach(MeshTransport transport) {
    if (_transportSubs.containsKey(transport)) return;
    _transportSubs[transport] = [
      transport.links.listen((info) => _onLink(transport, info)),
      transport.frames.listen(_onFrame),
    ];
  }

  Future<void> detach(MeshTransport transport) async {
    final subs = _transportSubs.remove(transport);
    for (final s in subs ?? const <StreamSubscription<Object?>>[]) {
      await s.cancel();
    }
    _links.removeWhere((_, l) => l.transport == transport);
    _publish();
  }

  Future<void> dispose() async {
    _disposed = true;
    _ticker?.cancel();
    _publishTimer?.cancel();
    for (final t in _transportSubs.keys.toList()) {
      await detach(t);
    }
    await flush();
    await _events.close();
    await _outboxChanges.close();
    await _deliveries.close();
    await _messages.close();
    await _statusResults.close();
  }

  /// Writes every pending document now.
  Future<void> flush() async {
    if (!persist) return;
    await Future.wait([
      _outboxDoc.flush(),
      _relayDoc.flush(),
      _inboxDoc.flush(),
      _seenDoc.flush(),
    ]);
  }

  /// RELAY mode on/off (affected role). Announced to every linked device.
  Future<void> setRelayEnabled(bool on) async {
    if (_relayEnabled == on) return;
    _relayEnabled = on;
    NetLog.relay(on ? 'Relay mode ON' : 'Relay mode OFF');
    for (final link in _links.values.where((l) => l.info.isReady)) {
      unawaited(_sendHello(link));
    }
    if (on) _flushAll();
    _publish();
  }

  // -------------------------------------------------------------------------
  // Links
  // -------------------------------------------------------------------------

  String _routeKey(_Link link) => link.peer?.id ?? 'link:${link.info.linkId}';

  bool _matchesRoute(_Link link, Set<String> keys) =>
      (link.peer != null && keys.contains(link.peer!.id)) ||
      keys.contains('link:${link.info.linkId}');

  void _onLink(MeshTransport transport, LinkInfo info) {
    final link = _links[info.linkId] ??= _Link(transport, info);
    _firstSeenAt.putIfAbsent(info.linkId, () => _clock().millisecondsSinceEpoch);
    final wasReady = link.info.isReady;
    link.info = info;

    if (info.isReady && !wasReady) {
      link.readyAt = _clock();
      link.helloSent = false;
      _connectBackoffMs.remove(info.linkId);
      _nextConnectAt.remove(info.linkId);
      NetLog.ble('Communication ready on ${info.side.name} link '
          '(${info.name ?? 'device'}, ${info.payloadSize} B/frame'
          '${info.hasAckChannel ? ', ACK channel' : ''})');
      unawaited(_sendHello(link));
    } else if (!info.isReady && wasReady) {
      final name = link.peer?.name ?? info.name ?? 'device';
      NetLog.ble('Link lost: $name (${info.state.label}'
          '${info.error != null ? ': ${info.error}' : ''})');
      _emit(MeshEventType.linkLost, 'Link to $name lost', peerName: name);
      link.reassembler.clear('${info.linkId}|data');
      link.reassembler.clear('${info.linkId}|ack');
      link.peer = null;
      link.readyAt = null;
      _scheduleReconnect(link);
    }

    if (info.side == LinkSide.central &&
        (info.state == LinkState.discovered ||
            info.state == LinkState.disconnected ||
            info.state == LinkState.error)) {
      _maybeConnect(link);
    }
    _publish();
  }

  void _scheduleReconnect(_Link link) {
    if (link.info.side != LinkSide.central) return;
    final id = link.info.linkId;
    final backoff = math.min(60000, (_connectBackoffMs[id] ?? 1000) * 2);
    _connectBackoffMs[id] = backoff;
    _nextConnectAt[id] = _clock().millisecondsSinceEpoch + backoff;
  }

  /// Distinct phones this node is linked with (either direction).
  Set<String> _phonePeerIds({_Link? except}) => {
        for (final l in _links.values)
          if (l != except && l.peer != null && l.peer!.isPhone && l.info.state.isConnectedish)
            l.peer!.id,
      };

  Set<String> _linkedPeerTags() => {
        for (final l in _links.values)
          if (l.peer != null && l.info.state.isConnectedish)
            MeshAdvertisement.tagFor(l.peer!.id),
      };

  /// Central-side connection policy. Every phone scans and connects (it is
  /// peripheral AND central); the rescue laptop connects to every phone.
  void _maybeConnect(_Link link) {
    if (!_initialized || _disposed || !autoConnect) return;
    final id = link.info.linkId;
    if (_blocked.contains(id)) return;
    final now = _clock().millisecondsSinceEpoch;
    if ((_nextConnectAt[id] ?? 0) > now) return;

    final adv = link.info.advertisement;
    if (adv != null) {
      if (adv.idTag == _myTag) return;
      // Already linked with this device (other direction / new address).
      if (_linkedPeerTags().contains(adv.idTag)) return;
    }

    if (role == MeshRole.affected) {
      // Phones only: a phone never connects to the laptop (the laptop has
      // no peripheral), so every central link here goes to another phone.
      final pending = _links.values
          .where((l) =>
              l.info.side == LinkSide.central &&
              (l.info.state == LinkState.connecting ||
                  (l.info.state.isConnectedish && l.peer == null)))
          .length;
      if (_phonePeerIds().length + pending >= maxAndroidPeers) {
        if (!_meshFullLogged) {
          _meshFullLogged = true;
          NetLog.ble('Mesh full: already linked with $maxAndroidPeers phones '
              '(max $maxAndroidNodes phones per mesh) -- not connecting to more');
        }
        return;
      }
      _meshFullLogged = false;
      // One link per pair of phones (data flows both ways on it): the lower
      // tag connects at once, the higher one only after [pairGrace].
      if (adv != null && adv.idTag.compareTo(_myTag) < 0) {
        final seen = _firstSeenAt[id] ?? now;
        if (now - seen < pairGrace.inMilliseconds) return;
      }
    } else {
      final activeCentral = _links.values
          .where((l) =>
              l.info.side == LinkSide.central &&
              (l.info.state == LinkState.connecting || l.info.state.isConnectedish))
          .length;
      if (activeCentral >= 8) return;
    }

    _nextConnectAt[id] = now + 15000; // until the attempt resolves
    NetLog.ble('Connecting to ${link.info.name ?? link.info.address}');
    unawaited(link.transport.connect(id));
  }

  /// Operator connect (also clears an earlier manual disconnect).
  Future<void> connect(String linkId) async {
    _blocked.remove(linkId);
    _nextConnectAt.remove(linkId);
    final link = _links[linkId];
    if (link == null) return;
    NetLog.ble('Connecting to ${link.info.name ?? link.info.address} (manual)');
    await link.transport.connect(linkId);
  }

  /// Operator disconnect; with [block] the device is not auto-reconnected
  /// until [connect] is called again.
  Future<void> disconnect(String linkId, {bool block = true}) async {
    if (block) _blocked.add(linkId);
    final link = _links[linkId];
    if (link == null) return;
    await link.transport.disconnect(linkId);
    _publish();
  }

  bool isBlocked(String linkId) => _blocked.contains(linkId);

  Iterable<_Link> get _identifiedLinks =>
      _links.values.where((l) => l.info.isReady && l.peer != null);

  /// Next hops for an SOS: a directly linked rescue endpoint if there is
  /// one, otherwise every relay-mode peer. [exclude] holds route keys.
  List<_Link> _sosTargets(SosPacket packet, Set<String> exclude) {
    final candidates = _identifiedLinks.where((l) {
      final peer = l.peer!;
      if (!peer.acceptsSos) return false;
      if (peer.id == packet.senderId) return false;
      if (packet.path.contains(peer.id)) return false;
      if (_matchesRoute(l, exclude)) return false;
      return true;
    }).toList();
    final rescue = candidates.where((l) => l.peer!.isRescue).toList();
    if (rescue.isNotEmpty) return _onePerPeer(rescue);
    return _onePerPeer(candidates);
  }

  /// Two links to the same device (both directions): use one.
  List<_Link> _onePerPeer(List<_Link> links) {
    final byPeer = <String, _Link>{};
    for (final l in links) {
      final existing = byPeer[l.peer!.id];
      if (existing == null ||
          (l.info.hasAckChannel && !existing.info.hasAckChannel)) {
        byPeer[l.peer!.id] = l;
      }
    }
    return byPeer.values.toList();
  }

  // -------------------------------------------------------------------------
  // Sending
  // -------------------------------------------------------------------------

  Future<bool> _sendJson(_Link link, MeshChannel channel, Map<String, dynamic> json) {
    final effective = channel == MeshChannel.ack && !link.info.hasAckChannel
        ? MeshChannel.data
        : channel;
    final completer = Completer<bool>();
    link.chain = link.chain.then((_) async {
      if (!link.info.isReady) {
        completer.complete(false);
        return;
      }
      try {
        final payload = BleProtocol.encodeJson(json);
        final frameSize = math.max(
            BleProtocol.attPayloadSize, math.min(link.info.payloadSize, 500));
        final frames = BleFrameCodec.encode(payload,
            messageId: link.frameIds.next(), attPayloadSize: frameSize);
        for (final frame in frames) {
          final ok = await link.transport
              .send(link.info.linkId, effective, frame)
              .timeout(frameTimeout, onTimeout: () => false);
          if (!ok) {
            completer.complete(false);
            return;
          }
        }
        completer.complete(true);
      } catch (e) {
        NetLog.ble('Send failed on ${link.info.linkId}: $e');
        if (!completer.isCompleted) completer.complete(false);
      }
    });
    return completer.future;
  }

  String get _helloRole => role == MeshRole.rescue
      ? BleProtocol.roleRescue
      : (_relayEnabled ? BleProtocol.roleRelay : BleProtocol.roleAffected);

  Future<void> _sendHello(_Link link) async {
    final ok = await _sendJson(
      link,
      MeshChannel.data,
      BleProtocol.hello(
        role: _helloRole,
        deviceName: identity.deviceName,
        senderId: _myId,
        relayEnabled: role == MeshRole.affected ? _relayEnabled : null,
        capabilities: BleProtocol.supportedTypes,
        maxMeshNodes: role == MeshRole.affected ? maxAndroidNodes : null,
      ),
    );
    link.helloSent = ok;
    if (!ok) NetLog.ble('HELLO to ${link.info.name ?? link.info.linkId} failed');
  }

  /// The CONTROL characteristic body (peripheral transports serve it).
  Uint8List controlValue() => BleProtocol.encodeJson(BleProtocol.control(
        role: _helloRole,
        deviceId: _myId,
        deviceName: identity.deviceName,
        relayEnabled: _relayEnabled,
        queued: _outbox.values.where((e) => !e.status.reachedRescue).length +
            _relay.values.where((e) => !e.delivered).length,
      ));

  // -------------------------------------------------------------------------
  // Receiving
  // -------------------------------------------------------------------------

  void _onFrame(InboundFrame frame) {
    final link = _links[frame.linkId];
    if (link == null) return;
    final complete =
        link.reassembler.add('${frame.linkId}|${frame.channel.name}', frame.bytes);
    if (complete == null) return;
    final json = BleProtocol.decodeJsonObject(complete);
    if (json == null) {
      _reject(link, null, 'unreadable (not JSON)');
      return;
    }
    switch (json['type']) {
      case BleProtocol.typeHello:
        _onHello(link, json);
      case BleProtocol.typeSos:
        unawaited(_onSos(link, json));
      case BleProtocol.typeAck:
        unawaited(_onAck(link, json));
      case BleProtocol.typeStatus:
        unawaited(_onStatus(link, json));
      case BleProtocol.typeMessage:
        if (role == MeshRole.rescue) _messages.add(json);
      default:
        _reject(link, json['id'] is String ? json['id'] as String : null,
            'unknown message type ${json['type']}');
    }
  }

  void _reject(_Link link, String? packetId, String reason) {
    _rejectedTotal++;
    final name = link.peer?.name ?? link.info.name ?? 'device';
    NetLog.relay('Packet rejected from $name: $reason');
    _emit(MeshEventType.packetRejected, 'Rejected from $name: $reason',
        packetId: packetId, peerName: name);
    _publish();
  }

  void _onHello(_Link link, Map<String, dynamic> json) {
    final id = json['senderId'];
    final role = json['role'];
    final name = json['deviceName'];
    if (role is! String ||
        !{BleProtocol.roleAffected, BleProtocol.roleRelay, BleProtocol.roleRescue}
            .contains(role)) {
      _reject(link, null, 'HELLO with unknown role');
      return;
    }
    final peerId = id is String && id.isNotEmpty && id.length <= 64
        ? id
        // Builds before v3 sent no id from the rescue console.
        : 'legacy-${link.info.address}';
    if (peerId == _myId) return;
    final previous = link.peer;
    final isPhone = role != BleProtocol.roleRescue;
    if (this.role == MeshRole.affected &&
        isPhone &&
        previous?.id != peerId &&
        !_phonePeerIds(except: link).contains(peerId) &&
        _phonePeerIds(except: link).length >= maxAndroidPeers) {
      NetLog.ble('Mesh full ($maxAndroidNodes phones): not linking with '
          '${name is String ? name : 'another phone'}');
      unawaited(link.transport.disconnect(link.info.linkId));
      return;
    }
    final caps = json['caps'];
    link.peer = PeerInfo(
      id: peerId,
      role: role,
      name: name is String && name.trim().isNotEmpty
          ? name.trim()
          : (link.info.name ?? 'Device'),
      relayEnabled: json['relay'] == true || role == BleProtocol.roleRelay,
      protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 1,
      capabilities: caps is List ? caps.whereType<String>().toSet() : const {},
    );
    if (previous?.id != peerId || previous?.role != role) {
      NetLog.ble('Peer identified: ${link.peer!.name} ($role) on '
          '${link.info.side.name} link');
      _emit(MeshEventType.linkReady, '${link.peer!.name} connected as $role',
          peerName: link.peer!.name);
    }
    if (!link.helloSent) unawaited(_sendHello(link));
    _flushToLink(link);
    _publish();
  }

  Future<void> _onSos(_Link link, Map<String, dynamic> json) async {
    final SosPacket packet;
    try {
      packet = SosPacket.fromWireJson(json);
    } on FormatException catch (e) {
      _reject(link, json['id'] is String ? json['id'] as String : null,
          'malformed SOS (${e.message})');
      return;
    } catch (_) {
      _reject(link, null, 'malformed SOS');
      return;
    }
    final reason = SosValidation.rejectReason(packet, now: _clock());
    if (reason != null) {
      _reject(link, packet.id, reason);
      return;
    }
    var authenticated = false;
    if (packet.mac != null) {
      if (!_auth.verifySos(packet)) {
        _reject(link, packet.id,
            'authentication failed (modified or foreign packet)');
        return;
      }
      authenticated = true;
    }
    if (packet.senderId == _myId) return; // our own SOS echoed back

    final peerName = link.peer?.name ?? link.info.name ?? 'device';
    if (role == MeshRole.rescue) {
      await _rescueReceive(link, packet, authenticated, peerName);
    } else if (_relayEnabled) {
      await _relayReceive(link, packet, peerName);
    } else {
      NetLog.relay('SOS ${packet.id} from $peerName ignored (relay mode off)');
    }
  }

  // ---- rescue endpoint ----------------------------------------------------

  Future<void> _rescueReceive(
      _Link link, SosPacket packet, bool authenticated, String peerName) async {
    final key = _routeKey(link);
    final existing = _inbox[packet.id];
    if (existing != null) {
      existing.arrivedFrom.add(key);
      _duplicatesTotal++;
      NetLog.rescue('Duplicate SOS ${packet.id} via $peerName -- re-sending ACK');
      _emit(MeshEventType.rescueDuplicate, 'Duplicate SOS via $peerName',
          packetId: packet.id, peerName: peerName);
      _save(_inboxDoc);
      _deliveries.add(RescueDelivery(
          entry: existing,
          linkId: link.info.linkId,
          linkName: peerName,
          linkPeer: link.peer,
          isDuplicate: true));
      // The sender is retrying: it may never have received our ACK/STATUS.
      final ok = await _sendJson(link, MeshChannel.ack, existing.rescueAck);
      if (ok) existing.ackDeliveredTo.add(key);
      for (final status in existing.statuses.entries) {
        final delivered = existing.statusDeliveredTo.putIfAbsent(status.key, () => {});
        if (await _sendJson(link, MeshChannel.ack, status.value)) delivered.add(key);
      }
      _save(_inboxDoc);
      _publish();
      return;
    }

    final now = _clock();
    final entry = InboxEntry(
      packet: packet,
      receivedAt: now,
      authenticated: authenticated,
      rescueAck: BleProtocol.rescueAck(
        packetId: packet.id,
        originId: packet.senderId,
        fromId: _myId,
        at: now,
        auth: _auth,
      ),
      arrivedFrom: {key},
      firstLinkName: peerName,
      firstLinkPeerId: link.peer?.id,
    );
    _inbox[packet.id] = entry;
    _seen.markIfNew('sos:${packet.id}', now: now);
    NetLog.rescue('SOS received ${packet.id} from ${packet.displayName}'
        '${packet.hopCount > 0 ? ' via $peerName (${packet.hopCount} hop${packet.hopCount == 1 ? '' : 's'})' : ''}'
        ', ${NetLog.gps(packet.latitude, packet.longitude, packet.accuracyMeters)}'
        '${authenticated ? '' : ', UNAUTHENTICATED (older build)'}');

    // Stored BEFORE the ACK: the phone is never told "received" for an SOS
    // that exists only in memory.
    final saved = await _saveNow(_inboxDoc);
    _emit(
        MeshEventType.rescueReceived,
        'SOS from ${packet.displayName}'
        '${packet.hopCount > 0 ? ' via $peerName (${packet.hopCount} hop${packet.hopCount == 1 ? '' : 's'})' : ''}'
        '${saved ? '' : ' (NOT saved to disk)'}',
        packetId: packet.id,
        peerName: peerName);
    _deliveries.add(RescueDelivery(
        entry: entry,
        linkId: link.info.linkId,
        linkName: peerName,
        linkPeer: link.peer,
        isDuplicate: false));

    NetLog.rescue('ACK generated for ${packet.id}');
    final ok = await _sendJson(link, MeshChannel.ack, entry.rescueAck);
    if (ok) {
      entry.ackDeliveredTo.add(key);
      NetLog.rescue('ACK sent to $peerName for ${packet.id}');
    } else {
      NetLog.rescue('ACK to $peerName failed for ${packet.id}; will retry');
    }
    _emit(MeshEventType.rescueAckSent,
        ok ? 'ACK delivered to $peerName' : 'ACK to $peerName failed (will retry)',
        packetId: packet.id, peerName: peerName);
    _save(_inboxDoc);
    _publish();
  }

  /// Rescue endpoint: routes a workflow status (ASSIGNED, IN_PROGRESS,
  /// RESCUED, ...) back to the origin along the reverse path. Returns true
  /// if at least one next device received it now; otherwise it stays
  /// pending and is retried whenever a path is available.
  Future<bool> sendStatus(String packetId, String status) async {
    final entry = _inbox[packetId];
    if (entry == null) return false;
    final message = BleProtocol.routedStatus(
      packetId: packetId,
      originId: entry.packet.senderId,
      status: status,
      fromId: _myId,
      at: _clock(),
      auth: _auth,
    );
    entry.statuses[status] = message;
    entry.statusDeliveredTo.remove(status);
    await _saveNow(_inboxDoc);
    final delivered = await _flushInbox(entry);
    _emit(MeshEventType.statusSent,
        'STATUS $status ${delivered ? 'sent' : 'queued (no path yet)'}',
        packetId: packetId);
    if (!_statusResults.isClosed) {
      _statusResults.add((packetId: packetId, status: status, delivered: delivered));
    }
    return delivered;
  }

  /// Sends the pending ACK / STATUS messages of one inbox entry. Returns
  /// true if anything was delivered to at least one device.
  Future<bool> _flushInbox(InboxEntry entry, {_Link? only}) async {
    var any = false;
    final targets = _identifiedLinks
        .where((l) =>
            _matchesRoute(l, entry.arrivedFrom) || l.peer!.id == entry.packet.senderId)
        .where((l) => only == null || l == only)
        .toList();
    for (final link in targets) {
      final key = _routeKey(link);
      if (!entry.ackDeliveredTo.contains(key)) {
        final firstDelivery = entry.ackDeliveredTo.isEmpty;
        if (await _sendJson(link, MeshChannel.ack, entry.rescueAck)) {
          entry.ackDeliveredTo.add(key);
          any = true;
          if (firstDelivery) {
            NetLog.rescue('ACK sent to ${link.peer!.name} for ${entry.packet.id} (retry)');
            _emit(MeshEventType.rescueAckSent, 'ACK delivered to ${link.peer!.name}',
                packetId: entry.packet.id, peerName: link.peer!.name);
          }
        }
      }
      for (final s in entry.statuses.entries) {
        final delivered = entry.statusDeliveredTo.putIfAbsent(s.key, () => {});
        if (delivered.contains(key)) continue;
        if (await _sendJson(link, MeshChannel.ack, s.value)) {
          delivered.add(key);
          any = true;
          NetLog.rescue('STATUS ${s.key} for ${entry.packet.id} sent to ${link.peer!.name}');
        }
      }
    }
    if (any) _save(_inboxDoc);
    return any;
  }

  // ---- relay --------------------------------------------------------------

  Future<void> _relayReceive(_Link link, SosPacket packet, String peerName) async {
    final key = _routeKey(link);
    NetLog.relay('Packet received ${packet.id} from $peerName');
    NetLog.relay('Packet validated ${packet.id}');
    final existing = _relay[packet.id];
    if (existing != null) {
      existing.receivedFrom.add(key);
      _duplicatesTotal++;
      NetLog.relay('Duplicate detected ${packet.id} -- not forwarded again');
      _emit(MeshEventType.relayDuplicate, 'Duplicate from $peerName',
          packetId: packet.id, peerName: peerName);
      _save(_relayDoc);
      await _sendJson(
          link,
          MeshChannel.ack,
          BleProtocol.hopAck(
              packetId: packet.id, fromId: _myId, willForward: existing.canForward));
      // The sender is retrying: maybe it never got the reverse messages.
      await _flushUpstream(existing, only: link, force: true);
      _publish();
      return;
    }

    final canForward = BleProtocol.shouldRelay(packet, _myId);
    final entry = RelayEntry(
      packet: packet,
      receivedAt: _clock(),
      canForward: canForward,
      receivedFrom: {key},
    );
    _relay[packet.id] = entry;
    _seen.markIfNew('sos:${packet.id}', now: _clock());
    await _saveNow(_relayDoc);
    NetLog.relay(canForward
        ? 'Packet queued ${packet.id} (hop ${packet.hopCount + 1}/${packet.maxHops})'
        : 'Packet ${packet.id} kept but NOT forwarded (TTL/hop limit reached)');
    _emit(canForward ? MeshEventType.relayReceived : MeshEventType.relayNotForwarded,
        canForward
            ? 'Relay received SOS of ${packet.displayName} from $peerName'
            : 'Hop limit reached for SOS of ${packet.displayName}',
        packetId: packet.id,
        peerName: peerName);

    await _sendJson(link, MeshChannel.ack,
        BleProtocol.hopAck(packetId: packet.id, fromId: _myId, willForward: canForward));
    if (canForward) await _forwardRelay(entry);
    _publish();
  }

  Future<void> _forwardRelay(RelayEntry entry, {_Link? only}) async {
    if (!_relayEnabled || !entry.canForward || entry.delivered) return;
    final now = _clock();
    final exclude = {...entry.receivedFrom, ...entry.custodyBy, ...entry.cannotForward};
    final targets = _sosTargets(entry.packet, exclude)
        .where((l) => only == null || l == only)
        .toList();
    if (targets.isEmpty) return;
    final forwarded =
        entry.packet.forRelay(relayerId: _myId, relayerName: identity.deviceName);
    for (final link in targets) {
      final key = _routeKey(link);
      if (only == null && !entry.attempts.due(key, now)) continue;
      entry.attempts.record(key, now);
      NetLog.relay('Forwarding packet ${entry.packet.id} to ${link.peer!.name} '
          '(${link.peer!.role})');
      final ok = await _sendJson(link, MeshChannel.data, forwarded.toTransportJson());
      if (ok) {
        entry.forwardedCount++;
        _forwardedTotal++;
        NetLog.relay('Forward successful ${entry.packet.id} -> ${link.peer!.name}');
      } else {
        NetLog.relay('Forward failed ${entry.packet.id} -> ${link.peer!.name}; will retry');
      }
      _emit(MeshEventType.relayForwarded,
          ok ? 'Forwarded to ${link.peer!.name}' : 'Forward to ${link.peer!.name} failed',
          packetId: entry.packet.id, peerName: link.peer!.name);
    }
    _save(_relayDoc);
  }

  /// Reverse path: delivers the rescue ACK / STATUS of [entry] to every
  /// upstream peer that has not received it yet ([force]: also to [only]
  /// even if it already got them -- it is retrying).
  Future<void> _flushUpstream(RelayEntry entry, {_Link? only, bool force = false}) async {
    final messages = <String, Map<String, dynamic>>{
      if (entry.rescueAck != null) 'ack': entry.rescueAck!,
      for (final s in entry.statuses.entries) 'status:${s.key}': s.value,
    };
    if (messages.isEmpty) return;
    final targets = _identifiedLinks
        .where((l) =>
            _matchesRoute(l, entry.receivedFrom) || l.peer!.id == entry.packet.senderId)
        .where((l) => only == null || l == only)
        .toList();
    var changed = false;
    for (final link in targets) {
      final key = _routeKey(link);
      for (final m in messages.entries) {
        final done = entry.upstreamDelivered.putIfAbsent(m.key, () => {});
        if (done.contains(key) && !force) continue;
        if (await _sendJson(link, MeshChannel.ack, m.value)) {
          final first = done.add(key);
          changed = true;
          if (first) {
            final what = m.key == 'ack' ? 'ACK' : 'STATUS ${m.key.substring(7)}';
            NetLog.rescue('$what forwarded upstream to ${link.peer!.name} '
                'for ${entry.packet.id}');
            _emit(m.key == 'ack' ? MeshEventType.ackForwarded : MeshEventType.statusForwarded,
                '$what forwarded to ${link.peer!.name}',
                packetId: entry.packet.id, peerName: link.peer!.name);
          }
        }
      }
    }
    if (changed) _save(_relayDoc);
  }

  // ---- ACK / STATUS -------------------------------------------------------

  Future<void> _onAck(_Link link, Map<String, dynamic> json) async {
    final id = json['id'];
    if (id is! String || id.isEmpty) return;
    final kind = BleProtocol.ackKindOf(json);
    final key = _routeKey(link);
    final peerName = link.peer?.name ?? link.info.name ?? 'device';
    final own = _outbox[id];
    final held = _relay[id];

    if (kind == BleProtocol.ackKindHop) {
      final fwd = json['fwd'] != false;
      if (own != null) {
        (fwd ? own.custodyBy : own.cannotForward).add(key);
        if (fwd && link.peer?.isRescue != true) {
          _advance(own, SosStatus.relayed,
              detail: 'Relay $peerName has your SOS and will forward it');
        }
        NetLog.sos('Hop ACK for ${own.packet.id} from $peerName'
            '${fwd ? '' : ' (cannot forward)'}');
        _emit(MeshEventType.hopAckReceived,
            'Hop ACK from $peerName${fwd ? '' : ' (cannot forward)'}',
            packetId: id, peerName: peerName);
        _save(_outboxDoc);
      }
      if (held != null) {
        (fwd ? held.custodyBy : held.cannotForward).add(key);
        NetLog.relay('Next hop $peerName ${fwd ? 'accepted' : 'cannot forward'} ${held.packet.id}');
        _save(_relayDoc);
      }
      _publish();
      return;
    }

    // RESCUE: only an authenticated ACK counts as the Rescue Team's.
    final originId = own?.packet.senderId ?? held?.packet.senderId;
    final verified =
        _auth.verifyAck(json) && (originId == null || json['origin'] == originId);
    if (!verified) {
      NetLog.sos('Unverified rescue ACK for $id from $peerName ignored');
      _emit(MeshEventType.packetRejected, 'Unverified rescue ACK from $peerName ignored',
          packetId: id, peerName: peerName);
      return;
    }
    if (own != null && own.rescueAck == null) {
      own.rescueAck = json;
      own.packet.acknowledgedAt = _clock();
      _advance(own, SosStatus.receivedByRescue,
          detail: 'The Rescue Team received your SOS'
              '${own.custodyBy.isNotEmpty ? ' (via relay)' : ''}');
      NetLog.sos('RECEIVED BY RESCUE: ${own.packet.id}');
      _emit(MeshEventType.rescueAckReceived, 'Rescue Team received the SOS',
          packetId: id, peerName: peerName);
      await _saveNow(_outboxDoc);
    }
    if (held != null && held.rescueAck == null) {
      held.rescueAck = json;
      NetLog.rescue('Rescue ACK for relayed ${held.packet.id} received from $peerName');
      _save(_relayDoc);
      await _flushUpstream(held);
    }
    _publish();
  }

  Future<void> _onStatus(_Link link, Map<String, dynamic> json) async {
    final id = json['id'];
    final status = json['status'];
    if (id is! String || status is! String || status.isEmpty || status.length > 32) {
      return;
    }
    final peerName = link.peer?.name ?? link.info.name ?? 'device';
    final own = _outbox[id];
    final held = _relay[id];
    final originId = own?.packet.senderId ?? held?.packet.senderId;
    if (!_auth.verifyStatus(json) || (originId != null && json['origin'] != originId)) {
      NetLog.sos('Unverified STATUS for $id from $peerName ignored');
      return;
    }
    if (own != null && own.rescueStatus != status) {
      own.rescueStatus = status;
      // A status implies the Rescue Team has the SOS.
      own.rescueAck ??= {'implied': true};
      _advance(own, SosStatus.acknowledged,
          detail: 'Rescue Team update: ${status.replaceAll('_', ' ')}');
      // Same state, new status text: still announce it.
      own.updatedAt = _clock();
      if (!_outboxChanges.isClosed) _outboxChanges.add(own);
      NetLog.sos('Rescue status for ${own.packet.id}: $status');
      _emit(MeshEventType.statusReceived, 'Rescue Team: $status',
          packetId: id, peerName: peerName);
      await _saveNow(_outboxDoc);
    }
    if (held != null && !held.statuses.containsKey(status)) {
      held.statuses[status] = json;
      _save(_relayDoc);
      await _flushUpstream(held);
    }
    _publish();
  }

  // -------------------------------------------------------------------------
  // Origin
  // -------------------------------------------------------------------------

  /// Signs, stores and starts delivering a new SOS. The returned entry is
  /// updated in place and announced on [outboxChanges].
  Future<OutboxEntry> originate(SosPacket packet) async {
    await init();
    final signed = packet.withMac(_auth.sign(packet));
    signed.status = SosStatus.queued;
    final now = _clock();
    final entry = OutboxEntry(packet: signed, createdAt: now, updatedAt: now);
    _outbox[signed.id] = entry;
    _seen.markIfNew('sos:${signed.id}', now: now);
    final saved = await _saveNow(_outboxDoc);
    NetLog.sos('SOS created ${signed.id} (${signed.priority}, '
        '${NetLog.gps(signed.latitude, signed.longitude, signed.accuracyMeters)})'
        '${saved ? '' : ' -- NOT saved to disk'}');
    _emit(MeshEventType.sosCreated,
        'SOS created${saved ? '' : ' (not saved to disk)'}',
        packetId: signed.id);
    entry.detail = 'Saved on this phone. Waiting for a Bluetooth link...';
    if (!_outboxChanges.isClosed) _outboxChanges.add(entry);
    await _sendOutbox(entry);
    if (entry.status == SosStatus.queued) {
      NetLog.sos('SOS queued ${signed.id} (no rescue/relay link ready)');
      _emit(MeshEventType.sosQueued,
          'Queued: no Bluetooth link to the Rescue Team or a relay yet',
          packetId: signed.id);
    }
    _publish();
    return entry;
  }

  Future<void> _sendOutbox(OutboxEntry entry, {_Link? only}) async {
    if (entry.status.reachedRescue || entry.status == SosStatus.failed) return;
    final now = _clock();
    final targets = _sosTargets(entry.packet, entry.cannotForward)
        .where((l) => only == null || l == only)
        .toList();
    for (final link in targets) {
      final key = _routeKey(link);
      final hasCustody = entry.custodyBy.contains(key);
      if (only == null &&
          !entry.attempts.due(key, now, fixed: hasCustody ? repokeInterval : null)) {
        continue;
      }
      entry.attempts.record(key, now);
      final peer = link.peer!;
      final ok = await _sendJson(link, MeshChannel.data, entry.packet.toTransportJson());
      NetLog.sos('SOS ${entry.packet.id} ${ok ? 'sent' : 'send FAILED'} to '
          '${peer.name} (${peer.role})');
      if (ok) {
        entry.nextHopRole = peer.role;
        entry.nextHopName = peer.name;
        _advance(entry, SosStatus.sentToRelay,
            detail: peer.isRescue
                ? 'Sent to the Rescue Team laptop (${peer.name}); waiting for its confirmation'
                : 'Sent to relay phone ${peer.name}; waiting for its confirmation');
        _emit(MeshEventType.sosSent, 'Sent to ${peer.name} (${peer.role})',
            packetId: entry.packet.id, peerName: peer.name);
      }
    }
    _save(_outboxDoc);
  }

  void _advance(OutboxEntry entry, SosStatus next, {String? detail}) {
    if (entry.status == next) {
      if (detail != null && detail != entry.detail) {
        entry.detail = detail;
        entry.updatedAt = _clock();
        if (!_outboxChanges.isClosed) _outboxChanges.add(entry);
      }
      return;
    }
    if (!entry.status.canMoveTo(next)) return;
    entry.status = next;
    entry.packet.status = next;
    entry.detail = detail ?? entry.detail;
    entry.updatedAt = _clock();
    if (!_outboxChanges.isClosed) _outboxChanges.add(entry);
  }

  /// Affected phone -> Rescue Team chat message (direct links only).
  Future<bool> sendMessage(Map<String, dynamic> json) async {
    var any = false;
    for (final link in _identifiedLinks.where((l) => l.peer!.isRescue).toList()) {
      any = await _sendJson(link, MeshChannel.data, json) || any;
    }
    return any;
  }

  // -------------------------------------------------------------------------
  // Retry ticker / flushing
  // -------------------------------------------------------------------------

  void _flushToLink(_Link link) {
    if (link.peer == null) return;
    unawaited(() async {
      for (final e in _outbox.values.toList()) {
        await _sendOutbox(e, only: link);
      }
      for (final e in _relay.values.toList()) {
        await _forwardRelay(e, only: link);
        await _flushUpstream(e, only: link);
      }
      for (final e in _inbox.values.toList()) {
        await _flushInbox(e, only: link);
      }
    }());
  }

  void _flushAll() {
    for (final link in _identifiedLinks.toList()) {
      _flushToLink(link);
    }
  }

  Future<void> _tick() async {
    if (_ticking || _disposed) return;
    _ticking = true;
    try {
      final now = _clock();
      for (final e in _outbox.values.toList()) {
        if (e.status.reachedRescue || e.status == SosStatus.failed) continue;
        if (now.difference(e.createdAt) > SosValidation.maxAge) {
          _advance(e, SosStatus.failed,
              detail: 'Not confirmed by the Rescue Team within '
                  '${SosValidation.maxAge.inHours} h');
          _save(_outboxDoc);
          continue;
        }
        await _sendOutbox(e);
      }
      final expired = <String>[];
      for (final e in _relay.values.toList()) {
        if (now.difference(e.receivedAt) > SosValidation.maxAge) {
          expired.add(e.packet.id);
          continue;
        }
        await _forwardRelay(e);
        await _flushUpstream(e);
      }
      if (expired.isNotEmpty) {
        expired.forEach(_relay.remove);
        _save(_relayDoc);
      }
      for (final e in _inbox.values.toList()) {
        if (e.hasPendingReverse) await _flushInbox(e);
      }
      for (final link in _links.values.toList()) {
        if (link.info.side == LinkSide.central &&
            (link.info.state == LinkState.discovered ||
                link.info.state == LinkState.disconnected ||
                link.info.state == LinkState.error)) {
          _maybeConnect(link);
        }
      }
      _publish();
    } finally {
      _ticking = false;
    }
  }

  /// Runs one retry pass now (tests).
  @visibleForTesting
  Future<void> tickForTest() => _tick();

  // -------------------------------------------------------------------------
  // Persistence / publishing helpers
  // -------------------------------------------------------------------------

  void _save(DebouncedDocument doc) {
    if (!persist || _disposed) return;
    doc.schedule();
    _seenDoc.schedule();
  }

  Future<bool> _saveNow(DebouncedDocument doc) async {
    if (!persist) return true;
    _seenDoc.schedule();
    final ok = await doc.flush();
    if (!ok) {
      _emit(MeshEventType.storageError,
          'Could not save ${doc.name}: ${LocalStore.lastError ?? 'unknown error'}');
    }
    return ok;
  }

  void _emit(MeshEventType type, String detail, {String? packetId, String? peerName}) {
    if (_events.isClosed) return;
    _events.add(
        MeshEvent(type, detail, packetId: packetId, peerName: peerName, at: _clock()));
  }

  Timer? _publishTimer;

  void _publish() {
    if (_disposed || (_publishTimer?.isActive ?? false)) return;
    _publishTimer = Timer(const Duration(milliseconds: 150), publishNow);
  }

  /// Rebuilds [links] / [stats] immediately (also used by tests).
  void publishNow() {
    if (_disposed) return;
    links.value = [
      for (final l in _links.values)
        LinkView(
            info: l.info,
            peer: l.peer,
            readyAt: l.readyAt,
            blocked: _blocked.contains(l.info.linkId)),
    ];
    stats.value = MeshStats(
      outboxPending: _outbox.values
          .where((e) => !e.status.reachedRescue && e.status != SosStatus.failed)
          .length,
      relayHeld: _relay.values.where((e) => !e.delivered).length,
      relayAwaitingNextHop: _relay.values
          .where((e) => e.canForward && !e.delivered && e.custodyBy.isEmpty)
          .length,
      forwarded: _forwardedTotal,
      duplicates: _duplicatesTotal,
      rejected: _rejectedTotal,
      inbox: _inbox.length,
      readyLinks: _links.values.where((l) => l.info.isReady).length,
    );
    for (final t in _transportSubs.keys) {
      if (t.side == LinkSide.peripheral) unawaited(t.setControlValue(controlValue()));
    }
  }
}
