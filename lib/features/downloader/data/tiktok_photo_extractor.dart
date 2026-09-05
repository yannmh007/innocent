import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// One picture in a TikTok photo post.
@immutable
class PhotoItem {
  const PhotoItem({
    required this.candidates,
    this.width,
    this.height,
  });

  /// Every CDN URL TikTok published for this image, best first.
  ///
  /// A list rather than one URL because TikTok hands out several mirrors and
  /// individual ones 403 depending on region and time of day. The downloader
  /// walks them in order, so one dead mirror costs nothing.
  final List<String> candidates;

  final int? width;
  final int? height;

  String get url => candidates.first;

  int? get shortSide {
    if (width != null && width! > 0 && height != null && height! > 0) {
      return width! < height! ? width : height;
    }
    return null;
  }
}

@immutable
class TikTokPhotoPost {
  const TikTokPhotoPost({
    required this.images,
    this.title,
    this.author,
    this.source,
  });

  final List<PhotoItem> images;
  final String? title;
  final String? author;

  /// Which path produced this, for diagnostics.
  final String? source;
}

/// Reads the images out of a TikTok photo post.
///
/// WHY THIS EXISTS: yt-dlp does not extract them. Its TikTok extractor builds
/// the format list from the `video` object, and a photo post has none, so it
/// falls through to a branch commented "Is it a slideshow with only audio for
/// download?" and returns the music track alone — its own tests for slideshow
/// posts expect an m4a or mp3 and nothing else.
///
/// WHY IT NOW HAS TWO PATHS: the first version read the post's web page, which
/// is the same thing yt-dlp does, and so it failed in exactly the same way —
/// "Unable to extract webpage video data" is a long-running, still-open yt-dlp
/// issue, reported continuously since 2024. TikTok serves that page stripped
/// of its hydration data to clients it doesn't like, intermittently and by IP.
/// Sharing a failure mode with the tool you are working around is not a
/// workaround at all.
///
/// So the mobile app API is tried FIRST. It is the same endpoint family
/// yt-dlp's own `_extract_aweme_app` uses, it answers with JSON rather than a
/// half-megabyte page, and being a different service on a different host it is
/// not affected when the web front end decides to stonewall. The web page
/// stays as the fallback, because when it does work it carries a better
/// caption.
///
/// In the API response `display_image` is the clean picture;
/// `owner_watermark_image` and `user_watermark_image` are the versions with the
/// logo burned in, and are never read.
class TikTokPhotoExtractor {
  TikTokPhotoExtractor._();

  /// The app's own user agent. The API is much more forgiving than the web
  /// front end, but it still answers differently to something that looks like
  /// a browser.
  static const String _appUserAgent =
      'com.zhiliaoapp.musically/2023501030 (Linux; U; Android 13; en; '
      'Pixel 7; Build/TQ3A.230805.001; Cronet/58.0.2991.0)';

  static const String _webUserAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';

  /// Same default host yt-dlp uses.
  static const List<String> _apiHosts = <String>[
    'api16-normal-c-useast1a.tiktokv.com',
    'api22-normal-c-useast2a.tiktokv.com',
  ];

  // 8s, not 12: this runs up to four times over two API hosts and the page,
  // and a person watching a spinner has a much shorter patience than a socket.
  static const Duration _timeout = Duration(seconds: 8);

  /// Why the last attempt produced nothing, for the diagnostics report.
  /// Without it a failure here is indistinguishable from a post that simply
  /// has no photos in it.
  static String? lastError;

  static bool isTikTok(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return false;
    final String host = uri.host.toLowerCase();
    return host.endsWith('tiktok.com') || host.endsWith('douyin.com');
  }

  /// Returns null when this isn't a photo post or nothing could be read.
  /// Never throws.
  static Future<TikTokPhotoPost?> fetch(String url) async {
    lastError = null;
    String resolved = url;
    try {
      resolved = await _followShortLink(url);
    } catch (_) {}

    // 1) The app API, by post id. Cheap, JSON, and on a different host to the
    //    web front end that keeps refusing us.
    final String? id = _awemeId(resolved) ?? _awemeId(url);
    if (id == null) {
      lastError = 'no post id in the link';
    } else {
      for (final String host in _apiHosts) {
        final TikTokPhotoPost? post = await _fromApi(host, id);
        if (post != null) return post;
      }
    }

    // 2) The page itself. Better caption when it works, which is why it is
    //    still here rather than deleted.
    final TikTokPhotoPost? web = await _fromWeb(resolved);
    if (web == null && lastError == null) lastError = 'no photos in the page';
    return web;
  }

  // ------------------------------------------------------------------ api

  static Future<TikTokPhotoPost?> _fromApi(String host, String id) async {
    try {
      final Random random = Random();
      final String openudid = List<String>.generate(
        16,
        (_) => random.nextInt(16).toRadixString(16),
      ).join();
      final String uuid = List<String>.generate(
        16,
        (_) => random.nextInt(10).toString(),
      ).join();
      final int nowMs = DateTime.now().millisecondsSinceEpoch;

      // The API rejects requests that don't look like a real install, so this
      // carries the full device description yt-dlp sends. Values are the app's
      // published build, not anything tied to this phone.
      final Uri uri = Uri.https(host, '/aweme/v1/feed/', <String, String>{
        'aweme_id': id,
        'version_name': '35.1.3',
        'version_code': '350103',
        'build_number': '35.1.3',
        'manifest_version_code': '2023501030',
        'update_version_code': '2023501030',
        'openudid': openudid,
        'uuid': uuid,
        '_rticket': '$nowMs',
        'ts': '${nowMs ~/ 1000}',
        'device_brand': 'Google',
        'device_type': 'Pixel 7',
        'device_platform': 'android',
        'resolution': '1080*2400',
        'dpi': '420',
        'os_version': '13',
        'os_api': '33',
        'carrier_region': 'US',
        'sys_region': 'US',
        'region': 'US',
        'app_name': 'musical_ly',
        'app_language': 'en',
        'language': 'en',
        'timezone_name': 'America/New_York',
        'timezone_offset': '-14400',
        'channel': 'googleplay',
        'ac': 'wifi',
        'mcc_mnc': '310260',
        'is_my_cn': '0',
        'aid': '1180',
        'ssmix': 'a',
        'as': 'a1qwert123',
        'cp': 'cbfhckdckkde1',
      });

      final http.Response res = await http.get(
        uri,
        headers: <String, String>{
          'User-Agent': _appUserAgent,
          'Accept': 'application/json',
        },
      ).timeout(_timeout);
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        lastError = 'api $host returned ${res.statusCode}';
        return null;
      }

      final Object? decoded =
          jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      if (decoded is! Map) return null;
      final Object? list = decoded['aweme_list'];
      if (list is! List || list.isEmpty) {
        lastError = 'api $host gave no post';
        return null;
      }

      // /feed/ can answer with unrelated posts when the id is unknown, so the
      // entry is matched by id rather than assumed to be the first one.
      Map<String, Object?>? detail;
      for (final Object? entry in list) {
        if (entry is! Map) continue;
        final Map<String, Object?> m = _asMap(entry);
        if ('${m['aweme_id']}' == id) {
          detail = m;
          break;
        }
      }
      if (detail == null) return null;

      final Object? imagePost = detail['image_post_info'];
      if (imagePost is! Map) {
        lastError = 'post has no photos (api)';
        return null;
      }
      final Object? images = imagePost['images'];
      if (images is! List || images.isEmpty) return null;

      final List<PhotoItem> parsed = <PhotoItem>[];
      for (final Object? entry in images) {
        if (entry is! Map) continue;
        // display_image is the clean one. owner_watermark_image and
        // user_watermark_image are the logo-burned versions — never read.
        final Object? display = entry['display_image'];
        if (display is! Map) continue;
        final List<String> urls = _urlList(display['url_list']);
        if (urls.isEmpty) continue;
        parsed.add(PhotoItem(
          candidates: _bestFirst(urls),
          width: _toInt(display['width']),
          height: _toInt(display['height']),
        ));
      }
      if (parsed.isEmpty) return null;

      final Object? author = detail['author'];
      return TikTokPhotoPost(
        images: parsed,
        title: detail['desc'] is String ? (detail['desc'] as String).trim() : null,
        author: (author is Map && author['unique_id'] is String)
            ? author['unique_id'] as String
            : null,
        source: 'api',
      );
    } catch (e) {
      lastError = 'api $host: $e';
      return null;
    }
  }

  static List<String> _urlList(Object? raw) {
    final List<String> out = <String>[];
    if (raw is List) {
      for (final Object? u in raw) {
        if (u is String && u.startsWith('http')) out.add(u);
      }
    }
    return out;
  }

  /// The numeric post id, which every TikTok URL form carries somewhere.
  static String? _awemeId(String url) {
    final RegExpMatch? m =
        RegExp(r'/(?:video|photo|v)/(\d{6,})').firstMatch(url);
    if (m != null) return m.group(1);
    final RegExpMatch? q = RegExp(r'[?&]item_id=(\d{6,})').firstMatch(url);
    if (q != null) return q.group(1);
    final RegExpMatch? bare = RegExp(r'/(\d{15,})').firstMatch(url);
    return bare?.group(1);
  }

  // ------------------------------------------------------------------ web

  static Future<TikTokPhotoPost?> _fromWeb(String url) async {
    try {
      final http.Response res = await http.get(
        Uri.parse(url),
        headers: <String, String>{
          'User-Agent': _webUserAgent,
          'Accept': 'text/html,application/xhtml+xml',
          'Accept-Language': 'en-US,en;q=0.9',
        },
      ).timeout(_timeout);
      if (res.statusCode != 200) {
        lastError = 'page returned ${res.statusCode}';
        return null;
      }
      return _parseWeb(utf8.decode(res.bodyBytes, allowMalformed: true));
    } catch (e) {
      lastError = 'page: $e';
      return null;
    }
  }

  /// vt.tiktok.com / vm.tiktok.com links redirect to the real post. The final
  /// URL is needed up front because the post id lives in it, and the API path
  /// is keyed on that id.
  static Future<String> _followShortLink(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return url;
    final String host = uri.host.toLowerCase();
    if (!host.startsWith('vt.') && !host.startsWith('vm.')) return url;
    final http.Client client = http.Client();
    try {
      final http.Request req = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['User-Agent'] = _webUserAgent;
      final http.StreamedResponse res =
          await client.send(req).timeout(_timeout);
      final String? location = res.headers['location'];
      // Drain so the connection can be reused rather than left hanging.
      await res.stream.drain<void>();
      if (location != null && location.startsWith('http')) return location;
    } catch (_) {
      // Some hosts reject this; the caller still has the original URL.
    } finally {
      client.close();
    }
    return url;
  }

  static TikTokPhotoPost? _parseWeb(String html) {
    final Map<String, Object?>? item =
        _itemFromUniversalData(html) ?? _itemFromSigiState(html);
    if (item == null) return null;

    final Object? imagePost = item['imagePost'];
    if (imagePost is! Map) return null;
    final Object? images = imagePost['images'];
    if (images is! List || images.isEmpty) return null;

    final List<PhotoItem> parsed = <PhotoItem>[];
    for (final Object? entry in images) {
      if (entry is! Map) continue;
      final Object? imageUrl = entry['imageURL'];
      final List<String> urls =
          imageUrl is Map ? _urlList(imageUrl['urlList']) : <String>[];
      if (urls.isEmpty) continue;
      parsed.add(PhotoItem(
        candidates: _bestFirst(urls),
        width: _toInt(entry['imageWidth']),
        height: _toInt(entry['imageHeight']),
      ));
    }
    if (parsed.isEmpty) return null;

    return TikTokPhotoPost(
      images: parsed,
      title: item['desc'] is String ? (item['desc'] as String).trim() : null,
      author: _author(item),
      source: 'web',
    );
  }

  /// Puts the least-processed URL first.
  ///
  /// TikTok's CDN encodes a resize recipe in the path as a `~tplv-...` token.
  /// A URL without one is the untouched original; among those that have one,
  /// the ones carrying an explicit large dimension beat the thumbnail recipes.
  /// Downloading the wrong one is exactly how a photo downloader ends up
  /// saving 300px previews.
  static List<String> _bestFirst(List<String> urls) {
    final List<String> sorted = List<String>.of(urls);
    sorted.sort((String a, String b) => _score(b).compareTo(_score(a)));
    return sorted;
  }

  static int _score(String url) {
    final String u = url.toLowerCase();
    int score = 0;
    if (!u.contains('~tplv-')) score += 100;
    if (u.contains('photomode-image')) score += 40;
    if (u.contains('origin')) score += 30;
    final RegExpMatch? m = RegExp(r'[~_](\d{3,4})x(\d{3,4})').firstMatch(u);
    if (m != null) score += (int.tryParse(m.group(1)!) ?? 0) ~/ 100;
    if (u.contains('tplv-obj')) score += 10;
    return score;
  }

  static Map<String, Object?>? _itemFromUniversalData(String html) {
    final Map<String, Object?>? root =
        _scriptJson(html, 'id="__UNIVERSAL_DATA_FOR_REHYDRATION__"');
    if (root == null) return null;
    final Object? scope = root['__DEFAULT_SCOPE__'];
    if (scope is! Map) return null;
    final Object? detail = scope['webapp.video-detail'];
    if (detail is! Map) return null;
    final Object? info = detail['itemInfo'];
    if (info is! Map) return null;
    final Object? struct = info['itemStruct'];
    return struct is Map ? _asMap(struct) : null;
  }

  static Map<String, Object?>? _itemFromSigiState(String html) {
    final Map<String, Object?>? root = _scriptJson(html, 'id="SIGI_STATE"');
    if (root == null) return null;
    final Object? module = root['ItemModule'];
    if (module is! Map || module.isEmpty) return null;
    final Object? first = module.values.first;
    return first is Map ? _asMap(first) : null;
  }

  /// Pulls the JSON body out of `<script ... marker ...>{ ... }</script>`.
  ///
  /// Written by hand rather than with a regex over the whole document: these
  /// blobs are hundreds of kilobytes and a greedy pattern across them is both
  /// slow and prone to running past the closing tag.
  static Map<String, Object?>? _scriptJson(String html, String marker) {
    final int at = html.indexOf(marker);
    if (at < 0) return null;
    final int open = html.indexOf('>', at);
    if (open < 0) return null;
    final int close = html.indexOf('</script>', open);
    if (close <= open) return null;
    final String body = html.substring(open + 1, close).trim();
    if (body.isEmpty || !body.startsWith('{')) return null;
    try {
      final Object? decoded = jsonDecode(body);
      return decoded is Map ? _asMap(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static String? _author(Map<String, Object?> item) {
    final Object? author = item['author'];
    if (author is Map) {
      final Object? unique = author['uniqueId'];
      if (unique is String && unique.isNotEmpty) return unique;
      final Object? nickname = author['nickname'];
      if (nickname is String && nickname.isNotEmpty) return nickname;
    }
    // SIGI_STATE stores the handle as a bare string.
    if (author is String && author.isNotEmpty) return author;
    return null;
  }

  static Map<String, Object?> _asMap(Map<Object?, Object?> raw) =>
      raw.map<String, Object?>(
        (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
      );

  static int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
