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

  String get displayName {
    final parts = <String>[];
    final l = language;
    if (l != null && l.isNotEmpty) parts.add(l);
    final c = codec;
    if (c != null && c.isNotEmpty) parts.add(c);
    if (channels != null) parts.add('${channels}ch');
    if (parts.isEmpty) return title ?? 'Track $id';
    return parts.join(' · ');
  }
}
