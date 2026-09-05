import 'package:flutter/foundation.dart';

import 'access.dart';
import 'account.dart';

/// Who is looking at the app.
///
/// THREE tiers, not a pair of booleans. `isSignedIn && entitlement.isActive`
/// spread across a dozen widgets is how a product ends up treating a
/// registered free user as anonymous in one screen and as premium in another;
/// one ordered value cannot disagree with itself.
///
/// The order is meaningful and load-bearing - [premium] > [registered] >
/// [anonymous] - so "at least registered" is a comparison rather than a
/// hand-written pair of conditions.
enum ViewerTier {
  /// No account. Still a REAL viewer with a stable id, because their taps are
  /// worth counting and they are the population most likely to become paying
  /// ones.
  anonymous,

  /// Signed in, not paying.
  registered,

  /// Signed in, active subscription.
  premium,
}

extension ViewerTierX on ViewerTier {
  String get id {
    switch (this) {
      case ViewerTier.anonymous:
        return 'anonymous';
      case ViewerTier.registered:
        return 'registered';
      case ViewerTier.premium:
        return 'premium';
    }
  }

  bool get isSignedIn => this != ViewerTier.anonymous;
  bool get isPremium => this == ViewerTier.premium;

  /// True when this tier is at least [floor]. Uses the declaration order, so
  /// inserting a tier in the middle later re-bases every check at once.
  bool atLeast(ViewerTier floor) => index >= floor.index;

  /// The only place a tier is derived. Two inputs, one answer.
  static ViewerTier from({
    required AuthUser? account,
    required Entitlement entitlement,
  }) {
    if (account == null) return ViewerTier.anonymous;
    // `isActive`, not `isPremium`: an expired subscription is a registered
    // user, and treating it as premium is how a lapsed account keeps watching.
    return entitlement.isActive ? ViewerTier.premium : ViewerTier.registered;
  }

  /// For code that only has an entitlement - notably a repository deciding
  /// playback, where "anonymous or registered" makes no difference because
  /// both are refused.
  static ViewerTier fromEntitlement(Entitlement entitlement) =>
      entitlement.isActive ? ViewerTier.premium : ViewerTier.registered;
}

/// The viewer, resolved.
///
/// Carries the id that events are attributed to, which is the point of the
/// whole model: an anonymous viewer's taps have to land somewhere, or the only
/// numbers the product ever sees are from people who already signed up - the
/// smallest and least interesting slice of the audience.
@immutable
class Viewer {
  final ViewerTier tier;

  /// The account, once there is one.
  final AuthUser? account;

  final Entitlement entitlement;

  /// Stable per-install id from [DeviceIdentity].
  ///
  /// TWO ROLES, one value, deliberately:
  ///
  ///   * before sign-in it IS the viewer - the thing anonymous views attribute
  ///     to, since there is nothing else to attribute them to;
  ///   * after sign-in it identifies the DEVICE, for the concurrency cap.
  ///
  /// A second id for the second role would have to be kept in step with the
  /// first, and on one phone they are the same thing anyway.
  final String installId;

  const Viewer({
    required this.tier,
    required this.entitlement,
    required this.installId,
    this.account,
  });

  /// Before anything has loaded. Assumes the LOWEST tier: a premium surface
  /// must never flash on screen during a cold start for someone who turns out
  /// to be anonymous.
  const Viewer.unknown()
      : tier = ViewerTier.anonymous,
        account = null,
        entitlement = const Entitlement.free(),
        installId = '';

  /// What events are attributed to.
  ///
  /// The ACCOUNT id once there is one, so a person's history stays theirs
  /// across a reinstall. Falls back to the install id while anonymous - which
  /// is exactly why sign-in has to hand the old install id to the server, so
  /// what they watched before registering is not orphaned.
  String get attributionId => account?.id ?? installId;

  bool get isSignedIn => tier.isSignedIn;
  bool get isPremium => tier.isPremium;

  @override
  bool operator ==(Object other) =>
      other is Viewer &&
      other.tier == tier &&
      other.account == account &&
      other.entitlement == entitlement &&
      other.installId == installId;

  @override
  int get hashCode => Object.hash(tier, account, entitlement, installId);
}
