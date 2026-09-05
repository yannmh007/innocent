import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Result of an audio-extraction request.
class AudioExtractionResult {
  final bool success;
  final String? outputPath;
  final String? error;
  const AudioExtractionResult.ok(this.outputPath)
      : success = true,
        error = null;
  const AudioExtractionResult.fail(this.error)
      : success = false,
        outputPath = null;
}

/// Extracts the audio track from a video into a standalone file saved under
/// the public `Innocent/Music/` folder, using a DEDICATED libmpv instance so
/// it never disturbs the video the user is currently playing.
///
/// Design notes / why this shape:
/// * We deliberately re-encode to AAC in an `.m4a` container rather than MP3.
///   media_kit's bundled libmpv reliably has the AAC encoder; the LAME/MP3
///   encoder is often NOT compiled in, so `.mp3` output would fail on many
///   devices. AAC/M4A is lossy-but-standard, plays everywhere (including this
///   app's own Music tab), and keeps the build free of a heavy FFmpeg native
///   dependency that FlutLab's cloud build struggles with.
/// * A fresh [mk.Player] is created per extraction and always disposed in a
///   `finally`, so there are no leaked native handles even on error.
/// * All failure paths return an [AudioExtractionResult.fail] — this service
///   never throws to its caller, so a bad file can't crash the UI.
class AudioExtractionService {
  static const _scanChannel = MethodChannel('mx_clone/media_scan');

  /// Progress 0.0–1.0 for the active extraction (or null when idle).
  final ValueNotifier<double?> progress = ValueNotifier<double?>(null);

  bool _busy = false;
  bool get isBusy => _busy;

  /// Extract audio from [videoPath] (an absolute on-disk path). [displayName]
  /// is used to name the output file. Returns the saved path on success.
  Future<AudioExtractionResult> extract({
    required String videoPath,
    required String displayName,
  }) async {
    if (_busy) {
      return const AudioExtractionResult.fail('Another extraction is running.');
    }
    final src = File(videoPath);
    if (!await src.exists()) {
      return const AudioExtractionResult.fail('Source file not found.');
    }

    _busy = true;
    progress.value = 0.0;
    mk.Player? player;
    Timer? watchdog;
    final completer = Completer<AudioExtractionResult>();
    final subs = <StreamSubscription>[];
    try {
      // Resolve the destination: Innocent/Music/<name>.m4a (deduped).
      final outPath = await _resolveOutputPath(displayName);

      player = mk.Player(
        configuration: const mk.PlayerConfiguration(
          // We don't need a big buffer for a straight decode-to-file pass.
          bufferSize: 8 * 1024 * 1024,
          title: 'Innocent',
        ),
      );
      final platform = player.platform;

      // Configure libmpv as an audio-only encoder BEFORE loading the file.
      Future<void> setProp(String k, String v) async {
        try {
          await (platform as dynamic)?.setProperty(k, v);
        } catch (_) {/* unknown prop on some builds — ignore */}
      }

      await setProp('vid', 'no'); // don't decode/attach video
      await setProp('audio-display', 'no'); // no cover-art rendering
      await setProp('of', 'mp4'); // MP4/M4A container
      await setProp('oac', 'aac'); // AAC encoder (widely available)
      await setProp('oacopts', 'b=192k'); // ~192 kbps, transparent enough
      await setProp('o', outPath); // <-- encode target
      // Safety: if a device's libmpv lacks the encoder and ignores `o`, it
      // would otherwise fall back to PLAYING the audio out loud. Force the
      // output device to null + mute so a failed encode stays silent; the
      // finalize step then reports "no audio produced" cleanly.
      await setProp('ao', 'null');
      await setProp('mute', 'yes');
      // Keep going even if something odd happens on init.
      await setProp('stop-playback-on-init-failure', 'no');

      // Progress: encoding mode advances position toward duration; when the
      // file ends, mpv finalises and emits an end-of-file/idle event.
      Duration total = Duration.zero;
      subs.add(player.stream.duration.listen((d) {
        if (d > Duration.zero) total = d;
      }));
      subs.add(player.stream.position.listen((pos) {
        if (total.inMilliseconds > 0) {
          final frac = pos.inMilliseconds / total.inMilliseconds;
          progress.value = frac.clamp(0.0, 0.999);
        }
      }));

      void finish(AudioExtractionResult r) {
        if (!completer.isCompleted) completer.complete(r);
      }

      // Completion is signalled by mpv going idle / reaching EOF.
      subs.add(player.stream.completed.listen((done) async {
        if (done) {
          await _finalize(outPath, finish);
        }
      }));
      // Some builds surface the end of an encode via the playing=false +
      // idle path rather than `completed`; guard with a duration-based
      // fallback below too.

      // Watchdog: absolute upper bound. Encoding runs faster than real time,
      // so anything approaching this means something is wrong.
      watchdog = Timer(const Duration(minutes: 20), () async {
        await _finalize(outPath, finish, timedOut: true);
      });

      // Kick off the decode→encode pass. (play defaults to true, matching
      // the main player's open() usage.)
      await player.open(mk.Media(_toUri(videoPath)));

      // Early encoder-support probe: in encoding mode libmpv creates the
      // output file within the first few seconds. If after a short grace
      // period the file still doesn't exist AT ALL, this libmpv build almost
      // certainly lacks the encoder (it silently ignored `o` and is "playing"
      // muted instead) — bail out fast with a clear message rather than
      // making the user wait out the whole (muted) duration. We only require
      // the file to EXIST (not a minimum size) so slow storage isn't
      // misjudged; the final size check happens in _finalize.
      Timer(const Duration(seconds: 8), () async {
        if (completer.isCompleted) return;
        final exists = await File(outPath).exists();
        if (!exists) {
          finish(const AudioExtractionResult.fail(
            'Audio conversion isn\'t supported on this device build.',
          ));
        }
      });

      final result = await completer.future;
      return result;
    } catch (e) {
      if (kDebugMode) debugPrint('audio_extraction: $e');
      return AudioExtractionResult.fail('Extraction failed: $e');
    } finally {
      watchdog?.cancel();
      for (final s in subs) {
        await s.cancel();
      }
      try {
        await player?.dispose();
      } catch (_) {}
      progress.value = null;
      _busy = false;
    }
  }

  /// Verify the output exists + is non-trivial, scan it into MediaStore, and
  /// complete the request. Shared by the completion + watchdog paths.
  Future<void> _finalize(
    String outPath,
    void Function(AudioExtractionResult) finish, {
    bool timedOut = false,
  }) async {
    try {
      final out = File(outPath);
      if (await out.exists()) {
        final len = await out.length();
        // A few hundred bytes means a header-only/failed encode.
        if (len > 4096) {
          await _mediaScan([outPath]);
          finish(AudioExtractionResult.ok(outPath));
          return;
        }
        // Clean up a stub file so we don't leave junk behind.
        try {
          await out.delete();
        } catch (_) {}
      }
      finish(AudioExtractionResult.fail(
        timedOut ? 'Timed out.' : 'No audio track was produced.',
      ));
    } catch (e) {
      finish(AudioExtractionResult.fail('Finalize error: $e'));
    }
  }

  /// Build `Innocent/Music/<sanitized name>.m4a`, avoiding overwrites by
  /// appending " (1)", " (2)", … when a file already exists.
  Future<String> _resolveOutputPath(String displayName) async {
    final dir = await _resolveMusicDir();
    // Strip any existing extension and unsafe characters from the base name.
    var base = p.basenameWithoutExtension(displayName).trim();
    base = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (base.isEmpty) base = 'audio';
    var candidate = p.join(dir.path, '$base.m4a');
    var n = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(dir.path, '$base ($n).m4a');
      n++;
    }
    return candidate;
  }

  /// Resolve `Innocent/Music`, creating it. Mirrors the file-receiver's
  /// public-root derivation with a writable fallback so extraction never
  /// fails just because all-files access is missing.
  Future<Directory> _resolveMusicDir() async {
    String root;
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final idx = ext.path.indexOf('/Android/');
        root = idx > 0
            ? p.join(ext.path.substring(0, idx), 'Innocent')
            : '/storage/emulated/0/Innocent';
      } else {
        root = '/storage/emulated/0/Innocent';
      }
    } catch (_) {
      root = '/storage/emulated/0/Innocent';
    }
    // Try the public Innocent/Music folder first.
    try {
      final dir = Directory(p.join(root, 'Music'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final probe = File(p.join(dir.path, '.wtest'));
      await probe.writeAsString('', flush: true);
      await probe.delete();
      return dir;
    } catch (_) {
      // Fall back to the app-specific external dir (no permission needed).
      final base = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(base.path, 'Innocent', 'Music'));
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
  }

  String _toUri(String path) {
    if (path.startsWith('file://') ||
        path.startsWith('http://') ||
        path.startsWith('https://') ||
        path.startsWith('content://')) {
      return path;
    }
    return Uri.file(path).toString();
  }

  Future<void> _mediaScan(List<String> paths) async {
    try {
      await _scanChannel.invokeMethod('scan', {'paths': paths});
    } catch (e) {
      if (kDebugMode) debugPrint('audio_extraction.scan: $e');
    }
  }
}
