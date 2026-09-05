import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../features/user_data/domain/user_data_models.dart';

/// Unified persistence layer for user-generated data (Phase 8).
/// Wraps SharedPreferences with JSON encoding.
class UserDataService {
  static const String _kFavourites = 'user_favourites_v1';
  static const String _kPlaylists = 'user_playlists_v1';
  static const String _kBookmarks = 'user_bookmarks_v1';
  static const String _kHistory = 'user_history_v1';
  static const String _kRecycle = 'user_recycle_v1';
  static const String _kWatchLater = 'user_watch_later_v1';
  static const String _kVideoSpeeds = 'user_video_speeds_v1';
  static const String _kSkipMarkers = 'user_skip_markers_v1';
  // Phase 41: per-video audio/subtitle track selection memory.
  // Used by the "Remember selections" setting (Settings → Player → Playback)
  // so the same video reopens with the same audio and subtitle choices.
  static const String _kVideoAudioTracks = 'user_video_audio_tracks_v1';
  static const String _kVideoSubtitleTracks = 'user_video_subtitle_tracks_v1';

  // Audit fix (B5): per-video brightness + volume memory. Brightness
  // is what users adjust most often during playback (dark show in a
  // bright room, etc.), so re-opening the same file at the
  // previously chosen brightness is the highest-impact piece of
  // per-URI state we don't yet store. Volume is the natural pair —
  // soundtracks vary file to file. Both stored 0.0..1.0.
  static const String _kVideoBrightness = 'user_video_brightness_v1';
  static const String _kVideoVolume = 'user_video_volume_v1';

  // Audit fix (B5 cont.): per-video aspect ratio + zoom. Aspect is
  // stored as the AspectRatioMode enum's `name` (so it survives enum
  // reordering); zoom as a 1.0..N double matching `videoScale`.
  static const String _kVideoAspect = 'user_video_aspect_v1';
  static const String _kVideoZoom = 'user_video_zoom_v1';

  // === FAVOURITES (Set<String> of video URIs) ===

  Future<Set<String>> loadFavourites() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_kFavourites);
    return raw?.toSet() ?? <String>{};
  }

  Future<void> saveFavourites(Set<String> uris) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_kFavourites, uris.toList());
  }

  Future<bool> toggleFavourite(String videoUri) async {
    final favs = await loadFavourites();
    final added = !favs.contains(videoUri);
    if (added) {
      favs.add(videoUri);
    } else {
      favs.remove(videoUri);
    }
    await saveFavourites(favs);
    return added;
  }

  // === PLAYLISTS ===

  Future<List<Playlist>> loadPlaylists() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kPlaylists);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> savePlaylists(List<Playlist> playlists) async {
    final sp = await SharedPreferences.getInstance();
    final list = playlists.map((p) => p.toJson()).toList();
    await sp.setString(_kPlaylists, jsonEncode(list));
  }

  Future<Playlist> createPlaylist(String name) async {
    final playlists = await loadPlaylists();
    final now = DateTime.now();
    final p = Playlist(
      id: 'pl_${now.microsecondsSinceEpoch}',
      name: name,
      videoUris: const [],
      createdAt: now,
      updatedAt: now,
    );
    playlists.add(p);
    await savePlaylists(playlists);
    return p;
  }

  Future<void> deletePlaylist(String playlistId) async {
    final playlists = await loadPlaylists();
    playlists.removeWhere((p) => p.id == playlistId);
    await savePlaylists(playlists);
  }

  Future<void> addToPlaylist(String playlistId, String videoUri) async {
    final playlists = await loadPlaylists();
    final idx = playlists.indexWhere((p) => p.id == playlistId);
    if (idx < 0) return;
    final old = playlists[idx];
    if (old.videoUris.contains(videoUri)) return;
    playlists[idx] = old.copyWith(
      videoUris: [...old.videoUris, videoUri],
      updatedAt: DateTime.now(),
    );
    await savePlaylists(playlists);
  }

  Future<void> removeFromPlaylist(String playlistId, String videoUri) async {
    final playlists = await loadPlaylists();
    final idx = playlists.indexWhere((p) => p.id == playlistId);
    if (idx < 0) return;
    final old = playlists[idx];
    final newUris = old.videoUris.where((u) => u != videoUri).toList();
    playlists[idx] = old.copyWith(
      videoUris: newUris,
      updatedAt: DateTime.now(),
    );
    await savePlaylists(playlists);
  }

  // === BOOKMARKS ===

  Future<List<Bookmark>> loadBookmarks({String? videoUri}) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kBookmarks);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final all = list
          .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
          .toList();
      if (videoUri == null) return all;
      return all.where((b) => b.videoUri == videoUri).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveBookmarks(List<Bookmark> bookmarks) async {
    final sp = await SharedPreferences.getInstance();
    final list = bookmarks.map((b) => b.toJson()).toList();
    await sp.setString(_kBookmarks, jsonEncode(list));
  }

  Future<Bookmark> addBookmark({
    required String videoUri,
    required String videoTitle,
    required Duration position,
    String? label,
  }) async {
    final bookmarks = await loadBookmarks();
    final b = Bookmark(
      id: 'bm_${DateTime.now().microsecondsSinceEpoch}',
      videoUri: videoUri,
      videoTitle: videoTitle,
      position: position,
      label: label,
      createdAt: DateTime.now(),
    );
    bookmarks.add(b);
    await saveBookmarks(bookmarks);
    return b;
  }

  Future<void> deleteBookmark(String bookmarkId) async {
    final bookmarks = await loadBookmarks();
    bookmarks.removeWhere((b) => b.id == bookmarkId);
    await saveBookmarks(bookmarks);
  }

  // === HISTORY ===

  Future<List<HistoryEntry>> loadHistory() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kHistory);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final all = list
          .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      // Newest first
      all.sort((a, b) => b.lastWatched.compareTo(a.lastWatched));
      return all;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHistory(List<HistoryEntry> entries) async {
    final sp = await SharedPreferences.getInstance();
    // Cap history at 500 entries
    final clamped = entries.take(500).toList();
    final list = clamped.map((e) => e.toJson()).toList();
    await sp.setString(_kHistory, jsonEncode(list));
  }

  /// Phase 45 (audit): remove a single video from the history list.
  /// Used by the long-press → "Remove from Continue Watching" UX.
  /// Idempotent — silently does nothing if the URI isn't in history.
  Future<void> removeFromHistory(String videoUri) async {
    final history = await loadHistory();
    final filtered =
        history.where((e) => e.videoUri != videoUri).toList(growable: false);
    if (filtered.length != history.length) {
      await saveHistory(filtered);
    }
  }

  /// Record (or update) a playback entry.
  ///
  /// [countAsNewPlay] must be true exactly once per time the user opens the
  /// file, and false for the periodic progress saves that follow.
  ///
  /// BUG FIX — there was no such flag, and every progress save incremented
  /// `watchCount`. Since progress saves fire on a timer while a video plays,
  /// the field counted SAVES rather than plays: a single viewing of a
  /// feature-length film reported having been watched over a hundred times,
  /// which made the number meaningless anywhere it was shown or sorted on.
  Future<void> recordPlayback({
    required String videoUri,
    required String videoTitle,
    required Duration position,
    required Duration duration,
    bool countAsNewPlay = false,
  }) async {
    final history = await loadHistory();
    final idx = history.indexWhere((e) => e.videoUri == videoUri);
    if (idx >= 0) {
      history[idx] = history[idx].copyWith(
        lastPosition: position,
        lastWatched: DateTime.now(),
        watchCount: history[idx].watchCount + (countAsNewPlay ? 1 : 0),
      );
    } else {
      history.insert(
        0,
        HistoryEntry(
          videoUri: videoUri,
          videoTitle: videoTitle,
          lastPosition: position,
          totalDuration: duration,
          lastWatched: DateTime.now(),
          watchCount: 1,
        ),
      );
    }
    await saveHistory(history);
  }

  Future<void> clearHistory() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kHistory);
  }

  Future<void> deleteHistoryEntry(String videoUri) async {
    final history = await loadHistory();
    history.removeWhere((e) => e.videoUri == videoUri);
    await saveHistory(history);
  }

  // === RECYCLE BIN ===

  Future<List<RecycleBinEntry>> loadRecycleBin() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kRecycle);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final all = list
          .map((e) => RecycleBinEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      all.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      return all;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveRecycleBin(List<RecycleBinEntry> entries) async {
    final sp = await SharedPreferences.getInstance();
    final list = entries.map((e) => e.toJson()).toList();
    await sp.setString(_kRecycle, jsonEncode(list));
  }

  Future<void> addToRecycleBin(RecycleBinEntry entry) async {
    final entries = await loadRecycleBin();
    entries.removeWhere((e) => e.videoUri == entry.videoUri);
    entries.insert(0, entry);
    await saveRecycleBin(entries);
  }

  Future<void> restoreFromRecycleBin(String videoUri) async {
    final entries = await loadRecycleBin();
    entries.removeWhere((e) => e.videoUri == videoUri);
    await saveRecycleBin(entries);
  }

  Future<void> emptyRecycleBin() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kRecycle);
  }

  // === WATCH LATER (Phase 11) ===
  /// Watch Later is a simple ordered queue (oldest at end, newest at top).

  Future<List<String>> loadWatchLater() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getStringList(_kWatchLater) ?? const [];
  }

  Future<void> saveWatchLater(List<String> uris) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_kWatchLater, uris);
  }

  Future<bool> addToWatchLater(String videoUri) async {
    final list = await loadWatchLater();
    if (list.contains(videoUri)) return false;
    list.insert(0, videoUri);
    await saveWatchLater(list);
    return true;
  }

  Future<void> removeFromWatchLater(String videoUri) async {
    final list = await loadWatchLater();
    list.remove(videoUri);
    await saveWatchLater(list);
  }

  Future<bool> isInWatchLater(String videoUri) async {
    final list = await loadWatchLater();
    return list.contains(videoUri);
  }

  // === PER-VIDEO SPEED MEMORY (Phase 11) ===
  /// Maps videoUri -> last-used speed for sticky playback speed per video.

  Future<Map<String, double>> loadVideoSpeeds() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kVideoSpeeds);
    if (raw == null) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, (v as num).toDouble()));
    } catch (_) {
      return {};
    }
  }

  Future<void> setVideoSpeed(String videoUri, double speed) async {
    final sp = await SharedPreferences.getInstance();
    final speeds = await loadVideoSpeeds();
    if (speed == 1.0) {
      speeds.remove(videoUri); // don't store default
    } else {
      speeds[videoUri] = speed;
    }
    // Cap at 200 entries
    if (speeds.length > 200) {
      final keys = speeds.keys.take(200).toList();
      final trimmed = {for (final k in keys) k: speeds[k]!};
      await sp.setString(_kVideoSpeeds, jsonEncode(trimmed));
    } else {
      await sp.setString(_kVideoSpeeds, jsonEncode(speeds));
    }
  }

  Future<double?> getVideoSpeed(String videoUri) async {
    final speeds = await loadVideoSpeeds();
    return speeds[videoUri];
  }

  // === SKIP MARKERS (Phase 14) ===
  /// Stores intro/outro skip markers per video: { videoUri: {intro: ms, outro: ms} }

  Future<Map<String, SkipMarkers>> loadAllSkipMarkers() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kSkipMarkers);
    if (raw == null) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(
            k,
            SkipMarkers.fromJson(v as Map<String, dynamic>),
          ));
    } catch (_) {
      return {};
    }
  }

  Future<SkipMarkers?> getSkipMarkers(String videoUri) async {
    final all = await loadAllSkipMarkers();
    return all[videoUri];
  }

  Future<void> setSkipMarkers(String videoUri, SkipMarkers markers) async {
    final sp = await SharedPreferences.getInstance();
    final all = await loadAllSkipMarkers();
    if (markers.introEndMs == null && markers.outroStartMs == null) {
      all.remove(videoUri);
    } else {
      all[videoUri] = markers;
    }
    // Cap at 500 entries
    if (all.length > 500) {
      final keys = all.keys.take(500).toList();
      final trimmed = {for (final k in keys) k: all[k]!};
      await sp.setString(
        _kSkipMarkers,
        jsonEncode(trimmed.map((k, v) => MapEntry(k, v.toJson()))),
      );
    } else {
      await sp.setString(
        _kSkipMarkers,
        jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))),
      );
    }
  }

  Future<void> clearSkipMarkers(String videoUri) async {
    final sp = await SharedPreferences.getInstance();
    final all = await loadAllSkipMarkers();
    all.remove(videoUri);
    await sp.setString(
      _kSkipMarkers,
      jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  /// Phase 10: Auto-cleanup recycle bin entries older than [retention].
  /// Called on app start in main.dart.
  /// Returns number of entries removed.
  Future<int> cleanupOldRecycleBinEntries({
    Duration retention = const Duration(days: 30),
  }) async {
    final entries = await loadRecycleBin();
    final cutoff = DateTime.now().subtract(retention);
    final remaining = entries.where((e) => e.deletedAt.isAfter(cutoff)).toList();
    final removed = entries.length - remaining.length;
    if (removed > 0) {
      await saveRecycleBin(remaining);
    }
    return removed;
  }

  // === PER-VIDEO TRACK MEMORY (Phase 41) ===
  // Used by the "Remember selections" setting. Stores the audio/subtitle
  // track ID last chosen for each video so reopening picks the same track.

  Future<Map<String, String>> _loadTrackMap(String key) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(key);
    if (raw == null) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveTrackMap(String key, Map<String, String> map) async {
    final sp = await SharedPreferences.getInstance();
    // Cap at 200 entries to keep SharedPreferences light.
    if (map.length > 200) {
      final keys = map.keys.take(200).toList();
      final trimmed = {for (final k in keys) k: map[k]!};
      await sp.setString(key, jsonEncode(trimmed));
    } else {
      await sp.setString(key, jsonEncode(map));
    }
  }

  Future<String?> getVideoAudioTrackId(String videoUri) async {
    final m = await _loadTrackMap(_kVideoAudioTracks);
    return m[videoUri];
  }

  Future<void> setVideoAudioTrackId(String videoUri, String? trackId) async {
    final m = await _loadTrackMap(_kVideoAudioTracks);
    if (trackId == null) {
      m.remove(videoUri);
    } else {
      m[videoUri] = trackId;
    }
    await _saveTrackMap(_kVideoAudioTracks, m);
  }

  Future<String?> getVideoSubtitleTrackId(String videoUri) async {
    final m = await _loadTrackMap(_kVideoSubtitleTracks);
    return m[videoUri];
  }

  Future<void> setVideoSubtitleTrackId(
      String videoUri, String? trackId) async {
    final m = await _loadTrackMap(_kVideoSubtitleTracks);
    if (trackId == null) {
      m.remove(videoUri);
    } else {
      m[videoUri] = trackId;
    }
    await _saveTrackMap(_kVideoSubtitleTracks, m);
  }

  // === PER-VIDEO BRIGHTNESS + VOLUME (Audit B5) ===

  Future<Map<String, double>> _loadDoubleMap(String key) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(key);
    if (raw == null) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, (v as num).toDouble()));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveDoubleMap(String key, Map<String, double> m) async {
    final sp = await SharedPreferences.getInstance();
    // Cap at 200 entries — same policy as the speed map. Oldest entries
    // (insertion order on iteration) get dropped if we exceed.
    if (m.length > 200) {
      final keys = m.keys.take(200).toList();
      final trimmed = {for (final k in keys) k: m[k]!};
      await sp.setString(key, jsonEncode(trimmed));
    } else {
      await sp.setString(key, jsonEncode(m));
    }
  }

  Future<double?> getVideoBrightness(String videoUri) async {
    final m = await _loadDoubleMap(_kVideoBrightness);
    return m[videoUri];
  }

  Future<void> setVideoBrightness(String videoUri, double? value) async {
    final m = await _loadDoubleMap(_kVideoBrightness);
    if (value == null) {
      m.remove(videoUri);
    } else {
      m[videoUri] = value.clamp(0.0, 1.0);
    }
    await _saveDoubleMap(_kVideoBrightness, m);
  }

  Future<double?> getVideoVolume(String videoUri) async {
    final m = await _loadDoubleMap(_kVideoVolume);
    return m[videoUri];
  }

  Future<void> setVideoVolume(String videoUri, double? value) async {
    final m = await _loadDoubleMap(_kVideoVolume);
    if (value == null) {
      m.remove(videoUri);
    } else {
      m[videoUri] = value.clamp(0.0, 1.0);
    }
    await _saveDoubleMap(_kVideoVolume, m);
  }

  // === PER-VIDEO ASPECT + ZOOM (Audit B5 cont.) ===

  Future<Map<String, String>> _loadStringMap(String key) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(key);
    if (raw == null) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveStringMap(String key, Map<String, String> m) async {
    final sp = await SharedPreferences.getInstance();
    if (m.length > 200) {
      final keys = m.keys.take(200).toList();
      final trimmed = {for (final k in keys) k: m[k]!};
      await sp.setString(key, jsonEncode(trimmed));
    } else {
      await sp.setString(key, jsonEncode(m));
    }
  }

  /// Returns the saved AspectRatioMode `.name` for [videoUri], or null
  /// if the user has never adjusted aspect for this file (use the
  /// app-level default in that case).
  Future<String?> getVideoAspectName(String videoUri) async {
    final m = await _loadStringMap(_kVideoAspect);
    return m[videoUri];
  }

  Future<void> setVideoAspectName(String videoUri, String? aspectName) async {
    final m = await _loadStringMap(_kVideoAspect);
    if (aspectName == null) {
      m.remove(videoUri);
    } else {
      m[videoUri] = aspectName;
    }
    await _saveStringMap(_kVideoAspect, m);
  }

  Future<double?> getVideoZoom(String videoUri) async {
    final m = await _loadDoubleMap(_kVideoZoom);
    return m[videoUri];
  }

  Future<void> setVideoZoom(String videoUri, double? scale) async {
    final m = await _loadDoubleMap(_kVideoZoom);
    // Only store if meaningfully different from default 1.0; clamp to a
    // sane range so a bad write can't blow up the next restore.
    if (scale == null || (scale - 1.0).abs() < 0.01) {
      m.remove(videoUri);
    } else {
      m[videoUri] = scale.clamp(0.5, 4.0);
    }
    await _saveDoubleMap(_kVideoZoom, m);
  }
}
