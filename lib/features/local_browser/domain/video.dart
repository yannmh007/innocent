/// Video entity (immutable)
class Video {
  final String id;
  final String uri;
  final String title;
  final String folderPath;
  final Duration duration;
  final int sizeBytes;
  final int width;
  final int height;
  final String? mimeType;
  final DateTime? dateAdded;

  /// When the file itself was last written.
  ///
  /// MX Player's NEW tag covers files "copied **or modified**" within the
  /// window, and those are two different timestamps: [dateAdded] is when the
  /// media index first saw the file, [dateModified] is when its bytes last
  /// changed. Re-encoding or replacing a video in place updates the second but
  /// not the first, so using only [dateAdded] would miss it. Null on sources
  /// that do not report it, in which case [freshestDate] falls back cleanly.
  final DateTime? dateModified;
  final String? thumbnailPath;

  const Video({
    required this.id,
    required this.uri,
    required this.title,
    required this.folderPath,
    required this.duration,
    required this.sizeBytes,
    required this.width,
    required this.height,
    this.mimeType,
    this.dateAdded,
    this.dateModified,
    this.thumbnailPath,
  });

  /// The later of "when it arrived" and "when it last changed" — the date MX
  /// Player's NEW rule is measured against. Falls back to whichever one is
  /// available when a source only reports one.
  DateTime? get freshestDate {
    final a = dateAdded;
    final m = dateModified;
    if (a == null) return m;
    if (m == null) return a;
    return m.isAfter(a) ? m : a;
  }

  Video copyWith({
    int? sizeBytes,
    String? thumbnailPath,
  }) =>
      Video(
        id: id,
        uri: uri,
        title: title,
        folderPath: folderPath,
        duration: duration,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        width: width,
        height: height,
        dateModified: dateModified,
        mimeType: mimeType,
        dateAdded: dateAdded,
        thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      );

  /// True when this video comes from a place normal galleries hide: an
  /// Android/data cache reached over ADB (adb:// uri), a dot-file, or a folder
  /// on the path whose name starts with a dot (e.g. .thumbnails, .Trash).
  bool get isHidden {
    if (uri.startsWith('adb://')) return true;
    if (title.startsWith('.')) return true;
    final path = folderPath.isNotEmpty ? folderPath : uri;
    for (final seg in path.split('/')) {
      if (seg.length > 1 && seg.startsWith('.')) return true;
    }
    return false;
  }

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String get formattedDuration {
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String get resolutionLabel {
    if (height >= 2160) return '4K';
    if (height >= 1440) return '1440p';
    if (height >= 1080) return '1080p';
    if (height >= 720) return '720p';
    if (height >= 480) return '480p';
    return '${height}p';
  }
}
