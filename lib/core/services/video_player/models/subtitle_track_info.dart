/// Engine-agnostic subtitle track info
class SubtitleTrackInfo {
  final String id;
  final String? title;
  final String? language;
  final bool isExternal;

  const SubtitleTrackInfo({
    required this.id,
    this.title,
    this.language,
    this.isExternal = false,
  });

  String get displayName {
    // Capture into locals so Dart's null-promotion works without `!`.
    final t = title;
    if (t != null && t.isNotEmpty) return t;
    final l = language;
    if (l != null && l.isNotEmpty) return l;
    return 'Subtitle $id';
  }
}
