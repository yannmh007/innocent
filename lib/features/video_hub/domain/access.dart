import 'rendition.dart';
import 'package:flutter/foundation.dart';

/// What a piece of content REQUIRES of the viewer.
///
/// A property of the content, set in the catalogue — never computed in the UI.
/// Which titles are free is an editorial and commercial decision that changes
/// weekly; if it lives in code, changing it means shipping a build.
enum AccessTier {
  /// Anyone can watch. The taster catalogue.
  free,

  /// Requires an active entitlement.
  premium,
}

extension AccessTierX on AccessTier {
  String get id => this == AccessTier.free ? 'free' : 'premium';

  static AccessTier fromId(String? id) =>
      id == 'premium' ? AccessTier.premium : AccessTier.free;

  bool get isPremium => this == AccessTier.premium;
}

/// What the viewer currently HAS.
///
/// Deliberately not a bare bool. An entitlement has an expiry, and code that
/// models it as `isPremium` alone ends up scattering "…and is it still valid?"
/// checks across the app, one of which is eventually forgotten.
@immutable
class Entitlement {
  final bool isPremium;

  /// Null for a lifetime entitlement, or when nothing is owned.
  final DateTime? expiresAt;

  /// Free-form plan identifier, shown in Settings and used for restore.
  final String? planId;

  const Entitlement.free()
      : isPremium = false,
        expiresAt = null,
        planId = null;

  const Entitlement.premium({this.expiresAt, this.planId}) : isPremium = true;

  /// True only if premium AND not expired. Every access decision must go
  /// through this rather than reading [isPremium] directly.
  bool get isActive {
    if (!isPremium) return false;
    final until = expiresAt;
    if (until == null) return true;
    return DateTime.now().isBefore(until);
  }

  @override
  bool operator ==(Object other) =>
      other is Entitlement &&
      other.isPremium == isPremium &&
      other.expiresAt == expiresAt &&
      other.planId == planId;

  @override
  int get hashCode => Object.hash(isPremium, expiresAt, planId);
}

/// Why something was refused.
///
/// A refusal is not an error and must not be shown as one. "You need premium"
/// and "this file is missing" call for completely different screens, and a
/// single null return value cannot tell them apart — which is exactly how a
/// paywall ends up rendered as "something went wrong".
enum AccessDenial {
  /// The viewer needs an entitlement. Show the paywall.
  needsPremium,

  /// The subscription is real and active, but THIS DEVICE is not one it
  /// covers - the device slots are full, or the grant was bound elsewhere.
  ///
  /// Its own value, not a flavour of [unavailable], because the two call for
  /// opposite reactions. "Unavailable" tells someone to come back later, which
  /// is useless advice to a paying customer holding a replacement phone: they
  /// will wait, then ask for a refund. This one has an action behind it - free
  /// a slot - and the message can say so.
  ///
  /// It is deliberately NOT a flavour of [needsPremium] either. Showing the
  /// paywall to someone who has already paid is the worst of the three
  /// mistakes: it reads as being charged twice.
  wrongDevice,

  /// The server could not be REACHED — no connection, a timeout, a 5xx. Not a
  /// refusal at all.
  ///
  /// Its own value, and the reason is the whole offline programme. Everything
  /// that fails is otherwise [unavailable], which mixes "we could not ask" in
  /// with "the answer was no for a reason we did not recognise" — a region
  /// block, a banned account. That mixture cannot be acted on: the phone holds
  /// bytes of this film already, paid for and already authorised once, and
  /// playing them is exactly right when nobody could be asked and exactly
  /// wrong when somebody said no.
  ///
  /// So the caller may offer what is already on disk for THIS value and must
  /// not for [unavailable]. See `OfflineReplay`.
  offline,

  /// No provider could serve this. Show the unavailable message.
  unavailable,
}

/// The answer to "can this be played, and with what URL?".
///
/// Returned by the repository rather than decided in the UI. That is the whole
/// point: today a bundled repository answers from a local flag; tomorrow an
/// API adapter answers from the SERVER, which is the only answer that actually
/// enforces anything. Neither the widgets nor the player change.
@immutable
class PlaybackGrant {
  final String? url;
  final AccessDenial? denial;

  /// When the URL stops working.
  ///
  /// Short-lived signed URLs are the single highest-value protection available
  /// without DRM: a link that dies in minutes cannot be shared, posted or
  /// scraped in bulk, and the whole "copy the MP4 address" attack disappears.
  /// Null only for sources that cannot express expiry.
  ///
  /// The client's obligation is simple and absolute: NEVER persist this URL,
  /// and request a fresh one on every playback. A cached URL defeats the
  /// mechanism entirely.
  final DateTime? expiresAt;

  /// Every copy of this video the server has, cheapest first.
  ///
  /// EMPTY IS THE NORMAL CASE and always will be for anything uploaded
  /// before the transcoding pipeline existed. The caller reads empty as
  /// "there is one copy and [url] is it", which is exactly what the app did
  /// before any of this — so an old server, a failed lookup and an
  /// un-transcoded file all behave identically and correctly.
  final List<Rendition> renditions;

  const PlaybackGrant.granted(String this.url,
      {this.expiresAt, this.renditions = const <Rendition>[]})
      : denial = null;

  const PlaybackGrant.denied(AccessDenial this.denial)
      : url = null,
        expiresAt = null,
        renditions = const <Rendition>[];

  /// A grant is granted when the server handed over a URL. Full stop.
  ///
  /// THIS DELIBERATELY DOES NOT CONSULT [isExpired] any more.
  ///
  /// The device clock is not evidence. A phone whose time is wrong — common
  /// enough on mid-range handsets, and guaranteed on one whose battery has
  /// been flat — would read a URL minted one second ago as long expired and
  /// refuse to play it, showing "unavailable" to someone who has paid. The
  /// same happens if the server ever returns a timestamp without a timezone.
  ///
  /// Nothing is given away by trying: the signature is checked by the SERVER,
  /// which has the only clock that counts. A genuinely expired URL is refused
  /// at the CDN, the player reports the failure, and [StreamRenewal] asks for
  /// a fresh one — a path that has to exist regardless, because a link can
  /// expire mid-film. So the honest failure mode is "attempt and be told no",
  /// not "refuse locally and be unable to say why".
  bool get isGranted => url != null && url!.isNotEmpty;

  /// Whether this URL is PROBABLY past its signature, by the device's clock.
  ///
  /// Advisory only — used to decide whether to ask for a fresh URL BEFORE
  /// opening, never whether playback is permitted. The tolerance absorbs
  /// ordinary clock drift; it is not a security margin, because this is not a
  /// security check.
  bool get isExpired {
    final t = expiresAt;
    if (t == null) return false;
    return DateTime.now().subtract(_clockSkewTolerance).isAfter(t);
  }

  static const Duration _clockSkewTolerance = Duration(minutes: 5);
}
