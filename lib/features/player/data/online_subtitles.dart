import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../video_hub/data/api/api_client.dart';
import '../../video_hub/data/api/api_exception.dart';
import '../../video_hub/data/device_identity.dart';

/// CC → Online: subtitles found and loaded in the app (P5, 28 Nov 2026),
/// through the edge function `subtitles-online` (docs/edge/subtitles-online.ts),
/// which holds OpenSubtitles' key and the owner's account. The app sends the
/// film's name (as typed) or its file hash, and this install's id for the
/// budget (migration 084); never anything else of the viewer's.
class OnlineSubtitle {
  const OnlineSubtitle({
    required this.fileId,
    required this.lang,
    required this.release,
    required this.name,
    this.downloads = 0,
    this.hearingImpaired = false,
    this.machine = false,
    this.hashMatch = false,
    this.title = '',
    this.year = 0,
  });

  factory OnlineSubtitle.fromJson(Map<String, dynamic> j) => OnlineSubtitle(
        fileId: (j['file_id'] as num?)?.toInt() ?? 0,
        lang: (j['lang'] as String?) ?? '',
        release: (j['release'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        downloads: (j['downloads'] as num?)?.toInt() ?? 0,
        hearingImpaired: j['hi'] == true,
        machine: j['ai'] == true,
        hashMatch: j['hash_match'] == true,
        title: (j['title'] as String?) ?? '',
        year: (j['year'] as num?)?.toInt() ?? 0,
      );

  final int fileId;
  final String lang;
  final String release;
  final String name;
  final int downloads;
  final bool hearingImpaired;
  final bool machine;
  final bool hashMatch;
  final String title;
  final int year;

  /// What the row says: the release, else the file's name.
  String get label => release.isNotEmpty ? release : name;
}

enum OnlineSubtitleFailure {
  /// No connection.
  offline,

  /// Too many searches or downloads from this phone or its network; later.
  busy,

  /// The day's downloads are spent (the shared account's, or this phone's).
  dayUsedUp,

  /// The service has no key yet (the owner has not set it).
  notReady,

  /// Anything else the service or OpenSubtitles answered.
  unavailable,
}

class OnlineSubtitleError implements Exception {
  const OnlineSubtitleError(this.why, {this.retryAfter});
  final OnlineSubtitleFailure why;
  final int? retryAfter;

  @override
  String toString() => 'OnlineSubtitleError(${why.name})';
}

class OnlineSubtitles {
  OnlineSubtitles(this._api, {Future<String?> Function()? deviceId})
      : _deviceId = deviceId ?? DeviceIdentity.get;

  final ApiClient _api;
  final Future<String?> Function() _deviceId;

  static const String _path = '/functions/v1/subtitles-online';

  Future<List<OnlineSubtitle>> search({
    String? query,
    String? moviehash,
    List<String> languages = const <String>[],
  }) async {
    final body = await _post(<String, dynamic>{
      'op': 'search',
      if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
      if (moviehash != null) 'moviehash': moviehash,
      if (languages.isNotEmpty) 'languages': languages.join(','),
    });
    final rows = body is Map ? body['results'] : null;
    if (rows is! List) return const <OnlineSubtitle>[];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(OnlineSubtitle.fromJson)
        .where((s) => s.fileId > 0)
        .toList(growable: false);
  }

  /// Downloads [s] as SubRip into [dir]; the file it wrote.
  Future<File> download(OnlineSubtitle s, Directory dir) async {
    final body = await _post(<String, dynamic>{
      'op': 'download',
      'file_id': s.fileId,
      'name': s.name,
    });
    final data = body is Map ? body['data'] : null;
    final name = body is Map ? body['name'] : null;
    if (data is! String || data.isEmpty) {
      throw const OnlineSubtitleError(OnlineSubtitleFailure.unavailable);
    }
    final bytes = base64Decode(data);
    await dir.create(recursive: true);
    final safe = (name is String && name.endsWith('.srt'))
        ? name.replaceAll(RegExp(r'[/\\]'), ' ')
        : 'subtitle-${s.fileId}.srt';
    final f = File('${dir.path}/$safe');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  Future<dynamic> _post(Map<String, dynamic> body) async {
    final id = await _deviceId();
    try {
      return await _api.postJson(_path,
          body: <String, dynamic>{...body, 'device_id': id ?? ''},
          timeout: const Duration(seconds: 25));
    } on ApiException catch (e) {
      throw OnlineSubtitleError(_why(e));
    } on SocketException {
      throw const OnlineSubtitleError(OnlineSubtitleFailure.offline);
    }
  }

  static OnlineSubtitleFailure _why(ApiException e) {
    if (e.kind == ApiErrorKind.network) return OnlineSubtitleFailure.offline;
    switch (e.code) {
      case 'quota_day':
        return OnlineSubtitleFailure.dayUsedUp;
      case 'rate_limited':
        return OnlineSubtitleFailure.busy;
      case 'not_configured':
        return OnlineSubtitleFailure.notReady;
    }
    if (e.statusCode == 429 || e.kind == ApiErrorKind.tooManyRequests) {
      return OnlineSubtitleFailure.busy;
    }
    return OnlineSubtitleFailure.unavailable;
  }
}

/// OpenSubtitles' hash of a video file: its size plus the 64-bit
/// little-endian sums of its first and last 64 KiB, as 16 hex digits — the
/// search then finds subtitles made for this very file first. Null for a
/// file under 128 KiB or one that cannot be read.
Future<String?> movieHash(File f) async {
  const chunk = 65536;
  RandomAccessFile? raf;
  try {
    raf = await f.open();
    final size = await raf.length();
    if (size < chunk * 2) return null;
    final head = await raf.read(chunk);
    await raf.setPosition(size - chunk);
    final tail = await raf.read(chunk);
    return movieHashOf(size, head, tail);
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

/// [movieHash] from the size and the two 64 KiB ends (tested on their own).
String movieHashOf(int size, Uint8List head, Uint8List tail) {
  final mask = (BigInt.one << 64) - BigInt.one;
  var h = BigInt.from(size) & mask;
  for (final part in <Uint8List>[head, tail]) {
    final v = ByteData.sublistView(part);
    for (var i = 0; i + 8 <= part.length; i += 8) {
      final lo = BigInt.from(v.getUint32(i, Endian.little));
      final hi = BigInt.from(v.getUint32(i + 4, Endian.little));
      h = (h + ((hi << 32) | lo)) & mask;
    }
  }
  return h.toRadixString(16).padLeft(16, '0');
}
