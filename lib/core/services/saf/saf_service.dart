import 'package:flutter/services.dart';

/// One video discovered under a granted SAF tree.
class SafVideo {
  /// content:// document URI — pass straight to the player.
  final String uri;
  final String name;
  final int sizeBytes;

  /// Decoded document id, e.g. "primary:Android/data/com.x/files/a.mp4".
  /// Used to derive a filesystem-style folder path for grouping.
  final String docPath;

  const SafVideo({
    required this.uri,
    required this.name,
    required this.sizeBytes,
    required this.docPath,
  });
}

/// Wraps the native Storage Access Framework channel. Lets the user grant
/// per-folder access (Android/data, an SD-card folder, …) that neither
/// MediaStore nor All-Files-Access can reach on Android 11+, then enumerates
/// video files inside the granted trees as playable content:// URIs.
///
/// Reality check baked into the UX: Google restricts ACTION_OPEN_DOCUMENT_TREE
/// from selecting Android/data on Android 13+, so seeding the picker there may
/// come back empty on newer devices — the user can still grant any other
/// folder. On Android 11/12 the Android/data grant generally succeeds.
class SafService {
  SafService._();
  static final SafService instance = SafService._();

  static const MethodChannel _channel = MethodChannel('mx_clone/saf');

  /// Seeds the system picker at Android/data (honoured on Android 8+).
  static const String androidDataInitialUri =
      'content://com.android.externalstorage.documents/document/'
      'primary%3AAndroid%2Fdata';

  /// Launch the system folder picker. Returns the granted tree URI, or null if
  /// the user cancelled or the OS blocked the selection.
  Future<String?> pickTree({String? initialUri}) async {
    try {
      return await _channel.invokeMethod<String>('pickTree', {
        if (initialUri != null) 'initialUri': initialUri,
      });
    } catch (_) {
      return null;
    }
  }

  /// URIs of all currently-persisted read grants.
  Future<List<String>> grantedTrees() async {
    try {
      final r = await _channel.invokeMethod<List<dynamic>>('grantedTrees');
      return (r ?? const <dynamic>[]).map((e) => e.toString()).toList();
    } catch (_) {
      return const <String>[];
    }
  }

  /// Drop a persisted grant.
  Future<void> releaseTree(String uri) async {
    try {
      await _channel.invokeMethod<void>('releaseTree', {'uri': uri});
    } catch (_) {/* best-effort */}
  }

  /// Drop every persisted grant.
  Future<void> releaseAll() async {
    final trees = await grantedTrees();
    for (final t in trees) {
      await releaseTree(t);
    }
  }

  /// Enumerate every video file under all granted trees.
  Future<List<SafVideo>> listVideos() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listVideos');
      final out = <SafVideo>[];
      for (final e in raw ?? const <dynamic>[]) {
        final m = Map<Object?, Object?>.from(e as Map);
        final uri = m['uri'] as String?;
        if (uri == null || uri.isEmpty) continue;
        out.add(SafVideo(
          uri: uri,
          name: (m['name'] as String?) ?? '?',
          sizeBytes: (m['size'] as num?)?.toInt() ?? 0,
          docPath: (m['path'] as String?) ?? '',
        ));
      }
      return out;
    } catch (_) {
      return const <SafVideo>[];
    }
  }
}
