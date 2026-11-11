import 'language_names.dart';

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

  /// What the subtitle menu shows: the track's title, and its language by
  /// its own name when the title does not already say it — "SDH ·
  /// English", "မြန်မာ". A bare code ("mya") becomes the language's name.
  String get displayName {
    // Capture into locals so Dart's null-promotion works without `!`.
    final t = title?.trim();
    final code = language?.trim();
    final lang = languageName(code) ?? languageName(t) ?? code;
    if (t != null && t.isNotEmpty) {
      // A title that is only a code ("eng") is the language's name.
      final titleLang = languageName(t);
      if (titleLang != null) return titleLang;
      if (lang != null &&
          lang.isNotEmpty &&
          !t.toLowerCase().contains(lang.toLowerCase())) {
        return '$t · $lang';
      }
      return t;
    }
    if (lang != null && lang.isNotEmpty) return lang;
    return 'Subtitle $id';
  }
}
