/// The one list of subtitle formats this app accepts.
///
/// v1.63 — WHY THIS EXISTS.
///
/// The same decision was written out five times, and all five had drifted:
/// the manual file picker took `srt ass ssa vtt sub`, sidecar auto-detection
/// looked only for `srt ass ssa vtt`, the "copy alongside" helper knew about
/// `idx` and `smi`, and the URL downloader had its own fourth list. So a
/// `.smi` file could be copied by the app but never opened by it, and a `.sub`
/// could be picked by hand but was invisible sitting next to its video.
///
/// WHAT libmpv ACTUALLY READS. Everything below, plus embedded tracks, is
/// handled by libmpv/FFmpeg already — none of this needed a new parser. The
/// formats were being refused by our own whitelists, not by the player. That
/// is what closes most of the gap against MX Player's subtitle-format list in
/// one change.
///
/// TWO PAIRED FORMATS worth knowing about:
///   * VobSub is `.idx` + `.sub` TOGETHER. The `.idx` is the index and is the
///     one to open; the `.sub` beside it holds the bitmaps. Opening the
///     `.sub` alone usually shows nothing, which is why `.idx` leads the list
///     for auto-detection.
///   * `.sub` is ambiguous — it is MicroDVD text OR the VobSub binary half.
///     libmpv sniffs the content, so both work; we just offer the file.
///
/// `.txt` is deliberately NOT in [pickerExtensions]. TMPlayer uses it, but so
/// does every readme and note on the device, and a file picker full of text
/// files is worse than a missing format. It stays in [allExtensions] so a
/// sidecar named `movie.txt` is still found automatically.
library;

class SubtitleFormats {
  SubtitleFormats._();

  /// Everything the app will accept from anywhere, without the dot.
  static const List<String> allExtensions = <String>[
    'srt', // SubRip — by far the most common
    'ass', // Advanced SubStation Alpha, full styling
    'ssa', // SubStation Alpha
    'vtt', // WebVTT
    'sub', // MicroDVD text, or the VobSub binary half
    'idx', // VobSub index — the half to open
    'smi', // SAMI
    'sami', // SAMI, spelled out
    'mpl', // MPL2
    'pjs', // Phoenix Japanimation Society
    'txt', // TMPlayer
    'sup', // PGS/Blu-ray bitmap subtitles
    'lrc', // lyrics, for the music side
  ];

  /// Offered in the "choose a subtitle file" picker. See the note about
  /// `.txt` above.
  static const List<String> pickerExtensions = <String>[
    'srt', 'ass', 'ssa', 'vtt', 'sub', 'idx', 'smi', 'sami', 'mpl', 'pjs',
    'sup',
  ];

  /// Tried, in order, when looking for `<video name>.<ext>` beside a video.
  ///
  /// Ordered by how likely each is to be the one the user means, because the
  /// first hit wins: text formats before bitmap ones, and `.idx` before
  /// `.sub` so a VobSub pair opens by its index rather than its data half.
  static const List<String> sidecarExtensions = <String>[
    'srt', 'ass', 'ssa', 'vtt', 'smi', 'sami', 'mpl', 'pjs', 'idx', 'sub',
    'txt', 'sup',
  ];

  /// With the leading dot, for matching a URL or filename suffix.
  static Set<String> get dotted =>
      allExtensions.map((e) => '.$e').toSet();

  /// True if [nameOrPath] ends in a subtitle extension we accept.
  static bool matches(String nameOrPath) {
    final lower = nameOrPath.toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot < 0 || dot == lower.length - 1) return false;
    return allExtensions.contains(lower.substring(dot + 1));
  }
}
