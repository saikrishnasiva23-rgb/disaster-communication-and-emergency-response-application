import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'net_log.dart';

/// Small persistent JSON document store (one file per document) used for the
/// SOS outbox, the relay store-and-forward queue, the dedup cache, the
/// rescue console's inbox and the audit chain.
///
/// * Works the same on Android and Windows (app support directory).
/// * Writes are atomic: a temp file is written, flushed, then renamed over
///   the old one, so a crash or power loss mid-write never leaves a
///   half-written document -- the previous version survives.
/// * Writes to one document are serialized; a burst of saves coalesces.
/// * If storage is unavailable (no path_provider in widget tests, disk
///   full, permission problem) the app keeps working from memory and
///   [lastError] says why -- data is never silently claimed to be saved.
class LocalStore {
  LocalStore._();

  static Directory? _overrideDirectory;
  static Future<Directory?>? _directory;

  /// Widget tests run in a fake-async zone where real file I/O never
  /// completes: they keep documents in memory instead.
  static Map<String, String>? _memory;

  /// Tests point the store at a temporary directory.
  @visibleForTesting
  static void useDirectoryForTesting(Directory? directory) {
    _overrideDirectory = directory;
    _directory = null;
    _memory = null;
  }

  /// Tests (widget tests) keep every document in memory.
  @visibleForTesting
  static void useMemoryForTesting() {
    _memory = {};
    _directory = null;
  }

  static String? lastError;

  static Future<Directory?> _dir() => _directory ??= _resolve();

  static Future<Directory?> _resolve() async {
    try {
      final base = _overrideDirectory ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}ble_store');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (e) {
      lastError = 'Local storage unavailable: $e';
      NetLog.store('storage unavailable -- running from memory only ($e)');
      return null;
    }
  }

  static final Map<String, Future<void>> _chains = {};

  static String _safe(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  /// Reads a document, or null if it does not exist / cannot be read. A
  /// corrupt file is moved aside (never deleted) so it can be inspected.
  static Future<Map<String, dynamic>?> read(String name) async {
    final memory = _memory;
    if (memory != null) {
      final text = memory[name];
      return text == null ? null : jsonDecode(text) as Map<String, dynamic>;
    }
    final dir = await _dir();
    if (dir == null) return null;
    final file = File('${dir.path}${Platform.pathSeparator}${_safe(name)}.json');
    try {
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      NetLog.store('could not read $name ($e); keeping a copy as .corrupt');
      try {
        await file.rename('${file.path}.corrupt');
      } catch (_) {}
      return null;
    }
  }

  /// Atomically replaces a document. Returns false if it could not be saved.
  static Future<bool> write(String name, Map<String, dynamic> document) {
    final memory = _memory;
    if (memory != null) {
      memory[name] = jsonEncode(document);
      return Future.value(true);
    }
    final completer = Completer<bool>();
    final previous = _chains[name] ?? Future<void>.value();
    final next = previous.then((_) async {
      completer.complete(await _writeNow(name, document));
    });
    _chains[name] = next;
    return completer.future;
  }

  static Future<bool> _writeNow(String name, Map<String, dynamic> document) async {
    final dir = await _dir();
    if (dir == null) return false;
    final path = '${dir.path}${Platform.pathSeparator}${_safe(name)}.json';
    final temp = File('$path.tmp');
    try {
      await temp.writeAsString(jsonEncode(document), flush: true);
      await temp.rename(path);
      return true;
    } catch (e) {
      lastError = 'Could not save $name: $e';
      NetLog.store('write of $name failed ($e)');
      return false;
    }
  }

  static Future<void> delete(String name) async {
    if (_memory != null) {
      _memory!.remove(name);
      return;
    }
    final dir = await _dir();
    if (dir == null) return;
    final file = File('${dir.path}${Platform.pathSeparator}${_safe(name)}.json');
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// A [LocalStore] document that saves at most once per [delay] while it is
/// being changed rapidly (e.g. many frames / ACKs in a burst).
class DebouncedDocument {
  DebouncedDocument(this.name, this.build, {this.delay = const Duration(milliseconds: 250)});

  final String name;
  final Map<String, dynamic> Function() build;
  final Duration delay;
  Timer? _timer;

  void schedule() {
    _timer?.cancel();
    _timer = Timer(delay, flush);
  }

  Future<bool> flush() {
    _timer?.cancel();
    _timer = null;
    return LocalStore.write(name, build());
  }
}
