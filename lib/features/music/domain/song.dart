/// Phase 32: Music domain models for real device audio.
/// Audit fix (album art + ID3): Song now carries optional album-art
/// bytes extracted lazily via MusicLocalDataSource.loadAlbumArt.
class Song {
  final String id;
  final String uri;
  final String title;
  final String artist;
  final String album;
  final String folderPath;
  final Duration duration;
  final int sizeBytes;
  final DateTime? dateAdded;
  /// Embedded album art bytes if the file has any. Null when not
  /// present or when skipped during bulk scan (art fetched lazily
  /// by the player screen).
  final List<int>? coverBytes;

  const Song({
    required this.id,
    required this.uri,
    required this.title,
    required this.artist,
    required this.album,
    required this.folderPath,
    required this.duration,
    required this.sizeBytes,
    this.dateAdded,
    this.coverBytes,
  });

  Song copyWith({List<int>? coverBytes}) {
    return Song(
      id: id,
      uri: uri,
      title: title,
      artist: artist,
      album: album,
      folderPath: folderPath,
      duration: duration,
      sizeBytes: sizeBytes,
      dateAdded: dateAdded,
      coverBytes: coverBytes ?? this.coverBytes,
    );
  }

  String get formattedSize {
    if (sizeBytes >= 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (sizeBytes >= 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$sizeBytes B';
  }

  /// Artist text for display. Uses the embedded tag when present;
  /// otherwise falls back to the containing folder's name, which is far
  /// more useful than a bare "Unknown" for the untagged files common in
  /// downloaded libraries. Only when neither exists do we show a generic
  /// label. Derives the folder name without the `path` package so it is
  /// safe to call from anywhere (including background isolates).
  String get displayArtist {
    final a = artist.trim();
    if (a.isNotEmpty) return a;
    final parts = folderPath.split(RegExp(r'[/\\]'))
      ..removeWhere((e) => e.isEmpty);
    if (parts.isNotEmpty) {
      final folder = parts.last.trim();
      if (folder.isNotEmpty) return folder;
    }
    return 'Unknown artist';
  }
}

/// Music folder (grouping of songs by parent directory)
class MusicFolder {
  final String path;
  final String name;
  final int songCount;
  const MusicFolder({
    required this.path,
    required this.name,
    required this.songCount,
  });
}

/// Album (grouping of songs by album tag, falling back to folder name)
class MusicAlbum {
  final String name;
  final int songCount;
  final String? artist;
  const MusicAlbum({
    required this.name,
    required this.songCount,
    this.artist,
  });
}

/// Artist (grouping by artist tag)
class MusicArtist {
  final String name;
  final int songCount;
  const MusicArtist({
    required this.name,
    required this.songCount,
  });
}
