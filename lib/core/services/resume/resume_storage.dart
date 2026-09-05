import 'package:shared_preferences/shared_preferences.dart';

/// Persists last playback position per video URI.
/// Used to prompt user to resume playback when reopening a video.
class ResumeStorage {
  static const String _prefix = 'resume_pos_';
  static const Duration _minSaveThreshold = Duration(seconds: 30);

  // Audit: keys for "what was the app actively playing when it last
  // ran?" — used by crash-recovery to offer "Resume X?" if the app
  // was force-closed mid-playback. These are deliberately separate
  // from the per-URI position map: the per-URI map records every
  // half-finished video, whereas these record only what is *open*
  // right now. A clean exit clears them; a force-close leaves them.
  static const String _lastUriKey = '_lastPlayingUri';
  static const String _lastTitleKey = '_lastPlayingTitle';
  static const String _lastTouchedKey = '_lastPlayingTouchedMs';

  /// Save position. Returns true if saved (skipped if too short or near-end).
  Future<bool> savePosition({
    required String uri,
    required Duration position,
    required Duration duration,
  }) async {
    // Skip if too short or near completion (>95%)
    if (position < _minSaveThreshold) return false;
    if (duration > Duration.zero) {
      final ratio = position.inMilliseconds / duration.inMilliseconds;
      if (ratio >= 0.95) {
        // Clear instead of saving to prevent resume prompt for completed videos
        await clearPosition(uri);
        return false;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key(uri), position.inMilliseconds);
    return true;
  }

  /// Get saved position. Returns null if no saved position exists.
  Future<Duration?> getPosition(String uri) async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_key(uri));
    if (ms == null || ms <= 0) return null;
    return Duration(milliseconds: ms);
  }

  Future<void> clearPosition(String uri) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(uri));
  }

  /// Record that this video is *currently* being played. Called by
  /// the player when a video opens. The clean-exit path
  /// ([clearLastPlaying]) wipes these keys, so anything that survives
  /// to the next cold start means we died mid-playback.
  Future<void> setLastPlaying(
      {required String uri, required String title}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastUriKey, uri);
    await prefs.setString(_lastTitleKey, title);
    await prefs.setInt(
        _lastTouchedKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// Called by the player on a normal close (back-button, completion,
  /// user-initiated stop). Wipes the "what was playing" markers so a
  /// later cold start does not prompt "Resume" for a video the user
  /// already finished with intentionally.
  Future<void> clearLastPlaying() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastUriKey);
    await prefs.remove(_lastTitleKey);
    await prefs.remove(_lastTouchedKey);
  }

  /// Returns the (uri, title, savedPosition) for crash-recovery, or
  /// null if there is nothing to recover. The caller is responsible
  /// for clearing the markers after presenting the prompt, otherwise
  /// the prompt would re-appear on every cold start until the user
  /// taps "Resume" or until something else opens a video.
  Future<({String uri, String title, Duration? position})?>
      getLastPlaying() async {
    final prefs = await SharedPreferences.getInstance();
    final uri = prefs.getString(_lastUriKey);
    if (uri == null || uri.isEmpty) return null;
    final title = prefs.getString(_lastTitleKey) ?? uri.split('/').last;
    final pos = await getPosition(uri);
    // Sanity guard: if the marker is older than 7 days the user has
    // almost certainly moved on; do not nag them.
    final touched = prefs.getInt(_lastTouchedKey);
    if (touched != null) {
      final ageMs = DateTime.now().millisecondsSinceEpoch - touched;
      if (ageMs > Duration(days: 7).inMilliseconds) {
        await clearLastPlaying();
        return null;
      }
    }
    return (uri: uri, title: title, position: pos);
  }

  String _key(String uri) {
    // Hash long URIs to keep keys reasonable
    final hash = uri.hashCode.toUnsigned(32).toRadixString(16);
    return '$_prefix$hash';
  }
}
