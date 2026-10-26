import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/audit_event.dart';
import '../services/local_store.dart';

/// TAMPER-EVIDENT BLOCKCHAIN-INSPIRED EVENT LOG.
///
/// This is a local SHA-256 hash chain, not a decentralized blockchain
/// network -- each device keeps its own chain and there is no distributed
/// consensus. Calling it a "blockchain" without that qualifier would
/// overstate what it is.
///
/// Each event's hash is computed over its own fields plus the previous
/// event's hash. Altering any field of any past event -- or reordering, or
/// dropping one -- changes that event's hash, which no longer matches what
/// the next event recorded as its `previousHash`, and [verifyChain] catches
/// it.
///
/// The chain is persisted (LocalStore document 'audit_chain') so it
/// survives restarts; [load] re-verifies what it reads.
class AuditLogState extends ChangeNotifier {
  AuditLogState({this.persist = false});

  /// The fixed previousHash value for the first event in the chain.
  static const String genesisHash =
      '0000000000000000000000000000000000000000000000000000000000000000';

  static const String _document = 'audit_chain';

  /// Oldest entries beyond this are archived into the document's
  /// 'archivedHead' so the chain stays verifiable from that point.
  static const int maxEvents = 5000;

  final bool persist;

  final List<AuditEvent> events = [];

  /// Hash of the last archived (dropped) event, or [genesisHash].
  String _baseHash = genesisHash;

  /// The demo-tampered event's original, so the saved chain is never
  /// corrupted by the demo.
  int? _tamperedIndex;
  AuditEvent? _tamperedOriginal;

  late final DebouncedDocument _doc = DebouncedDocument(_document, () {
    final list = [
      for (var i = 0; i < events.length; i++)
        (i == _tamperedIndex && _tamperedOriginal != null)
            ? _tamperedOriginal!.toJson()
            : events[i].toJson(),
    ];
    return {'baseHash': _baseHash, 'events': list};
  });

  /// Restores a saved chain (newest first).
  Future<void> load() async {
    if (!persist) return;
    final doc = await LocalStore.read(_document);
    final raw = doc?['events'];
    if (raw is! List) return;
    final loaded = <AuditEvent>[];
    for (final item in raw) {
      final event = AuditEvent.fromJson(item);
      if (event != null) loaded.add(event);
    }
    events
      ..clear()
      ..addAll(loaded);
    _baseHash = doc?['baseHash'] as String? ?? genesisHash;
    notifyListeners();
  }

  /// Appends a new event, chaining it to whatever is currently the most
  /// recent event, and computes its hash. [event.hash] / [event.previousHash]
  /// are overwritten here regardless of what the caller set.
  void addEvent(AuditEvent event) {
    // The demo tamper keeps the stored hash, so events.first.hash is always
    // the genuine link.
    final previousHash = events.isEmpty ? _baseHash : events.first.hash!;

    event.previousHash = previousHash;
    event.hash = _computeHash(previousHash, event);

    events.insert(0, event);
    if (_tamperedIndex != null) _tamperedIndex = _tamperedIndex! + 1;
    if (events.length > maxEvents) {
      final dropped = events.removeLast();
      _baseHash = dropped.hash ?? _baseHash;
      if (_tamperedIndex == events.length) {
        _tamperedIndex = null;
        _tamperedOriginal = null;
      }
    }
    notifyListeners();
    if (persist) _doc.schedule();
  }

  String _computeHash(String previousHash, AuditEvent event) {
    final input = [
      previousHash,
      event.id,
      event.type.name,
      event.actorId,
      event.timestamp.toUtc().toIso8601String(),
      event.details,
    ].join('|');

    return sha256.convert(utf8.encode(input)).toString();
  }

  /// Walks the chain oldest-to-newest, recomputing each event's hash from
  /// its own fields and confirming it both matches what is stored AND
  /// matches what the next event recorded as its previousHash.
  bool verifyChain() {
    final chronological = events.reversed.toList();
    var expectedPrevious = _baseHash;

    for (final event in chronological) {
      if (event.previousHash != expectedPrevious) return false;

      final recomputed = _computeHash(expectedPrevious, event);
      if (recomputed != event.hash) return false;

      expectedPrevious = event.hash!;
    }

    return true;
  }

  /// Demo-only: corrupts the oldest event's details IN MEMORY, without
  /// recomputing its hash, so [verifyChain] can be shown catching it. The
  /// saved chain keeps the original; restarting the app restores it.
  void simulateTamperingForDemo() {
    if (events.isEmpty) return;

    final index = events.length - 1;
    final oldest = events[index];
    _tamperedIndex = index;
    _tamperedOriginal ??= oldest;
    events[index] = AuditEvent(
      id: oldest.id,
      type: oldest.type,
      actorId: oldest.actorId,
      timestamp: oldest.timestamp,
      details: '${oldest.details} [TAMPERED FOR DEMO]',
      previousHash: oldest.previousHash,
      hash: oldest.hash,
    );

    notifyListeners();
  }

  /// Undoes [simulateTamperingForDemo].
  void restoreAfterTamperDemo() {
    final index = _tamperedIndex;
    final original = _tamperedOriginal;
    if (index == null || original == null || index >= events.length) return;
    events[index] = original;
    _tamperedIndex = null;
    _tamperedOriginal = null;
    notifyListeners();
  }

  bool get isTamperDemoActive => _tamperedIndex != null;

  Future<void> flush() => persist ? _doc.flush() : Future.value();
}
