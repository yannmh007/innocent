/// User playlist (named collection of video URIs)
class Playlist {
  final String id;
  final String name;
  final List<String> videoUris;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Playlist({
    required this.id,
    required this.name,
    required this.videoUris,
    required this.createdAt,
    required this.updatedAt,
  });

  Playlist copyWith({
    String? name,
    List<String>? videoUris,
    DateTime? updatedAt,
  }) {
    return Playlist(
      id: id,
      name: name ?? this.name,
      videoUris: videoUris ?? this.videoUris,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'videoUris': videoUris,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: j['id'] as String,
        name: j['name'] as String,
        videoUris: (j['videoUris'] as List).cast<String>(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num).toInt()),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['updatedAt'] as num).toInt()),
      );
}

/// Bookmark — a saved playback position within a video
class Bookmark {
  final String id;
  final String videoUri;
  final String videoTitle;
  final Duration position;
  final String? label;
  final DateTime createdAt;

  const Bookmark({
    required this.id,
    required this.videoUri,
    required this.videoTitle,
    required this.position,
    required this.createdAt,
    this.label,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'videoUri': videoUri,
        'videoTitle': videoTitle,
        'positionMs': position.inMilliseconds,
        'label': label,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory Bookmark.fromJson(Map<String, dynamic> j) => Bookmark(
        id: j['id'] as String,
        videoUri: j['videoUri'] as String,
        videoTitle: j['videoTitle'] as String,
        position: Duration(milliseconds: (j['positionMs'] as num).toInt()),
        label: j['label'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num).toInt()),
      );
}

/// History entry — last-watched record per video
class HistoryEntry {
  final String videoUri;
  final String videoTitle;
  final Duration lastPosition;
  final Duration totalDuration;
  final DateTime lastWatched;
  final int watchCount;

  const HistoryEntry({
    required this.videoUri,
    required this.videoTitle,
    required this.lastPosition,
    required this.totalDuration,
    required this.lastWatched,
    required this.watchCount,
  });

  HistoryEntry copyWith({
    Duration? lastPosition,
    DateTime? lastWatched,
    int? watchCount,
  }) {
    return HistoryEntry(
      videoUri: videoUri,
      videoTitle: videoTitle,
      lastPosition: lastPosition ?? this.lastPosition,
      totalDuration: totalDuration,
      lastWatched: lastWatched ?? this.lastWatched,
      watchCount: watchCount ?? this.watchCount,
    );
  }

  /// Completion ratio 0.0 - 1.0
  double get progress {
    if (totalDuration.inMilliseconds == 0) return 0.0;
    return (lastPosition.inMilliseconds / totalDuration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'videoUri': videoUri,
        'videoTitle': videoTitle,
        'lastPositionMs': lastPosition.inMilliseconds,
        'totalDurationMs': totalDuration.inMilliseconds,
        'lastWatched': lastWatched.millisecondsSinceEpoch,
        'watchCount': watchCount,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        videoUri: j['videoUri'] as String,
        videoTitle: j['videoTitle'] as String,
        lastPosition:
            Duration(milliseconds: (j['lastPositionMs'] as num).toInt()),
        totalDuration:
            Duration(milliseconds: (j['totalDurationMs'] as num).toInt()),
        lastWatched: DateTime.fromMillisecondsSinceEpoch(
            (j['lastWatched'] as num).toInt()),
        watchCount: (j['watchCount'] as num).toInt(),
      );
}

/// Recycle bin entry — soft-deleted video reference
class RecycleBinEntry {
  final String videoUri;
  final String videoTitle;
  final String folderPath;
  final DateTime deletedAt;
  final int sizeBytes;

  const RecycleBinEntry({
    required this.videoUri,
    required this.videoTitle,
    required this.folderPath,
    required this.deletedAt,
    required this.sizeBytes,
  });

  Map<String, dynamic> toJson() => {
        'videoUri': videoUri,
        'videoTitle': videoTitle,
        'folderPath': folderPath,
        'deletedAt': deletedAt.millisecondsSinceEpoch,
        'sizeBytes': sizeBytes,
      };

  factory RecycleBinEntry.fromJson(Map<String, dynamic> j) => RecycleBinEntry(
        videoUri: j['videoUri'] as String,
        videoTitle: j['videoTitle'] as String,
        folderPath: j['folderPath'] as String,
        deletedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['deletedAt'] as num).toInt()),
        sizeBytes: (j['sizeBytes'] as num).toInt(),
      );
}

/// Skip markers for a video — intro end + outro start, both in milliseconds.
/// Used to auto-skip intro/outro on subsequent plays.
class SkipMarkers {
  final int? introEndMs;
  final int? outroStartMs;

  const SkipMarkers({this.introEndMs, this.outroStartMs});

  bool get hasMarkers => introEndMs != null || outroStartMs != null;

  Duration? get introEnd =>
      introEndMs != null ? Duration(milliseconds: introEndMs!) : null;

  Duration? get outroStart =>
      outroStartMs != null ? Duration(milliseconds: outroStartMs!) : null;

  SkipMarkers copyWith({
    Object? introEndMs = _sentinel,
    Object? outroStartMs = _sentinel,
  }) {
    return SkipMarkers(
      introEndMs: introEndMs == _sentinel
          ? this.introEndMs
          : introEndMs as int?,
      outroStartMs: outroStartMs == _sentinel
          ? this.outroStartMs
          : outroStartMs as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        if (introEndMs != null) 'introEndMs': introEndMs,
        if (outroStartMs != null) 'outroStartMs': outroStartMs,
      };

  factory SkipMarkers.fromJson(Map<String, dynamic> j) => SkipMarkers(
        introEndMs: j['introEndMs'] as int?,
        outroStartMs: j['outroStartMs'] as int?,
      );
}

const Object _sentinel = Object();
