import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Serves a remote media URL to the local player, with headers attached.
///
/// WHY, after two attempts at the direct approach failed:
///
/// TikTok's CDN refuses a request for one of its own video addresses unless it
/// carries the Referer the page would have sent. The downloader sends it and
/// plays fine; the player sent nothing and failed. Twice now that was tackled
/// by handing the headers to the player — first keyed to an exact URL string,
/// then keyed to the host — and twice it still failed, which is the point at
/// which the approach itself is the problem rather than the details of it.
/// Whether the headers survive a route, a screen and two controllers, and
/// whether the player passes them on to its own network layer, are things this
/// code cannot see and therefore cannot fix.
///
/// So the headers stop travelling with the request and become the request. A
/// tiny server on the loopback address fetches the media itself — with the
/// Referer, the user agent, and anything else the site expects — and hands the
/// bytes to the player as an ordinary local URL that needs nothing special.
/// Whatever the player does or doesn't forward no longer matters, and the same
/// fix covers every site rather than the one that prompted it.
///
/// Range requests are forwarded and range responses passed straight back, so
/// seeking behaves exactly as it would without the proxy.
///
/// Bound to 127.0.0.1 only — nothing outside this phone can reach it — and it
/// serves only the handful of random tokens it has issued.
class StreamProxy {
  StreamProxy._();

  static final StreamProxy instance = StreamProxy._();

  static const int _maxEntries = 8;

  /// Headers a well-behaved client sets for itself; forwarding OUR copies of
  /// them would fight with what the player is asking for.
  static const Set<String> _clientOwned = <String>{
    'range',
    'host',
    'connection',
    'accept-encoding',
    'content-length',
  };

  /// Called with every streaming outcome worth recording.
  ///
  /// A hook rather than a direct call into the diagnostics log, because this
  /// file sits in core and the log belongs to the downloader feature; wiring
  /// it from the screen keeps the dependency pointing the way it should.
  static void Function(String stage, String message, {String? url})? onEvent;

  static void _note(String stage, String message, {String? url}) {
    try {
      onEvent?.call(stage, message, url: url);
    } catch (_) {
      // Diagnostics must never be able to break playback.
    }
  }

  /// Asks the site for the first two bytes, exactly as the player will.
  ///
  /// Returns the HTTP status, 0 if the request could not be made at all.
  /// This is deliberately the SAME code path the player's first request takes
  /// — headers, redirects and all — so a pass here means the real thing will
  /// pass too, and a failure here is the failure the player would have hit,
  /// caught while we can still do something about it.
  Future<int> check(
    String url,
    Map<String, String> headers, {
    bool withRange = true,
  }) async {
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..autoUncompress = false;
      final HttpClientRequest req =
          await client.openUrl('GET', Uri.parse(url));
      req.followRedirects = true;
      req.maxRedirects = 5;
      headers.forEach((String name, String value) {
        if (_clientOwned.contains(name.toLowerCase())) return;
        req.headers.set(name, value);
      });
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      // Some CDNs refuse a two-byte range while serving the full request
      // perfectly, so a refusal here is retried once without it below. Asking
      // for two bytes is only an optimisation; it is not worth a false verdict.
      if (withRange) req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
      final HttpClientResponse res =
          await req.close().timeout(const Duration(seconds: 12));
      final int status = res.statusCode;
      // Drain rather than abandon: two bytes, and leaving it hanging keeps a
      // socket alive for no reason.
      await res.drain<void>().timeout(
            const Duration(seconds: 5),
            onTimeout: () {},
          );
      // A refusal might be about the RANGE rather than about us. Ask once
      // more, plainly, before reporting a verdict — one extra round trip is
      // cheap next to telling somebody a working video cannot be played.
      if (status >= 400 && withRange) {
        final int plain = await check(url, headers, withRange: false);
        if (plain < 400) {
          _note('stream', 'range refused ($status) but plain GET $plain',
              url: url);
          return plain;
        }
      }
      return status;
    } catch (e) {
      _note('stream', 'check failed: $e', url: url);
      return 0;
    } finally {
      client?.close(force: true);
    }
  }

  HttpServer? _server;
  final Map<String, _Entry> _entries = <String, _Entry>{};
  final Random _random = Random.secure();

  /// True for an HLS or DASH address — a PLAYLIST of media rather than media.
  ///
  /// This distinction is the whole of the second streaming bug. Proxying a
  /// manifest works perfectly and helps nothing: the player fetches the
  /// manifest through us, reads a list of ABSOLUTE segment URLs pointing
  /// straight at the CDN, and then goes and fetches every one of those itself
  /// — bare, with no Referer and no user agent. The one request we secured was
  /// the only request that never needed securing.
  ///
  /// libmpv, by contrast, applies its `http-header-fields` to every request it
  /// makes, segments included. So for manifests the DIRECT url plus attached
  /// headers is not a fallback, it is the correct answer, and the proxy is the
  /// wrong tool. Progressive files are the opposite case and keep the proxy.
  static bool isManifest(String url) {
    final String path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    return path.endsWith('.m3u8') ||
        path.endsWith('.mpd') ||
        path.contains('.m3u8') ||
        path.contains('/manifest/');
  }

  /// Returns a local URL that plays [url], or [url] itself if the proxy
  /// cannot start. Failing open matters: a proxy that won't start must not
  /// become a player that won't play.
  Future<String> wrap(String url, Map<String, String> headers) async {
    if (headers.isEmpty) return url;
    // A manifest must reach the player unwrapped — see [isManifest].
    if (isManifest(url)) return url;
    try {
      final HttpServer server = await _ensureServer();
      final String token = _newToken();
      if (_entries.length >= _maxEntries) {
        _entries.remove(_entries.keys.first);
      }
      _entries[token] = _Entry(url, Map<String, String>.of(headers));
      return 'http://127.0.0.1:${server.port}/s/$token';
    } catch (_) {
      return url;
    }
  }

  String _newToken() {
    final List<int> bytes = List<int>.generate(12, (_) => _random.nextInt(256));
    return bytes
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<HttpServer> _ensureServer() async {
    final HttpServer? existing = _server;
    if (existing != null) return existing;
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: true);
    // The player opens and closes connections as it seeks; leaving them idle
    // for a while is cheaper than renegotiating each time.
    server.idleTimeout = const Duration(seconds: 30);
    server.autoCompress = false;
    _server = server;
    unawaited(_serve(server));
    return server;
  }

  Future<void> _serve(HttpServer server) async {
    await for (final HttpRequest request in server) {
      // Deliberately not awaited: one slow or stalled fetch must not hold up
      // the next range request the player makes.
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    HttpClient? client;
    try {
      final String path = request.uri.path;
      final _Entry? entry =
          path.startsWith('/s/') ? _entries[path.substring(3)] : null;
      if (entry == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..autoUncompress = false;
      final HttpClientRequest upstream =
          await client.openUrl(request.method, Uri.parse(entry.url));
      upstream.followRedirects = true;
      upstream.maxRedirects = 5;

      // What the site expects...
      entry.headers.forEach((String name, String value) {
        if (_clientOwned.contains(name.toLowerCase())) return;
        upstream.headers.set(name, value);
      });
      // ...plus what the player is actually asking for, Range above all.
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) upstream.headers.set(HttpHeaders.rangeHeader, range);

      // ASK FOR THE BYTES UNTOUCHED. This one line is a real bug fixed, not a
      // precaution: HttpClient advertises `Accept-Encoding: gzip` by default,
      // and because we deliberately set autoUncompress=false to pass bytes
      // through unchanged, a server that took it up on the offer would send us
      // a compressed body which we then forwarded WITHOUT its Content-Encoding
      // header — leaving the player to decode gzip as though it were video.
      // Demanding identity removes the whole class of problem rather than
      // patching one end of it.
      upstream.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

      final HttpClientResponse response =
          await upstream.close().timeout(const Duration(seconds: 20));
      if (response.statusCode >= 400) {
        // The player will render this as a bare "playback error". Say what it
        // actually was, once, where someone can read it.
        _note('stream', 'upstream ${response.statusCode}', url: entry.url);
      }
      request.response.statusCode = response.statusCode;
      // Copy the headers that describe the body. Getting Content-Range and
      // Accept-Ranges back to the player is what keeps seeking working.
      //
      // Content-Encoding is copied too, even though we now ask for identity:
      // a server is entitled to ignore that, and a body labelled wrongly is
      // worse than a body labelled unhelpfully.
      for (final String name in <String>[
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.lastModifiedHeader,
        HttpHeaders.contentEncodingHeader,
      ]) {
        final String? value = response.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }
      // Length is set through the PROPERTY, not the header map. dart:io keeps
      // its own notion of the body length and will happily contradict a header
      // written behind its back; a response whose declared length disagrees
      // with the bytes that follow is one a player is entitled to reject, and
      // it does. -1 means "chunked / unknown", which is a legitimate answer.
      request.response.contentLength =
          response.contentLength >= 0 ? response.contentLength : -1;
      await response.pipe(request.response);
    } catch (e) {
      _note('stream', 'proxy fetch failed: $e');
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {
        // The player hung up first; nothing to report to.
      }
    } finally {
      client?.close(force: false);
    }
  }

  /// Frees the port. Not required — the server is tiny and local — but useful
  /// when the downloader is closed for good.
  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    _entries.clear();
    try {
      await server?.close(force: true);
    } catch (_) {}
  }
}

class _Entry {
  _Entry(this.url, this.headers);

  final String url;
  final Map<String, String> headers;
}
