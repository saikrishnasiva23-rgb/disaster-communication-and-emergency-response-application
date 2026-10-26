import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show HandshakeException, HttpDate, HttpException, SocketException, TlsException;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/backend_config.dart';
import 'local_store.dart';
import 'net_log.dart';

// Cloud sync for the Windows rescue console.
//
// The console stores every SOS it receives over BLE locally (MeshNode's
// inbox). When internet is available, this service uploads those SOS and
// the rescuers' status changes to the FastAPI backend
// (backend/docs/API_CONTRACT.md, section 5 "Offline sync").
//
// The cloud is NEVER part of the BLE path: nothing here is awaited by the
// mesh, a cloud failure only changes [CloudSyncService.status], and the
// phone's "Help is coming" state comes only from the BLE ACK.
//
// Credentials and the access token live in memory only -- they are never
// written to LocalStore and never logged.

/// Allowed by the backend's `ClientId` type: `^[A-Za-z0-9_.:-]{1,64}$`.
final RegExp _clientIdPattern = RegExp(r'^[A-Za-z0-9_.:\-]{1,64}$');

bool _isClientId(String? value) =>
    value != null && _clientIdPattern.hasMatch(value);

String _utcIso(DateTime time) => time.toUtc().toIso8601String();

DateTime? _parseTime(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

double? _parseDouble(Object? value) => value is num ? value.toDouble() : null;

int? _parseInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// Caps [value] at [max] UTF-16 code units without splitting a surrogate
/// pair (the backend counts code points, so this never exceeds its limit).
String _cap(String value, int max) {
  if (value.length <= max) return value;
  var end = max;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return value.substring(0, end);
}

String _short(String? value, [int max = 160]) {
  if (value == null) return '';
  final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= max ? flat : '${flat.substring(0, max)}...';
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

/// One SOS the rescue console received over BLE, as it is uploaded to the
/// cloud (`EmergencyCreate` / `SyncEmergencyItem` on the backend).
@immutable
class CloudEmergencyRecord {
  const CloudEmergencyRecord({
    required this.clientEmergencyId,
    required this.emergencyType,
    required this.occurredAt,
    required this.originDeviceId,
    this.description = '',
    this.peopleCount = 1,
    this.injured = false,
    this.trapped = false,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.fixTime,
    this.senderDisplayName = '',
    this.relayedByDeviceId,
    this.relayedByName,
    this.hopCount = 0,
    this.clientPriority,
    this.localBleAcknowledged = false,
    this.localBleAcknowledgedAt,
  });

  /// The BLE SOS packet id -- the cloud's idempotency key.
  final String clientEmergencyId;

  /// The app's label (e.g. 'Medical Emergency', 'Flood', 'Trapped Person',
  /// 'General Emergency'); the backend normalizes labels and aliases.
  final String emergencyType;
  final String description;
  final int peopleCount;
  final bool injured;
  final bool trapped;

  /// When the SOS was created on the phone.
  final DateTime occurredAt;
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final DateTime? fixTime;

  /// The stable per-install id of the phone that raised the SOS.
  final String originDeviceId;
  final String senderDisplayName;
  final String? relayedByDeviceId;
  final String? relayedByName;
  final int hopCount;

  /// 'LOW' | 'MEDIUM' | 'HIGH' | 'CRITICAL' | null (reference only -- the
  /// server computes its own priority).
  final String? clientPriority;

  /// Did this console's BLE ACK reach the phone (platform-confirmed)?
  final bool localBleAcknowledged;
  final DateTime? localBleAcknowledgedAt;

  static const Set<String> validPriorities = {'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'};

  /// Max hop count the backend accepts.
  static const int maxHopCount = 16;

  /// True only for a real GPS fix: both coordinates present, finite, in
  /// range and not the 0,0 placeholder.
  bool get hasLocation {
    final lat = latitude;
    final lon = longitude;
    if (lat == null || lon == null) return false;
    if (!lat.isFinite || !lon.isFinite) return false;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return false;
    if (lat == 0 && lon == 0) return false;
    return true;
  }

  bool get _isTrappedType {
    final key = emergencyType.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    return key == 'trapped' || key == 'trappedperson';
  }

  String? get _normalizedPriority {
    final p = clientPriority?.trim().toUpperCase();
    return p != null && validPriorities.contains(p) ? p : null;
  }

  /// The JSON body item for `POST /api/v1/sync/emergencies`, matching the
  /// backend's `EmergencyCreate` exactly:
  ///   * `location` is omitted when there was no real fix (never 0,0);
  ///   * `source` is `BLE_RELAY` when the SOS arrived over relay hops;
  ///   * `hop_count` is capped at 16, `client_priority` only when valid;
  ///   * text is capped at the backend's maximum lengths, ids that do not
  ///     fit the backend's id format are left out rather than altered.
  Map<String, dynamic> toApiJson() {
    final json = <String, dynamic>{
      'client_emergency_id': clientEmergencyId,
      'emergency_type': emergencyType.trim(),
      'people_count': peopleCount.clamp(1, 10000),
      'injured': injured,
      'trapped': trapped || _isTrappedType,
      'occurred_at': _utcIso(occurredAt),
      'hop_count': hopCount.clamp(0, maxHopCount),
      'source': hopCount > 0 ? 'BLE_RELAY' : 'BLE',
      'local_ble_acknowledged': localBleAcknowledged,
    };
    if (description.trim().isNotEmpty) {
      json['description'] = _cap(description, 2000);
    }
    if (hasLocation) {
      final accuracy = accuracyMeters;
      json['location'] = <String, dynamic>{
        'latitude': latitude,
        'longitude': longitude,
        if (accuracy != null && accuracy.isFinite && accuracy >= 0 && accuracy <= 100000)
          'accuracy_m': accuracy,
        if (fixTime != null) 'recorded_at': _utcIso(fixTime!),
      };
    }
    if (_isClientId(originDeviceId)) json['origin_device_id'] = originDeviceId;
    if (senderDisplayName.trim().isNotEmpty) {
      json['sender_display_name'] = _cap(senderDisplayName, 120);
    }
    if (_isClientId(relayedByDeviceId)) {
      json['relayed_by_device_id'] = relayedByDeviceId;
    }
    final relayName = relayedByName;
    if (relayName != null && relayName.trim().isNotEmpty) {
      json['relayed_by_name'] = _cap(relayName, 120);
    }
    final priority = _normalizedPriority;
    if (priority != null) json['client_priority'] = priority;
    if (localBleAcknowledged && localBleAcknowledgedAt != null) {
      json['local_ble_acknowledged_at'] = _utcIso(localBleAcknowledgedAt!);
    }
    return json;
  }

  /// Local persistence form.
  Map<String, dynamic> toJson() => {
        'clientEmergencyId': clientEmergencyId,
        'emergencyType': emergencyType,
        'description': description,
        'peopleCount': peopleCount,
        'injured': injured,
        'trapped': trapped,
        'occurredAt': _utcIso(occurredAt),
        'latitude': latitude,
        'longitude': longitude,
        'accuracyMeters': accuracyMeters,
        'fixTime': fixTime == null ? null : _utcIso(fixTime!),
        'originDeviceId': originDeviceId,
        'senderDisplayName': senderDisplayName,
        'relayedByDeviceId': relayedByDeviceId,
        'relayedByName': relayedByName,
        'hopCount': hopCount,
        'clientPriority': clientPriority,
        'localBleAcknowledged': localBleAcknowledged,
        'localBleAcknowledgedAt':
            localBleAcknowledgedAt == null ? null : _utcIso(localBleAcknowledgedAt!),
      };

  /// Throws [FormatException] when a required field is missing.
  factory CloudEmergencyRecord.fromJson(Map<String, dynamic> json) {
    final id = json['clientEmergencyId'];
    final type = json['emergencyType'];
    final occurred = _parseTime(json['occurredAt']);
    if (id is! String || id.isEmpty || type is! String || occurred == null) {
      throw const FormatException('CloudEmergencyRecord: missing required field');
    }
    return CloudEmergencyRecord(
      clientEmergencyId: id,
      emergencyType: type,
      description: json['description'] as String? ?? '',
      peopleCount: _parseInt(json['peopleCount']) ?? 1,
      injured: json['injured'] == true,
      trapped: json['trapped'] == true,
      occurredAt: occurred,
      latitude: _parseDouble(json['latitude']),
      longitude: _parseDouble(json['longitude']),
      accuracyMeters: _parseDouble(json['accuracyMeters']),
      fixTime: _parseTime(json['fixTime']),
      originDeviceId: json['originDeviceId'] as String? ?? '',
      senderDisplayName: json['senderDisplayName'] as String? ?? '',
      relayedByDeviceId: json['relayedByDeviceId'] as String?,
      relayedByName: json['relayedByName'] as String?,
      hopCount: _parseInt(json['hopCount']) ?? 0,
      clientPriority: json['clientPriority'] as String?,
      localBleAcknowledged: json['localBleAcknowledged'] == true,
      localBleAcknowledgedAt: _parseTime(json['localBleAcknowledgedAt']),
    );
  }

  @override
  String toString() => 'CloudEmergencyRecord($clientEmergencyId)';
}

/// A status change a rescuer made on the console (possibly offline).
@immutable
class CloudStatusUpdate {
  const CloudStatusUpdate({
    required this.updateId,
    required this.clientEmergencyId,
    required this.consoleStatus,
    required this.changedAt,
    this.reason,
  });

  /// Idempotency key of this change (applied at most once by the cloud).
  final String updateId;
  final String clientEmergencyId;

  /// 'ACKNOWLEDGED' | 'ASSIGNED' | 'IN_PROGRESS' | 'RESCUED'.
  final String consoleStatus;
  final DateTime changedAt;
  final String? reason;

  static const Set<String> validStatuses = {
    'ACKNOWLEDGED',
    'ASSIGNED',
    'IN_PROGRESS',
    'RESCUED',
  };

  String get normalizedStatus => consoleStatus.trim().toUpperCase();

  Map<String, dynamic> toJson() => {
        'updateId': updateId,
        'clientEmergencyId': clientEmergencyId,
        'consoleStatus': consoleStatus,
        'changedAt': _utcIso(changedAt),
        'reason': reason,
      };

  /// Throws [FormatException] when a required field is missing.
  factory CloudStatusUpdate.fromJson(Map<String, dynamic> json) {
    final id = json['updateId'];
    final emergency = json['clientEmergencyId'];
    final status = json['consoleStatus'];
    final changed = _parseTime(json['changedAt']);
    if (id is! String ||
        emergency is! String ||
        status is! String ||
        changed == null) {
      throw const FormatException('CloudStatusUpdate: missing required field');
    }
    return CloudStatusUpdate(
      updateId: id,
      clientEmergencyId: emergency,
      consoleStatus: status,
      changedAt: changed,
      reason: json['reason'] as String?,
    );
  }

  @override
  String toString() => 'CloudStatusUpdate($updateId $consoleStatus)';
}

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------

enum CloudSyncPhase {
  /// No cloud credentials set.
  notConfigured,

  /// Configured; waiting for the next attempt.
  idle,

  /// The cloud could not be reached (network error / timeout). BLE is
  /// unaffected; the queue is retried with exponential backoff.
  offline,
  authenticating,
  syncing,

  /// Every queued item has a final result.
  upToDate,

  /// The cloud rejected the credentials. Not retried until they change.
  authFailed,

  /// The cloud answered with an error (5xx, unexpected response, rate
  /// limit...). Retried with backoff; [CloudSyncStatus.lastError] says why.
  error,
}

extension CloudSyncPhaseLabel on CloudSyncPhase {
  String get label => switch (this) {
        CloudSyncPhase.notConfigured => 'NOT CONFIGURED',
        CloudSyncPhase.idle => 'IDLE',
        CloudSyncPhase.offline => 'OFFLINE',
        CloudSyncPhase.authenticating => 'AUTHENTICATING',
        CloudSyncPhase.syncing => 'SYNCING',
        CloudSyncPhase.upToDate => 'UP TO DATE',
        CloudSyncPhase.authFailed => 'LOGIN FAILED',
        CloudSyncPhase.error => 'ERROR',
      };
}

@immutable
class CloudSyncStatus {
  const CloudSyncStatus({
    required this.phase,
    required this.baseUrl,
    this.pending = 0,
    this.synced = 0,
    this.conflicts = 0,
    this.invalid = 0,
    this.statusesDone = 0,
    this.skipped = 0,
    this.lastError,
    this.lastSyncAt,
    this.nextRetryAt,
    this.storageError,
  });

  final CloudSyncPhase phase;

  /// Emergencies + status updates still waiting for a cloud result.
  final int pending;

  /// Emergencies stored on the cloud (created or already there).
  final int synced;

  /// Emergencies + status updates the cloud reported as conflicting.
  final int conflicts;

  /// Emergencies + status updates the cloud rejected (invalid / not found).
  final int invalid;

  /// Status updates the cloud applied (or already had).
  final int statusesDone;

  /// Status updates that could not be sent (e.g. no rescue team).
  final int skipped;

  /// Human-readable reason of the last failed attempt (null after success).
  final String? lastError;

  /// Last time a sync pass reached the cloud and finished.
  final DateTime? lastSyncAt;

  /// When the next automatic attempt is due after a failure.
  final DateTime? nextRetryAt;

  /// Set when the queue could not be saved locally (it is then kept in
  /// memory only).
  final String? storageError;
  final String baseUrl;

  @override
  String toString() =>
      'CloudSyncStatus(${phase.label} pending=$pending synced=$synced '
      'conflicts=$conflicts invalid=$invalid)';
}

enum CloudItemKind { emergency, status }

enum CloudItemPhase {
  /// Waiting to be sent (or for its emergency to be synced first).
  pending,

  /// Emergency stored on the cloud (`created` or `duplicate`).
  synced,

  /// Status update applied by the cloud (`applied` or `duplicate`).
  done,

  /// The cloud kept a different version. Not retried.
  conflict,

  /// The cloud rejected it (see errorCode). Not retried.
  invalid,

  /// Status update for an emergency the cloud does not know. Not retried.
  notFound,

  /// Status update that could not be expressed on the cloud. Not retried.
  skipped,
}

/// Per-item cloud state. In [CloudSyncService.items] an emergency is keyed
/// by its clientEmergencyId; a status update by `status:<updateId>`.
@immutable
class CloudItemState {
  const CloudItemState({
    required this.key,
    required this.kind,
    required this.clientEmergencyId,
    required this.phase,
    required this.queuedAt,
    this.updateId,
    this.result,
    this.errorCode,
    this.errorMessage,
    this.note,
    this.attempts = 0,
    this.lastAttemptAt,
    this.finishedAt,
    this.serverEmergencyId,
    this.serverStatus,
    this.sentStatus,
  });

  static String statusKey(String updateId) => 'status:$updateId';

  final String key;
  final CloudItemKind kind;
  final String clientEmergencyId;
  final String? updateId;
  final CloudItemPhase phase;
  final DateTime queuedAt;

  /// The cloud's per-item result string (created, duplicate, applied...).
  final String? result;
  final String? errorCode;
  final String? errorMessage;

  /// Extra information, e.g. "ASSIGNED sent as ACKNOWLEDGED".
  final String? note;
  final int attempts;
  final DateTime? lastAttemptAt;
  final DateTime? finishedAt;
  final String? serverEmergencyId;

  /// The emergency's status on the cloud as last reported.
  final String? serverStatus;

  /// Status updates: the cloud status actually sent.
  final String? sentStatus;

  bool get isPending => phase == CloudItemPhase.pending;
  bool get isFinal => !isPending;

  CloudItemState copyWith({
    CloudItemPhase? phase,
    String? result,
    String? errorCode,
    String? errorMessage,
    String? note,
    int? attempts,
    DateTime? lastAttemptAt,
    DateTime? finishedAt,
    String? serverEmergencyId,
    String? serverStatus,
    String? sentStatus,
    bool clearError = false,
    bool clearResult = false,
    bool clearNote = false,
  }) =>
      CloudItemState(
        key: key,
        kind: kind,
        clientEmergencyId: clientEmergencyId,
        updateId: updateId,
        phase: phase ?? this.phase,
        queuedAt: queuedAt,
        result: clearResult ? result : (result ?? this.result),
        errorCode: clearError ? errorCode : (errorCode ?? this.errorCode),
        errorMessage: clearError ? errorMessage : (errorMessage ?? this.errorMessage),
        note: clearNote ? note : (note ?? this.note),
        attempts: attempts ?? this.attempts,
        lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
        finishedAt: clearResult ? finishedAt : (finishedAt ?? this.finishedAt),
        serverEmergencyId: serverEmergencyId ?? this.serverEmergencyId,
        serverStatus: serverStatus ?? this.serverStatus,
        sentStatus: sentStatus ?? this.sentStatus,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'kind': kind.name,
        'clientEmergencyId': clientEmergencyId,
        'updateId': updateId,
        'phase': phase.name,
        'queuedAt': _utcIso(queuedAt),
        'result': result,
        'errorCode': errorCode,
        'errorMessage': errorMessage,
        'note': note,
        'attempts': attempts,
        'lastAttemptAt': lastAttemptAt == null ? null : _utcIso(lastAttemptAt!),
        'finishedAt': finishedAt == null ? null : _utcIso(finishedAt!),
        'serverEmergencyId': serverEmergencyId,
        'serverStatus': serverStatus,
        'sentStatus': sentStatus,
      };

  /// Throws [FormatException] when a required field is missing.
  factory CloudItemState.fromJson(Map<String, dynamic> json) {
    final key = json['key'];
    final emergency = json['clientEmergencyId'];
    final kind = CloudItemKind.values.asNameMap()[json['kind']];
    final phase = CloudItemPhase.values.asNameMap()[json['phase']];
    if (key is! String || emergency is! String || kind == null || phase == null) {
      throw const FormatException('CloudItemState: missing required field');
    }
    return CloudItemState(
      key: key,
      kind: kind,
      clientEmergencyId: emergency,
      updateId: json['updateId'] as String?,
      phase: phase,
      queuedAt: _parseTime(json['queuedAt']) ?? DateTime.now(),
      result: json['result'] as String?,
      errorCode: json['errorCode'] as String?,
      errorMessage: json['errorMessage'] as String?,
      note: json['note'] as String?,
      attempts: _parseInt(json['attempts']) ?? 0,
      lastAttemptAt: _parseTime(json['lastAttemptAt']),
      finishedAt: _parseTime(json['finishedAt']),
      serverEmergencyId: json['serverEmergencyId'] as String?,
      serverStatus: json['serverStatus'] as String?,
      sentStatus: json['sentStatus'] as String?,
    );
  }

  @override
  String toString() => 'CloudItemState($key ${phase.name}'
      '${errorCode == null ? '' : ' $errorCode'})';
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

class _EmergencyEntry {
  _EmergencyEntry(this.record, this.state);
  CloudEmergencyRecord record;
  CloudItemState state;
}

class _StatusEntry {
  _StatusEntry(this.update, this.state);
  CloudStatusUpdate update;
  CloudItemState state;
}

enum _FailureKind { offline, rateLimited, authFailed, error }

class _SyncFailure implements Exception {
  _SyncFailure(this.kind, this.reason, {this.retryAfter});

  final _FailureKind kind;
  final String reason;
  final Duration? retryAfter;

  @override
  String toString() => '_SyncFailure(${kind.name}: $reason)';
}

/// A decoded `{success, data, message}` / `{success:false, error}` envelope.
class _ApiResponse {
  _ApiResponse(this.statusCode, this.headers, this.body);

  final int statusCode;
  final Map<String, String> headers;
  final Map<String, dynamic>? body;

  factory _ApiResponse.from(http.Response response) {
    Map<String, dynamic>? body;
    try {
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      final decoded = text.trim().isEmpty ? null : jsonDecode(text);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      body = null;
    }
    return _ApiResponse(response.statusCode, response.headers, body);
  }

  bool get isJsonEnvelope => body != null && body!['success'] is bool;

  bool get ok =>
      statusCode >= 200 && statusCode < 300 && body?['success'] == true;

  Object? get data => body?['data'];

  Map<String, dynamic>? get _error {
    final e = body?['error'];
    return e is Map<String, dynamic> ? e : null;
  }

  String? get errorCode => _error?['code'] as String?;

  String? get errorMessage => _error?['message'] as String?;

  Object? get errorDetails => _error?['details'];

  String? header(String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  /// "HTTP 503 DATABASE_UNAVAILABLE: The database is temporarily ..."
  String describe() {
    if (!isJsonEnvelope) {
      return 'HTTP $statusCode with an unexpected (non-JSON) response';
    }
    final code = errorCode;
    final message = errorMessage;
    if (code == null && message == null) return 'HTTP $statusCode';
    return 'HTTP $statusCode ${code ?? ''}'
        '${message == null ? '' : ': ${_short(message)}'}';
  }
}

class _TeamInfo {
  const _TeamInfo({required this.userId, this.teamId, this.teamName, this.note});

  final String userId;
  final String? teamId;
  final String? teamName;
  final String? note;
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Uploads the SOS the rescue console received over BLE (and the rescuers'
/// status changes) to the FastAPI cloud backend whenever it is reachable.
///
/// * Queue + per-item states persist in the LocalStore document
///   'cloud_sync' after every change, so a restart never loses or
///   duplicates work (uploads are idempotent per clientEmergencyId).
/// * Credentials are kept in memory only (set them after the rescuer logs
///   in); the access token too. Neither is ever persisted or logged.
/// * Never throws out of its public methods; failures are reported through
///   [status] with a human-readable reason.
class CloudSyncService {
  CloudSyncService({
    http.Client? client,
    String? baseUrl,
    this.interval = const Duration(seconds: 20),
    this.requestTimeout = const Duration(seconds: 8),
    this.minBackoff = const Duration(seconds: 5),
    this.maxBackoff = const Duration(minutes: 2),
    DateTime Function()? clock,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _baseUrl = _normalizeBase(baseUrl ?? BackendConfig.baseUrl),
        _clock = clock ?? DateTime.now {
    _status = ValueNotifier(_snapshot());
  }

  static final CloudSyncService instance = CloudSyncService();

  /// LocalStore document holding the queue and item states.
  static const String documentName = 'cloud_sync';

  static const int defaultBatchSize = 100;

  /// Finished items kept per kind (oldest finished ones are pruned).
  static const int maxFinishedItems = 5000;

  static const Set<String> _reloginCodes = {
    'TOKEN_EXPIRED',
    'INVALID_TOKEN',
    'NOT_AUTHENTICATED',
    'AUTHENTICATION_FAILED',
  };

  final Duration interval;
  final Duration requestTimeout;
  final Duration minBackoff;
  final Duration maxBackoff;

  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;
  String _baseUrl;

  late final ValueNotifier<CloudSyncStatus> _status;
  final StreamController<CloudItemState> _changes =
      StreamController<CloudItemState>.broadcast();

  // Insertion-ordered: uploads go oldest-queued first.
  final Map<String, _EmergencyEntry> _emergencies = {};
  final Map<String, _StatusEntry> _statuses = {};

  // Memory only.
  String? _username;
  String? _password;
  String? _token;
  DateTime? _tokenExpiresAt;
  String? _loginUserId;
  _TeamInfo? _team;
  int _credentialEpoch = 0;
  bool _authBlocked = false;

  String? _deviceId;
  int _batchSize = defaultBatchSize;

  CloudSyncPhase _phase = CloudSyncPhase.notConfigured;
  String? _lastError;
  DateTime? _lastSyncAt;
  String? _storageError;

  int _failures = 0;
  DateTime? _retryAt;
  DateTime? _rateLimitedUntil;
  String _stage = 'upload';

  Future<void>? _loading;
  Future<void>? _inFlight;
  bool _rerun = false;
  bool _started = false;
  bool _disposed = false;
  Timer? _timer;
  Timer? _retryTimer;

  static String _normalizeBase(String url) {
    var value = url.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  // -- Public API -----------------------------------------------------------

  ValueListenable<CloudSyncStatus> get status => _status;

  String get baseUrl => _baseUrl;

  /// Every item's cloud state: emergencies keyed by clientEmergencyId,
  /// status updates by `status:<updateId>`.
  Map<String, CloudItemState> get items => Map.unmodifiable({
        for (final e in _emergencies.values) e.state.key: e.state,
        for (final s in _statuses.values) s.state.key: s.state,
      });

  CloudItemState? emergencyState(String clientEmergencyId) =>
      _emergencies[clientEmergencyId]?.state;

  CloudItemState? statusState(String updateId) => _statuses[updateId]?.state;

  /// Each per-item state change.
  Stream<CloudItemState> get changes => _changes.stream;

  bool get hasCredentials => _username != null && _password != null;

  /// Loads the queue from LocalStore. Idempotent; every other method awaits
  /// it, so the persisted queue is never overwritten by an empty one.
  Future<void> init() => _loading ??= _load();

  /// Cloud login for this session. Kept in memory only -- never persisted,
  /// never logged. Changing them lifts an [CloudSyncPhase.authFailed] stop.
  void setCredentials(String username, String password) {
    final user = username.trim();
    if (user.isEmpty || password.isEmpty) {
      clearCredentials();
      return;
    }
    final changed = user != _username || password != _password;
    _username = user;
    _password = password;
    if (changed) {
      _credentialEpoch++;
      _resetSession();
      _authBlocked = false;
      _failures = 0;
      _retryAt = null;
      _retryTimer?.cancel();
      if (_phase == CloudSyncPhase.notConfigured ||
          _phase == CloudSyncPhase.authFailed) {
        _phase = CloudSyncPhase.idle;
        _lastError = null;
      }
      NetLog.sync('Cloud credentials set (memory only)');
    }
    _publish();
    if (changed && _started) unawaited(syncNow());
  }

  void clearCredentials() {
    final had = _username != null || _password != null || _token != null;
    _username = null;
    _password = null;
    _credentialEpoch++;
    _resetSession();
    _authBlocked = false;
    _phase = CloudSyncPhase.notConfigured;
    _lastError = null;
    _retryAt = null;
    _retryTimer?.cancel();
    if (had) NetLog.sync('Cloud credentials cleared');
    _publish();
  }

  /// The console's stable device id, sent as `device_id`. An id the
  /// backend would reject is left out (with a log line) instead of altered.
  void setDeviceId(String deviceId) {
    final id = deviceId.trim();
    if (_isClientId(id)) {
      _deviceId = id;
    } else {
      _deviceId = null;
      NetLog.sync('Console device id is not a valid cloud id -- uploading without device_id');
    }
  }

  /// Points the service at another backend (drops the session).
  void setBaseUrl(String baseUrl) {
    final next = _normalizeBase(baseUrl);
    if (next.isEmpty || next == _baseUrl) return;
    _baseUrl = next;
    _resetSession();
    _publish();
    NetLog.sync('Cloud base URL set to $next');
  }

  /// Queues one SOS for upload. Idempotent per clientEmergencyId:
  ///   * pending -> the record is replaced by the newer one;
  ///   * synced -> ignored, except when the BLE ACK was confirmed after the
  ///     upload (it is re-sent once so the cloud records the ACK; the
  ///     server answers `duplicate`);
  ///   * conflict -> ignored (the server keeps its copy);
  ///   * invalid -> re-queued only if the content changed.
  Future<void> enqueueEmergency(CloudEmergencyRecord record) async {
    try {
      await init();
      final id = record.clientEmergencyId;
      final now = _clock();
      final existing = _emergencies[id];
      CloudItemState state;
      if (existing == null) {
        state = CloudItemState(
          key: id,
          kind: CloudItemKind.emergency,
          clientEmergencyId: id,
          phase: CloudItemPhase.pending,
          queuedAt: now,
        );
        if (!_isClientId(id)) {
          state = state.copyWith(
            phase: CloudItemPhase.invalid,
            errorCode: 'INVALID_CLIENT_ID',
            errorMessage: 'The SOS id does not fit the cloud id format '
                '(letters, digits, _ . : -, max 64).',
            finishedAt: now,
          );
          NetLog.sync('Upload rejected locally: SOS id is not a valid cloud id');
        } else {
          NetLog.sync('Upload queued $id');
        }
        _emergencies[id] = _EmergencyEntry(record, state);
      } else {
        switch (existing.state.phase) {
          case CloudItemPhase.pending:
            existing.record = record;
            state = existing.state;
            NetLog.sync('Upload queued $id (updated)');
          case CloudItemPhase.synced:
            final ackNews =
                record.localBleAcknowledged && !existing.record.localBleAcknowledged;
            if (!ackNews) return;
            existing.record = record;
            state = existing.state.copyWith(
              phase: CloudItemPhase.pending,
              note: 'BLE ACK confirmed after upload -- re-sending',
            );
            existing.state = state;
            NetLog.sync('Upload queued $id (BLE ACK update)');
          case CloudItemPhase.invalid:
            final changed = jsonEncode(record.toApiJson()) !=
                jsonEncode(existing.record.toApiJson());
            if (!changed || !_isClientId(id)) return;
            existing.record = record;
            state = existing.state.copyWith(
              phase: CloudItemPhase.pending,
              clearError: true,
              clearResult: true,
            );
            existing.state = state;
            NetLog.sync('Upload queued $id (changed after rejection)');
          default:
            return;
        }
      }
      _emit(state);
      _publish();
      await _persist();
      _kick();
    } catch (e) {
      NetLog.sync('Upload queue error (${e.runtimeType})');
    }
  }

  /// Queues one console status change. Idempotent per updateId (a pending
  /// update is replaced; a finished one is kept). Sent only once its
  /// emergency is synced, oldest changedAt first.
  Future<void> enqueueStatus(CloudStatusUpdate update) async {
    try {
      await init();
      final key = update.updateId;
      final existing = _statuses[key];
      if (existing != null && existing.state.isFinal) return;
      final now = _clock();
      var state = existing?.state ??
          CloudItemState(
            key: CloudItemState.statusKey(key),
            kind: CloudItemKind.status,
            clientEmergencyId: update.clientEmergencyId,
            updateId: key,
            phase: CloudItemPhase.pending,
            queuedAt: now,
          );
      String? problem;
      if (!_isClientId(update.updateId)) {
        problem = 'The update id does not fit the cloud id format.';
      } else if (!_isClientId(update.clientEmergencyId)) {
        problem = 'The SOS id does not fit the cloud id format.';
      } else if (!CloudStatusUpdate.validStatuses.contains(update.normalizedStatus)) {
        problem = 'Unsupported console status.';
      }
      if (problem != null) {
        state = state.copyWith(
          phase: CloudItemPhase.invalid,
          errorCode: 'INVALID_STATUS_UPDATE',
          errorMessage: problem,
          finishedAt: now,
        );
        NetLog.sync('Status sync rejected locally: $problem');
      } else {
        NetLog.sync('Status sync queued ${update.normalizedStatus} for '
            '${update.clientEmergencyId}');
      }
      if (existing == null) {
        _statuses[key] = _StatusEntry(update, state);
      } else {
        existing
          ..update = update
          ..state = state;
      }
      _emit(state);
      _publish();
      await _persist();
      _kick();
    } catch (e) {
      NetLog.sync('Status queue error (${e.runtimeType})');
    }
  }

  /// One sync pass now (also while backing off after a network error, but
  /// never inside a server Retry-After window or after the credentials
  /// were rejected). Concurrent calls share the running pass. Never throws.
  Future<void> syncNow() {
    final running = _inFlight;
    if (running != null) {
      _rerun = true;
      return running;
    }
    final run = _runPasses();
    _inFlight = run;
    return run;
  }

  /// Periodic sync every [interval] plus an immediate attempt.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _timer = Timer.periodic(interval, (_) => _tick());
    _tick();
  }

  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Stops timers, closes the change stream and the owned HTTP client.
  void dispose() {
    stop();
    _disposed = true;
    _changes.close();
    if (_ownsClient) _client.close();
  }

  // -- Loading / persistence -----------------------------------------------

  Future<void> _load() async {
    try {
      final doc = await LocalStore.read(documentName);
      var skipped = 0;
      if (doc != null) {
        final emergencies = doc['emergencies'];
        if (emergencies is List) {
          for (final raw in emergencies) {
            try {
              final map = raw as Map<String, dynamic>;
              final record = CloudEmergencyRecord.fromJson(
                  map['record'] as Map<String, dynamic>);
              final state =
                  CloudItemState.fromJson(map['state'] as Map<String, dynamic>);
              _emergencies.putIfAbsent(
                  record.clientEmergencyId, () => _EmergencyEntry(record, state));
            } catch (_) {
              skipped++;
            }
          }
        }
        final statuses = doc['statuses'];
        if (statuses is List) {
          for (final raw in statuses) {
            try {
              final map = raw as Map<String, dynamic>;
              final update = CloudStatusUpdate.fromJson(
                  map['update'] as Map<String, dynamic>);
              final state =
                  CloudItemState.fromJson(map['state'] as Map<String, dynamic>);
              _statuses.putIfAbsent(update.updateId, () => _StatusEntry(update, state));
            } catch (_) {
              skipped++;
            }
          }
        }
      }
      final pending = _emergencies.values.where((e) => e.state.isPending).length +
          _statuses.values.where((s) => s.state.isPending).length;
      NetLog.sync('Cloud queue loaded ($pending pending'
          '${skipped == 0 ? '' : ', $skipped unreadable entries skipped'})');
    } catch (e) {
      NetLog.sync('Cloud queue could not be loaded (${e.runtimeType}) -- starting empty');
    }
    _publish();
  }

  Map<String, dynamic> _document() => {
        'version': 1,
        'savedAt': _utcIso(_clock()),
        'emergencies': [
          for (final e in _emergencies.values)
            {'record': e.record.toJson(), 'state': e.state.toJson()},
        ],
        'statuses': [
          for (final s in _statuses.values)
            {'update': s.update.toJson(), 'state': s.state.toJson()},
        ],
      };

  Future<void> _persist() async {
    _prune();
    final ok = await LocalStore.write(documentName, _document());
    final next = ok ? null : (LocalStore.lastError ?? 'Could not save the cloud queue');
    if (next != _storageError) {
      _storageError = next;
      _publish();
    }
  }

  void _prune() {
    void pruneMap<T>(Map<String, T> map, CloudItemState Function(T) stateOf) {
      final finished = map.entries.where((e) => stateOf(e.value).isFinal).toList();
      final excess = finished.length - maxFinishedItems;
      if (excess <= 0) return;
      finished.sort((a, b) {
        final ta = stateOf(a.value).finishedAt ?? stateOf(a.value).queuedAt;
        final tb = stateOf(b.value).finishedAt ?? stateOf(b.value).queuedAt;
        return ta.compareTo(tb);
      });
      for (final entry in finished.take(excess)) {
        map.remove(entry.key);
      }
    }

    pruneMap<_EmergencyEntry>(_emergencies, (e) => e.state);
    pruneMap<_StatusEntry>(_statuses, (s) => s.state);
  }

  // -- Status publishing ----------------------------------------------------

  CloudSyncStatus _snapshot() {
    var pending = 0, synced = 0, conflicts = 0, invalid = 0, done = 0, skipped = 0;
    for (final e in _emergencies.values) {
      switch (e.state.phase) {
        case CloudItemPhase.pending:
          pending++;
        case CloudItemPhase.synced:
          synced++;
        case CloudItemPhase.conflict:
          conflicts++;
        case CloudItemPhase.invalid:
        case CloudItemPhase.notFound:
          invalid++;
        case CloudItemPhase.done:
        case CloudItemPhase.skipped:
          skipped++;
      }
    }
    for (final s in _statuses.values) {
      switch (s.state.phase) {
        case CloudItemPhase.pending:
          pending++;
        case CloudItemPhase.done:
        case CloudItemPhase.synced:
          done++;
        case CloudItemPhase.conflict:
          conflicts++;
        case CloudItemPhase.invalid:
        case CloudItemPhase.notFound:
          invalid++;
        case CloudItemPhase.skipped:
          skipped++;
      }
    }
    return CloudSyncStatus(
      phase: _phase,
      baseUrl: _baseUrl,
      pending: pending,
      synced: synced,
      conflicts: conflicts,
      invalid: invalid,
      statusesDone: done,
      skipped: skipped,
      lastError: _lastError,
      lastSyncAt: _lastSyncAt,
      nextRetryAt: _retryAt,
      storageError: _storageError,
    );
  }

  void _publish() {
    if (_disposed) return;
    _status.value = _snapshot();
  }

  void _setPhase(CloudSyncPhase phase) {
    _phase = phase;
    _publish();
  }

  void _emit(CloudItemState state) {
    if (!_changes.isClosed) _changes.add(state);
  }

  // -- Scheduling -----------------------------------------------------------

  void _tick({bool force = false}) {
    if (!_started || _disposed) return;
    final retryAt = _retryAt;
    if (!force && retryAt != null && _clock().isBefore(retryAt)) return;
    unawaited(syncNow());
  }

  /// A new item while started: try soon unless backing off.
  void _kick() {
    if (!_started || _disposed || _authBlocked || !hasCredentials) return;
    final retryAt = _retryAt;
    if (retryAt != null && _clock().isBefore(retryAt)) return;
    unawaited(syncNow());
  }

  void _scheduleRetry(Duration delay) {
    _retryAt = _clock().add(delay);
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_started && !_disposed) {
      _retryTimer = Timer(delay, () => _tick(force: true));
    }
  }

  Duration _backoff() {
    final factor = math.pow(2, math.max(0, _failures - 1)).toDouble();
    final ms = math.min(
      minBackoff.inMilliseconds * factor,
      maxBackoff.inMilliseconds.toDouble(),
    );
    return Duration(milliseconds: ms.round());
  }

  // -- Sync pass ------------------------------------------------------------

  Future<void> _runPasses() async {
    try {
      var passes = 0;
      do {
        _rerun = false;
        final ok = await _syncPass();
        if (!ok) break;
        passes++;
      } while (_rerun && passes < 3);
    } catch (e) {
      // _syncPass already catches everything; this is a last guard.
      NetLog.sync('Sync error (${e.runtimeType})');
    } finally {
      _inFlight = null;
    }
  }

  /// True when the pass finished without a failure.
  Future<bool> _syncPass() async {
    await init();
    if (_disposed) return false;
    if (!hasCredentials) {
      _setPhase(CloudSyncPhase.notConfigured);
      return false;
    }
    if (_authBlocked) {
      _setPhase(CloudSyncPhase.authFailed);
      return false;
    }
    final limited = _rateLimitedUntil;
    if (limited != null && _clock().isBefore(limited)) {
      _publish();
      return false;
    }
    await _resolveBlockedStatuses();
    if (!_hasWork()) {
      _finishOk(contactedCloud: false);
      return true;
    }
    try {
      _stage = 'upload';
      await _ensureToken();
      _setPhase(CloudSyncPhase.syncing);
      _stage = 'upload';
      await _uploadEmergencies();
      _stage = 'status';
      await _uploadStatuses();
      _finishOk(contactedCloud: true);
      return true;
    } on _SyncFailure catch (failure) {
      _onFailure(failure);
      return false;
    } catch (e) {
      _onFailure(_SyncFailure(
          _FailureKind.error, 'Unexpected sync error (${e.runtimeType})'));
      return false;
    }
  }

  bool _hasWork() =>
      _emergencies.values.any((e) => e.state.isPending) ||
      _statuses.values.any((s) => s.state.isPending && _emergencySynced(s));

  bool _emergencySynced(_StatusEntry s) =>
      _emergencies[s.update.clientEmergencyId]?.state.phase == CloudItemPhase.synced;

  void _finishOk({required bool contactedCloud}) {
    _failures = 0;
    _retryAt = null;
    _rateLimitedUntil = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _lastError = null;
    if (contactedCloud) _lastSyncAt = _clock();
    final anyPending = _emergencies.values.any((e) => e.state.isPending) ||
        _statuses.values.any((s) => s.state.isPending);
    _setPhase(anyPending ? CloudSyncPhase.idle : CloudSyncPhase.upToDate);
  }

  void _onFailure(_SyncFailure failure) {
    final what = switch (_stage) {
      'login' => 'Cloud login failed',
      'status' => 'Status sync failed',
      _ => 'Upload failed',
    };
    _lastError = failure.reason;
    switch (failure.kind) {
      case _FailureKind.authFailed:
        _authBlocked = true;
        _resetSession();
        _retryAt = null;
        _retryTimer?.cancel();
        NetLog.sync('$what: ${failure.reason} -- not retrying until the '
            'credentials change');
        _setPhase(CloudSyncPhase.authFailed);
      case _FailureKind.rateLimited:
        final wait = failure.retryAfter ?? const Duration(seconds: 30);
        _rateLimitedUntil = _clock().add(wait);
        _scheduleRetry(wait);
        NetLog.sync('$what: ${failure.reason} -- retrying in ${wait.inSeconds} s');
        _setPhase(CloudSyncPhase.error);
      case _FailureKind.offline:
        _failures++;
        final wait = _backoff();
        _scheduleRetry(wait);
        NetLog.sync('$what: ${failure.reason}');
        NetLog.sync('Cloud offline -- will retry in ${wait.inSeconds} s');
        _setPhase(CloudSyncPhase.offline);
      case _FailureKind.error:
        _failures++;
        final wait = _backoff();
        _scheduleRetry(wait);
        NetLog.sync('$what: ${failure.reason} -- retrying in ${wait.inSeconds} s');
        _setPhase(CloudSyncPhase.error);
    }
  }

  void _resetSession() {
    _token = null;
    _tokenExpiresAt = null;
    _loginUserId = null;
    _team = null;
  }

  // -- HTTP -----------------------------------------------------------------

  Future<_ApiResponse> _request(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    bool retried = false,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json; charset=utf-8';
    if (auth) headers['Authorization'] = 'Bearer ${_token ?? ''}';

    http.Response response;
    try {
      final Future<http.Response> future = method == 'GET'
          ? _client.get(uri, headers: headers)
          : _client.post(uri, headers: headers, body: jsonEncode(body));
      response = await future.timeout(requestTimeout);
    } on TimeoutException {
      throw _SyncFailure(_FailureKind.offline,
          'No response from the cloud within ${requestTimeout.inSeconds} s');
    } on SocketException catch (e) {
      throw _SyncFailure(_FailureKind.offline,
          'Network unreachable (${_short(e.osError?.message ?? e.message, 80)})');
    } on HandshakeException {
      throw _SyncFailure(_FailureKind.offline, 'TLS handshake with the cloud failed');
    } on TlsException {
      throw _SyncFailure(_FailureKind.offline, 'TLS error talking to the cloud');
    } on HttpException catch (e) {
      throw _SyncFailure(_FailureKind.offline, 'HTTP error (${_short(e.message, 80)})');
    } on http.ClientException catch (e) {
      throw _SyncFailure(_FailureKind.offline, 'Network error (${_short(e.message, 80)})');
    }

    final res = _ApiResponse.from(response);
    if (res.statusCode == 401 && auth) {
      final code = res.errorCode;
      if (!retried && (code == null || _reloginCodes.contains(code))) {
        NetLog.sync('Cloud session rejected (${code ?? 'HTTP 401'}) -- logging in again');
        await _login();
        return _request(method, path, body: body, auth: auth, retried: true);
      }
      throw _SyncFailure(
          _FailureKind.error, 'The cloud rejected a fresh session (${res.describe()})');
    }
    if (res.statusCode == 429) {
      throw _SyncFailure(_FailureKind.rateLimited, 'Rate limited by the cloud',
          retryAfter: _retryAfter(res));
    }
    return res;
  }

  Duration _retryAfter(_ApiResponse res) {
    const fallback = Duration(seconds: 30);
    const ceiling = Duration(hours: 1);
    Duration clamp(Duration d) => d < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : (d > ceiling ? ceiling : d);
    final raw = res.header('retry-after')?.trim();
    if (raw != null && raw.isNotEmpty) {
      final seconds = int.tryParse(raw);
      if (seconds != null && seconds >= 0) return clamp(Duration(seconds: seconds));
      try {
        return clamp(HttpDate.parse(raw).difference(DateTime.now()));
      } catch (_) {}
    }
    final details = res.errorDetails;
    if (details is Map) {
      final seconds = _parseInt(details['retry_after_seconds']);
      if (seconds != null && seconds >= 0) return clamp(Duration(seconds: seconds));
    }
    return fallback;
  }

  Future<void> _ensureToken() async {
    final token = _token;
    final expires = _tokenExpiresAt;
    if (token != null &&
        (expires == null ||
            _clock().isBefore(expires.subtract(const Duration(seconds: 30))))) {
      return;
    }
    await _login();
  }

  Future<void> _login() async {
    final previousStage = _stage;
    _stage = 'login';
    final epoch = _credentialEpoch;
    final user = _username;
    final pass = _password;
    if (user == null || pass == null) {
      throw _SyncFailure(_FailureKind.error, 'No cloud credentials');
    }
    _resetSession();
    _setPhase(CloudSyncPhase.authenticating);
    final res = await _request(
      'POST',
      BackendConfig.authLoginPath,
      body: {'username': user, 'password': pass},
      auth: false,
    );
    if (epoch != _credentialEpoch) {
      throw _SyncFailure(_FailureKind.error, 'Credentials changed during login');
    }
    if (res.ok) {
      final data = res.data;
      final token = data is Map ? data['access_token'] : null;
      if (token is! String || token.isEmpty) {
        throw _SyncFailure(_FailureKind.error, 'Login response had no access token');
      }
      _token = token;
      final expiresIn = data is Map ? _parseInt(data['expires_in']) : null;
      _tokenExpiresAt =
          expiresIn != null && expiresIn > 0 ? _clock().add(Duration(seconds: expiresIn)) : null;
      final loginUser = data is Map ? data['user'] : null;
      _loginUserId = loginUser is Map ? loginUser['id']?.toString() : null;
      _team = null; // team lookup is cached per login
      NetLog.sync('Cloud login ok');
      _stage = previousStage;
      if (_phase == CloudSyncPhase.authenticating) _setPhase(CloudSyncPhase.syncing);
      return;
    }
    if (res.statusCode == 401 || res.statusCode == 403 || res.statusCode == 422) {
      throw _SyncFailure(_FailureKind.authFailed,
          'Cloud login rejected (${res.errorCode ?? 'HTTP ${res.statusCode}'})');
    }
    throw _SyncFailure(_FailureKind.error, res.describe());
  }

  Map<String, dynamic> _batchBody(List<Map<String, dynamic>> items) => {
        if (_deviceId != null) 'device_id': _deviceId,
        'items': items,
      };

  /// Per-item validation errors in a 422 VALIDATION_ERROR: index -> fields.
  static Map<int, List<String>> _itemErrors(Object? details, int count) {
    final result = <int, List<String>>{};
    if (details is! List) return result;
    final pattern = RegExp(r'^items\.(\d+)(?:\.(.+))?$');
    for (final d in details) {
      if (d is! Map) continue;
      final field = d['field'];
      if (field is! String) continue;
      final m = pattern.firstMatch(field);
      if (m == null) continue;
      final index = int.tryParse(m.group(1)!);
      if (index == null || index < 0 || index >= count) continue;
      final name = m.group(2) ?? 'item';
      final message = d['message'] is String ? ' (${_short(d['message'] as String, 120)})' : '';
      result.putIfAbsent(index, () => []).add('$name$message');
    }
    return result;
  }

  /// Posts [chunk] to [path], handling a smaller server batch limit and
  /// per-item validation errors. [apply] returns how many entries got a
  /// result; zero is treated as an unusable response.
  Future<void> _postChunk<T>({
    required String path,
    required String label,
    required List<T> chunk,
    required Map<String, dynamic> Function(T) payload,
    required void Function(T, String code, String message) markInvalid,
    required int Function(List<T> sent, _ApiResponse res) apply,
  }) async {
    var items = List<T>.of(chunk);
    var guard = 0;
    while (items.isNotEmpty && guard++ <= chunk.length + 1) {
      final res = await _request('POST', path,
          body: _batchBody([for (final item in items) payload(item)]));
      if (res.ok) {
        if (apply(items, res) == 0) {
          throw _SyncFailure(
              _FailureKind.error, 'The cloud response did not cover the items sent');
        }
        _publish();
        await _persist();
        return;
      }
      if (res.statusCode == 422 && res.errorCode == 'BATCH_TOO_LARGE') {
        final details = res.errorDetails;
        final max = details is Map ? _parseInt(details['max_items']) : null;
        if (max != null && max >= 1 && max < items.length) {
          _batchSize = max;
          NetLog.sync('$label: the cloud accepts at most $max items per request -- splitting');
          items = items.sublist(0, max);
          continue;
        }
      }
      if (res.statusCode == 422 && res.errorCode == 'VALIDATION_ERROR') {
        final bad = _itemErrors(res.errorDetails, items.length);
        if (bad.isNotEmpty) {
          final rest = <T>[];
          for (var i = 0; i < items.length; i++) {
            final fields = bad[i];
            if (fields == null) {
              rest.add(items[i]);
            } else {
              markInvalid(items[i], 'VALIDATION_ERROR',
                  'Rejected by cloud validation: ${fields.join('; ')}');
            }
          }
          _publish();
          await _persist();
          items = rest;
          continue;
        }
      }
      throw _SyncFailure(_FailureKind.error, res.describe());
    }
  }

  // -- Emergencies ----------------------------------------------------------

  Future<void> _uploadEmergencies() async {
    while (true) {
      final pending = _emergencies.values
          .where((e) => e.state.isPending)
          .take(_batchSize)
          .toList();
      if (pending.isEmpty) return;
      final now = _clock();
      final sent = <String, CloudEmergencyRecord>{};
      for (final e in pending) {
        sent[e.record.clientEmergencyId] = e.record;
        e.state = e.state.copyWith(attempts: e.state.attempts + 1, lastAttemptAt: now);
      }
      await _postChunk<_EmergencyEntry>(
        path: BackendConfig.syncEmergenciesPath,
        label: 'Upload',
        chunk: pending,
        payload: (e) => sent[e.record.clientEmergencyId]!.toApiJson(),
        markInvalid: (e, code, message) {
          e.state = e.state.copyWith(
            phase: CloudItemPhase.invalid,
            result: 'invalid',
            errorCode: code,
            errorMessage: message,
            finishedAt: _clock(),
          );
          _emit(e.state);
          NetLog.sync('Upload invalid ${e.state.key} ($code) -- not retrying');
        },
        apply: (entries, res) => _applyEmergencyResults(entries, sent, res),
      );
    }
  }

  int _applyEmergencyResults(
    List<_EmergencyEntry> entries,
    Map<String, CloudEmergencyRecord> sent,
    _ApiResponse res,
  ) {
    final data = res.data;
    final results = data is Map ? data['results'] : null;
    if (results is! List) return 0;
    final byId = <String, Map>{};
    for (final r in results) {
      if (r is Map && r['client_emergency_id'] is String) {
        byId[r['client_emergency_id'] as String] = r;
      }
    }
    var created = 0, duplicate = 0, changed = 0;
    final now = _clock();
    for (final entry in entries) {
      final id = entry.record.clientEmergencyId;
      final r = byId[id];
      if (r == null) continue;
      final outcome = r['result'];
      final error = r['error'] is Map ? r['error'] as Map : null;
      final code = error?['code'] as String?;
      final message = error?['message'] as String?;
      final serverId = r['emergency_id']?.toString();
      final serverStatus = r['status']?.toString();
      switch (outcome) {
        case 'created':
        case 'duplicate':
          if (outcome == 'created') {
            created++;
          } else {
            duplicate++;
          }
          final replaced = !identical(entry.record, sent[id]);
          entry.state = entry.state.copyWith(
            phase: replaced ? CloudItemPhase.pending : CloudItemPhase.synced,
            result: outcome as String,
            finishedAt: replaced ? null : now,
            serverEmergencyId: serverId,
            serverStatus: serverStatus,
            note: replaced ? 'Updated while uploading -- re-sending' : null,
            clearError: true,
          );
        case 'conflict':
          entry.state = entry.state.copyWith(
            phase: CloudItemPhase.conflict,
            result: 'conflict',
            errorCode: code ?? 'IDEMPOTENCY_CONFLICT',
            errorMessage: message ??
                'The cloud already has a different emergency with this id.',
            finishedAt: now,
            serverEmergencyId: serverId,
          );
          NetLog.sync('Upload conflict $id (${code ?? 'IDEMPOTENCY_CONFLICT'}) '
              '-- cloud keeps its copy, not retrying');
        case 'invalid':
          entry.state = entry.state.copyWith(
            phase: CloudItemPhase.invalid,
            result: 'invalid',
            errorCode: code ?? 'INVALID',
            errorMessage: message ?? 'The cloud rejected this emergency.',
            finishedAt: now,
          );
          NetLog.sync('Upload invalid $id (${code ?? 'INVALID'}) -- not retrying');
        default:
          continue;
      }
      changed++;
      _emit(entry.state);
    }
    if (created + duplicate > 0) {
      NetLog.sync('Upload successful ($created created, $duplicate duplicate)');
    }
    if (changed > 0) {
      _publish();
      // Persisted before the next batch; awaited by the caller's loop via
      // _persistAfterApply.
      _pendingPersist = _persist();
    }
    return changed;
  }

  Future<void>? _pendingPersist;

  // -- Status updates -------------------------------------------------------

  /// Statuses whose emergency can never reach the cloud are marked skipped
  /// (they would otherwise stay pending forever).
  Future<void> _resolveBlockedStatuses() async {
    var changed = false;
    final now = _clock();
    for (final s in _statuses.values) {
      if (!s.state.isPending) continue;
      final emergency = _emergencies[s.update.clientEmergencyId]?.state.phase;
      if (emergency == CloudItemPhase.conflict || emergency == CloudItemPhase.invalid) {
        s.state = s.state.copyWith(
          phase: CloudItemPhase.skipped,
          errorCode: 'EMERGENCY_NOT_SYNCED',
          errorMessage: 'Its emergency was not accepted by the cloud '
              '(${emergency!.name}).',
          finishedAt: now,
        );
        _emit(s.state);
        changed = true;
        NetLog.sync('Status sync skipped ${s.update.updateId}: emergency ${emergency.name}');
      }
    }
    if (changed) {
      _publish();
      await _persist();
    }
  }

  Future<_TeamInfo> _ensureTeam() async {
    final cached = _team;
    if (cached != null) return cached;
    final me = await _request('GET', BackendConfig.authMePath);
    String? userId;
    if (me.ok && me.data is Map) userId = (me.data as Map)['id']?.toString();
    if (userId == null) {
      if (!me.ok) {
        throw _SyncFailure(
            _FailureKind.error, 'Could not read the cloud user (${me.describe()})');
      }
      userId = _loginUserId;
    }
    if (userId == null) {
      throw _SyncFailure(_FailureKind.error, 'The cloud user has no id');
    }
    final teams = await _request('GET', BackendConfig.rescueTeamsPath);
    _TeamInfo info;
    if (teams.statusCode == 403) {
      info = _TeamInfo(
          userId: userId, note: 'This cloud account cannot list rescue teams');
    } else if (!teams.ok || teams.data is! List) {
      throw _SyncFailure(
          _FailureKind.error, 'Could not list rescue teams (${teams.describe()})');
    } else {
      Map? match;
      final me0 = userId.toLowerCase();
      for (final t in teams.data as List) {
        if (t is! Map) continue;
        final members = t['members'];
        if (members is! List) continue;
        final isMember = members.any(
            (m) => m is Map && m['user_id']?.toString().toLowerCase() == me0);
        if (!isMember) continue;
        if (match == null || (match['is_active'] == false && t['is_active'] != false)) {
          match = t;
        }
      }
      info = match == null
          ? _TeamInfo(userId: userId, note: 'This cloud account is not in any rescue team')
          : _TeamInfo(
              userId: userId,
              teamId: match['id']?.toString(),
              teamName: match['name']?.toString());
    }
    _team = info;
    NetLog.sync(info.teamId == null
        ? 'Status sync: ${info.note}'
        : 'Status sync: using rescue team ${info.teamName ?? info.teamId}');
    return info;
  }

  Future<void> _uploadStatuses() async {
    while (true) {
      final eligible = _statuses.values
          .where((s) => s.state.isPending && _emergencySynced(s))
          .toList()
        ..sort((a, b) => a.update.changedAt.compareTo(b.update.changedAt));
      if (eligible.isEmpty) return;

      final needsTeam = eligible.any((s) {
        final status = s.update.normalizedStatus;
        return status == 'ASSIGNED' || status == 'IN_PROGRESS';
      });
      final team = needsTeam ? await _ensureTeam() : _team;
      final teamId = team?.teamId;

      // Map console statuses to cloud statuses.
      final now = _clock();
      final sendable = <_StatusEntry>[];
      final payloads = <String, Map<String, dynamic>>{};
      var skippedAny = false;
      for (final s in eligible) {
        final u = s.update;
        String cloudStatus;
        String? note;
        final extra = <String, dynamic>{};
        switch (u.normalizedStatus) {
          case 'ACKNOWLEDGED':
            cloudStatus = 'ACKNOWLEDGED';
          case 'ASSIGNED':
            if (teamId != null) {
              cloudStatus = 'ASSIGNED';
              extra['team_id'] = teamId;
            } else {
              cloudStatus = 'ACKNOWLEDGED';
              note = 'No rescue team for this cloud account -- ASSIGNED sent as ACKNOWLEDGED';
            }
          case 'IN_PROGRESS':
            if (teamId == null) {
              s.state = s.state.copyWith(
                phase: CloudItemPhase.skipped,
                errorCode: 'NO_RESCUE_TEAM',
                errorMessage: 'IN_PROGRESS needs a rescue team; '
                    '${team?.note ?? 'this cloud account is not in any rescue team'}.',
                finishedAt: now,
              );
              _emit(s.state);
              skippedAny = true;
              NetLog.sync('Status sync skipped ${u.updateId}: IN_PROGRESS needs a rescue team');
              continue;
            }
            cloudStatus = 'IN_PROGRESS';
          case 'RESCUED':
            cloudStatus = 'RESOLVED';
            extra['outcome'] = 'RESCUED';
          default:
            continue; // rejected at enqueue time
        }
        final reason = u.reason;
        payloads[u.updateId] = {
          'update_id': u.updateId,
          'client_emergency_id': u.clientEmergencyId,
          'status': cloudStatus,
          'changed_at': _utcIso(u.changedAt),
          if (reason != null && reason.trim().isNotEmpty) 'reason': _cap(reason, 1000),
          ...extra,
        };
        s.state = s.state.copyWith(
          sentStatus: cloudStatus,
          note: note,
          attempts: s.state.attempts + 1,
          lastAttemptAt: now,
        );
        if (note != null) {
          NetLog.sync('Status sync ${u.updateId}: ASSIGNED sent as ACKNOWLEDGED (no rescue team)');
        }
        sendable.add(s);
      }
      if (skippedAny) {
        _publish();
        await _persist();
      }
      if (sendable.isEmpty) continue;

      await _postChunk<_StatusEntry>(
        path: BackendConfig.syncStatusPath,
        label: 'Status sync',
        chunk: sendable.take(_batchSize).toList(),
        payload: (s) => payloads[s.update.updateId]!,
        markInvalid: (s, code, message) {
          s.state = s.state.copyWith(
            phase: CloudItemPhase.invalid,
            result: 'invalid',
            errorCode: code,
            errorMessage: message,
            finishedAt: _clock(),
          );
          _emit(s.state);
          NetLog.sync('Status sync invalid ${s.update.updateId} ($code) -- not retrying');
        },
        apply: _applyStatusResults,
      );
      await _flushPendingPersist();
    }
  }

  int _applyStatusResults(List<_StatusEntry> entries, _ApiResponse res) {
    final data = res.data;
    final results = data is Map ? data['results'] : null;
    if (results is! List) return 0;
    final byId = <String, Map>{};
    for (final r in results) {
      if (r is Map && r['update_id'] is String) byId[r['update_id'] as String] = r;
    }
    var applied = 0, duplicate = 0, conflict = 0, invalid = 0, notFound = 0, changed = 0;
    final now = _clock();
    for (final s in entries) {
      final r = byId[s.update.updateId];
      if (r == null) continue;
      final outcome = r['result'];
      final error = r['error'] is Map ? r['error'] as Map : null;
      final code = error?['code'] as String?;
      final message = error?['message'] as String?;
      final serverStatus = r['current_status']?.toString();
      final serverId = r['emergency_id']?.toString();
      CloudItemPhase phase;
      switch (outcome) {
        case 'applied':
          applied++;
          phase = CloudItemPhase.done;
        case 'duplicate':
          duplicate++;
          phase = CloudItemPhase.done;
        case 'conflict':
          conflict++;
          phase = CloudItemPhase.conflict;
        case 'invalid':
          invalid++;
          phase = CloudItemPhase.invalid;
        case 'not_found':
          notFound++;
          phase = CloudItemPhase.notFound;
        default:
          continue;
      }
      final failed = phase != CloudItemPhase.done;
      s.state = s.state.copyWith(
        phase: phase,
        result: outcome as String,
        errorCode: failed ? (code ?? outcome.toUpperCase()) : null,
        errorMessage: failed ? message : null,
        clearError: !failed,
        finishedAt: now,
        serverStatus: serverStatus,
        serverEmergencyId: serverId,
      );
      _emit(s.state);
      changed++;
      if (failed) {
        NetLog.sync('Status sync ${s.update.updateId}: $outcome'
            '${code == null ? '' : ' ($code)'} -- not retrying');
      }
    }
    if (changed > 0) {
      NetLog.sync('Status sync: $applied applied, $duplicate duplicate, '
          '$conflict conflict, $invalid invalid, $notFound not found');
      _publish();
      _pendingPersist = _persist();
    }
    return changed;
  }

  Future<void> _flushPendingPersist() async {
    final pending = _pendingPersist;
    _pendingPersist = null;
    if (pending != null) await pending;
  }
}
