import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net_server.dart';

/// Why something on the network did not work, in the native side's words
/// (android/…/net/core/NetCore.kt NetError). The screens turn [code] into a
/// sentence; [detail] is the new fingerprint for `hostkey_changed`.
class NetFailure implements Exception {
  const NetFailure(this.code, [this.message, this.detail]);
  final String code;
  final String? message;
  final String? detail;

  static NetFailure from(Object e) {
    if (e is NetFailure) return e;
    if (e is PlatformException) {
      return NetFailure(e.code, e.message, e.details as String?);
    }
    if (e is MissingPluginException) return const NetFailure('unsupported');
    if (e is TimeoutException) return const NetFailure('timeout');
    return NetFailure('protocol', e.toString());
  }

  @override
  String toString() => 'NetFailure($code, $message)';
}

class ScanHit {
  const ScanHit(this.ip, this.port, this.name);
  final String ip;
  final int port;
  final String? name;
}

class ScanResult {
  const ScanResult(this.subnet, this.hits);
  final String subnet;
  final List<ScanHit> hits;
}

/// The native channel (android/…/net/NetPlugin.kt). Swappable in tests.
class NetChannel {
  const NetChannel();
  static const MethodChannel _ch = MethodChannel('mx_clone/net');

  Future<T> _call<T>(
      String method, Map<String, dynamic> args, Duration limit) async {
    try {
      final r = await _ch.invokeMethod<dynamic>(method, args).timeout(limit);
      return r as T;
    } catch (e) {
      throw NetFailure.from(e);
    }
  }

  /// Signs in; returns the start folder and the server's fingerprint.
  Future<({String home, String? fingerprint})> connect(
      Map<String, dynamic> spec) async {
    final m = await _call<Map<dynamic, dynamic>>('connect',
        <String, dynamic>{'spec': spec}, const Duration(seconds: 45));
    return (
      home: m['home'] as String,
      fingerprint: m['fingerprint'] as String?
    );
  }

  Future<List<NetEntry>> list(Map<String, dynamic> spec, String path) async {
    final l = await _call<List<dynamic>>(
        'list',
        <String, dynamic>{'spec': spec, 'path': path},
        const Duration(seconds: 60));
    return l.map((e) => NetEntry.fromMap(e as Map<dynamic, dynamic>)).toList();
  }

  Future<String> url(Map<String, dynamic> spec, String path) => _call<String>(
      'url',
      <String, dynamic>{'spec': spec, 'path': path},
      const Duration(seconds: 10));

  Future<void> register(List<Map<String, dynamic>> specs) => _call<dynamic>(
      'register',
      <String, dynamic>{'specs': specs},
      const Duration(seconds: 10));

  Future<void> forget(String id) => _call<dynamic>(
      'forget', <String, dynamic>{'id': id}, const Duration(seconds: 10));

  Future<ScanResult> scan(NetProtocol p) async {
    final m = await _call<Map<dynamic, dynamic>>('scan',
        <String, dynamic>{'protocol': p.name}, const Duration(seconds: 30));
    final hits = (m['hits'] as List<dynamic>)
        .map((h) => h as Map<dynamic, dynamic>)
        .map((h) => ScanHit(h['ip'] as String, (h['port'] as num).toInt(),
            h['name'] as String?))
        .toList();
    return ScanResult(m['subnet'] as String? ?? '', hits);
  }
}

/// Saved servers: the list in SharedPreferences, the secrets in the
/// Keystore-backed secure storage (never in a backup, never in the list).
class NetStore {
  NetStore({FlutterSecureStorage? secure}) : _secure = secure ?? _defaultSecure;

  static const String _kList = 'net.servers.v1';
  static const FlutterSecureStorage _defaultSecure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final FlutterSecureStorage _secure;

  Future<List<NetServer>> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kList);
    if (raw == null) return <NetServer>[];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => NetServer.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      if (kDebugMode) debugPrint('NetStore.load: $e');
      return <NetServer>[];
    }
  }

  Future<void> save(List<NetServer> servers) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
        _kList, jsonEncode(servers.map((s) => s.toJson()).toList()));
  }

  Future<NetSecrets> secrets(String id) async {
    try {
      return NetSecrets.decode(await _secure.read(key: 'net.secret.$id'));
    } catch (e) {
      if (kDebugMode) debugPrint('NetStore.secrets: $e');
      return NetSecrets.none;
    }
  }

  Future<void> setSecrets(String id, NetSecrets s) async {
    try {
      await _secure.write(key: 'net.secret.$id', value: s.encode());
    } catch (e) {
      if (kDebugMode) debugPrint('NetStore.setSecrets: $e');
    }
  }

  Future<void> deleteSecrets(String id) async {
    try {
      await _secure.delete(key: 'net.secret.$id');
    } catch (_) {}
  }
}

final netChannelProvider = Provider<NetChannel>((ref) => const NetChannel());
final netStoreProvider = Provider<NetStore>((ref) => NetStore());

/// The saved servers, most recently used first.
class NetServersNotifier extends StateNotifier<List<NetServer>> {
  NetServersNotifier(this._store, this._channel) : super(const <NetServer>[]) {
    _ready = _load();
  }

  final NetStore _store;
  final NetChannel _channel;
  late final Future<void> _ready;
  bool loaded = false;

  Future<void> get ready => _ready;

  Future<void> _load() async {
    final list = await _store.load();
    list.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    if (mounted) state = list;
    loaded = true;
    // So a network film resumed from History after a restart can open: the
    // player's URL names the server, and the native side needs its spec.
    unawaited(_registerAll(list));
  }

  Future<void> _registerAll(List<NetServer> list) async {
    try {
      final specs = <Map<String, dynamic>>[];
      for (final s in list) {
        specs.add(s.spec(await _store.secrets(s.id)));
      }
      if (specs.isNotEmpty) await _channel.register(specs);
    } catch (e) {
      if (kDebugMode) debugPrint('NetServers.register: $e');
    }
  }

  static String newId() {
    final r = Random.secure();
    return List<int>.generate(9, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<Map<String, dynamic>> specOf(NetServer s) async =>
      s.spec(await _store.secrets(s.id));

  Future<NetSecrets> secretsOf(String id) => _store.secrets(id);

  /// Adds or replaces [s] (same id), with its secrets.
  Future<void> put(NetServer s, NetSecrets secrets) async {
    await _ready;
    await _store.setSecrets(s.id, secrets);
    final next = <NetServer>[s, ...state.where((x) => x.id != s.id)];
    state = next;
    await _store.save(next);
  }

  Future<void> touch(String id) async {
    final i = state.indexWhere((x) => x.id == id);
    if (i < 0) return;
    final s =
        state[i].copyWith(lastUsed: DateTime.now().millisecondsSinceEpoch);
    state = <NetServer>[s, ...state.where((x) => x.id != id)];
    await _store.save(state);
  }

  /// The server proved a new identity and the person said "trust it".
  Future<void> pin(String id, String? fingerprint) async {
    final i = state.indexWhere((x) => x.id == id);
    if (i < 0 || fingerprint == null) return;
    final next = [...state];
    next[i] = next[i].copyWith(pinned: fingerprint);
    state = next;
    await _store.save(next);
  }

  Future<void> remove(String id) async {
    state = state.where((x) => x.id != id).toList();
    await _store.save(state);
    await _store.deleteSecrets(id);
    try {
      await _channel.forget(id);
    } catch (_) {}
  }
}

final netServersProvider =
    StateNotifierProvider<NetServersNotifier, List<NetServer>>((ref) {
  return NetServersNotifier(
      ref.read(netStoreProvider), ref.read(netChannelProvider));
});
