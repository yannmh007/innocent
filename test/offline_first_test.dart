// What the app knows when the network is gone.
//
// ══════════════════════════════════════════════════════════════════════════
// WHY THESE THREE THINGS ARE TESTED TOGETHER
// ══════════════════════════════════════════════════════════════════════════
//
// They are the three decisions that made the difference between an app that
// looks offline and an app that looks broken, and all three fail SILENTLY.
//
//   • `isUnreachableError` decides whether a failure may be answered from a
//     cache at all. Get it wrong in one direction and a 401 serves the
//     previous account's catalogue; wrong in the other and a phone in
//     aeroplane mode gets a retry button instead of its own library.
//
//   • `AccountSnapshot.decode` decides whether a premium download opens with
//     no connection. This is the only thing standing between a paying viewer
//     and a paywall on their own file — and between someone who signed in once
//     and a permanent free subscription, which is why every refusal below is
//     as important as every acceptance.
//
//   • `CatalogueCache.collectTitles` decides what offline search can find. A
//     still from a title's album carries an `id` too, and letting one through
//     puts a photo in a list of films.
//
// All three are pure, so every case here is exact. The parts that touch a
// filesystem or the Android Keystore are deliberately not faked: a test that
// mocks a plugin proves the mock works.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/api/account_snapshot.dart';
import 'package:innocent/features/video_hub/data/api/api_exception.dart';
import 'package:innocent/features/video_hub/data/cache/catalogue_cache.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_id.dart';
import 'package:innocent/features/video_hub/domain/access.dart';
import 'package:innocent/features/video_hub/domain/account.dart';

/// A snapshot as it would sit on disk, written [age] ago.
String stored({
  required bool premium,
  Duration age = Duration.zero,
  DateTime? expires,
  String id = 'user-1',
  int version = 1,
  String? plan = 'monthly',
  Object? expiresOverride,
  bool omitId = false,
  bool omitEntitlement = false,
}) {
  final at = DateTime.now().toUtc().subtract(age).millisecondsSinceEpoch;
  return jsonEncode(<String, dynamic>{
    'v': version,
    'at': at,
    'user': <String, dynamic>{
      if (!omitId) 'id': id,
      'method': 'phone',
      'phone': '+95912345678',
    },
    if (!omitEntitlement)
      'entitlement': <String, dynamic>{
        'premium': premium,
        if (expiresOverride != null)
          'expires': expiresOverride
        else if (expires != null)
          'expires': expires.toUtc().toIso8601String(),
        if (plan != null) 'plan': plan,
      },
  });
}

void main() {
  group('isUnreachableError', () {
    test('a dead network, a dead server and a rate limit may use the cache', () {
      expect(isUnreachableError(const ApiException(ApiErrorKind.network)), isTrue);
      expect(isUnreachableError(const ApiException(ApiErrorKind.server)), isTrue);
      expect(
        isUnreachableError(const ApiException(ApiErrorKind.tooManyRequests)),
        isTrue,
      );
      expect(isUnreachableError(const SocketException('no route')), isTrue);
      expect(isUnreachableError(TimeoutException('slow')), isTrue);
    });

    test('a refusal may NOT — this is the whole security line', () {
      // 401: the session is gone. Serving a remembered catalogue here would
      // show one account's listing after the server declined it.
      expect(
        isUnreachableError(const ApiException(ApiErrorKind.unauthenticated)),
        isFalse,
      );
      // 403 needs_premium: a lapsed subscriber. Falling back would keep them
      // premium for as long as they stayed lapsed.
      expect(
        isUnreachableError(const ApiException(ApiErrorKind.needsPremium)),
        isFalse,
      );
      expect(
        isUnreachableError(const ApiException(ApiErrorKind.forbidden)),
        isFalse,
      );
      expect(
        isUnreachableError(const ApiException(ApiErrorKind.notFound)),
        isFalse,
      );
    });

    test('something unrecognised is treated as an answer, not an outage', () {
      // The safe direction: an unknown throw must not unlock a cache.
      expect(isUnreachableError(ArgumentError('nonsense')), isFalse);
      expect(isUnreachableError(null), isFalse);
    });
  });

  group('AccountSnapshot: what an offline licence may say', () {
    test('a premium snapshot survives a round trip intact', () {
      final expires = DateTime.now().add(const Duration(days: 20));
      final encoded = AccountSnapshot.encode(
        const AuthUser(
          id: 'user-7',
          method: AuthMethod.google,
          email: 'a@b.c',
          displayName: 'A',
        ),
        Entitlement.premium(expiresAt: expires, planId: 'monthly'),
      );
      final back = AccountSnapshot.decode(jsonEncode(encoded),
          now: DateTime.now());
      expect(back, isNotNull);
      expect(back!.user.id, 'user-7');
      expect(back.user.method, AuthMethod.google);
      expect(back.user.displayName, 'A');
      expect(back.entitlement.isPremium, isTrue);
      expect(back.entitlement.isActive, isTrue);
      expect(back.entitlement.planId, 'monthly');
      // To the millisecond, because the expiry is what stops a snapshot
      // outliving the subscription it describes.
      expect(
        back.entitlement.expiresAt!.millisecondsSinceEpoch,
        expires.millisecondsSinceEpoch,
      );
    });

    test('a lifetime entitlement round-trips with no expiry', () {
      final encoded = AccountSnapshot.encode(
        const AuthUser(id: 'u', method: AuthMethod.phone),
        const Entitlement.premium(),
      );
      final back =
          AccountSnapshot.decode(jsonEncode(encoded), now: DateTime.now());
      expect(back!.entitlement.expiresAt, isNull);
      expect(back.entitlement.isActive, isTrue);
    });

    test('inside the grace window it stands', () {
      final back = AccountSnapshot.decode(
        stored(premium: true, age: AccountSnapshot.grace - const Duration(hours: 1)),
        now: DateTime.now(),
      );
      expect(back, isNotNull);
      expect(back!.entitlement.isActive, isTrue);
    });

    test('past the grace window it is refused', () {
      // Not "downgraded to free" — refused, so the caller reports nobody
      // signed in and the app asks the server again rather than running on a
      // month-old answer forever.
      final back = AccountSnapshot.decode(
        stored(premium: true, age: AccountSnapshot.grace + const Duration(hours: 1)),
        now: DateTime.now(),
      );
      expect(back, isNull);
    });

    test('a snapshot dated in the future is refused', () {
      // The device clock is the only thing this expiry can be measured
      // against, so winding it forward is the obvious attack on the grace
      // window. A file that claims to be from tomorrow is not trusted.
      final back = AccountSnapshot.decode(
        stored(premium: true, age: const Duration(days: -2)),
        now: DateTime.now(),
      );
      expect(back, isNull);
    });

    test('an expired subscription reads as inactive, not as premium', () {
      final back = AccountSnapshot.decode(
        stored(
          premium: true,
          expires: DateTime.now().subtract(const Duration(days: 1)),
        ),
        now: DateTime.now(),
      );
      expect(back, isNotNull);
      expect(back!.entitlement.isPremium, isTrue);
      // isActive is what every access decision goes through.
      expect(back.entitlement.isActive, isFalse);
    });

    test('a premium snapshot with an unreadable expiry is refused', () {
      // The dangerous case: `Entitlement.premium(expiresAt: null)` never
      // expires, so treating a corrupt date as absent would turn a one-month
      // subscription into a lifetime one.
      final back = AccountSnapshot.decode(
        stored(premium: true, expiresOverride: 'not-a-date'),
        now: DateTime.now(),
      );
      expect(back, isNull);
    });

    test('a snapshot from an older format is refused', () {
      expect(
        AccountSnapshot.decode(stored(premium: true, version: 99),
            now: DateTime.now()),
        isNull,
      );
    });

    test('no user id, no snapshot', () {
      // Everything downstream keys a subscription on the id.
      expect(
        AccountSnapshot.decode(stored(premium: true, omitId: true),
            now: DateTime.now()),
        isNull,
      );
    });

    test('a missing entitlement block is refused rather than read as free', () {
      expect(
        AccountSnapshot.decode(stored(premium: true, omitEntitlement: true),
            now: DateTime.now()),
        isNull,
      );
    });

    test('garbage is refused rather than thrown', () {
      for (final raw in <String>['', 'null', '[]', '{', 'not json']) {
        expect(AccountSnapshot.decode(raw, now: DateTime.now()), isNull,
            reason: raw);
      }
    });

    test('a free account is remembered as free', () {
      final back = AccountSnapshot.decode(
        stored(premium: false, plan: null),
        now: DateTime.now(),
      );
      expect(back, isNotNull);
      expect(back!.entitlement.isPremium, isFalse);
      expect(back.user.method, AuthMethod.phone);
    });
  });

  group('streamCacheCandidates: finding a cached film with no server to ask', () {
    test('every rung the encoder writes, and the original', () {
      // Seven, because `tool/transcode.sh` writes six rungs and 0 is the
      // master. A rung missing from this list is a film that cannot be found
      // offline at all.
      expect(kStreamCacheRungs, <int>[0, 360, 480, 720, 1080, 1440, 2160]);
      final ids = streamCacheCandidates(titleId: 't1');
      expect(ids.length, kStreamCacheRungs.length);
      // No duplicates: two rungs hashing to one id would mean one entry could
      // be found under two names and the cache would look inconsistent.
      expect(ids.toSet().length, ids.length);
    });

    test('a candidate list contains the id the player actually cached under', () {
      // THE POINT OF THE WHOLE LIST. Online the rung is known and
      // `streamCacheId` is called with it; offline nobody knows which it was,
      // so the id must be reachable by guessing. If these two ever stopped
      // agreeing, offline replay would find nothing while the bytes sat there.
      for (final h in kStreamCacheRungs) {
        expect(
          streamCacheCandidates(titleId: 'title-9'),
          contains(streamCacheId(titleId: 'title-9', height: h)),
          reason: '${h}p',
        );
      }
    });

    test('an album clip is not the main film', () {
      // A behind-the-scenes clip cached offline must not be offered as the
      // feature, and vice versa.
      final main = streamCacheCandidates(titleId: 't1');
      final clip = streamCacheCandidates(titleId: 't1', assetId: 'asset-4');
      expect(main.toSet().intersection(clip.toSet()), isEmpty);
    });

    test('two titles never share a candidate', () {
      final a = streamCacheCandidates(titleId: 'a').toSet();
      final b = streamCacheCandidates(titleId: 'b').toSet();
      expect(a.intersection(b), isEmpty);
    });

    test('the ids are stable across runs', () {
      // They name directories on disk. An id that changed between releases
      // would orphan every cached film on every phone at once.
      expect(
        streamCacheId(titleId: 'fixed-title', height: 720),
        streamCacheId(titleId: 'fixed-title', height: 720),
      );
      expect(streamCacheId(titleId: 'fixed-title', height: 720).length, 32);
    });
  });

  group('CatalogueCache.keyFor', () {
    test('the same question is one entry however the map is ordered', () {
      // Two entries for one question would mean the cache answers a screen
      // that happens to build its query in the other order with nothing.
      final a = CatalogueCache.keyFor('/rest/v1/titles', <String, dynamic>{
        'select': 'id,title',
        'category': 'eq.movie',
        'order': 'title.asc',
      });
      final b = CatalogueCache.keyFor('/rest/v1/titles', <String, dynamic>{
        'order': 'title.asc',
        'category': 'eq.movie',
        'select': 'id,title',
      });
      expect(a, b);
    });

    test('different arguments are different entries', () {
      expect(
        CatalogueCache.keyFor('/rest/v1/rpc/row_catalogue',
            <String, dynamic>{'row_key': 'trending'}),
        isNot(CatalogueCache.keyFor('/rest/v1/rpc/row_catalogue',
            <String, dynamic>{'row_key': 'new'})),
      );
    });

    test('no arguments is the bare path', () {
      expect(CatalogueCache.keyFor('/rest/v1/rpc/landing_rows'),
          '/rest/v1/rpc/landing_rows');
      expect(
        CatalogueCache.keyFor(
            '/rest/v1/rpc/landing_rows', const <String, dynamic>{}),
        '/rest/v1/rpc/landing_rows',
      );
    });
  });

  group('CatalogueCache.collectTitles: what offline search may find', () {
    Map<String, dynamic> title(String id) => <String, dynamic>{
          'id': id,
          'title': 'Film $id',
          'category': 'movie',
        };

    test('a flat list of rows', () {
      final found = <String, Map<String, dynamic>>{};
      CatalogueCache.collectTitles(
          <dynamic>[title('a'), title('b')], found, 100);
      expect(found.keys, <String>['a', 'b']);
    });

    test('rows nested inside the landing_rows envelope', () {
      // The reason this is shape-based rather than key-based: nothing here
      // knows what `landing_rows` returns, and it still finds the titles.
      final found = <String, Map<String, dynamic>>{};
      CatalogueCache.collectTitles(<dynamic>[
        <String, dynamic>{
          'key': 'trending',
          'title': 'Trending',
          'items': <dynamic>[title('a'), title('b')],
        },
        <String, dynamic>{
          'key': 'new',
          'title': 'New',
          'items': <dynamic>[title('c')],
        },
      ], found, 100);
      expect(found.keys.toList()..sort(), <String>['a', 'b', 'c']);
      // The ENVELOPE ITSELF has an id-less 'title', so it must not become a
      // search result called "Trending".
      expect(found.containsKey(''), isFalse);
    });

    test('an album still is not a film', () {
      // A `title_media` row carries an id and no category. Without that second
      // test a photo would appear in a list of films, and tapping it would ask
      // the server to play a still.
      final found = <String, Map<String, dynamic>>{};
      CatalogueCache.collectTitles(<dynamic>[
        <String, dynamic>{
          'id': 'photo-1',
          'kind': 'photo',
          'url': 'https://example/x.jpg',
        },
        title('a'),
      ], found, 100);
      expect(found.keys, <String>['a']);
    });

    test('the same title in two cached screens is one result', () {
      final found = <String, Map<String, dynamic>>{};
      CatalogueCache.collectTitles(<dynamic>[title('a')], found, 100);
      CatalogueCache.collectTitles(<dynamic>[title('a')], found, 100);
      expect(found.length, 1);
    });

    test('the cap is honoured', () {
      final found = <String, Map<String, dynamic>>{};
      CatalogueCache.collectTitles(
        List<dynamic>.generate(50, (i) => title('t$i')),
        found,
        10,
      );
      expect(found.length, lessThanOrEqualTo(10));
    });

    test('deep nesting terminates instead of recursing forever', () {
      // Built as a chain 40 levels deep. The depth bound is what stops a
      // malformed entry turning a search into a stack overflow inside a tap
      // handler.
      dynamic node = title('deep');
      for (var i = 0; i < 40; i++) {
        node = <String, dynamic>{'wrap': node};
      }
      final found = <String, Map<String, dynamic>>{};
      CatalogueCache.collectTitles(node, found, 100);
      // Past the bound it simply finds nothing, which is the right failure:
      // one unreachable title, not a crash.
      expect(found, isEmpty);
    });

    test('a null or scalar body is not an error', () {
      final found = <String, Map<String, dynamic>>{};
      CatalogueCache.collectTitles(null, found, 100);
      CatalogueCache.collectTitles(42, found, 100);
      CatalogueCache.collectTitles('text', found, 100);
      expect(found, isEmpty);
    });
  });
}
