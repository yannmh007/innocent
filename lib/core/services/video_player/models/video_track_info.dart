/// Engine-agnostic video track info
class VideoTrackInfo {
  final String id;
  final int? width;
  final int? height;
  final double? frameRate;
  final int? bitrate;
  final String? codec;

  const VideoTrackInfo({
    required this.id,
    this.width,
    this.height,
    this.frameRate,
    this.bitrate,
    this.codec,
  });

  String get displayName {
    final parts = <String>[];
    if (height != null) parts.add('${height}p');
    final fr = frameRate;
    if (fr != null) parts.add('${fr.toStringAsFixed(0)}fps');
    final c = codec;
    if (c != null && c.isNotEmpty) parts.add(c);
    if (parts.isEmpty) return 'Track $id';
    return parts.join(' · ');
  }
}
