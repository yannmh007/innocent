import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A quality choice that can be made BEFORE knowing what a video offers.
///
/// This is the piece that was missing, and it unlocks two things at once.
/// Picking a row out of a probed format list only works when there is exactly
/// one video and someone is looking at it; it cannot express "720p if there is
/// one" for fifty playlist entries nobody has resolved yet, and it cannot be
/// saved as a preference. A yt-dlp format EXPRESSION can do both.
///
/// So the same six presets drive the default-quality setting (paste a link and
/// it just downloads) and batch downloads (choose once, apply to everything).
enum QualityPreset { ask, best, p1080, p720, p480, p360, audio }

extension QualityPresetX on QualityPreset {
  /// The `-f` expression.
  ///
  /// Each one is a chain with fallbacks: take the best video up to the height
  /// plus the best audio; failing that a combined stream up to that height;
  /// failing that whatever exists. Without the tail a video published only at
  /// 240p would fail a 720p request instead of quietly giving 240p.
  String get selector {
    switch (this) {
      case QualityPreset.ask:
        return '';
      case QualityPreset.best:
        return 'bv*+ba/b';
      case QualityPreset.p1080:
        return 'bv*[height<=1080]+ba/b[height<=1080]/b';
      case QualityPreset.p720:
        return 'bv*[height<=720]+ba/b[height<=720]/b';
      case QualityPreset.p480:
        return 'bv*[height<=480]+ba/b[height<=480]/b';
      case QualityPreset.p360:
        return 'bv*[height<=360]+ba/b[height<=360]/b';
      case QualityPreset.audio:
        return 'ba/b';
    }
  }

  bool get isAudioOnly => this == QualityPreset.audio;

  /// Video presets can resolve to two separate streams, so they need the muxer.
  bool get needsMerge =>
      this != QualityPreset.ask && this != QualityPreset.audio;

  String get id => name;

  static QualityPreset fromId(String? value) {
    for (final QualityPreset p in QualityPreset.values) {
      if (p.name == value) return p;
    }
    return QualityPreset.ask;
  }
}

/// One video inside a collection.
@immutable
class PlaylistEntry {
  const PlaylistEntry({
    required this.url,
    required this.title,
    this.durationSeconds,
  });

  final String url;
  final String title;
  final double? durationSeconds;
}

/// A link that turned out to name many videos.
@immutable
class PlaylistProbe {
  const PlaylistProbe({
    required this.title,
    required this.entries,
    this.uploader,
  });

  final String title;
  final List<PlaylistEntry> entries;
  final String? uploader;

  bool get isEmpty => entries.isEmpty;
}

/// Reads `yt-dlp --flat-playlist -J` output.
///
/// Flat on purpose: resolving every entry to build a list the user may close
/// again would be minutes of work and dozens of requests to a site that is
/// already rationing them. Titles and addresses are enough to choose from; the
/// real resolution happens per item, as each download starts.
class PlaylistParser {
  PlaylistParser._();

  /// True when a link names a collection rather than one video.
  ///
  /// Note the `watch?v=…&list=…` case: that is a video that happens to sit in
  /// a playlist, and treating it as a playlist would be against what the
  /// person clearly meant. Only links whose subject IS the collection count.
  static bool looksLikePlaylist(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return false;
    final String path = uri.path.toLowerCase();
    if (path.contains('/playlist') ||
        path.contains('/sets/') ||
        path.endsWith('/videos') ||
        path.contains('/album/')) {
      return true;
    }
    // A bare list= with no video is a playlist link.
    return uri.queryParameters.containsKey('list') &&
        !uri.queryParameters.containsKey('v');
  }

  static PlaylistProbe? tryParse(String rawJson, String requestedUrl) {
    try {
      final Object? decoded = jsonDecode(rawJson);
      if (decoded is! Map) return null;
      if (decoded['_type'] != 'playlist') return null;
      final Object? rawEntries = decoded['entries'];
      if (rawEntries is! List || rawEntries.isEmpty) return null;

      final List<PlaylistEntry> entries = <PlaylistEntry>[];
      for (final Object? raw in rawEntries) {
        if (raw is! Map) continue;
        final String? url = _entryUrl(raw, requestedUrl);
        if (url == null) continue;
        entries.add(PlaylistEntry(
          url: url,
          title: _string(raw['title']) ?? _string(raw['id']) ?? 'Video',
          durationSeconds: _double(raw['duration']),
        ));
        // A channel can hold thousands. Past a couple of hundred the list
        // stops being something anyone scrolls through and starts being a way
        // to fill a phone by accident.
        if (entries.length >= 200) break;
      }
      if (entries.isEmpty) return null;

      return PlaylistProbe(
        title: _string(decoded['title']) ?? 'Playlist',
        uploader: _string(decoded['uploader']) ?? _string(decoded['channel']),
        entries: entries,
      );
    } catch (_) {
      return null;
    }
  }

  /// Flat entries carry a full URL on most sites and a bare id on some, so the
  /// id is rebuilt into an address using the collection's own host.
  static String? _entryUrl(Map<Object?, Object?> raw, String requestedUrl) {
    final String? url = _string(raw['url']);
    if (url != null && url.startsWith('http')) return url;
    final String? id = _string(raw['id']);
    if (id == null) return null;
    final Uri? parent = Uri.tryParse(requestedUrl);
    final String host = parent?.host.toLowerCase() ?? '';
    if (host.contains('youtube') || host.contains('youtu.be')) {
      return 'https://www.youtube.com/watch?v=$id';
    }
    if (url != null && url.isNotEmpty && parent != null) {
      // A site-relative reference.
      return parent.resolve(url).toString();
    }
    return null;
  }

  static String? _string(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return value.toString();
    return null;
  }

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
