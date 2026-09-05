import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'subtitle_formats.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Audit fix (standard high-quality): download a subtitle file from
/// a direct URL into the app's subtitles directory. Real, contained
/// alternative to a full OpenSubtitles API integration — the user
/// brings a URL (e.g. from OpenSubtitles, Subscene, a friend's
/// dropbox link), we fetch it, save it locally with a deterministic
/// filename keyed to the video URI, and the player's existing
/// "Add subtitle file" affordance picks it up.
///
/// Design choices:
/// - **Validates content-type loosely**: many subtitle hosts return
///   `application/octet-stream` or `text/plain`. We only reject
///   responses that are clearly HTML (a sign the link 404'd into a
///   landing page).
/// - **Size cap**: 5 MB. A real subtitle is rarely > 100 KB. The
///   cap blocks accidental download of multi-GB MKVs.
/// - **Recognised extensions**: see [SubtitleFormats]. The URL's
///   extension determines the saved filename's suffix.
/// - **No streaming**: subtitles are small, read into memory then
///   written to disk in one shot. Simpler than chunked I/O.
class SubtitleDownloadService {
  static const int _maxBytes = 5 * 1024 * 1024; // 5 MB
  // v1.63: was its own fourth copy of the format list. Shares the canonical
  // one now, so anything the player can open can also be downloaded.
  static Set<String> get _validExts => SubtitleFormats.dotted;

  /// Fetch [url] and save to `<app_docs>/subtitles/<safeName><ext>`.
  /// Returns the saved file path on success, throws on failure.
  Future<String> downloadFor({
    required String videoUri,
    required String url,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isAbsolute) {
      throw const FormatException('Invalid URL — must include http(s)://');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('Only http and https URLs supported');
    }
    // Extension is derived from the URL path, lowered.
    final pathExt = p.extension(uri.path).toLowerCase();
    if (!_validExts.contains(pathExt)) {
      throw FormatException(
          'URL does not end in a known subtitle extension '
          '(${_validExts.join(", ")}). Got: "$pathExt"');
    }
    // Issue the request with a polite timeout — slow hosts shouldn't
    // hang the UI forever.
    final resp = await http
        .get(uri, headers: {
      'User-Agent':
          'Innocent/0.46 (manual subtitle fetch; libmpv backend)'
    }).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw HttpException(
          'Server returned ${resp.statusCode} ${resp.reasonPhrase ?? ""}');
    }
    if (resp.bodyBytes.length > _maxBytes) {
      throw const FormatException(
          'Subtitle file too large (>5 MB) — likely not a subtitle file');
    }
    if (resp.bodyBytes.isEmpty) {
      throw const FormatException('Empty response body');
    }
    // Loose content-type check: reject obvious HTML landing pages.
    final ctype = resp.headers['content-type']?.toLowerCase() ?? '';
    if (ctype.contains('text/html')) {
      throw const FormatException(
          'URL returned an HTML page, not a subtitle file (link likely broken)');
    }
    // Deterministic save path: <docs>/subtitles/<videoHash><ext>
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'subtitles'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final safeName = _hashFor(videoUri);
    final dest = File(p.join(dir.path, '$safeName$pathExt'));
    await dest.writeAsBytes(resp.bodyBytes, flush: true);
    return dest.path;
  }

  /// Cheap path-safe hash of a video URI. Not cryptographic — just
  /// stable + filesystem-safe + collision-resistant for the
  /// subtitle-per-video use case.
  String _hashFor(String s) {
    var hash = 0;
    for (final cu in s.codeUnits) {
      hash = (hash * 31 + cu) & 0x7fffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Look up an already-downloaded subtitle for [videoUri], if any,
  /// returning the local path. Used by the player to auto-attach
  /// the user's previously-downloaded subtitle on open.
  Future<String?> findExisting(String videoUri) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'subtitles'));
      if (!await dir.exists()) return null;
      final safeName = _hashFor(videoUri);
      for (final ext in _validExts) {
        final f = File(p.join(dir.path, '$safeName$ext'));
        if (await f.exists()) return f.path;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

final subtitleDownloadServiceProvider =
    Provider<SubtitleDownloadService>((ref) {
  return SubtitleDownloadService();
});
