// Unit tests for the Video Hub's PURE logic — the decisions that have no
// widgets, no network and no device, and are therefore the only parts of the
// feature that can be tested without a running app.
//
// These four were chosen because each is quietly wrong-able: a boundary that
// reads correctly and rounds the wrong way, a tier table that drifts from the
// policy that consults it, a cache key that changes when it should not. None
// of them would fail loudly in review.

import 'package:flutter_test/flutter_test.dart';

import 'package:innocent/features/video_hub/domain/access.dart';
import 'package:innocent/features/video_hub/domain/access_policy.dart';
import 'package:innocent/features/video_hub/domain/capability.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/content_filters.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:innocent/features/video_hub/domain/viewer.dart';
import 'package:innocent/features/video_hub/presentation/widgets/view_count_badge.dart';

VideoContent _title({
  AccessTier tier = AccessTier.premium,
  List<AlbumItem> items = const <AlbumItem>[],
}) {
  return VideoContent(
    id: 't1',
    title: 'Test title',
    category: ContentCategory.movies,
    accessTier: tier,
    items: items,
  );
}

AlbumItem _photo(String id) =>
    AlbumItem(id: id, kind: MediaKind.photo, source: MediaRef.none);

AlbumItem _video(String id, {bool preview = false}) => AlbumItem(
      id: id,
      kind: MediaKind.video,
      source: MediaRef.none,
      isPreview: preview,
    );

void main() {
  group('ViewCount.compact', () {
    test('shows exact numbers below a thousand', () {
      expect(ViewCount.compact(0), '0');
      expect(ViewCount.compact(1), '1');
      expect(ViewCount.compact(999), '999');
    });

    test('switches to K at a thousand', () {
      expect(ViewCount.compact(1000), '1K');
      expect(ViewCount.compact(1234), '1.2K');
      expect(ViewCount.compact(9999), '9.9K');
    });

    test('drops the decimal once the integer part is two digits', () {
      // The decimal stops carrying information here and costs the two
      // characters that make a card label wrap.
      expect(ViewCount.compact(10000), '10K');
      expect(ViewCount.compact(12345), '12K');
      expect(ViewCount.compact(999999), '999K');
    });

    test('TRUNCATES rather than rounding at the boundary', () {
      // The one that matters: 999,999 must not read "1.0M" while the
      // catalogue still says it is under a million.
      expect(ViewCount.compact(999999), isNot(contains('M')));
      expect(ViewCount.compact(1000000), '1M');
      expect(ViewCount.compact(1200000), '1.2M');
    });

    test('never returns a negative label', () {
      expect(ViewCount.compact(-5), '0');
    });
  });

  group('CapabilityMatrix tiers', () {
    test('anonymous can browse and preview, nothing more', () {
      expect(
          CapabilityMatrix.allows(
              ViewerTier.anonymous, Capability.browseCatalogue),
          isTrue);
      expect(
          CapabilityMatrix.allows(
              ViewerTier.anonymous, Capability.viewPreviewMedia),
          isTrue);
      expect(
          CapabilityMatrix.allows(
              ViewerTier.anonymous, Capability.playPremiumVideo),
          isFalse);
      expect(
          CapabilityMatrix.allows(
              ViewerTier.anonymous, Capability.saveToWatchlist),
          isFalse);
    });

    test('registering buys the account-bound features and nothing paid', () {
      expect(
          CapabilityMatrix.allows(
              ViewerTier.registered, Capability.saveToWatchlist),
          isTrue);
      expect(
          CapabilityMatrix.allows(
              ViewerTier.registered, Capability.syncHistory),
          isTrue);
      expect(
          CapabilityMatrix.allows(
              ViewerTier.registered, Capability.playPremiumVideo),
          isFalse);
      expect(
          CapabilityMatrix.allows(
              ViewerTier.registered, Capability.downloadOffline),
          isFalse);
    });

    test('premium has every capability there is', () {
      for (final c in Capability.values) {
        expect(CapabilityMatrix.allows(ViewerTier.premium, c), isTrue,
            reason: 'premium should allow $c');
      }
    });

    test('free stills increase with the tier and never decrease', () {
      final anon = CapabilityMatrix.freePhotoCountFor(ViewerTier.anonymous);
      final reg = CapabilityMatrix.freePhotoCountFor(ViewerTier.registered);
      final prem = CapabilityMatrix.freePhotoCountFor(ViewerTier.premium);
      expect(reg, greaterThan(anon));
      expect(prem, greaterThan(reg));
    });

    test('tier order is meaningful, because atLeast() depends on it', () {
      expect(ViewerTier.premium.atLeast(ViewerTier.registered), isTrue);
      expect(ViewerTier.registered.atLeast(ViewerTier.registered), isTrue);
      expect(ViewerTier.anonymous.atLeast(ViewerTier.registered), isFalse);
    });
  });

  group('ViewerTier derivation', () {
    test('no account is anonymous even with a premium entitlement', () {
      // Defensive: an entitlement without an account is a state that should
      // not arise, and if it does the cheaper answer is the safe one.
      final tier = ViewerTierX.from(
        account: null,
        entitlement: const Entitlement.premium(),
      );
      expect(tier, ViewerTier.anonymous);
    });

    test('an EXPIRED subscription is registered, not premium', () {
      final expired = Entitlement.premium(
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(expired.isActive, isFalse);
      expect(ViewerTierX.fromEntitlement(expired), ViewerTier.registered);
    });

    test('a lifetime entitlement stays active', () {
      const lifetime = Entitlement.premium();
      expect(lifetime.isActive, isTrue);
    });
  });

  group('AccessPolicy', () {
    const policy = AccessPolicy.standard;

    test('a free title plays for anyone', () {
      final free = _title(tier: AccessTier.free);
      expect(policy.canPlayTitle(free, ViewerTier.anonymous), isTrue);
    });

    test('a premium title plays only for premium', () {
      final paid = _title();
      expect(policy.canPlayTitle(paid, ViewerTier.anonymous), isFalse);
      expect(policy.canPlayTitle(paid, ViewerTier.registered), isFalse);
      expect(policy.canPlayTitle(paid, ViewerTier.premium), isTrue);
    });

    test('photo ordinals count PHOTOS, ignoring interleaved clips', () {
      // The rule the free allowance depends on: "first 3 photos" must mean the
      // same thing however many clips are mixed in.
      final items = <AlbumItem>[
        _photo('p0'),
        _video('v0'),
        _photo('p1'),
        _photo('p2'),
      ];
      final ordinals = AccessPolicy.photoOrdinalsOf(items);
      expect(ordinals, <int>[0, -1, 1, 2]);
    });

    test('a marked preview clip opens for anyone', () {
      final item = _video('v0', preview: true);
      final parent = _title(items: <AlbumItem>[item]);
      expect(
        policy.canOpenItem(
          parent: parent,
          item: item,
          photoOrdinal: -1,
          tier: ViewerTier.anonymous,
        ),
        isTrue,
      );
    });

    test('an unmarked clip in a premium title does not', () {
      final item = _video('v1');
      final parent = _title(items: <AlbumItem>[item]);
      expect(
        policy.canOpenItem(
          parent: parent,
          item: item,
          photoOrdinal: -1,
          tier: ViewerTier.registered,
        ),
        isFalse,
      );
    });

    test('the free still allowance follows the tier', () {
      final items = List<AlbumItem>.generate(10, (i) => _photo('p$i'));
      final parent = _title(items: items);
      bool canOpen(int ordinal, ViewerTier tier) => policy.canOpenItem(
            parent: parent,
            item: items[ordinal],
            photoOrdinal: ordinal,
            tier: tier,
          );
      // Anonymous gets 3: indices 0..2 open, 3 does not.
      expect(canOpen(2, ViewerTier.anonymous), isTrue);
      expect(canOpen(3, ViewerTier.anonymous), isFalse);
      // Registered gets 5.
      expect(canOpen(4, ViewerTier.registered), isTrue);
      expect(canOpen(5, ViewerTier.registered), isFalse);
      // Premium gets all of them.
      expect(canOpen(9, ViewerTier.premium), isTrue);
    });

    test('lockedCountFor is zero for premium and for free titles', () {
      final items = List<AlbumItem>.generate(6, (i) => _photo('p$i'));
      expect(policy.lockedCountFor(_title(items: items), ViewerTier.premium), 0);
      expect(
        policy.lockedCountFor(
            _title(tier: AccessTier.free, items: items), ViewerTier.anonymous),
        0,
      );
    });

    test('lockedCountFor counts exactly what cannot be opened', () {
      final items = List<AlbumItem>.generate(6, (i) => _photo('p$i'));
      // Anonymous opens 3 of 6, so 3 are locked.
      expect(
        policy.lockedCountFor(_title(items: items), ViewerTier.anonymous),
        3,
      );
    });

    test('the premium badge is hidden from viewers who already pay', () {
      final paid = _title();
      expect(policy.showsPremiumBadge(paid, ViewerTier.anonymous), isTrue);
      expect(policy.showsPremiumBadge(paid, ViewerTier.premium), isFalse);
    });
  });

  group('ContentFilters.signature', () {
    test('is stable regardless of the order genres were added', () {
      // Load-bearing: the signature is a paging cache key, so {A,B} and {B,A}
      // must not fetch twice.
      const base = ContentFilters();
      final ab = base.toggleGenre('Action').toggleGenre('Drama');
      final ba = base.toggleGenre('Drama').toggleGenre('Action');
      expect(ab.signature, ba.signature);
    });

    test('changes when any filter changes', () {
      const base = ContentFilters();
      expect(base.copyWith(year: 2024).signature, isNot(base.signature));
      expect(base.copyWith(quality: '4K').signature, isNot(base.signature));
      expect(base.toggleGenre('Action').signature, isNot(base.signature));
      expect(base.copyWith(sort: ContentSort.titleAsc).signature,
          isNot(base.signature));
    });

    test('toggling a genre twice returns to the original signature', () {
      const base = ContentFilters();
      final twice = base.toggleGenre('Action').toggleGenre('Action');
      expect(twice.signature, base.signature);
      expect(twice.genres, isEmpty);
    });

    test('activeCount ignores sort, so Clear is not offered for nothing', () {
      const sorted = ContentFilters(sort: ContentSort.titleAsc);
      expect(sorted.activeCount, 0);
      expect(sorted.isEmpty, isTrue);
    });

    test('cleared() keeps the sort but drops every filter', () {
      final filters = const ContentFilters(sort: ContentSort.titleAsc)
          .toggleGenre('Action')
          .copyWith(year: 2024);
      final cleared = filters.cleared();
      expect(cleared.isEmpty, isTrue);
      expect(cleared.sort, ContentSort.titleAsc);
    });
  });

  // Added v1.63.5 with AccessDenial.wrongDevice. The refusal reasons are the
  // one place in this feature where collapsing two values costs money: a
  // device conflict shown as "unavailable" tells a paying customer to come
  // back later, and shown as "needs premium" tells them to pay twice.
  group('PlaybackGrant refusals', () {
    test('every refusal is ungranted and carries no URL', () {
      for (final reason in AccessDenial.values) {
        final grant = PlaybackGrant.denied(reason);
        expect(grant.isGranted, isFalse, reason: reason.name);
        expect(grant.url, isNull, reason: reason.name);
        expect(grant.denial, reason);
      }
    });

    test('the three reasons stay distinct', () {
      // A guard, not a tautology: this fails the moment someone deletes a
      // value or aliases two of them, which is exactly how wrongDevice would
      // quietly become unavailable again.
      expect(AccessDenial.values.length, 3);
      expect(AccessDenial.values.toSet().length, 3);
      expect(AccessDenial.needsPremium == AccessDenial.wrongDevice, isFalse);
      expect(AccessDenial.wrongDevice == AccessDenial.unavailable, isFalse);
    });

    test('a granted URL is granted even when the device clock says expired',
        () {
      // The device clock is not evidence; the CDN checks the signature. A
      // phone whose battery went flat must not refuse a URL minted a second
      // ago.
      final grant = PlaybackGrant.granted(
        'https://example.invalid/signed',
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(grant.isGranted, isTrue);
      expect(grant.isExpired, isTrue);
    });
  });
}
