// Channel-level tests of AndroidPeripheralTransport against a MOCKED native
// side (the real one is MeshGattServer.kt). They prove the Dart mapping of
// advertising / connection / subscription / MTU / write events -- not that
// a physical radio advertises or connects.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/services/mesh/android_peripheral_transport.dart';
import 'package:disaster_communication_app/services/mesh/mesh_link.dart';

const _methods = MethodChannel('disaster_communication/ble_peripheral');
const _events = EventChannel('disaster_communication/ble_peripheral/events');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late MockStreamHandlerEventSink? sink;

  setUp(() {
    AndroidPeripheralTransport.debugIsAndroid = true;
    calls = [];
    sink = null;
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'isSupported':
          return true;
        case 'permissionStatus':
          return 'granted';
        case 'isBluetoothOn':
          return true;
        case 'start':
          return {'ok': true, 'code': null};
        case 'notify':
          return true;
        default:
          return null;
      }
    });
    messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(onListen: (args, events) => sink = events),
    );
  });

  tearDown(() {
    AndroidPeripheralTransport.debugIsAndroid = null;
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockStreamHandler(_events, null);
  });

  Future<void> emit(Map<String, Object?> event) async {
    sink!.success(event);
    await Future<void>.delayed(Duration.zero);
  }

  test('advertising starts with the capability record and reports active', () async {
    final record = Uint8List.fromList([3, 1, 0xAA, 0xBB, 0xCC, 0xDD]);
    final t = AndroidPeripheralTransport(manufacturerData: () => record);
    expect(await t.start(), isTrue);
    expect(t.status.value.availability, TransportAvailability.active);
    final start = calls.firstWhere((c) => c.method == 'start');
    expect((start.arguments as Map)['manufacturerData'], record);
    await t.stop();
  });

  test('a central connects, subscribes, negotiates MTU, writes -- per device', () async {
    final t = AndroidPeripheralTransport(manufacturerData: () => Uint8List(6));
    final links = <LinkInfo>[];
    final frames = <InboundFrame>[];
    t.links.listen(links.add);
    t.frames.listen(frames.add);
    await t.start();

    await emit({'event': 'connection', 'address': 'AA:01', 'connected': true, 'status': 0});
    expect(links.last.state, LinkState.connected, reason: 'connected is not ready');
    await emit({'event': 'subscription', 'address': 'AA:01', 'characteristic': 'data', 'enabled': true});
    expect(links.last.state, LinkState.ready);
    await emit({'event': 'subscription', 'address': 'AA:01', 'characteristic': 'ack', 'enabled': true});
    expect(links.last.hasAckChannel, isTrue);
    await emit({'event': 'mtu', 'address': 'AA:01', 'mtu': 247});
    expect(links.last.payloadSize, 244);

    // A second central at the same time: its own link, its own state.
    await emit({'event': 'connection', 'address': 'BB:02', 'connected': true, 'status': 0});
    await emit({'event': 'subscription', 'address': 'BB:02', 'characteristic': 'data', 'enabled': true});
    final ids = links.map((l) => l.linkId).toSet();
    expect(ids, {'peripheral:AA:01', 'peripheral:BB:02'});

    // Writes are tagged with the writer and the characteristic.
    await emit({'event': 'write', 'address': 'BB:02', 'characteristic': 'ack', 'value': Uint8List.fromList([1, 2, 3])});
    expect(frames.single.linkId, 'peripheral:BB:02');
    expect(frames.single.channel, MeshChannel.ack);

    // Sending goes to ONE device on the requested characteristic.
    expect(await t.send('peripheral:AA:01', MeshChannel.ack, Uint8List.fromList([9])), isTrue);
    final notify = calls.lastWhere((c) => c.method == 'notify').arguments as Map;
    expect(notify['address'], 'AA:01');
    expect(notify['characteristic'], 'ack');

    // A frame larger than the link's MTU is refused, never truncated.
    expect(await t.send('peripheral:BB:02', MeshChannel.data, Uint8List(21)), isFalse);

    // Disconnect (any status) ends the link; sending to it then fails.
    await emit({'event': 'connection', 'address': 'AA:01', 'connected': false, 'status': 8});
    expect(links.last.linkId, 'peripheral:AA:01');
    expect(links.last.state, LinkState.disconnected);
    expect(await t.send('peripheral:AA:01', MeshChannel.data, Uint8List(4)), isFalse);
    await t.stop();
  });

  test('Bluetooth off drops every link and reports it', () async {
    final t = AndroidPeripheralTransport(manufacturerData: () => Uint8List(6));
    final links = <LinkInfo>[];
    t.links.listen(links.add);
    await t.start();
    await emit({'event': 'connection', 'address': 'AA:01', 'connected': true, 'status': 0});
    await emit({'event': 'subscription', 'address': 'AA:01', 'characteristic': 'data', 'enabled': true});
    await emit({'event': 'adapter', 'state': 'off'});
    expect(links.last.state, LinkState.disconnected);
    expect(t.status.value.availability, TransportAvailability.bluetoothOff);
    await t.stop();
  });

  test('permission refused -> permissionDenied, nothing advertised', () async {
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      return switch (call.method) {
        'isSupported' => true,
        'permissionStatus' || 'requestPermissions' => 'permanentlyDenied',
        _ => null,
      };
    });
    final t = AndroidPeripheralTransport(manufacturerData: () => Uint8List(6));
    expect(await t.start(), isFalse);
    expect(t.status.value.availability, TransportAvailability.permissionDenied);
    expect(calls.any((c) => c.method == 'start'), isFalse);
  });
}
