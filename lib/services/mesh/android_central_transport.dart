import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble_protocol.dart';
import '../net_log.dart';
import 'mesh_link.dart';

class _PeerLink {
  _PeerLink(this.device, this.info);

  final BluetoothDevice device;
  LinkInfo info;

  /// Bumped on every connect / disconnect so a late result of an older
  /// attempt never changes a newer one.
  int attempt = 0;
  BluetoothCharacteristic? dataWrite;
  BluetoothCharacteristic? ack;
  final List<StreamSubscription<Object?>> subs = [];
  StreamSubscription<BluetoothConnectionState>? stateSub;
  int lastScanEmitMs = 0;
}

/// The BLE central (GATT client) role of a RELAY-mode Android phone, on
/// flutter_blue_plus: scans for other mesh phones, connects to each on its
/// own link, discovers the GATT layout, subscribes to DATA (+ ACK)
/// notifications and only then reports the link READY.
///
/// flutter_blue_plus is used here (not flutter_ble_central) because on
/// Android it reports real disconnect reasons, cancels pending connects
/// cleanly, synthesises disconnects when the adapter turns off, fails
/// operations fast on a dead link and negotiates a 512-byte MTU itself --
/// flutter_ble_central's Android code has confirmed crash paths (double
/// replies on connect timeout / "Already connected").
///
/// flutter_blue_plus serialises operations across all devices, so connects
/// run one at a time from a queue.
class AndroidCentralTransport implements MeshTransport {
  AndroidCentralTransport();

  static const Duration connectTimeout = Duration(seconds: 12);
  static const Duration discoverTimeout = Duration(seconds: 15);
  static const int writeTimeoutSeconds = 5;
  static const int notifyTimeoutSeconds = 10;
  static const Duration scanEmitInterval = Duration(seconds: 2);

  final ValueNotifier<TransportStatus> _status =
      ValueNotifier(const TransportStatus(TransportAvailability.stopped));
  final StreamController<LinkInfo> _linkEvents = StreamController.broadcast();
  final StreamController<InboundFrame> _frameEvents = StreamController.broadcast();

  final Map<String, _PeerLink> _links = {};
  final Set<String> _announced = {};

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<bool>? _isScanningSub;
  Timer? _scanRestart;

  Future<void> _connectQueue = Future<void>.value();
  Future<bool>? _starting;
  bool _wantRunning = false;
  bool _scanning = false;

  @override
  LinkSide get side => LinkSide.central;

  @override
  ValueListenable<TransportStatus> get status => _status;

  @override
  Stream<LinkInfo> get links => _linkEvents.stream;

  @override
  Stream<InboundFrame> get frames => _frameEvents.stream;

  // ---------------------------------------------------------------------------
  // Start / stop
  // ---------------------------------------------------------------------------

  @override
  Future<bool> start() {
    _wantRunning = true;
    if (_scanning && _status.value.isActive) return Future.value(true);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<bool> _start() async {
    _setStatus(TransportAvailability.starting);
    try {
      if (!await FlutterBluePlus.isSupported) {
        return _fail(TransportAvailability.unsupported,
            'This phone does not support Bluetooth LE scanning.');
      }
      _adapterSub ??= FlutterBluePlus.adapterState.listen(_onAdapterState);

      var adapter = FlutterBluePlus.adapterStateNow;
      if (adapter == BluetoothAdapterState.unknown) {
        adapter = await FlutterBluePlus.adapterState
            .firstWhere((s) => s != BluetoothAdapterState.unknown)
            .timeout(const Duration(seconds: 3), onTimeout: () => BluetoothAdapterState.unknown);
      }
      if (adapter == BluetoothAdapterState.unauthorized) {
        return _fail(TransportAvailability.permissionDenied,
            'Allow "Nearby devices" for this app, then retry relay mode.');
      }
      if (adapter != BluetoothAdapterState.on) {
        try {
          await FlutterBluePlus.turnOn(timeout: 15);
        } catch (_) {}
        if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
          return _fail(TransportAvailability.bluetoothOff,
              'Bluetooth is off. Turn it on, then retry relay mode.');
        }
      }
      return await _startScan();
    } catch (e) {
      final text = e.toString().toLowerCase();
      if (text.contains('permission') || text.contains('unauthorized')) {
        return _fail(TransportAvailability.permissionDenied,
            'Allow "Nearby devices" for this app, then retry relay mode.');
      }
      return _fail(TransportAvailability.failed,
          'Bluetooth scanning could not start (${_short(e)}).');
    }
  }

  Future<bool> _startScan() async {
    _scanSub ??= FlutterBluePlus.onScanResults.listen(_onScanResults,
        onError: (Object e) => NetLog.ble('Scan error: ${_short(e)}'));
    _isScanningSub ??= FlutterBluePlus.isScanning.listen((scanning) {
      if (!scanning && _scanning && _wantRunning) {
        // Android stops long scans on its own; resume.
        _scanRestart?.cancel();
        _scanRestart = Timer(const Duration(seconds: 5), () {
          if (_wantRunning && !FlutterBluePlus.isScanningNow) unawaited(_restartScan());
        });
      }
    });
    await FlutterBluePlus.startScan(
      withServices: [Guid(BleProtocol.serviceUuid)],
      continuousUpdates: true,
      removeIfGone: const Duration(seconds: 30),
      androidScanMode: AndroidScanMode.lowLatency,
      // BLUETOOTH_SCAN is declared neverForLocation: no location needed.
      androidCheckLocationServices: false,
    );
    _scanning = true;
    _setStatus(TransportAvailability.active);
    NetLog.ble('Scan started (relay mode: looking for nearby mesh phones)');
    return true;
  }

  Future<void> _restartScan() async {
    if (!_wantRunning) return;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await _startScan();
    } catch (e) {
      NetLog.ble('Scan restart failed: ${_short(e)}');
    }
  }

  bool _fail(TransportAvailability availability, String detail) {
    _scanning = false;
    _setStatus(availability, detail);
    NetLog.ble('Relay scan unavailable: $detail');
    return false;
  }

  @override
  Future<void> stop() async {
    _wantRunning = false;
    final pending = _starting;
    if (pending != null) await pending;
    _scanRestart?.cancel();
    _scanning = false;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    for (final link in _links.values.toList()) {
      if (_isActive(link.info.state)) await disconnect(link.info.linkId);
    }
    _announced.clear();
    _setStatus(TransportAvailability.stopped);
    NetLog.ble('Relay scan stopped');
  }

  void _onAdapterState(BluetoothAdapterState state) {
    if (state == BluetoothAdapterState.on) {
      if (_wantRunning && !_status.value.isActive) {
        NetLog.ble('Bluetooth turned on -- restarting relay scan');
        unawaited(start());
      }
      return;
    }
    if (state == BluetoothAdapterState.off || state == BluetoothAdapterState.turningOff) {
      var dropped = 0;
      for (final link in _links.values) {
        if (!_isActive(link.info.state)) continue;
        dropped++;
        link.attempt++;
        _cancelSubs(link);
        _set(link, _closed(link.info, LinkState.disconnected, error: 'Bluetooth off'));
      }
      _scanning = false;
      if (_wantRunning) {
        _setStatus(TransportAvailability.bluetoothOff,
            'Bluetooth is off. Turn it on to resume relay mode.');
      }
      NetLog.ble('Bluetooth off -- relay scan stopped, $dropped link(s) dropped');
    }
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  void _onScanResults(List<ScanResult> results) {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    for (final r in results) {
      final address = r.device.remoteId.str;
      final linkId = LinkInfo.idFor(LinkSide.central, address);
      final adData = r.advertisementData;
      final name = adData.advName.trim().isNotEmpty
          ? adData.advName.trim()
          : (r.device.platformName.trim().isNotEmpty ? r.device.platformName.trim() : null);
      final adv = MeshAdvertisement.decode(adData.manufacturerData[BleProtocol.manufacturerId]);

      var link = _links[linkId];
      if (link == null) {
        link = _PeerLink(
          r.device,
          LinkInfo(
            linkId: linkId,
            side: LinkSide.central,
            address: address,
            state: LinkState.discovered,
            updatedAt: now,
            name: name,
            rssi: r.rssi,
            advertisement: adv,
          ),
        );
        _links[linkId] = link;
      } else {
        if (nowMs - link.lastScanEmitMs < scanEmitInterval.inMilliseconds) continue;
        final state = _isActive(link.info.state) ? link.info.state : LinkState.discovered;
        link.info = link.info.copyWith(state: state, name: name, rssi: r.rssi, advertisement: adv);
      }
      link.lastScanEmitMs = nowMs;
      if (_announced.add(address)) {
        NetLog.ble('Device discovered: ${name ?? 'mesh phone'} (${r.rssi} dBm'
            '${adv != null ? ', mesh v${adv.protocolVersion}' : ''})');
      }
      _emit(link);
    }
  }

  // ---------------------------------------------------------------------------
  // Connecting
  // ---------------------------------------------------------------------------

  @override
  Future<void> connect(String linkId) {
    final link = _links[linkId];
    if (link == null || _isActive(link.info.state)) return Future.value();
    final attempt = ++link.attempt;
    _set(link, link.info.copyWith(
      state: LinkState.connecting,
      clearError: true,
      payloadSize: BleProtocol.attPayloadSize,
      hasAckChannel: false,
    ));
    final run = _connectQueue.then((_) => _connect(link, attempt));
    _connectQueue = run.catchError((_) {});
    return run;
  }

  Future<void> _connect(_PeerLink link, int attempt) async {
    if (link.attempt != attempt || link.info.state != LinkState.connecting) return;
    final device = link.device;
    NetLog.ble('Connecting: ${_label(link)}');
    try {
      await device.connect(timeout: connectTimeout, autoConnect: false);
    } catch (e) {
      if (link.attempt == attempt) _failLink(link, 'Connection failed (${_short(e)})', stage: 'Connect failed');
      return;
    }
    if (link.attempt != attempt) {
      unawaited(device.disconnect().catchError((_) {}));
      return;
    }

    link.stateSub?.cancel();
    link.stateSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) _onDisconnected(link, attempt);
    });
    _set(link, link.info.copyWith(state: LinkState.connected));
    NetLog.ble('Connected: ${_label(link)}');

    _set(link, link.info.copyWith(state: LinkState.serviceDiscovery));
    final List<BluetoothService> services;
    try {
      services = await device.discoverServices().timeout(discoverTimeout);
    } catch (e) {
      if (link.attempt == attempt) _failLink(link, 'GATT service discovery failed (${_short(e)})');
      return;
    }
    if (link.attempt != attempt) return;

    BluetoothService? service;
    for (final s in services) {
      if (BleProtocol.sameUuid(s.serviceUuid.str128, BleProtocol.serviceUuid)) service = s;
    }
    if (service == null) {
      _failLink(link, 'This device does not run the mesh BLE service');
      return;
    }
    BluetoothCharacteristic? find(String uuid) {
      for (final c in service!.characteristics) {
        if (BleProtocol.sameUuid(c.characteristicUuid.str128, uuid)) return c;
      }
      return null;
    }

    final dataNotify = find(BleProtocol.notifyCharacteristicUuid);
    final dataWrite = find(BleProtocol.writeCharacteristicUuid);
    final ack = find(BleProtocol.ackCharacteristicUuid);
    if (dataNotify == null || !dataNotify.properties.notify) {
      _failLink(link, 'The mesh service has no DATA notify characteristic');
      return;
    }
    if (dataWrite == null || !dataWrite.properties.write) {
      _failLink(link, 'The mesh service has no DATA write characteristic');
      return;
    }
    final ackUsable = ack != null && ack.properties.write && ack.properties.notify;
    NetLog.ble('GATT services discovered: ${_label(link)} (ACK ${ackUsable ? 'yes' : 'no'}, '
        'CONTROL ${find(BleProtocol.controlCharacteristicUuid) != null ? 'yes' : 'no'})');

    _cancelSubs(link);
    final linkId = link.info.linkId;
    link.subs.add(dataNotify.onValueReceived.listen((value) {
      if (value.isNotEmpty && !_frameEvents.isClosed) {
        _frameEvents.add(InboundFrame(linkId, MeshChannel.data, Uint8List.fromList(value)));
      }
    }));
    try {
      await dataNotify.setNotifyValue(true, timeout: notifyTimeoutSeconds);
    } catch (e) {
      if (link.attempt == attempt) _failLink(link, 'Could not subscribe to DATA notifications (${_short(e)})');
      return;
    }
    var hasAck = false;
    if (ackUsable) {
      link.subs.add(ack.onValueReceived.listen((value) {
        if (value.isNotEmpty && !_frameEvents.isClosed) {
          _frameEvents.add(InboundFrame(linkId, MeshChannel.ack, Uint8List.fromList(value)));
        }
      }));
      try {
        await ack.setNotifyValue(true, timeout: notifyTimeoutSeconds);
        hasAck = true;
      } catch (e) {
        NetLog.ble('ACK channel unavailable on ${_label(link)} (${_short(e)}) -- using DATA');
      }
    }
    if (link.attempt != attempt) return;
    link.dataWrite = dataWrite;
    link.ack = hasAck ? ack : null;

    final mtu = device.mtuNow;
    link.subs.add(device.mtu.listen((m) {
      if (link.attempt == attempt && link.info.isReady) {
        _set(link, link.info.copyWith(payloadSize: _payloadFor(m)));
      }
    }));
    _set(link, link.info.copyWith(
      state: LinkState.ready,
      payloadSize: _payloadFor(mtu),
      hasAckChannel: hasAck,
      clearError: true,
    ));
    NetLog.ble('Communication ready: ${_label(link)} (MTU $mtu)');
  }

  static int _payloadFor(int mtu) =>
      math.max(BleProtocol.attPayloadSize, math.min(mtu - 3, 512));

  void _onDisconnected(_PeerLink link, int attempt) {
    if (link.attempt != attempt) return;
    final state = link.info.state;
    if (!_isActive(state) || state == LinkState.disconnecting) return;
    link.attempt++;
    _cancelSubs(link);
    final reason = link.device.disconnectReason?.description ?? 'Connection lost';
    final next = state == LinkState.ready ? LinkState.disconnected : LinkState.error;
    _set(link, _closed(link.info, next, error: reason));
    NetLog.ble('Disconnected: ${_label(link)} ($reason)');
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  @override
  Future<bool> send(String linkId, MeshChannel channel, Uint8List frame) async {
    final link = _links[linkId];
    if (link == null || !link.info.isReady) return false;
    if (frame.isEmpty || frame.length > link.info.payloadSize) return false;
    final target = channel == MeshChannel.ack && link.ack != null ? link.ack : link.dataWrite;
    if (target == null) return false;
    try {
      await target.write(frame, withoutResponse: false, timeout: writeTimeoutSeconds);
      return true;
    } catch (e) {
      NetLog.ble('Write failed on ${_label(link)}: ${_short(e)}');
      return false;
    }
  }

  @override
  Future<void> setControlValue(Uint8List value) async {}

  // ---------------------------------------------------------------------------
  // Disconnecting
  // ---------------------------------------------------------------------------

  @override
  Future<void> disconnect(String linkId) async {
    final link = _links[linkId];
    if (link == null || !_isActive(link.info.state)) return;
    link.attempt++;
    _set(link, link.info.copyWith(state: LinkState.disconnecting));
    _cancelSubs(link);
    try {
      await link.device.disconnect();
    } catch (_) {}
    _set(link, _closed(link.info, LinkState.disconnected, clearError: true));
    NetLog.ble('Disconnected: ${_label(link)} (closed on this phone)');
  }

  void _failLink(_PeerLink link, String reason, {String stage = 'GATT setup failed'}) {
    link.attempt++;
    _cancelSubs(link);
    _set(link, _closed(link.info, LinkState.error, error: reason));
    NetLog.ble('$stage: ${_label(link)}: $reason');
    unawaited(link.device.disconnect().catchError((_) {}));
  }

  void _cancelSubs(_PeerLink link) {
    for (final s in link.subs) {
      unawaited(s.cancel());
    }
    link.subs.clear();
    if (!_isActive(link.info.state) || link.info.state == LinkState.disconnecting) {
      unawaited(link.stateSub?.cancel());
      link.stateSub = null;
    }
    link.dataWrite = null;
    link.ack = null;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static bool _isActive(LinkState s) =>
      s == LinkState.connecting || s.isConnectedish || s == LinkState.disconnecting;

  static LinkInfo _closed(LinkInfo info, LinkState state, {String? error, bool clearError = false}) =>
      info.copyWith(
        state: state,
        error: error,
        clearError: clearError,
        payloadSize: BleProtocol.attPayloadSize,
        hasAckChannel: false,
      );

  void _set(_PeerLink link, LinkInfo info) {
    link.info = info;
    _emit(link);
  }

  void _emit(_PeerLink link) {
    if (!_linkEvents.isClosed) _linkEvents.add(link.info);
  }

  void _setStatus(TransportAvailability availability, [String? detail]) {
    _status.value = TransportStatus(availability, detail);
  }

  static String _label(_PeerLink link) =>
      link.info.name ?? 'phone ..${link.info.address.length > 5 ? link.info.address.substring(link.info.address.length - 5) : link.info.address}';

  static String _short(Object e) {
    final text = e.toString();
    return text.length > 120 ? '${text.substring(0, 120)}...' : text;
  }
}
