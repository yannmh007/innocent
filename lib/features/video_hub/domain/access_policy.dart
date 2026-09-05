import 'package:flutter/foundation.dart';

import 'access.dart';
import 'capability.dart';
import 'video_content.dart';
import 'viewer.dart';

/// EVERY free-tier rule, in one object.
///
/// This file exists so that changing what a free user gets is a one-line edit
/// in a place you can find six months from now — not a hunt through widgets
/// for scattered `if (isPremium)` checks. Nothing else in the feature is
/// allowed to decide what is locked; screens ask this.
///
/// The balance it encodes is the hard part of freemium, and the research is
/// blunt about both failure modes: too generous and nobody upgrades, too
/// restrictive and people leave before the app means anything to them. The
/// shape chosen here is a SOFT paywall — a real taste of each title, then a
/// clear, honest wall:
///
///   * poster, title, synopsis, rating, metadata — ALWAYS free. These are the
///     advertisement; hiding them hides the reason to pay.
///   * the first [freePhotoCount] stills of a premium title — free. Enough to
///     judge the title, not enough to replace it.
///   * anything marked [AlbumItem.isPreview] — free regardless of tier. This
///     is the trailer slot: one clip per title that the free user can actually
///     watch.
///   * everything else in a premium title — locked, shown but not opened.
///
/// Locked items are SHOWN rather than hidden. A free user who cannot see what
/// they are missing has no reason to pay; a free user looking at eleven
/// blurred stills and a lock has a very concrete one.
@immutable
class AccessPolicy {
  /// Whether locked items appear in the grid at all.
  ///
  /// True (show them) is the deliberate default; see the class note. Set false
  /// only if a jurisdiction or a partner requires locked content to be
  /// invisible rather than merely unopenable.
  final bool showLockedItems;

  const AccessPolicy({this.showLockedItems = true});

  /// The shipping configuration. Change these numbers, not the widgets.
  static const AccessPolicy standard = AccessPolicy();

  // ---- decisions -----------------------------------------------------------

  /// Can the viewer play this title's main video?
  ///
  /// UI ONLY. The authoritative answer comes from
  /// [ContentRepository.requestPlayback], because a client-side check protects
  /// nothing — it decides whether to draw a lock, not whether a stream is
  /// handed over.
  bool canPlayTitle(VideoContent content, ViewerTier tier) {
    if (content.accessTier == AccessTier.free) return true;
    return CapabilityMatrix.allows(tier, Capability.playPremiumVideo);
  }

  /// Whether the viewer may keep an offline copy.
  ///
  /// A premium subscriber's downloads are theirs and stay playable; that is
  /// what they bought. What must NOT happen is a free account acquiring the
  /// file at all - which is a server question, not a button-visibility one.
  bool canDownload(VideoContent content, ViewerTier tier) {
    if (content.accessTier == AccessTier.free) return true;
    return CapabilityMatrix.allows(tier, Capability.downloadOffline);
  }

  /// Can the viewer open this album item?
  ///
  /// [photoOrdinal] is the item's position among the title's PHOTOS (0-based),
  /// or -1 for a video. Callers get it from [photoOrdinalsOf] so the counting
  /// rule lives here too.
  bool canOpenItem({
    required VideoContent parent,
    required AlbumItem item,
    required int photoOrdinal,
    required ViewerTier tier,
  }) {
    if (parent.accessTier == AccessTier.free) return true;
    if (CapabilityMatrix.allows(tier, Capability.viewFullAlbum)) return true;
    // The trailer slot: an explicit taste of a paid title.
    if (item.isPreview) return true;
    if (item.isVideo) return false;
    return photoOrdinal >= 0 &&
        photoOrdinal < CapabilityMatrix.freePhotoCountFor(tier);
  }

  /// Photo ordinals for a title's album, indexed the same way as
  /// [VideoContent.items]. Videos get -1.
  ///
  /// Computed once per album instead of counting backwards inside a grid
  /// builder — an O(n^2) scan that also silently changes meaning the moment
  /// the grid is reordered.
  static List<int> photoOrdinalsOf(List<AlbumItem> items) {
    final out = List<int>.filled(items.length, -1);
    int photo = 0;
    for (int i = 0; i < items.length; i++) {
      if (!items[i].isVideo) {
        out[i] = photo;
        photo += 1;
      }
    }
    return out;
  }

  /// How many items in this album a free viewer cannot open. Drives the
  /// "unlock N more" line on the paywall, which converts far better than a
  /// generic pitch because it names what is actually being bought.
  int lockedCountFor(VideoContent content, ViewerTier tier) {
    if (tier.isPremium) return 0;
    if (content.accessTier == AccessTier.free) return 0;
    final ordinals = photoOrdinalsOf(content.items);
    var locked = 0;
    for (int i = 0; i < content.items.length; i++) {
      final ok = canOpenItem(
        parent: content,
        item: content.items[i],
        photoOrdinal: ordinals[i],
        tier: tier,
      );
      if (!ok) locked += 1;
    }
    return locked;
  }

  /// Should a "PREMIUM" marker be drawn on this title's poster?
  ///
  /// Only for viewers who do not already have it. Badging every card for a
  /// paying subscriber is noise about a decision they already made.
  bool showsPremiumBadge(VideoContent content, ViewerTier tier) =>
      content.accessTier == AccessTier.premium && !tier.isPremium;
}
