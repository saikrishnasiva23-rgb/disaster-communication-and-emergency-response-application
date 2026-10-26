import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_ble_central/flutter_ble_central.dart';

import '../ble_protocol.dart';
import '../net_log.dart';
import 'mesh_link.dart';

/// One link as this transport tracks it. Every link has its own state, so
/// several phones can be connecting / connected at the same time.
class _CentralLink {
  _CentralLink(this.info);

  LinkInfo info;

  String get linkId => info.linkId;
  String get address => info.address;

  /// Bumped by every connect, disconnect, failure and loss. An operation
  /// still in flight compares it with the value it started with, so it can
  /// never report against a newer attempt (or a link that is gone).
  int attempt = 0;

  /// The plugin's connect() was issued for [attempt]. False during the
  /// pre-connect cleanup, whose own 'disconnected' event must be ignored.
  bool nativeRequested = false;

  Timer? connectTimer;

  /// The peer serves a readable CONTROL characteristic.
  bool hasControl = false;

  /// Last scan sighting / last scan-driven emit (ms since epoch).
  int lastSeenMs = 0;
  int lastScanEmitMs = 0;

  /// The disconnect() in flight, so a second call waits for the same one.
  Future<void>? closing;
}

/// The Windows Rescue laptop's BLE central (GATT client) on
/// flutter_ble_central 1.1.0 -- the only Windows GATT client available.
///
/// Scans (actively) for the mesh service, connects to each phone on its own
/// link, discovers the GATT layout, subscribes to DATA notify (+ ACK notify)
/// and only then reports the link READY. Nothing is reported connected,
/// ready or sent unless the plugin confirmed it.
///
/// Plugin problems worked around here (from its Windows C++ source):
///  * a remote disconnect leaves the native connection entry (and its
///    MaintainConnection) in place, so a later connect() fails with
///    "Already connected": every 'disconnected' event is followed by a
///    native disconnect(), and every connect() starts with one;
///  * after a rediscovery on an existing entry the notification handler is
///    not re-attached to the new characteristic object: notifications are
///    always switched off (errors ignored) and then on again;
///  * Windows ignores connect timeouts -- this class enforces 20 s;
///  * no plugin call has a Dart timeout -- every one is wrapped here;
///  * the advertisement watcher silently dies when the radio turns off:
///    the radio state stream drops every link and rebuilds the watcher when
///    the radio comes back;
///  * only the first manufacturer-data entry reaches Dart; the
///    MeshAdvertisement rides under company id 0xFFFF in the scan response.
class WindowsCentralTransport implements MeshTransport {
  WindowsCentralTransport({FlutterBleCentral? central})
      : _central = central ?? FlutterBleCentral();

  /// Connecting -> plugin 'connected' event.
  static const Duration connectTimeout = Duration(seconds: 20);
  static const Duration discoverTimeout = Duration(seconds: 15);
  static const Duration notifyTimeout = Duration(seconds: 10);
  static const Duration writeTimeout = Duration(seconds: 5);
  static const Duration mtuTimeout = Duration(seconds: 5);
  static const Duration readTimeout = Duration(seconds: 5);

  /// Adapter / permission queries and starting / stopping the watcher.
  static const Duration adapterTimeout = Duration(seconds: 10);

  /// Native disconnect (it answers at once; this only guards a hang).
  static const Duration releaseTimeout = Duration(seconds: 5);

  /// At most one scan-driven link emit per device in this window.
  static const Duration scanEmitInterval = Duration(seconds: 2);

  /// A device the scanner has not reported for this long is not connected
  /// to: it is out of range, or the phone rotated its Bluetooth address, and
  /// a 20 s attempt on it would only hold a connection slot.
  static const Duration sightingMaxAge = Duration(seconds: 60);

  static const int requestedMtu = 517;
  static const int defaultMtu = 23;
  static const int maxPayloadSize = 512;

  static const String noAdapterText =
      'This computer has no usable Bluetooth LE adapter.';
  static const String permissionText =
      'Allow Bluetooth for this app in Windows Settings > Privacy & security.';
  static const String bluetoothOffText =
      'Bluetooth is off. Turn it on in Windows Settings > Bluetooth & devices.';
  static const String connectTimeoutText =
      "Connection timed out -- keep the phone's app open with the screen on";

  final FlutterBleCentral _central;

  final ValueNotifier<TransportStatus> _status =
      ValueNotifier(const TransportStatus(TransportAvailability.stopped));
  final StreamController<LinkInfo> _linkEvents =
      StreamController<LinkInfo>.broadcast();
  final StreamController<InboundFrame> _frameEvents =
      StreamController<InboundFrame>.broadcast();

  /// By linkId.
  final Map<String, _CentralLink> _links = {};

  /// Native disconnects in flight, by address. While one is pending, the
  /// 'disconnected' events for that address are this class's own.
  final Map<String, int> _closing = {};

  /// Addresses already logged as discovered in this scan session.
  final Set<String> _announced = {};

  StreamSubscription<CentralState>? _radioSub;
  StreamSubscription<ConnectionStateChange>? _connectionSub;
  StreamSubscription<CharacteristicValue>? _valueSub;
  StreamSubscription<ScanResult>? _scanSub;

  Future<bool>? _starting;
  bool _wantRunning = false;
  bool _scanning = false;
  bool _radioOff = false;
  bool _disposed = false;

  @override
  LinkSide get side => LinkSide.central;

  @override
  ValueListenable<TransportStatus> get status => _status;

  @override
  Stream<LinkInfo> get links => _linkEvents.stream;

  @override
  Stream<InboundFrame> get frames => _frameEvents.stream;

  /// Snapshot of every link (diagnostics).
  List<LinkInfo> get currentLinks => [for (final l in _links.values) l.info];

  // ---------------------------------------------------------------------------
  // Start / stop
  // ---------------------------------------------------------------------------

  @override
  Future<bool> start() {
    if (_disposed) return Future.value(false);
    _wantRunning = true;
    if (_scanning && _status.value.isActive) return Future.value(true);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<bool> _start() async {
    _setStatus(TransportAvailability.starting);
    try {
      final supported = await _central.isSupported.timeout(adapterTimeout);
      if (!supported) {
        return _startFailed(TransportAvailability.unsupported, noAdapterText);
      }

      var permission = await _central.hasPermission().timeout(adapterTimeout);
      if (!_permissionGranted(permission)) {
        permission = await _central.requestPermission().timeout(adapterTimeout);
      }
      if (_permissionRefused(permission)) {
        return _startFailed(
            TransportAvailability.permissionDenied, permissionText);
      }

      // Before the radio check, so a radio that is off now and turned on
      // later restarts the scan by itself.
      _subscribe();

      var on = await _central.isBluetoothOn.timeout(adapterTimeout);
      if (!on) {
        NetLog.ble('Bluetooth is off -- asking Windows to turn it on');
        on = await _central
            .enableBluetooth()
            .timeout(adapterTimeout, onTimeout: () => false);
      }
      if (!on) {
        _radioOff = true;
        return _startFailed(
            TransportAvailability.bluetoothOff, bluetoothOffText);
      }
      _radioOff = false;

      // A watcher the radio aborted cannot be started again; stop() drops it
      // so start() builds a fresh one.
      try {
        await _central.stop().timeout(adapterTimeout);
      } catch (_) {
        // Nothing was scanning.
      }
      final state = await _central
          .start(serviceUuids: [BleProtocol.serviceUuid])
          .timeout(adapterTimeout);

      if (state != CentralBluetoothState.ready &&
          state != CentralBluetoothState.granted) {
        if (state == CentralBluetoothState.unsupported) {
          return _startFailed(TransportAvailability.unsupported, noAdapterText);
        }
        var stillOn = false;
        try {
          stillOn = await _central.isBluetoothOn.timeout(adapterTimeout);
        } catch (_) {
          // Reported as a plain failure below.
        }
        if (!stillOn) {
          _radioOff = true;
          return _startFailed(
              TransportAvailability.bluetoothOff, bluetoothOffText);
        }
        return _startFailed(
          TransportAvailability.failed,
          'Bluetooth scanning could not start. Turn Bluetooth off and on in '
          'Windows Settings, then try again.',
        );
      }

      // The radio went off while the watcher was being started.
      if (_radioOff) {
        return _startFailed(
            TransportAvailability.bluetoothOff, bluetoothOffText);
      }

      _scanning = true;
      _setStatus(TransportAvailability.active);
      NetLog.ble('Scan started (active scan for the mesh service)');
      return true;
    } on TimeoutException {
      return _startFailed(
        TransportAvailability.failed,
        'Bluetooth did not respond. Check that Bluetooth is on, then try '
        'again.',
      );
    } catch (e) {
      return _startFailed(
        TransportAvailability.failed,
        'Bluetooth scanning failed to start (${_reason(e)}).',
      );
    }
  }

  bool _startFailed(TransportAvailability availability, String detail) {
    _scanning = false;
    _setStatus(availability, detail);
    NetLog.ble('Scan failed to start: $detail');
    return false;
  }

  /// Subscribes to the plugin's streams, once for the transport's life.
  void _subscribe() {
    _radioSub ??= _central.onCentralStateChanged.listen(
      _onRadioState,
      onError: (Object e) =>
          NetLog.ble('Bluetooth state stream error: ${_reason(e)}'),
    );
    _connectionSub ??= _central.onConnectionStateChanged.listen(
      _onConnectionState,
      onError: (Object e) =>
          NetLog.ble('Connection state stream error: ${_reason(e)}'),
    );
    _valueSub ??= _central.onCharacteristicValueChanged.listen(
      _onValue,
      onError: (Object e) =>
          NetLog.ble('Notification stream error: ${_reason(e)}'),
    );
    _scanSub ??= _central.onScanResult.listen(
      _onScanResult,
      onError: (Object e) => NetLog.ble('Scan stream error: ${_reason(e)}'),
    );
  }

  @override
  Future<void> stop() async {
    _wantRunning = false;
    final pending = _starting;
    if (pending != null) await pending;

    final wasScanning = _scanning;
    _scanning = false;
    try {
      await _central.stop().timeout(adapterTimeout);
    } catch (_) {
      // Already stopped, or the radio is gone.
    }
    final active = [
      for (final l in _links.values.toList())
        if (_isActive(l.info.state)) l,
    ];
    await Future.wait([for (final l in active) disconnect(l.linkId)]);
    _announced.clear();
    _setStatus(TransportAvailability.stopped);
    if (wasScanning || active.isNotEmpty) {
      NetLog.ble('Scan stopped (${active.length} link(s) closed)');
    }
  }

  /// Stops everything and releases the plugin streams. The transport cannot
  /// be started again afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    for (final link in _links.values) {
      link.connectTimer?.cancel();
      link.connectTimer = null;
    }
    await _radioSub?.cancel();
    await _connectionSub?.cancel();
    await _valueSub?.cancel();
    await _scanSub?.cancel();
    _radioSub = null;
    _connectionSub = null;
    _valueSub = null;
    _scanSub = null;
    await _linkEvents.close();
    await _frameEvents.close();
  }

  // ---------------------------------------------------------------------------
  // Radio
  // ---------------------------------------------------------------------------

  void _onRadioState(CentralState state) {
    if (_disposed) return;
    switch (state) {
      case CentralState.poweredOff:
        _onRadioLost(
            TransportAvailability.bluetoothOff, bluetoothOffText, 'Bluetooth off');
      case CentralState.unauthorized:
        // Windows reports a radio disabled by Device Manager / policy here.
        _onRadioLost(
          TransportAvailability.bluetoothOff,
          'Bluetooth is disabled on this computer (Device Manager or policy).',
          'Bluetooth off',
        );
      case CentralState.unsupported:
        _onRadioLost(TransportAvailability.unsupported, noAdapterText,
            'Bluetooth adapter unavailable');
      case CentralState.idle:
      case CentralState.advertising:
      case CentralState.connected:
        _onRadioOn();
      case CentralState.unknown:
        break;
    }
  }

  /// The watcher died with the radio and every link is gone with it.
  void _onRadioLost(
    TransportAvailability availability,
    String detail,
    String linkError,
  ) {
    final wasOff = _radioOff;
    _radioOff = true;
    _scanning = false;
    var dropped = 0;
    for (final link in _links.values.toList()) {
      if (!_isActive(link.info.state)) continue;
      dropped++;
      _invalidate(link);
      _set(link, _closed(link.info, LinkState.disconnected, error: linkError));
      unawaited(_releaseNative(link.address));
    }
    if (_wantRunning) _setStatus(availability, detail);
    if (!wasOff || dropped > 0) {
      NetLog.ble('$linkError -- scanning stopped, $dropped link(s) dropped');
    }
  }

  void _onRadioOn() {
    if (!_radioOff) return;
    _radioOff = false;
    NetLog.ble('Bluetooth turned on');
    if (_wantRunning) unawaited(_restartScan());
  }

  Future<void> _restartScan() async {
    final pending = _starting;
    if (pending != null) await pending;
    if (_disposed || !_wantRunning || _radioOff) return;
    if (_scanning && _status.value.isActive) return;
    NetLog.ble('Restarting the scan');
    await start();
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  void _onScanResult(ScanResult result) {
    if (_disposed || !_scanning) return;
    final address = result.device?.address ?? '';
    if (address.isEmpty) return;

    final record = result.scanRecord;
    final name = _cleanName(record?.deviceName ?? result.device?.name);
    final advertisement = MeshAdvertisement.decode(
      record?.manufacturerSpecificData?[BleProtocol.manufacturerId],
    );
    final linkId = LinkInfo.idFor(LinkSide.central, address);
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;

    var link = _links[linkId];
    if (link == null) {
      link = _CentralLink(LinkInfo(
        linkId: linkId,
        side: LinkSide.central,
        address: address,
        state: LinkState.discovered,
        updatedAt: now,
        name: name,
        rssi: result.rssi,
        advertisement: advertisement,
      ));
      _links[linkId] = link;
    } else if (nowMs - link.lastScanEmitMs < scanEmitInterval.inMilliseconds) {
      // Rate-limited: keep the newest values for the next emit, silently.
      link.lastSeenMs = nowMs;
      link.info = link.info.copyWith(
        name: name,
        rssi: result.rssi,
        advertisement: advertisement,
        updatedAt: link.info.updatedAt,
      );
      return;
    } else {
      final state =
          _isActive(link.info.state) ? link.info.state : LinkState.discovered;
      link.info = link.info.copyWith(
        state: state,
        name: name,
        rssi: result.rssi,
        advertisement: advertisement,
      );
    }
    link.lastSeenMs = nowMs;
    link.lastScanEmitMs = nowMs;

    if (_announced.add(address)) {
      final adv = advertisement;
      NetLog.ble('Device discovered: ${_label(link)} '
          '(${result.rssi ?? '?'} dBm'
          '${adv == null ? '' : ', mesh v${adv.protocolVersion}'
              '${adv.relayCapable ? ', relay-capable' : ''}'})');
    }
    _emit(link);
  }

  // ---------------------------------------------------------------------------
  // Connecting
  // ---------------------------------------------------------------------------

  @override
  Future<void> connect(String linkId) async {
    if (_disposed) return;
    final link = _links[linkId];
    if (link == null) {
      NetLog.ble('Connect ignored: unknown link');
      return;
    }
    // Already connecting / connected / closing: nothing to do.
    if (_isActive(link.info.state)) return;

    final refusal = _connectRefusal(link);
    if (refusal != null) {
      if (link.info.state != LinkState.error || link.info.error != refusal) {
        _set(link, _closed(link.info, LinkState.error, error: refusal));
        NetLog.ble('Connect failed: ${_label(link)}: $refusal');
      }
      return;
    }

    final attempt = _invalidate(link);
    _set(
      link,
      link.info.copyWith(
        state: LinkState.connecting,
        clearError: true,
        payloadSize: BleProtocol.attPayloadSize,
        hasAckChannel: false,
      ),
    );
    NetLog.ble('Connecting: ${_label(link)}');
    // Windows ignores the plugin's connect timeout and keeps trying for ever.
    link.connectTimer =
        Timer(connectTimeout, () => _onConnectTimeout(link, attempt));

    // Plugin workaround: drop a native entry a remote disconnect left behind,
    // or connect() fails with "Already connected".
    await _releaseNative(link.address);
    if (!_owns(link, attempt)) return;

    link.nativeRequested = true;
    try {
      await _central.connect(
        address: link.address,
        timeout: connectTimeout.inSeconds,
      );
    } catch (e) {
      if (_owns(link, attempt) && link.info.state == LinkState.connecting) {
        _failLink(link, 'Windows refused the connection: ${_reason(e)}',
            stage: 'Connect failed');
      }
      return;
    }

    // Cancelled (disconnect, timeout, Bluetooth off) while the plugin was
    // still opening the session, which it then kept: release it, or Windows
    // holds the link open. A newer attempt owns the link otherwise.
    if (!_owns(link, attempt) && !_isActive(link.info.state)) {
      unawaited(_releaseNative(link.address));
    }
  }

  /// Why a connect cannot even be tried right now, or null.
  String? _connectRefusal(_CentralLink link) {
    final current = _status.value;
    if (_radioOff ||
        current.availability == TransportAvailability.bluetoothOff) {
      return 'Bluetooth off';
    }
    if (!current.isActive) {
      return current.detail ?? 'Bluetooth scanning is not running on this computer';
    }
    final age = DateTime.now().millisecondsSinceEpoch - link.lastSeenMs;
    if (age > sightingMaxAge.inMilliseconds) {
      return 'Not seen by the scanner for over ${sightingMaxAge.inSeconds} s '
          '(out of range, or the phone changed its Bluetooth address)';
    }
    return null;
  }

  void _onConnectTimeout(_CentralLink link, int attempt) {
    if (!_owns(link, attempt) || link.info.state != LinkState.connecting) {
      return;
    }
    _failLink(link, connectTimeoutText, stage: 'Connection timed out');
  }

  void _onConnectionState(ConnectionStateChange change) {
    if (_disposed) return;
    final address = change.address;
    if (address.isEmpty) return;
    final link = _links[LinkInfo.idFor(LinkSide.central, address)];
    switch (change.state) {
      case GattConnectionState.connected:
        _onNativeConnected(address, link);
      case GattConnectionState.disconnected:
        _onNativeDisconnected(address, link);
      case GattConnectionState.connecting:
      case GattConnectionState.disconnecting:
        // 'connecting' is the state the link is already in; Windows never
        // reports 'disconnecting'.
        break;
    }
  }

  void _onNativeConnected(String address, _CentralLink? link) {
    // Not a device this transport knows: leave it to whoever opened it.
    if (link == null) return;
    final state = link.info.state;
    if (state == LinkState.connecting) {
      // A leftover entry the pre-connect cleanup is closing right now.
      if (!link.nativeRequested) return;
      final attempt = link.attempt;
      link.connectTimer?.cancel();
      link.connectTimer = null;
      _set(link, link.info.copyWith(state: LinkState.connected, clearError: true));
      NetLog.ble('Connected: ${_label(link)}');
      unawaited(_setUpGatt(link, attempt));
      return;
    }
    // A repeat, or the link is being closed anyway.
    if (state.isConnectedish || state == LinkState.disconnecting) return;
    // Connected although nothing here wants it (an attempt cancelled while
    // Windows was still bringing the link up): release it.
    unawaited(_releaseNative(address));
  }

  void _onNativeDisconnected(String address, _CentralLink? link) {
    // The event of a native disconnect this class issued itself; whoever
    // issued it sets the link's state.
    if (_closing.containsKey(address)) return;

    // Plugin workaround: a remote disconnect leaves the native entry (still
    // maintaining the connection) behind; drop it so the next connect works.
    unawaited(_releaseNative(address));

    if (link == null) return;
    final state = link.info.state;
    if (state == LinkState.connecting && !link.nativeRequested) return;
    if (!_isActive(state) || state == LinkState.disconnecting) return;

    final LinkState next;
    final String reason;
    switch (state) {
      case LinkState.connecting:
        next = LinkState.error;
        reason = 'The phone did not accept the connection -- keep its app '
            'open with the screen on';
      case LinkState.connected:
      case LinkState.serviceDiscovery:
        next = LinkState.error;
        reason = 'Disconnected during GATT setup';
      default:
        next = LinkState.disconnected;
        reason = 'Connection lost (out of range, Bluetooth off on the phone, '
            'or the app was closed)';
    }
    _invalidate(link);
    _set(link, _closed(link.info, next, error: reason));
    NetLog.ble('Disconnected: ${_label(link)} ($reason)');
  }

  /// Service discovery -> subscriptions -> MTU -> READY. Any failure puts
  /// the link in [LinkState.error] with the reason and drops the connection.
  Future<void> _setUpGatt(_CentralLink link, int attempt) async {
    final address = link.address;
    _set(link, link.info.copyWith(state: LinkState.serviceDiscovery));

    final List<GattService> services;
    try {
      services = await _central.discoverServices(address).timeout(discoverTimeout);
    } catch (e) {
      if (_owns(link, attempt)) {
        _failLink(link, 'GATT service discovery failed: ${_reason(e)}');
      }
      return;
    }
    if (!_owns(link, attempt)) return;

    GattService? service;
    for (final s in services) {
      if (BleProtocol.sameUuid(s.uuid, BleProtocol.serviceUuid)) {
        service = s;
        break;
      }
    }
    if (service == null) {
      _failLink(link,
          'This device does not run the mesh BLE service (is the app open on the phone?)');
      return;
    }

    final characteristics = service.characteristics ?? const <GattCharacteristic>[];
    GattCharacteristic? find(String uuid) {
      for (final c in characteristics) {
        if (BleProtocol.sameUuid(c.uuid, uuid)) return c;
      }
      return null;
    }

    final dataNotify = find(BleProtocol.notifyCharacteristicUuid);
    final dataWrite = find(BleProtocol.writeCharacteristicUuid);
    final ack = find(BleProtocol.ackCharacteristicUuid);
    final control = find(BleProtocol.controlCharacteristicUuid);

    if (dataNotify == null || !dataNotify.properties.notify) {
      _failLink(link,
          'The mesh service on this device has no DATA notify characteristic');
      return;
    }
    if (dataWrite == null || !dataWrite.properties.write) {
      _failLink(link,
          'The mesh service on this device has no DATA write characteristic');
      return;
    }
    final ackUsable =
        ack != null && ack.properties.write && ack.properties.notify;
    link.hasControl = control != null && control.properties.read;
    NetLog.ble('GATT services discovered: ${_label(link)} (DATA notify + write'
        ', ACK ${ackUsable ? 'yes' : (ack == null ? 'no' : 'unusable')}'
        ', CONTROL ${control != null ? 'yes' : 'no'})');

    final dataError =
        await _subscribeNotify(address, BleProtocol.notifyCharacteristicUuid);
    if (!_owns(link, attempt)) return;
    if (dataError != null) {
      _failLink(link, 'Could not subscribe to DATA notifications: $dataError');
      return;
    }

    var hasAck = false;
    if (ackUsable) {
      final ackError =
          await _subscribeNotify(address, BleProtocol.ackCharacteristicUuid);
      if (!_owns(link, attempt)) return;
      if (ackError == null) {
        hasAck = true;
      } else {
        // Not fatal: ACKs then travel on the DATA characteristics, exactly as
        // with a phone that has no ACK characteristic.
        NetLog.ble('ACK channel unavailable on ${_label(link)} ($ackError) '
            '-- ACKs use the DATA channel');
      }
    }

    var mtu = defaultMtu;
    try {
      // Windows ignores the requested size and returns the negotiated
      // GattSession.MaxPduSize.
      mtu = await _central
          .requestMtu(address: address, mtu: requestedMtu)
          .timeout(mtuTimeout);
    } catch (e) {
      mtu = defaultMtu;
      NetLog.ble('MTU query failed on ${_label(link)} (${_reason(e)}) '
          '-- assuming $defaultMtu');
    }
    if (!_owns(link, attempt)) return;
    final payload = math.max(
      BleProtocol.attPayloadSize,
      math.min(mtu - 3, maxPayloadSize),
    );

    _set(
      link,
      link.info.copyWith(
        state: LinkState.ready,
        payloadSize: payload,
        hasAckChannel: hasAck,
        clearError: true,
      ),
    );
    NetLog.ble('Communication ready: ${_label(link)} (MTU $mtu, $payload B/frame'
        '${hasAck ? ', ACK channel' : ''})');
  }

  /// Turns notifications on for one characteristic. Returns null on success,
  /// otherwise the reason.
  Future<String?> _subscribeNotify(String address, String characteristicUuid) async {
    // Plugin workaround: after a rediscovery the old handler stays registered
    // but is not attached to the new characteristic object, and enable alone
    // keeps it. Switching off first drops it, so enable attaches a fresh one.
    try {
      await _central
          .setCharacteristicNotification(
            address: address,
            serviceUuid: BleProtocol.serviceUuid,
            characteristicUuid: characteristicUuid,
            enable: false,
          )
          .timeout(notifyTimeout);
    } catch (_) {
      // Expected when nothing was subscribed yet.
    }
    try {
      await _central
          .setCharacteristicNotification(
            address: address,
            serviceUuid: BleProtocol.serviceUuid,
            characteristicUuid: characteristicUuid,
            enable: true,
          )
          .timeout(notifyTimeout);
      return null;
    } catch (e) {
      return _reason(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  void _onValue(CharacteristicValue event) {
    if (_disposed || event.value.isEmpty) return;
    final link = _links[LinkInfo.idFor(LinkSide.central, event.address)];
    if (link == null || !link.info.state.isConnectedish) return;
    if (event.serviceUuid.isNotEmpty &&
        !BleProtocol.sameUuid(event.serviceUuid, BleProtocol.serviceUuid)) {
      return;
    }
    final MeshChannel channel;
    if (BleProtocol.sameUuid(
        event.characteristicUuid, BleProtocol.notifyCharacteristicUuid)) {
      channel = MeshChannel.data;
    } else if (BleProtocol.sameUuid(
        event.characteristicUuid, BleProtocol.ackCharacteristicUuid)) {
      channel = MeshChannel.ack;
    } else {
      return;
    }
    if (!_frameEvents.isClosed) {
      _frameEvents.add(InboundFrame(link.linkId, channel, event.value));
    }
  }

  @override
  Future<bool> send(String linkId, MeshChannel channel, Uint8List frame) async {
    if (_disposed) return false;
    final link = _links[linkId];
    if (link == null || !link.info.isReady) return false;
    if (frame.isEmpty || frame.length > link.info.payloadSize) {
      NetLog.ble('Send refused on ${_label(link)}: frame of ${frame.length} B '
          '(link allows ${link.info.payloadSize} B)');
      return false;
    }
    final useAck = channel == MeshChannel.ack && link.info.hasAckChannel;
    try {
      await _central
          .writeCharacteristic(
            address: link.address,
            serviceUuid: BleProtocol.serviceUuid,
            characteristicUuid: useAck
                ? BleProtocol.ackCharacteristicUuid
                : BleProtocol.writeCharacteristicUuid,
            value: frame,
            withoutResponse: false,
          )
          .timeout(writeTimeout);
      // The write response came back: the peer has the frame.
      return true;
    } catch (e) {
      NetLog.ble('Write failed on ${_label(link)} '
          '(${useAck ? 'ACK' : 'DATA'}): ${_reason(e)}');
      return false;
    }
  }

  /// Reads the peer's CONTROL characteristic (node status JSON), or null when
  /// the link is not ready, the peer has none, or the read failed.
  Future<Uint8List?> readControl(String linkId) async {
    if (_disposed) return null;
    final link = _links[linkId];
    if (link == null || !link.info.isReady || !link.hasControl) return null;
    try {
      return await _central
          .readCharacteristic(
            address: link.address,
            serviceUuid: BleProtocol.serviceUuid,
            characteristicUuid: BleProtocol.controlCharacteristicUuid,
          )
          .timeout(readTimeout);
    } catch (e) {
      NetLog.ble('CONTROL read failed on ${_label(link)}: ${_reason(e)}');
      return null;
    }
  }

  /// Peripheral-side only.
  @override
  Future<void> setControlValue(Uint8List value) async {}

  // ---------------------------------------------------------------------------
  // Disconnecting
  // ---------------------------------------------------------------------------

  @override
  Future<void> disconnect(String linkId) {
    final link = _links[linkId];
    if (link == null) return Future.value();
    final state = link.info.state;
    if (state == LinkState.disconnecting) {
      return link.closing ?? Future.value();
    }
    if (!_isActive(state)) return Future.value();
    final closing = link.closing = _disconnect(link);
    return closing.whenComplete(() {
      if (identical(link.closing, closing)) link.closing = null;
    });
  }

  Future<void> _disconnect(_CentralLink link) async {
    _invalidate(link);
    _set(link, link.info.copyWith(state: LinkState.disconnecting));
    await _releaseNative(link.address);
    _set(link, _closed(link.info, LinkState.disconnected, clearError: true));
    NetLog.ble('Disconnected: ${_label(link)} (closed on this computer)');
  }

  /// Plugin disconnect() with errors ignored: "Device not connected" is the
  /// normal answer when there is no native entry to drop.
  Future<void> _releaseNative(String address) async {
    _closing[address] = (_closing[address] ?? 0) + 1;
    try {
      await _central.disconnect(address).timeout(releaseTimeout);
    } catch (_) {
      // Nothing to drop, or already gone.
    } finally {
      final left = (_closing[address] ?? 1) - 1;
      if (left <= 0) {
        _closing.remove(address);
      } else {
        _closing[address] = left;
      }
    }
  }

  /// Error state with [reason]; drops the native connection.
  void _failLink(
    _CentralLink link,
    String reason, {
    String stage = 'GATT setup failed',
  }) {
    _invalidate(link);
    _set(link, _closed(link.info, LinkState.error, error: reason));
    NetLog.ble('$stage: ${_label(link)}: $reason');
    unawaited(_releaseNative(link.address));
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Ends whatever the link was doing: timer cancelled, attempt bumped.
  int _invalidate(_CentralLink link) {
    link.connectTimer?.cancel();
    link.connectTimer = null;
    link.nativeRequested = false;
    return ++link.attempt;
  }

  bool _owns(_CentralLink link, int attempt) =>
      !_disposed && link.attempt == attempt;

  /// A link state that holds (or is about to hold / release) a connection.
  static bool _isActive(LinkState state) =>
      state == LinkState.connecting ||
      state.isConnectedish ||
      state == LinkState.disconnecting;

  /// A closed link no longer has a negotiated MTU or an ACK subscription.
  static LinkInfo _closed(
    LinkInfo info,
    LinkState state, {
    String? error,
    bool clearError = false,
  }) =>
      info.copyWith(
        state: state,
        error: error,
        clearError: clearError,
        payloadSize: BleProtocol.attPayloadSize,
        hasAckChannel: false,
      );

  void _set(_CentralLink link, LinkInfo info) {
    link.info = info;
    _emit(link);
  }

  void _emit(_CentralLink link) {
    if (!_linkEvents.isClosed) _linkEvents.add(link.info);
  }

  void _setStatus(TransportAvailability availability, [String? detail]) {
    if (_disposed) return;
    _status.value = TransportStatus(availability, detail);
  }

  static bool _permissionGranted(CentralBluetoothState state) =>
      state == CentralBluetoothState.granted ||
      state == CentralBluetoothState.ready ||
      state == CentralBluetoothState.limited;

  static bool _permissionRefused(CentralBluetoothState state) =>
      state == CentralBluetoothState.denied ||
      state == CentralBluetoothState.permanentlyDenied ||
      state == CentralBluetoothState.restricted;

  static String? _cleanName(String? name) {
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// Log label: the scan name, else the address as a MAC (the plugin uses
  /// the decimal 48-bit address).
  static String _label(_CentralLink link) =>
      link.info.name ?? 'device ${_mac(link.address)}';

  static String _mac(String address) {
    final value = int.tryParse(address);
    if (value == null || value < 0) return address;
    final hex = value.toRadixString(16).padLeft(12, '0').toUpperCase();
    return [
      for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2),
    ].join(':');
  }

  static String _reason(Object error) {
    final String text;
    if (error is TimeoutException) {
      text = 'timed out';
    } else if (error is PlatformException) {
      final message = error.message?.trim();
      text = message == null || message.isEmpty ? error.code : message;
    } else {
      text = error.toString();
    }
    return text.length > 120 ? '${text.substring(0, 120)}...' : text;
  }
}
