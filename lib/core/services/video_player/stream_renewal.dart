import 'package:flutter/foundation.dart';

/// Produces a FRESH playable URL for a stream whose current one has died —
/// or, with [belowKbps], a SMALLER copy of the same video.
///
/// THE SECOND USE IS WHY THIS TAKES AN ARGUMENT AT ALL. A stream the player
/// has measured as too heavy for the connection cannot be fixed by fetching
/// the same thing again; it needs a different rung of the ladder, and the
/// only place that knows what rungs exist is the feature that interpreted
/// the grant. `belowKbps` is the bitrate of the copy that FAILED, so the
/// answer is "anything cheaper than this".
///
/// Returns null when no replacement can be had — the caller must then fail,
/// never fall back to the dead URL.
///
/// [quality] is the viewer's own choice from the player's Quality menu — an
/// id from [QualityMenu.options] — and asks for exactly that copy. It wins
/// over [belowKbps]; the two are never sent together.
typedef StreamRenewer = Future<String?> Function({int? belowKbps, String? quality});

/// One line of the player's Quality menu.
///
/// THE IDS ARE THE FEATURE'S, NOT THE PLAYER'S. The player shows [label] and
/// hands [id] back unread; what "720" or "original" means is decided by the
/// code that registered the menu, which is the only code that has seen the
/// ladder.
@immutable
class QualityOption {
  const QualityOption({required this.id, required this.label, this.detail});

  /// 'auto', 'original', or a height such as '720'.
  final String id;

  /// What the menu shows: 'Auto', '1080p', 'Original'.
  final String label;

  /// A second, quieter line: '2.5 Mbps', '4K · 61 Mbps'.
  final String? detail;
}

/// What the Quality menu offers for the stream that is playing, and which
/// of it the viewer chose.
@immutable
class QualityMenu {
  const QualityMenu({
    required this.uri,
    required this.options,
    required this.selected,
    this.playing,
  });

  /// The stream this menu belongs to. A menu for a different address is not
  /// shown — the viewer has moved on.
  final String uri;
  final List<QualityOption> options;

  /// The viewer's choice: an option id.
  final String selected;

  /// What is actually on screen when [selected] is 'auto' — '720p' — so the
  /// menu can say "Auto (720p)" the way YouTube does.
  final String? playing;

  /// True when the viewer pinned a copy, so the player must not step it down
  /// by itself on a stall: they asked for this one.
  bool get pinned => selected != 'auto';

  QualityMenu copyWith({String? uri, String? selected, String? playing}) => QualityMenu(
        uri: uri ?? this.uri,
        options: options,
        selected: selected ?? this.selected,
        playing: playing ?? this.playing,
      );
}

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
  static void register(String uri, StreamRenewer renewer, {QualityMenu? menu}) {
    _uri = uri;
    _renewer = renewer;
    _at = DateTime.now();
    quality.value = menu;
  }

  /// The Quality menu for what is playing, or null when there is nothing to
  /// choose between (a local file, a title with no streaming copies, an
  /// offline download). The player's top bar listens to this.
  static final ValueNotifier<QualityMenu?> quality = ValueNotifier<QualityMenu?>(null);

  /// The viewer's choice for the current stream, or 'auto' when there is no
  /// menu at all.
  static bool get qualityPinned => quality.value?.pinned ?? false;

  /// Forget the current registration. Called when playback of an unrelated
  /// file begins, so a renewer can never be applied to the wrong stream.
  static void clear() {
    _uri = null;
    _renewer = null;
    _at = null;
    quality.value = null;
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
  /// [belowKbps] asks for a copy cheaper than that bitrate, for the case
  /// where the current one is not dead but is too heavy for the connection.
  /// Omitted, this is the original behaviour: the best copy available.
  static Future<String?> renew(String uri, {int? belowKbps, String? quality}) async {
    if (!canRenew(uri)) return null;
    final renewer = _renewer;
    if (renewer == null) return null;
    try {
      final fresh = await renewer(belowKbps: belowKbps, quality: quality);
      if (fresh == null || fresh.isEmpty) return null;
      // The registration now describes the NEW url, or a second failure would
      // look up a key that no longer matches.
      _uri = fresh;
      _at = DateTime.now();
      // And so does the menu, or it would disappear the moment the stream
      // it belongs to was renewed.
      final menu = StreamRenewal.quality.value;
      if (menu != null && menu.uri == uri) {
        StreamRenewal.quality.value = menu.copyWith(uri: fresh);
      }
      return fresh;
    } catch (e) {
      if (kDebugMode) debugPrint('StreamRenewal.renew: $e');
      return null;
    }
  }
}
