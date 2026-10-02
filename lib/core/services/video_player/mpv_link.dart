import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// One libmpv property read or write, OFF the UI thread, with a deadline.
///
/// WHY. media_kit's `NativePlayer.setProperty` / `getProperty` are plain
/// synchronous FFI calls (`mpv_set_property_string`, `mpv_get_property_string`)
/// made on the Dart UI isolate, which on Android IS the main thread. libmpv
/// answers them by taking its core lock, so they return only when libmpv's
/// play loop is free. The player makes forty of them per file opened and
/// polls a few more every couple of seconds.
///
/// Normally that costs microseconds. When the core is stuck — a hardware
/// decoder (MediaCodec) wedged on the zeros of a half-downloaded file, which
/// is what froze the player on 2026-10-02 — every one of those calls blocks
/// the main thread with it: taps stop registering, the screen stops drawing,
/// and Android shows "Innocent isn't responding".
///
/// So they are made from a helper isolate instead. A call that is stuck now
/// blocks only that isolate; the UI keeps running, and after [timeout] this
/// says the engine is [wedged], which is what lets the player tell the viewer
/// what happened and start a fresh engine for the next video instead of
/// going down with this one.
///
/// SELF-HEALING. A call that eventually returns clears [wedged] again: a
/// decoder re-initialisation that took five seconds on a slow phone is slow,
/// not dead.
class MpvLink {
  MpvLink({
    this.timeout = const Duration(seconds: 4),
    MpvCallRunner? runner,
  }) : _runner = runner;

  /// How long one call may take before the engine is called stuck.
  final Duration timeout;

  /// For tests: run a request without an isolate. Production leaves this null.
  final MpvCallRunner? _runner;

  Future<_IsolateRunner?>? _starting;
  bool _isolateFailed = false;
  int _generation = 0;
  int _outstanding = 0;

  bool _wedged = false;
  String? _wedgedOn;
  final StreamController<bool> _wedgedCtl = StreamController<bool>.broadcast();

  /// True while a call has been outstanding for longer than [timeout].
  bool get wedged => _wedged;

  /// Which call was hanging, for the playback log.
  String? get wedgedOn => _wedgedOn;

  /// Every change of [wedged].
  Stream<bool> get wedgedChanges => _wedgedCtl.stream;

  /// False when the helper isolate could not be started (no libmpv on this
  /// platform, a test without a runner): callers then use the old direct path.
  bool get available => _runner != null || !_isolateFailed;

  /// The value of [key], or null when it has none, libmpv refuses, or the
  /// engine is stuck. Throws [MpvLinkUnavailable] only when there is no
  /// helper isolate at all, so the caller can use the direct path.
  Future<String?> get(int ctx, String key) async {
    final r = await _call(<Object?>['get', ctx, key, null]);
    return r is String ? r : null;
  }

  /// True when libmpv accepted the write. False when it refused it, or when
  /// the engine is stuck — a stuck engine is not written to at all, because
  /// every write would join the queue behind the call that is hanging.
  Future<bool> set(int ctx, String key, String value) async {
    final r = await _call(<Object?>['set', ctx, key, value]);
    return r is int && r >= 0;
  }

  /// Forget the stuck engine. Called after the player has replaced it: the
  /// old isolate is still inside the call that hung and can never be used
  /// again, so a fresh one is started for the new engine.
  void reset() {
    _generation++;
    if (_outstanding > 0) {
      final old = _starting;
      _starting = null;
      old?.then((iso) => iso?.abandon());
    }
    _outstanding = 0;
    _setWedged(false, null);
  }

  Future<Object?> _call(List<Object?> request) async {
    if (_wedged) return null;
    final gen = _generation;
    final Future<Object?> reply;
    final runner = _runner;
    if (runner != null) {
      reply = runner(request);
    } else {
      final iso = await (_starting ??= _IsolateRunner.start());
      if (iso == null) {
        _isolateFailed = true;
        _starting = null;
        throw const MpvLinkUnavailable();
      }
      reply = iso.send(request);
    }
    _outstanding++;
    var timedOut = false;
    final timer = Timer(timeout, () {
      if (gen != _generation) return;
      timedOut = true;
      _setWedged(true, '${request[0]} ${request[2]}');
    });
    try {
      final value = await reply;
      return timedOut ? null : value;
    } catch (_) {
      return null;
    } finally {
      timer.cancel();
      if (gen == _generation) {
        _outstanding--;
        // It came back: whatever was slow is not dead.
        if (timedOut && _outstanding == 0) _setWedged(false, null);
      }
    }
  }

  void _setWedged(bool value, String? on) {
    if (_wedged == value) return;
    _wedged = value;
    _wedgedOn = on;
    if (!_wedgedCtl.isClosed) _wedgedCtl.add(value);
  }

  void dispose() {
    final old = _starting;
    _starting = null;
    old?.then((iso) => iso?.abandon());
    _wedgedCtl.close();
  }
}

/// There is no helper isolate on this platform (libmpv could not be opened
/// by name). The caller falls back to media_kit's own, synchronous, calls.
class MpvLinkUnavailable implements Exception {
  const MpvLinkUnavailable();
}

/// A request in, the libmpv answer out: `String?` for get, `int` for set.
typedef MpvCallRunner = Future<Object?> Function(List<Object?> request);

class _IsolateRunner {
  _IsolateRunner._(this._isolate, this._send, this._replies);

  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _replies;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _next = 1;

  static Future<_IsolateRunner?> start() async {
    final replies = ReceivePort();
    try {
      final isolate = await Isolate.spawn<SendPort>(
        _mpvLinkMain,
        replies.sendPort,
        debugName: 'mpv-link',
      );
      final first = Completer<SendPort?>();
      late final _IsolateRunner runner;
      var ready = false;
      replies.listen((message) {
        if (!ready) {
          ready = true;
          first.complete(message is SendPort ? message : null);
          return;
        }
        if (message is List && message.isNotEmpty && message[0] is int) {
          final c = runner._pending.remove(message[0] as int);
          c?.complete(message.length > 1 ? message[1] : null);
        }
      });
      final send = await first.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      if (send == null) {
        replies.close();
        isolate.kill(priority: Isolate.immediate);
        return null;
      }
      runner = _IsolateRunner._(isolate, send, replies);
      return runner;
    } catch (_) {
      replies.close();
      return null;
    }
  }

  Future<Object?> send(List<Object?> request) {
    final id = _next++;
    final c = _pending[id] = Completer<Object?>();
    _send.send(<Object?>[id, ...request]);
    return c.future;
  }

  /// Stop listening. The isolate itself may be inside a call that never
  /// returns; kill is asked for and takes effect whenever it can.
  void abandon() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
    _replies.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

typedef _GetNative = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _SetNative = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

/// The helper isolate. libmpv's client API is thread-safe, and the library is
/// already loaded in the process by media_kit, so opening it by name here
/// returns the same instance.
void _mpvLinkMain(SendPort out) {
  final DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open('libmpv.so');
  } catch (_) {
    out.send(null);
    return;
  }
  final getS = lib.lookupFunction<_GetNative, _GetNative>('mpv_get_property_string');
  final setS = lib.lookupFunction<_SetNative, _SetDart>('mpv_set_property_string');
  final freeS = lib.lookupFunction<_FreeNative, _FreeDart>('mpv_free');
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  inbox.listen((message) {
    final m = message as List;
    final id = m[0] as int;
    final op = m[1] as String;
    final ctx = Pointer<Void>.fromAddress(m[2] as int);
    final key = (m[3] as String).toNativeUtf8();
    try {
      if (op == 'get') {
        final p = getS(ctx, key);
        String? value;
        if (p != nullptr) {
          value = p.toDartString();
          freeS(p.cast());
        }
        out.send(<Object?>[id, value]);
      } else {
        final v = (m[4] as String).toNativeUtf8();
        final r = setS(ctx, key, v);
        malloc.free(v);
        out.send(<Object?>[id, r]);
      }
    } catch (_) {
      out.send(<Object?>[id, null]);
    } finally {
      malloc.free(key);
    }
  });
}
