// LOGIC-TEST SUPPORT ONLY -- a simulated radio that connects real MeshNode
// instances in memory. It proves the routing logic; it is NOT Bluetooth and
// says nothing about real hardware behaviour.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:disaster_communication_app/services/ble_protocol.dart';
import 'package:disaster_communication_app/services/mesh/mesh_link.dart';

class _Pair {
  _Pair(this.central, this.centralLinkId, this.peripheral, this.peripheralLinkId);

  final FakeTransport central;
  final String centralLinkId;
  final FakeTransport peripheral;
  final String peripheralLinkId;
  bool up = true;
}

/// One simulated device role (peripheral or central) of one node.
class FakeTransport implements MeshTransport {
  FakeTransport(this.radio, this.owner, this.side, this.deviceId)
      : address = '${side == LinkSide.central ? 'C' : 'P'}-$owner';

  final FakeRadio radio;

  /// Node name, e.g. 'A'.
  final String owner;
  @override
  final LinkSide side;

  /// The owning node's app-level id (for its advertisement tag).
  final String deviceId;
  final String address;

  final ValueNotifier<TransportStatus> _status =
      ValueNotifier(const TransportStatus(TransportAvailability.stopped));
  final StreamController<LinkInfo> _links = StreamController.broadcast();
  final StreamController<InboundFrame> _frames = StreamController.broadcast();

  @override
  ValueListenable<TransportStatus> get status => _status;
  @override
  Stream<LinkInfo> get links => _links.stream;
  @override
  Stream<InboundFrame> get frames => _frames.stream;

  void emitLink(LinkInfo info) {
    if (!_links.isClosed) _links.add(info);
  }

  void emitFrame(InboundFrame frame) {
    if (!_frames.isClosed) _frames.add(frame);
  }

  @override
  Future<bool> start() async {
    _status.value = const TransportStatus(TransportAvailability.active);
    radio._register(this);
    return true;
  }

  @override
  Future<void> stop() async {
    radio._unregister(this);
    _status.value = const TransportStatus(TransportAvailability.stopped);
  }

  @override
  Future<bool> send(String linkId, MeshChannel channel, Uint8List frame) =>
      radio._deliver(this, linkId, channel, frame);

  @override
  Future<void> connect(String linkId) => radio._connect(this, linkId);

  @override
  Future<void> disconnect(String linkId) async => radio._disconnectLink(this, linkId);

  @override
  Future<void> setControlValue(Uint8List value) async {}

  Future<void> close() async {
    await _links.close();
    await _frames.close();
  }
}

/// The simulated air. Devices only "see" each other when [inRange].
class FakeRadio {
  FakeRadio({this.payloadSize = 20, this.ackChannel = true});

  int payloadSize;
  bool ackChannel;

  final Map<String, FakeTransport> _peripherals = {};
  final Map<String, FakeTransport> _centrals = {};
  final Set<String> _range = {};
  final List<_Pair> _pairs = [];

  /// Every frame accepted for delivery (for traffic bounds).
  int framesSent = 0;

  /// Every complete JSON message sent over the air, by type.
  final Map<String, int> messagesByType = {};

  static String _key(String a, String b) => ([a, b]..sort()).join('|');

  void inRange(String a, String b) => _range.add(_key(a, b));

  void outOfRange(String a, String b) {
    _range.remove(_key(a, b));
    for (final p in _pairs.where((p) =>
        p.up &&
        _key(p.central.owner, p.peripheral.owner) == _key(a, b))) {
      _down(p, 'out of range');
    }
  }

  bool canSee(String a, String b) => _range.contains(_key(a, b));

  /// Live links between two nodes (either direction).
  int linksBetween(String a, String b) => _pairs
      .where((p) => p.up && _key(p.central.owner, p.peripheral.owner) == _key(a, b))
      .length;

  /// Every live link as 'central->peripheral' owner names.
  List<String> get liveLinks => [
        for (final p in _pairs.where((p) => p.up)) '${p.central.owner}->${p.peripheral.owner}',
      ];

  void _register(FakeTransport t) =>
      (t.side == LinkSide.peripheral ? _peripherals : _centrals)[t.owner] = t;

  void _unregister(FakeTransport t) {
    (t.side == LinkSide.peripheral ? _peripherals : _centrals).remove(t.owner);
    for (final p in _pairs.where((p) => p.up && (p.central == t || p.peripheral == t)).toList()) {
      _down(p, 'stopped');
    }
  }

  /// Every central scanner "sees" every in-range peripheral once.
  void advertise() {
    for (final c in _centrals.values) {
      for (final p in _peripherals.values) {
        if (c.owner == p.owner || !canSee(c.owner, p.owner)) continue;
        final linkId = LinkInfo.idFor(LinkSide.central, p.address);
        if (_pairs.any((x) => x.up && x.central == c && x.centralLinkId == linkId)) continue;
        c.emitLink(LinkInfo(
          linkId: linkId,
          side: LinkSide.central,
          address: p.address,
          state: LinkState.discovered,
          updatedAt: DateTime.now(),
          name: 'Phone ${p.owner}',
          advertisement: MeshAdvertisement(
            protocolVersion: 3,
            relayCapable: true,
            idTag: MeshAdvertisement.tagFor(p.deviceId),
          ),
        ));
      }
    }
  }

  Future<void> _connect(FakeTransport central, String linkId) async {
    final address = linkId.substring(linkId.indexOf(':') + 1);
    final peripheral = _peripherals.values.where((p) => p.address == address).firstOrNull;
    LinkInfo info(LinkState s) => LinkInfo(
          linkId: linkId,
          side: LinkSide.central,
          address: address,
          state: s,
          updatedAt: DateTime.now(),
          name: peripheral == null ? null : 'Phone ${peripheral.owner}',
          payloadSize: payloadSize,
          hasAckChannel: ackChannel,
        );
    central.emitLink(info(LinkState.connecting));
    await Future<void>.delayed(Duration.zero);
    if (peripheral == null || !canSee(central.owner, peripheral.owner)) {
      central.emitLink(info(LinkState.error).copyWith(error: 'out of range'));
      return;
    }
    final peripheralLinkId = LinkInfo.idFor(LinkSide.peripheral, central.address);
    _pairs.removeWhere((p) => p.central == central && p.centralLinkId == linkId);
    final pair = _Pair(central, linkId, peripheral, peripheralLinkId);
    _pairs.add(pair);
    central.emitLink(info(LinkState.connected));
    central.emitLink(info(LinkState.serviceDiscovery));
    peripheral.emitLink(LinkInfo(
      linkId: peripheralLinkId,
      side: LinkSide.peripheral,
      address: central.address,
      state: LinkState.ready,
      updatedAt: DateTime.now(),
      payloadSize: payloadSize,
      hasAckChannel: ackChannel,
    ));
    central.emitLink(info(LinkState.ready));
  }

  void _disconnectLink(FakeTransport t, String linkId) {
    for (final p in _pairs.where((p) =>
        p.up &&
        ((p.central == t && p.centralLinkId == linkId) ||
            (p.peripheral == t && p.peripheralLinkId == linkId))).toList()) {
      _down(p, 'disconnected');
    }
  }

  void _down(_Pair p, String reason) {
    p.up = false;
    LinkInfo closed(String linkId, LinkSide side, String address) => LinkInfo(
          linkId: linkId,
          side: side,
          address: address,
          state: LinkState.disconnected,
          updatedAt: DateTime.now(),
          error: reason,
        );
    p.central.emitLink(closed(p.centralLinkId, LinkSide.central, p.peripheral.address));
    p.peripheral.emitLink(closed(p.peripheralLinkId, LinkSide.peripheral, p.central.address));
  }

  /// Drops every link between two nodes (devices stay in range).
  void dropLinks(String a, String b) {
    for (final p in _pairs.where((p) =>
        p.up && _key(p.central.owner, p.peripheral.owner) == _key(a, b)).toList()) {
      _down(p, 'link dropped');
    }
  }

  final Map<String, List<int>> _partial = {};

  Future<bool> _deliver(
      FakeTransport sender, String linkId, MeshChannel channel, Uint8List frame) async {
    final pair = _pairs.where((p) =>
        p.up &&
        ((p.central == sender && p.centralLinkId == linkId) ||
            (p.peripheral == sender && p.peripheralLinkId == linkId))).firstOrNull;
    if (pair == null) return false;
    if (frame.length > payloadSize) return false;
    framesSent++;
    _countMessage('$linkId|${channel.name}|${sender.address}', frame);
    final toCentral = pair.peripheral == sender;
    final target = toCentral ? pair.central : pair.peripheral;
    final targetLinkId = toCentral ? pair.centralLinkId : pair.peripheralLinkId;
    scheduleMicrotask(() {
      if (pair.up) target.emitFrame(InboundFrame(targetLinkId, channel, frame));
    });
    return true;
  }

  void _countMessage(String key, Uint8List frame) {
    if (frame.length < BleFrameCodec.headerSize || frame[0] != BleFrameCodec.magic) return;
    final index = frame[2];
    final count = frame[3];
    final parts = index == 0 ? <int>[] : (_partial[key] ?? <int>[]);
    parts.addAll(frame.sublist(BleFrameCodec.headerSize));
    if (index + 1 < count) {
      _partial[key] = parts;
      return;
    }
    _partial.remove(key);
    try {
      final json = jsonDecode(utf8.decode(parts)) as Map<String, dynamic>;
      final type = json['type'] as String? ?? '?';
      final kind = type == 'ACK' ? 'ACK:${json['k'] ?? json['by']}' : type;
      messagesByType[kind] = (messagesByType[kind] ?? 0) + 1;
    } catch (_) {}
  }
}
