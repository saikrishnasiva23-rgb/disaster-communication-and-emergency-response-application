import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ble_protocol.dart';
import '../net_log.dart';
import 'mesh_link.dart';

enum MeshPermissionResult { granted, denied, permanentlyDenied }

/// The affected phone's BLE peripheral over the app's own native GATT
/// server + advertiser (android/.../MeshGattServer.kt).
///
/// One link per connected central (Rescue Team laptop or relay phone),
/// keyed by its address. A link is READY only once that central subscribed
/// to the DATA notify characteristic -- the exact condition under which a
/// notification can reach it. Every notification goes to ONE central.
class AndroidPeripheralTransport implements MeshTransport {
  AndroidPeripheralTransport({required this.manufacturerData});

  /// The 6-byte MeshAdvertisement put in the scan response.
  final Uint8List Function() manufacturerData;

  static const MethodChannel _methods = MethodChannel('disaster_communication/ble_peripheral');
  static const EventChannel _events = EventChannel('disaster_communication/ble_peripheral/events');

  /// Tests exercise the channel mapping on the host.
  @visibleForTesting
  static bool? debugIsAndroid;

  static bool get _isAndroid => debugIsAndroid ?? (!kIsWeb && Platform.isAndroid);

  final ValueNotifier<TransportStatus> _status =
      ValueNotifier(const TransportStatus(TransportAvailability.stopped));
  final StreamController<LinkInfo> _linkEvents = StreamController.broadcast();
  final StreamController<InboundFrame> _frameEvents = StreamController.broadcast();

  final Map<String, LinkInfo> _links = {};
  final Map<String, Set<String>> _subscribed = {};
  StreamSubscription<dynamic>? _eventSub;
  Future<bool>? _starting;
  Uint8List? _lastControl;

  @override
  LinkSide get side => LinkSide.peripheral;

  @override
  ValueListenable<TransportStatus> get status => _status;

  @override
  Stream<LinkInfo> get links => _linkEvents.stream;

  @override
  Stream<InboundFrame> get frames => _frameEvents.stream;

  // ---------------------------------------------------------------------------
  // Static platform helpers (no-ops off Android)
  // ---------------------------------------------------------------------------

  static MeshPermissionResult _permission(Object? raw) => switch (raw) {
        'granted' => MeshPermissionResult.granted,
        'permanentlyDenied' => MeshPermissionResult.permanentlyDenied,
        _ => MeshPermissionResult.denied,
      };

  static Future<MeshPermissionResult> permissionStatus() async {
    if (!_isAndroid) return MeshPermissionResult.denied;
    try {
      return _permission(await _methods.invokeMethod<String>('permissionStatus'));
    } catch (_) {
      return MeshPermissionResult.denied;
    }
  }

  /// Bluetooth (advertise / connect / scan), plus location for GPS and the
  /// foreground-service notification -- only the Bluetooth ones decide the
  /// result.
  static Future<MeshPermissionResult> requestPermissions() async {
    if (!_isAndroid) return MeshPermissionResult.denied;
    try {
      return _permission(await _methods.invokeMethod<String>('requestPermissions'));
    } catch (_) {
      return MeshPermissionResult.denied;
    }
  }

  static Future<bool> isBluetoothOn() async {
    if (!_isAndroid) return false;
    try {
      return await _methods.invokeMethod<bool>('isBluetoothOn') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> enableBluetooth() async {
    if (!_isAndroid) return false;
    try {
      return await _methods.invokeMethod<bool>('enableBluetooth') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openAppSettings() async {
    if (!_isAndroid) return;
    try {
      await _methods.invokeMethod<void>('openAppSettings');
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Start / stop
  // ---------------------------------------------------------------------------

  @override
  Future<bool> start() {
    if (_status.value.isActive) return Future.value(true);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<bool> _start() async {
    if (!_isAndroid) {
      return _fail(TransportAvailability.unsupported, 'Bluetooth peripheral mode needs an Android phone.');
    }
    _setStatus(TransportAvailability.starting);
    try {
      final supported = await _methods.invokeMethod<bool>('isSupported') ?? false;
      if (!supported) {
        return _fail(TransportAvailability.unsupported,
            'This phone cannot act as a Bluetooth LE peripheral (advertising not supported).');
      }
      var permission = await permissionStatus();
      if (permission != MeshPermissionResult.granted) permission = await requestPermissions();
      if (permission != MeshPermissionResult.granted) {
        return _fail(
          TransportAvailability.permissionDenied,
          permission == MeshPermissionResult.permanentlyDenied
              ? 'Bluetooth permission is blocked. Allow "Nearby devices" for this app in Settings, then tap Retry.'
              : 'Allow "Nearby devices" (and Location) for this app, then tap Retry.',
        );
      }
      if (!await isBluetoothOn() && !await enableBluetooth()) {
        return _fail(TransportAvailability.bluetoothOff, 'Bluetooth is off. Turn it on, then tap Retry.');
      }

      _eventSub ??= _events.receiveBroadcastStream().listen(_onEvent,
          onError: (Object e) => NetLog.ble('Peripheral event error: $e'));

      final result = await _methods.invokeMapMethod<String, dynamic>(
        'start',
        {'manufacturerData': manufacturerData()},
      );
      final ok = result?['ok'] == true;
      final code = result?['code'] as String?;
      if (!ok) {
        return _fail(
          code == 'BLUETOOTH_OFF'
              ? TransportAvailability.bluetoothOff
              : code == 'PERMISSION_DENIED'
                  ? TransportAvailability.permissionDenied
                  : TransportAvailability.failed,
          _describe(code, result?['message'] as String?),
        );
      }
      _setStatus(TransportAvailability.active);
      NetLog.ble('Advertising started (mesh service'
          '${code == 'NO_SCAN_RESPONSE' ? ', without the capability record' : ', capability record in scan response'})');
      return true;
    } on PlatformException catch (e) {
      return _fail(TransportAvailability.failed, _describe(e.code, e.message));
    } catch (e) {
      return _fail(TransportAvailability.failed, 'Bluetooth is unavailable on this phone right now.');
    }
  }

  String _describe(String? code, String? message) => switch (code) {
        'DATA_TOO_LARGE' => 'The phone rejected the advertisement as too large.',
        'TOO_MANY_ADVERTISERS' =>
          'Too many apps are using Bluetooth advertising. Close other Bluetooth apps and tap Retry.',
        'FEATURE_UNSUPPORTED' => 'This phone does not support BLE advertising.',
        'INTERNAL_ERROR' => 'Bluetooth reported an internal error. Toggle Bluetooth off and on, then tap Retry.',
        'PERMISSION_DENIED' => 'Bluetooth permission missing. Allow "Nearby devices", then tap Retry.',
        'SERVICE_ADD_FAILED' || 'SERVER_FAILED' =>
          'The Bluetooth GATT server could not start. Toggle Bluetooth off and on, then tap Retry.',
        'BLUETOOTH_OFF' => 'Bluetooth is off. Turn it on, then tap Retry.',
        _ => 'Bluetooth advertising failed (${message ?? code ?? 'unknown'}).',
      };

  bool _fail(TransportAvailability availability, String detail) {
    _setStatus(availability, detail);
    NetLog.ble('Advertising not started: $detail');
    return false;
  }

  @override
  Future<void> stop() async {
    if (_isAndroid) {
      try {
        await _methods.invokeMethod<void>('stop');
      } catch (_) {}
    }
    for (final id in _links.keys.toList()) {
      _drop(id, 'Stopped');
    }
    _setStatus(TransportAvailability.stopped);
    NetLog.ble('Advertising stopped');
  }

  // ---------------------------------------------------------------------------
  // Native events
  // ---------------------------------------------------------------------------

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final event = raw['event'];
    final address = raw['address'] as String?;
    switch (event) {
      case 'adapter':
        final state = raw['state'];
        if (state == 'off') {
          for (final id in _links.keys.toList()) {
            _drop(id, 'Bluetooth off');
          }
          _setStatus(TransportAvailability.bluetoothOff, 'Bluetooth was turned off.');
          NetLog.ble('Bluetooth turned off');
        } else if (state == 'on') {
          NetLog.ble('Bluetooth turned on -- restarting advertising');
        }
      case 'advertising':
        if (raw['active'] == true) {
          _setStatus(TransportAvailability.active);
        } else if (raw['code'] == 'BLUETOOTH_OFF') {
          _setStatus(TransportAvailability.bluetoothOff, 'Bluetooth is off.');
        } else if (_status.value.isActive) {
          _setStatus(TransportAvailability.failed,
              _describe(raw['code'] as String?, raw['message'] as String?));
        }
      case 'connection':
        if (address == null) return;
        final id = LinkInfo.idFor(LinkSide.peripheral, address);
        if (raw['connected'] == true) {
          final existing = _links[id];
          if (existing == null || !existing.state.isConnectedish) {
            _set(LinkInfo(
              linkId: id,
              side: LinkSide.peripheral,
              address: address,
              state: LinkState.connected,
              updatedAt: DateTime.now(),
            ));
            NetLog.ble('Connected: central ..${_short(address)}');
          }
        } else {
          _drop(id, 'Disconnected (status ${raw['status']})');
        }
      case 'subscription':
        if (address == null) return;
        _onSubscription(address, raw['characteristic'] as String?, raw['enabled'] == true);
      case 'mtu':
        if (address == null) return;
        final id = LinkInfo.idFor(LinkSide.peripheral, address);
        final link = _links[id];
        final mtu = (raw['mtu'] as num?)?.toInt() ?? 23;
        if (link != null) _set(link.copyWith(payloadSize: _payloadFor(mtu)));
      case 'write':
        if (address == null) return;
        final id = LinkInfo.idFor(LinkSide.peripheral, address);
        final value = raw['value'];
        if (value is! Uint8List || value.isEmpty) return;
        final channel = raw['characteristic'] == 'ack' ? MeshChannel.ack : MeshChannel.data;
        if (!_links.containsKey(id)) {
          _set(LinkInfo(
            linkId: id,
            side: LinkSide.peripheral,
            address: address,
            state: LinkState.connected,
            updatedAt: DateTime.now(),
          ));
        }
        if (!_frameEvents.isClosed) _frameEvents.add(InboundFrame(id, channel, value));
      case 'warning':
        NetLog.ble('Warning: ${raw['message']}');
    }
  }

  void _onSubscription(String address, String? characteristic, bool enabled) {
    if (characteristic == null) return;
    final id = LinkInfo.idFor(LinkSide.peripheral, address);
    final set = _subscribed.putIfAbsent(id, () => <String>{});
    enabled ? set.add(characteristic) : set.remove(characteristic);
    final link = _links[id] ??
        LinkInfo(
          linkId: id,
          side: LinkSide.peripheral,
          address: address,
          state: LinkState.connected,
          updatedAt: DateTime.now(),
        );
    final ready = set.contains('data');
    _set(link.copyWith(
      state: ready ? LinkState.ready : LinkState.connected,
      hasAckChannel: set.contains('ack'),
    ));
    if (characteristic == 'data') {
      NetLog.ble(ready
          ? 'Communication ready: central ..${_short(address)} subscribed to DATA'
          : 'Central ..${_short(address)} unsubscribed from DATA');
    }
  }

  void _drop(String linkId, String reason) {
    final link = _links.remove(linkId);
    _subscribed.remove(linkId);
    if (link == null) return;
    final closed = link.copyWith(
      state: LinkState.disconnected,
      error: reason,
      payloadSize: BleProtocol.attPayloadSize,
      hasAckChannel: false,
    );
    if (!_linkEvents.isClosed) _linkEvents.add(closed);
    NetLog.ble('Disconnected: central ..${_short(link.address)} ($reason)');
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  @override
  Future<bool> send(String linkId, MeshChannel channel, Uint8List frame) async {
    final link = _links[linkId];
    if (link == null || !link.isReady || !_isAndroid) return false;
    if (frame.isEmpty || frame.length > link.payloadSize) return false;
    final characteristic =
        channel == MeshChannel.ack && link.hasAckChannel ? 'ack' : 'data';
    try {
      return await _methods.invokeMethod<bool>('notify', {
            'address': link.address,
            'characteristic': characteristic,
            'value': frame,
          }) ??
          false;
    } catch (e) {
      NetLog.ble('Notify failed to ..${_short(link.address)}: $e');
      return false;
    }
  }

  @override
  Future<void> setControlValue(Uint8List value) async {
    if (!_isAndroid) return;
    final last = _lastControl;
    if (last != null && listEquals(last, value)) return;
    _lastControl = value;
    try {
      await _methods.invokeMethod<void>('setControlValue', {'value': value});
    } catch (_) {}
  }

  @override
  Future<void> connect(String linkId) async {}

  @override
  Future<void> disconnect(String linkId) async {
    final link = _links[linkId];
    if (link == null || !_isAndroid) return;
    try {
      await _methods.invokeMethod<void>('disconnect', {'address': link.address});
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static int _payloadFor(int mtu) =>
      math.max(BleProtocol.attPayloadSize, math.min(mtu - 3, 512));

  void _set(LinkInfo info) {
    _links[info.linkId] = info;
    if (!_linkEvents.isClosed) _linkEvents.add(info);
  }

  void _setStatus(TransportAvailability availability, [String? detail]) {
    _status.value = TransportStatus(availability, detail);
  }

  static String _short(String address) =>
      address.length > 5 ? address.substring(address.length - 5) : address;
}
