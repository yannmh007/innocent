import 'package:flutter/foundation.dart';

import 'viewer.dart';

/// A thing a viewer may be allowed to do.
///
/// Named capabilities rather than a single `isPremium` boolean, because the
/// tiers differ in SEVERAL ways and a boolean forces every one of those
/// questions to be re-derived at the call site. When "free users get 480p"
/// arrives, a boolean means hunting for every place quality is chosen; a
/// capability means one row in [CapabilityMatrix].
enum Capability {
  /// Browse the catalogue, read titles, posters, synopses. Everyone, always:
  /// this is the advertisement, and hiding it hides the reason to pay.
  browseCatalogue,

  /// Open the stills a premium title exposes as a taste.
  viewPreviewMedia,

  /// Keep a watchlist and have resume positions follow the account.
  ///
  /// The REGISTERED tier's reason to exist. Account-bound by nature - there is
  /// nowhere to sync an anonymous list to - so it costs nothing to give away
  /// and it turns "sign up" into an offer rather than a toll gate.
  saveToWatchlist,

  /// History and resume that survive a reinstall.
  syncHistory,

  /// Open every still and clip in a title.
  viewFullAlbum,

  /// Play a premium title's main video. THE paid line.
  playPremiumVideo,

  /// Keep a copy for offline viewing.
  downloadOffline,

  /// Streams above the free ceiling.
  highQuality,
}

/// What each tier is allowed to do.
///
/// THIS TABLE IS FOR DRAWING THE UI, NOT FOR GRANTING ANYTHING.
///
/// Read that twice. Every entry is a PREDICTION of what the server will say,
/// used to decide whether to draw a lock, dim a tile or show an Upgrade
/// button. It is not a decision. The server re-decides every one of these
/// against its own records, and if this table and the server disagree, the
/// server is right and the app is showing the wrong icon - a cosmetic bug, not
/// a breach.
///
/// That separation is the whole security model in one sentence: an attacker
/// who patches this file gets a nicer-looking free account.
///
/// THE LADDER is deliberate. Anonymous can look; registering buys a watchlist
/// and history that follow you; paying buys the video. Two steps, each with
/// something real behind it, because a single leap from "nothing" to "pay me"
/// converts far worse than a first step that costs the user nothing.
@immutable
class CapabilityMatrix {
  const CapabilityMatrix._();

  static const Set<Capability> _anonymous = <Capability>{
    Capability.browseCatalogue,
    Capability.viewPreviewMedia,
  };

  static const Set<Capability> _registered = <Capability>{
    Capability.browseCatalogue,
    Capability.viewPreviewMedia,
    Capability.saveToWatchlist,
    Capability.syncHistory,
  };

  static const Set<Capability> _premium = <Capability>{
    Capability.browseCatalogue,
    Capability.viewPreviewMedia,
    Capability.saveToWatchlist,
    Capability.syncHistory,
    Capability.viewFullAlbum,
    Capability.playPremiumVideo,
    Capability.downloadOffline,
    Capability.highQuality,
  };

  /// Stills a viewer may open inside a premium title, by tier.
  ///
  /// Registering earns two more. Small on purpose: enough to feel like the
  /// account did something, not enough to be a substitute for paying.
  static const Map<ViewerTier, int> freePhotoCount = <ViewerTier, int>{
    ViewerTier.anonymous: 3,
    ViewerTier.registered: 5,
    ViewerTier.premium: 1 << 30,
  };

  /// Quality ceiling in vertical pixels; 0 means the source.
  ///
  /// A ceiling rather than a block: a free viewer watching a preview at 480p
  /// still sees the film, and "your copy is worse" is a better upgrade
  /// argument than "you may not look". Enforced by which rendition the SERVER
  /// signs, never by a player setting.
  static const Map<ViewerTier, int> maxHeight = <ViewerTier, int>{
    ViewerTier.anonymous: 480,
    ViewerTier.registered: 480,
    ViewerTier.premium: 0,
  };

  /// How many devices may stream at once.
  ///
  /// The number that decides whether one subscription serves a group chat.
  /// Enforced SERVER-SIDE from the playback-grant log - a client-side count
  /// knows only about the streams that are not the problem.
  static const Map<ViewerTier, int> concurrentStreams = <ViewerTier, int>{
    ViewerTier.anonymous: 1,
    ViewerTier.registered: 1,
    ViewerTier.premium: 2,
  };

  static Set<Capability> forTier(ViewerTier tier) {
    switch (tier) {
      case ViewerTier.anonymous:
        return _anonymous;
      case ViewerTier.registered:
        return _registered;
      case ViewerTier.premium:
        return _premium;
    }
  }

  static bool allows(ViewerTier tier, Capability capability) =>
      forTier(tier).contains(capability);

  static int freePhotoCountFor(ViewerTier tier) =>
      freePhotoCount[tier] ?? 3;

  static int maxHeightFor(ViewerTier tier) => maxHeight[tier] ?? 480;

  static int concurrentStreamsFor(ViewerTier tier) =>
      concurrentStreams[tier] ?? 1;
}
