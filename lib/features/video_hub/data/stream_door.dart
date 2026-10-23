import 'dart:io';

import 'package:flutter/foundation.dart';

import 'device_identity.dart';

/// How the app knocks on the stream Worker's door: which URLs are grants,
/// and the install id that goes with each fetch of one.
///
/// WHY. Since 1.64.70 the app asks for its grants with `bind: true`, and
/// request-playback seals the install's hash into every token. The Worker
/// then plays a token only for a request carrying that install's id in
/// [header] (docs/security_streaming.md, phase 1). A link copied off the
/// phone stops being a film anyone can open for ten minutes.
///
/// EVERY FETCH OF A GRANTED URL MUST CARRY IT — the stream proxy's lanes and
/// probe, the warm-up, the downloader's parts and copies, and the player if
/// it is ever handed the URL directly. One that forgets plays today (the
/// Worker only logs a missing header) and stops the day the check is
/// enforced. So the rule lives here, once, and each of those calls it.
///
/// ONLY TO THE WORKER. The id goes to the origins grants have pointed at
/// this run ([learn]), on the token path, and nowhere else: not to a poster
/// host, a Telegram file, a server on the local network. The origin is
/// learned rather than written down so that the day the Worker moves to a
/// domain of our own, no app release is needed.
class StreamDoor {
  StreamDoor._();

  static const String header = 'X-Innocent-Device';

  static final Set<String> _origins = <String>{};

  /// For tests, whose stand-in Worker is plain http on loopback. Never set
  /// in the app: the id is not sent over plain http.
  @visibleForTesting
  static bool allowPlainHttp = false;

  static bool _schemeOk(Uri u) =>
      u.scheme == 'https' || (allowPlainHttp && u.scheme == 'http');

  /// Remembers where a granted [url] points. Called for every URL a grant
  /// hands over, before anything fetches it.
  static void learn(String url) {
    final u = Uri.tryParse(url);
    if (u == null || !_schemeOk(u) || !_isTokenPath(u)) return;
    _origins.add(u.origin);
  }

  static bool _isTokenPath(Uri u) =>
      u.pathSegments.length == 2 && u.pathSegments.first == 'v';

  /// The headers a fetch of [url] needs: the install id for a granted URL,
  /// nothing for anything else, or before the id has been read.
  static Map<String, String> headersFor(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return const <String, String>{};
    return headersForUri(u);
  }

  static Map<String, String> headersForUri(Uri u) {
    final id = DeviceIdentity.current;
    if (id == null || id.isEmpty) return const <String, String>{};
    if (!_schemeOk(u) || !_isTokenPath(u)) return const <String, String>{};
    if (!_origins.contains(u.origin)) return const <String, String>{};
    return <String, String>{header: id};
  }

  /// [headersFor], set on a dart:io request.
  static void apply(HttpClientRequest req, Uri url) {
    headersForUri(url).forEach(req.headers.set);
  }

  /// For tests: forget every learned origin.
  @visibleForTesting
  static void reset() => _origins.clear();
}
