import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// What a cut came to: the new file, or why there is none.
class VideoCutResult {
  final String? path;
  final String? error;

  /// The source had sound and the cut has none: its audio is in a format
  /// MP4 cannot carry.
  final bool silent;

  /// The cut starts exactly at A. False when the video could only be copied
  /// from the key frame before A.
  final bool exact;
  const VideoCutResult.ok(String this.path,
      {this.silent = false, this.exact = true})
      : error = null;
  const VideoCutResult.fail(String this.error)
      : path = null,
        silent = false,
        exact = false;
}

/// The player's Cut: the stretch between two points of a video on this phone,
/// into a new MP4 in `Innocent/Cuts`. By default copied losslessly, from the
/// key frame at or before A (VideoTrimmer.kt); with "Exact start", from A
/// itself (PreciseTrimmer.kt).
class VideoCutService {
  VideoCutService._();

  static const MethodChannel _channel = MethodChannel('mx_clone/media_scan');

  /// [exact]: start exactly at A (Media3: a smart cut where it can stitch,
  /// otherwise the clip re-encoded; [progress] and [cancel] while it runs).
  /// Without it, the lossless copy from the key frame at or before A.
  static Future<VideoCutResult> cut({
    required String sourcePath,
    required Duration start,
    required Duration end,
    bool exact = false,
  }) async {
    if (end <= start) return const VideoCutResult.fail('empty range');
    if (!await File(sourcePath).exists()) {
      return const VideoCutResult.fail('source not found');
    }
    final String out;
    try {
      out = await _outputPath(sourcePath);
    } catch (e) {
      return VideoCutResult.fail('$e');
    }
    try {
      final reply =
          await _channel.invokeMapMethod<String, Object?>('trim', <String, Object>{
        'src': sourcePath,
        'dst': out,
        'startMs': start.inMilliseconds,
        'endMs': end.inMilliseconds,
        'exact': exact,
      });
      final err = reply?['error'] as String?;
      if (reply == null) return const VideoCutResult.fail('no reply');
      return err == null
          ? VideoCutResult.ok(out,
              silent: reply['silent'] == true, exact: reply['exact'] != false)
          : VideoCutResult.fail(err);
    } on PlatformException catch (e) {
      return VideoCutResult.fail(e.message ?? e.code);
    } on MissingPluginException {
      return const VideoCutResult.fail('not available on this device');
    }
  }

  /// How far an exact cut is, 0-100, or null when unknown.
  static Future<int?> progress() async {
    try {
      final p = await _channel.invokeMethod<int>('trimProgress');
      return p == null || p < 0 ? null : p;
    } catch (_) {
      return null;
    }
  }

  /// Stops an exact cut; [cut] then reports `cancelled` and saves nothing.
  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('trimCancel');
    } catch (_) {/* nothing running */}
  }

  /// Where the default (lossless) cut from [at] starts: the key frame at or
  /// before it. Null when the file cannot be read.
  static Future<Duration?> keyFrameBefore(String path, Duration at) async {
    try {
      final ms = await _channel.invokeMethod<int>(
          'keyFrameBefore', <String, Object>{'src': path, 'atMs': at.inMilliseconds});
      return ms == null || ms < 0 ? null : Duration(milliseconds: ms);
    } catch (_) {
      return null;
    }
  }

  /// `Innocent/Cuts/<name> (cut).mp4`, numbered rather than overwriting.
  static Future<String> _outputPath(String sourcePath) async {
    final dir = await _cutsDir();
    var base = p.basenameWithoutExtension(sourcePath).trim();
    base = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (base.isEmpty) base = 'video';
    var candidate = p.join(dir.path, '$base (cut).mp4');
    var n = 2;
    while (await File(candidate).exists()) {
      candidate = p.join(dir.path, '$base (cut $n).mp4');
      n++;
    }
    return candidate;
  }

  /// The public `Innocent/Cuts` folder (where the Video tab finds it), or the
  /// app's own external folder when shared storage cannot be written.
  static Future<Directory> _cutsDir() async {
    var root = '/storage/emulated/0/Innocent';
    try {
      final ext = await getExternalStorageDirectory();
      final idx = ext?.path.indexOf('/Android/') ?? -1;
      if (ext != null && idx > 0) {
        root = p.join(ext.path.substring(0, idx), 'Innocent');
      }
    } catch (_) {/* keep the default root */}
    try {
      final dir = Directory(p.join(root, 'Cuts'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final probe = File(p.join(dir.path, '.wtest'));
      await probe.writeAsString('', flush: true);
      await probe.delete();
      return dir;
    } catch (_) {
      final base = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(base.path, 'Innocent', 'Cuts'));
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
  }
}
