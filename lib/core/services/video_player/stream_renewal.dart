import 'package:flutter/foundation.dart';

/// Produces a FRESH playable URL for a stream whose current one has died.
///
/// Returns null when no replacement can be had — the caller must then fail,
/// never fall back to the dead URL.
typedef StreamRenewer = Future<String?> Function();

/// Lets the player recover from an EXPIRED URL instead of retrying a dead one.
///
/// ─── WHY THIS EXISTS ─────────────────────────────────────────────────────
///
/// Premium playback is handed a short-lived signed URL. That is the whole
/// protection: a link that dies in minutes cannot be shared, posted or
/// scraped. But a signed URL is not a file path, and the player was written
/// for file paths — so both of its recovery routes reopened the SAME string:
///
///   * the automatic reconnect after a network error, and
///   * the Retry button on the error card.
///
/// Neither can work once the signature has expired, and libmpv re-issues an
/// HTTP request whenever a seek lands outside the buffer, so a film longer
/// than the URL's lifetime would simply stop being playable part of the way
/// through — with a "check your connection" message blaming the network for
/// something the network did not do.
///
/// ─── WHY IT IS A REGISTRY AND NOT A PARAMETER ────────────────────────────
///
/// The rule the Video Hub is built on is that ONE file interprets a
/// `PlaybackGrant`. Threading a grant down through the route, the player
/// screen, the provider and two controllers would put that decision in five
/// more places and quietly end the guarantee.
///
/// So the player never sees a grant. It sees a closure that answers "give me
/// a URL for what is playing", registered by the same function that opened the
/// player in the first place. The feature keeps every rule about entitlement;
/// core keeps a five-line interface it can call when a stream dies.
///
/// A renewal is a NEW request, so the server re-decides entitlement, expiry
/// and the concurrency cap exactly as it did the first time. A viewer whose
/// subscription lapsed mid-film gets a refusal, not an extension.
class StreamRenewal {
  StreamRenewal._();

  static String? _uri;
  static StreamRenewer? _renewer;
  static DateTime? _at;

  /// How long a registration stays valid.
  ///
  /// Generous, because it has to outlive the film: this is the window in which
  /// a stream may need replacing, not the window in which playback starts.
  /// Bounded all the same so a closure cannot be held for the life of the
  /// process after the user has moved on.
  static const Duration _window = Duration(hours: 6);

  /// Register [renewer] as the way to get a fresh URL for [uri].
  ///
  /// Exactly one registration exists at a time: the app has one video player,
  /// and a second registration means a second video was opened, at which point
  /// the first is no longer anything's business.
  static void register(String uri, StreamRenewer renewer) {
    _uri = uri;
    _renewer = renewer;
    _at = DateTime.now();
  }

  /// Forget the current registration. Called when playback of an unrelated
  /// file begins, so a renewer can never be applied to the wrong stream.
  static void clear() {
    _uri = null;
    _renewer = null;
    _at = null;
  }

  /// True when [uri] is a stream this class can replace. Cheap enough to call
  /// on an error path.
  static bool canRenew(String uri) {
    final at = _at;
    if (_renewer == null || _uri != uri || at == null) return false;
    return DateTime.now().difference(at) <= _window;
  }

  /// Ask for a fresh URL for [uri], or null.
  ///
  /// Never throws: a failed renewal is a failed playback attempt, and the
  /// caller already has an error path for that.
  static Future<String?> renew(String uri) async {
    if (!canRenew(uri)) return null;
    final renewer = _renewer;
    if (renewer == null) return null;
    try {
      final fresh = await renewer();
      if (fresh == null || fresh.isEmpty) return null;
      // The registration now describes the NEW url, or a second failure would
      // look up a key that no longer matches.
      _uri = fresh;
      _at = DateTime.now();
      return fresh;
    } catch (e) {
      if (kDebugMode) debugPrint('StreamRenewal.renew: $e');
      return null;
    }
  }
}
