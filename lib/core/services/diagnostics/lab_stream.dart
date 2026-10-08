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

  /// The loopback address to play, or null when the lab named no film.
  static Future<String?> localUrl() async {
    if (!const bool.fromEnvironment('INNOCENT_LAB')) return null;
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return null;
      final f = File('${dir.path}/lab_stream_url');
      if (!await f.exists()) return null;
      final upstream = (await f.readAsString()).trim();
      if (upstream.isEmpty) return null;
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
