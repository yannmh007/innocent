/// Folder entity (immutable)
class Folder {
  final String path;
  final String name;
  final int videoCount;
  final String? coverThumbnailPath;

  /// Phase 16: Number of "new" videos (added within last 7 days, never watched).
  /// Used to show the red badge in folder lists/grids (MX Player parity).
  final int newCount;

  /// Phase 28: Sum of video sizes in this folder (in bytes).
  /// Used to display the size chip beside "X videos" (MX Player parity).
  final int totalSizeBytes;

  const Folder({
    required this.path,
    required this.name,
    required this.videoCount,
    this.coverThumbnailPath,
    this.newCount = 0,
    this.totalSizeBytes = 0,
  });

  /// Human-readable size string ("174 GB", "641 MB", "1.8 GB").
  String get sizeLabel {
    final b = totalSizeBytes;
    if (b <= 0) return '';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    final gb = b / (1024 * 1024 * 1024);
    return gb < 10 ? '${gb.toStringAsFixed(1)} GB' : '${gb.toStringAsFixed(0)} GB';
  }
}
