import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Where this process spends its CPU, thread by thread, read from `/proc`.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS EXISTS
/// ═══════════════════════════════════════════════════════════════════════
///
/// On 2026-10-04 the owner put the phone's own GPU/CPU meter beside MX
/// Player: the Video tab sitting still at 69 % overall CPU and redrawing
/// about three times a second, and a 720p film at 83 % against MX's 26 %.
/// A meter like that says THAT the phone is busy, not WHO is busy — and the
/// usual suspects (the Dart UI thread rebuilding, the raster thread drawing,
/// libmpv decoding in software, thumbnail decoders, a scan) each have a
/// different fix. Guessing between them costs a release per guess.
///
/// Every thread of a process has a line in `/proc/self/task/<tid>/stat`
/// with its name and the CPU it has used; reading them twice, ten seconds
/// apart, names the thread that is burning the battery. Flutter's own
/// threads are `1.ui` (Dart), `1.raster` (drawing) and `1.io`; libmpv's are
/// `mpv/…`; MediaCodec's `CodecLooper`/`MediaCodec_loop`; isolates and
/// background Dart work run on `DartWorker`. Alongside that, how many
/// frames Flutter drew in the same ten seconds: a screen that is standing
/// still should draw none.
///
/// It costs about a hundred tiny file reads every ten seconds, and keeps
/// only short text lines, which "Report a problem" sends.
class CpuProbe {
  CpuProbe._();

  static const Duration window = Duration(seconds: 10);
  static const int _cap = 30;

  /// Linux USER_HZ — 100 on every Android kernel.
  static const int _ticksPerSecond = 100;

  static final List<String> _lines = <String>[];
  static Timer? _timer;
  static Map<int, CpuSample> _last = <int, CpuSample>{};
  static DateTime? _lastAt;
  static int _frames = 0;
  static int _quietSkipped = 0;
  static DateTime? _epoch;

  /// The latest readings, oldest first.
  static String get text => _lines.join('\n');

  /// Starts sampling. Safe to call more than once; does nothing off Android
  /// and Linux, where there is no `/proc` to read.
  static void start() {
    if (_timer != null) return;
    if (!(Platform.isAndroid || Platform.isLinux)) return;
    try {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    } catch (_) {
      // No binding (a plain unit test): sample without the frame count.
    }
    _last = _read();
    _lastAt = DateTime.now();
    _timer = Timer.periodic(window, (_) => _tick());
  }

  static void _onTimings(List<FrameTiming> timings) {
    _frames += timings.length;
  }

  static void _tick() {
    try {
      final now = DateTime.now();
      final cur = _read();
      final elapsed = now.difference(_lastAt ?? now).inMilliseconds / 1000.0;
      final line = summarise(_last, cur, elapsed, _frames);
      _last = cur;
      _lastAt = now;
      _frames = 0;
      if (line == null) return;
      // A process doing nothing is the normal case and not worth a line
      // every ten seconds; one in six keeps the record honest about it.
      if (line.quiet && _quietSkipped < 5) {
        _quietSkipped++;
        return;
      }
      _quietSkipped = 0;
      _record(line.text);
    } catch (e) {
      if (kDebugMode) debugPrint('CpuProbe: $e');
    }
  }

  static void _record(String text) {
    final at = DateTime.now();
    _epoch ??= at;
    final s = (at.difference(_epoch!).inMilliseconds / 1000).toStringAsFixed(0);
    _lines.add('${s.padLeft(5)}s  $text');
    if (_lines.length > _cap) _lines.removeRange(0, _lines.length - _cap);
    // DEVICE LAB BUILDS ONLY, like PlaybackLog: the lab reads these from
    // logcat. A store build keeps them for "Report a problem" alone.
    if (const bool.fromEnvironment('INNOCENT_LAB')) {
      debugPrint('LAB cpu $text');
    }
  }

  /// Every thread's name and CPU ticks so far.
  static Map<int, CpuSample> _read() {
    final out = <int, CpuSample>{};
    final dir = Directory('/proc/self/task');
    for (final e in dir.listSync(followLinks: false)) {
      final tid = int.tryParse(e.path.split('/').last);
      if (tid == null) continue;
      try {
        final s = parseStat(File('${e.path}/stat').readAsStringSync());
        if (s != null) out[tid] = s;
      } catch (_) {
        // The thread ended between the listing and the read.
      }
    }
    return out;
  }

  /// One `/proc/<pid>/task/<tid>/stat` line → its name and used ticks.
  ///
  /// The name sits in parentheses and may itself contain spaces or
  /// parentheses, so the fields are counted from the LAST `)`.
  @visibleForTesting
  static CpuSample? parseStat(String raw) {
    final open = raw.indexOf('(');
    final close = raw.lastIndexOf(')');
    if (open < 0 || close < open) return null;
    final name = raw.substring(open + 1, close);
    final rest = raw.substring(close + 2).split(' ');
    // After the name: state(0) ppid(1) … utime is field 14 overall, which is
    // index 11 here; stime is index 12.
    if (rest.length < 13) return null;
    final u = int.tryParse(rest[11]);
    final s = int.tryParse(rest[12]);
    if (u == null || s == null) return null;
    return CpuSample(name, u + s);
  }

  /// Threads with the same job share a name up to a number ("DartWorker",
  /// "pool-3-thread-2", "binder:1234_5"): fold those together.
  @visibleForTesting
  static String group(String name) {
    if (name.startsWith('binder:')) return 'binder';
    if (name.startsWith('pool-')) return 'pool-thread';
    return name.replaceAll(RegExp(r'[-_#:]?\d+$'), '');
  }

  /// The line for one window, or null when nothing could be compared.
  @visibleForTesting
  static ({String text, bool quiet})? summarise(
    Map<int, CpuSample> before,
    Map<int, CpuSample> after,
    double seconds,
    int frames,
  ) {
    if (seconds <= 0) return null;
    final byGroup = <String, int>{};
    var total = 0;
    after.forEach((tid, s) {
      final prev = before[tid];
      // A thread born inside the window counts from zero.
      final d = s.ticks - (prev != null && prev.name == s.name ? prev.ticks : 0);
      if (d <= 0) return;
      total += d;
      final g = group(s.name);
      byGroup[g] = (byGroup[g] ?? 0) + d;
    });
    double pct(int ticks) => ticks * 100 / _ticksPerSecond / seconds;
    final top = byGroup.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final parts = <String>[
      for (final e in top.take(6))
        if (pct(e.value) >= 1) '${e.key} ${pct(e.value).round()}%',
    ];
    final fps = (frames / seconds).toStringAsFixed(1);
    final totalPct = pct(total).round();
    return (
      text: 'app $totalPct% · ${fps}fps · ${parts.isEmpty ? '-' : parts.join(' | ')}',
      // "Quiet" is the app at rest: under 5 % of one core and no drawing.
      quiet: totalPct < 5 && frames == 0,
    );
  }
}

/// One thread: its name and the CPU ticks it has used.
class CpuSample {
  const CpuSample(this.name, this.ticks);
  final String name;
  final int ticks;
}
