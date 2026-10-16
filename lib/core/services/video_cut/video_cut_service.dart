import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// What a cut came to: the new file, or why there is none.
class VideoCutResult {
  final String? path;
  final String? error;
  const VideoCutResult.ok(String this.path) : error = null;
  const VideoCutResult.fail(String this.error) : path = null;
}

/// The player's Cut: the stretch between two points of a video on this phone,
/// copied into a new MP4 in `Innocent/Cuts` without re-encoding
/// (VideoTrimmer.kt). It starts on the key frame at or before the chosen
/// start, so it can begin a second or two early; nothing is lost in quality.
class VideoCutService {
  VideoCutService._();

  static const MethodChannel _channel = MethodChannel('mx_clone/media_scan');

  static Future<VideoCutResult> cut({
    required String sourcePath,
    required Duration start,
    required Duration end,
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
      final err = await _channel.invokeMethod<String>('trim', <String, Object>{
        'src': sourcePath,
        'dst': out,
        'startMs': start.inMilliseconds,
        'endMs': end.inMilliseconds,
      });
      return err == null ? VideoCutResult.ok(out) : VideoCutResult.fail(err);
    } on PlatformException catch (e) {
      return VideoCutResult.fail(e.message ?? e.code);
    } on MissingPluginException {
      return const VideoCutResult.fail('not available on this device');
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
