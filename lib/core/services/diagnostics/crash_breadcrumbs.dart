import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'playback_log.dart';

/// v1.61 — WHAT THE APP WAS DOING WHEN IT DIED.
///
/// [Diagnostics] on the native side can say *how* a previous process ended —
/// native crash, ANR, low memory. That is half an answer. The other half is
/// what the app was in the middle of, and that is only knowable if it was
/// written to disk BEFORE the process went away.
///
/// So this keeps a short trail of lines in a file, rewritten (with fsync)
/// after every entry. On the next start the previous run's file is rotated to
/// `-prev` and shown next to the exit reason, which pairs "died with SIGSEGV
/// in libmpv" with "the last thing it did was open an adb:// file with
/// hwdec=auto".
///
/// Deliberately a plain file rather than SharedPreferences: preferences are
/// rewritten as a whole XML document and there is no way to force them out to
/// storage from Dart, whereas `writeAsString(flush: true)` is an fsync.
///
/// The trail is capped and the lines are short, so the write is a few
/// kilobytes at a rate of a handful per minute. It must never be able to
/// affect playback: every path is wrapped, and a failure is silent.
class CrashBreadcrumbs {
  CrashBreadcrumbs._();

  static const int _cap = 160;
  static const String _fileName = 'diag_breadcrumbs.log';
  static const String _prevName = 'diag_breadcrumbs_prev.log';

  static final List<String> _lines = <String>[];
  static String _previous = '';
  static File? _file;
  static DateTime? _epoch;
  static bool _busy = false;
  static bool _dirty = false;
  static bool _started = false;

  /// The trail from the run before this one. Empty on a first launch.
  static String get previousSession => _previous;

  /// The trail so far in this run.
  static String get currentSession => _lines.join('\n');

  /// Rotate the previous run's trail and start a fresh one. Call once, early
  /// in `main()`, before anything that might crash.
  static Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final dir = await getApplicationSupportDirectory();
      final current = File('${dir.path}/$_fileName');
      final prev = File('${dir.path}/$_prevName');
      if (await current.exists()) {
        _previous = await current.readAsString();
        try {
          if (await prev.exists()) await prev.delete();
        } catch (_) {}
        try {
          await current.rename(prev.path);
        } catch (_) {
          // Rename can fail across some vendor filesystems; copying is fine.
          try {
            await prev.writeAsString(_previous, flush: true);
            await current.delete();
          } catch (_) {}
        }
      }
      _file = current;
    } catch (e) {
      if (kDebugMode) debugPrint('CrashBreadcrumbs.start: $e');
    }
    // Everything already routed through PlaybackLog becomes a breadcrumb for
    // free — that is six existing call sites in the background-play path that
    // now survive a crash instead of dying with the process.
    PlaybackLog.sink = add;
    add('app start');
  }

  /// Record one short event. Safe to call from anywhere, including before
  /// [start] — early lines are buffered and land in the first write.
  static void add(String message) {
    try {
      final now = DateTime.now();
      _epoch ??= now;
      final ms = now.difference(_epoch!).inMilliseconds;
      final stamp = (ms / 1000).toStringAsFixed(1).padLeft(7);
      _lines.add('$stamp  $message');
      if (_lines.length > _cap) {
        _lines.removeRange(0, _lines.length - _cap);
      }
      // ignore: discarded_futures
      _flush();
    } catch (_) {
      // A diagnostic must never be the thing that breaks the app.
    }
  }

  /// Record a caught error with its stack, trimmed to something readable on a
  /// phone.
  static void addError(String where, Object error, StackTrace? stack) {
    final head = stack == null
        ? ''
        : '\n    ${stack.toString().split('\n').take(6).join('\n    ')}';
    add('ERROR $where: $error$head');
  }

  /// Coalesced write. If a write is already running the next one is folded
  /// into it, so a burst of entries costs one extra pass rather than one write
  /// each — and the loop guarantees the final state always reaches disk.
  static Future<void> _flush() async {
    final f = _file;
    if (f == null) return;
    if (_busy) {
      _dirty = true;
      return;
    }
    _busy = true;
    try {
      do {
        _dirty = false;
        await f.writeAsString(_lines.join('\n'), flush: true);
      } while (_dirty);
    } catch (e) {
      if (kDebugMode) debugPrint('CrashBreadcrumbs.flush: $e');
    } finally {
      _busy = false;
    }
  }
}
