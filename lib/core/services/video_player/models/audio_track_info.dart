import 'language_names.dart';

/// Engine-agnostic audio track info
class AudioTrackInfo {
  final String id;
  final String? title;
  final String? language;
  final String? codec;
  final int? channels;

  const AudioTrackInfo({
    required this.id,
    this.title,
    this.language,
    this.codec,
    this.channels,
  });

  /// What the audio menu shows: the track's own title, its language by its
  /// own name, then codec and channels — "Commentary · English · AAC 2.0".
  ///
  /// The title used to be dropped whenever a language was set, so a film's
  /// two English tracks (the film and its commentary, or stereo and 5.1)
  /// both read "eng" and could not be told apart.
  String get displayName {
    final parts = <String>[];
    final t = title?.trim();
    if (t != null && t.isNotEmpty) parts.add(t);
    final code = language?.trim();
    final lang = languageName(code) ?? code;
    if (lang != null &&
        lang.isNotEmpty &&
        !parts.any((p) => p.toLowerCase().contains(lang.toLowerCase()))) {
      parts.add(lang);
    }
    final c = codec?.trim();
    final ch = channels;
    final tech = [
      if (c != null && c.isNotEmpty) c.toUpperCase(),
      if (ch != null && ch > 0) channelLayout(ch),
    ].join(' ');
    if (tech.isNotEmpty) parts.add(tech);
    if (parts.isEmpty) return 'Track $id';
    return parts.join(' · ');
  }
}
