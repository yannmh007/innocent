import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../../features/video_hub/data/cache/stream_cache_server.dart';
import 'playback_log.dart';

/// DEVICE LAB ONLY — a film from a URL the lab names, played through the real
/// stream proxy exactly as a catalogue film is.
///
/// WHY. The proxy's behaviour on a lossy line (how many connections, how fast
/// the first frame, how often the picture stops) cannot be judged on a desk
/// connection, and the emulator's own shaping adds speed limits and delay but
/// drops nothing. The lab runner can do both: it serves a film it made from
/// 127.0.0.1 behind `tc netem` (delay, loss, a rate cap), the emulator reaches
/// it at 10.0.2.2, and this opens it through [StreamCacheServer] — the same
/// door, the same lanes, the same player — with no catalogue, no account and
/// nothing signed.
///
/// The URL is in `lab_stream_url` in the app's external files directory,
/// written by test_device/run.sh with adb. A release build never looks: the
/// caller is gated on `INNOCENT_LAB`.
class LabStream {
  LabStream._();

  static Future<String?> _read(String name) async {
    final dir = await getExternalStorageDirectory();
    if (dir == null) return null;
    final f = File('${dir.path}/$name');
    if (!await f.exists()) return null;
    return (await f.readAsString()).trim();
  }

  /// When to jump and where to: `lab_seek` holds "AFTER:TO" in seconds, or
  /// several separated by commas ("45:4866,60:2000,75:7300") — the lab's
  /// seeks into a long film, each timed by the trail's rebuffer lines. One
  /// seek a line was one sample of a noisy thing; three are a pattern.
  /// Empty when the lab asked for none.
  static Future<List<(Duration after, Duration to)>> seekPlan() async {
    if (!const bool.fromEnvironment('INNOCENT_LAB')) return const [];
    try {
      final raw = await _read('lab_seek');
      if (raw == null || raw.isEmpty) return const [];
      return parseSeekPlan(raw);
    } catch (_) {
      return const [];
    }
  }

  /// "AFTER:TO[,AFTER:TO…]" in seconds; malformed entries are skipped.
  static List<(Duration after, Duration to)> parseSeekPlan(String raw) => [
        for (final item in raw.split(','))
          if (item.trim().split(':') case [final a, final b]
              when int.tryParse(a) != null && int.tryParse(b) != null)
            (Duration(seconds: int.parse(a)), Duration(seconds: int.parse(b))),
      ];

  /// A CATALOGUE TITLE to play the way a viewer would — `title:<uuid>` in
  /// `lab_stream_url` — or null. Played through `playMedia`: the real
  /// request-playback, the real Worker and R2, the rung Auto picks, the
  /// climb and the step down. Free titles only (the lab has no account).
  ///
  /// [file] is `lab_loop_title` for the game-loop path (scenario 3) when the
  /// device lab reproduces a Test Lab launch on the emulator — a different
  /// file, so the launch-time path does not also start the same film.
  static Future<String?> titleId({String file = 'lab_stream_url'}) async {
    if (!const bool.fromEnvironment('INNOCENT_LAB')) return null;
    try {
      final raw = await _read(file);
      if (raw == null || !raw.startsWith('title:')) return null;
      final id = raw.substring('title:'.length).trim();
      return id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }

  /// The link estimate to start from (`lab_throughput`, kbit/s), or null.
  static Future<int?> seedKbps() async {
    if (!const bool.fromEnvironment('INNOCENT_LAB')) return null;
    try {
      return int.tryParse((await _read('lab_throughput')) ?? '');
    } catch (_) {
      return null;
    }
  }

  /// The loopback address to play, or null when the lab named no film.
  static Future<String?> localUrl() async {
    if (!const bool.fromEnvironment('INNOCENT_LAB')) return null;
    try {
      final upstream = await _read('lab_stream_url');
      if (upstream == null) return null;
      if (upstream.isEmpty || upstream.startsWith('title:')) return null;
      final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'lab-film',
        upstream: upstream,
        refresh: () async => upstream,
        label: 'lab film',
      );
      PlaybackLog.add('LAB stream: ${local == null ? 'no proxy' : 'proxy ready'}');
      return local;
    } catch (e) {
      PlaybackLog.add('LAB stream failed: $e');
      return null;
    }
  }
}
