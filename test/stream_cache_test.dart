import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_id.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_store.dart';

CachePart part(int start, int length) =>
    CachePart(start: start, length: length, file: File('unused'));

CacheEntry entry(List<CachePart> parts, {int total = 1000}) => CacheEntry(
      id: 'x',
      total: total,
      label: 'A film',
      usedAt: DateTime(2026),
      parts: parts,
    );

void main() {
  group('CacheEntry', () {
    test('a position inside a run finds that run', () {
      final e = entry([part(0, 100), part(500, 100)]);
      expect(e.partAt(0)?.start, 0);
      expect(e.partAt(99)?.start, 0);
      expect(e.partAt(500)?.start, 500);
      expect(e.partAt(599)?.start, 500);
    });

    test('a position in a hole finds nothing, which is the whole point', () {
      // Bytes that were never written read back from a file as nothing at
      // all. If this ever returned a run for a hole, the player would be
      // handed silence and would have no way to tell.
      final e = entry([part(0, 100), part(500, 100)]);
      expect(e.partAt(100), isNull);
      expect(e.partAt(499), isNull);
      expect(e.partAt(600), isNull);
    });

    test('held bytes count the runs, not the span between them', () {
      // A cache holding two hundred bytes at either end of a film has not
      // used six hundred bytes of the viewer's storage, and a budget that
      // thought so would evict a cache that was never large.
      final e = entry([part(0, 100), part(500, 100)]);
      expect(e.heldBytes, 200);
    });

    test('the next run bounds how far ahead a fetch should read', () {
      // Reading past the start of something already held would spend the
      // viewer's data downloading a duplicate.
      final e = entry([part(0, 100), part(500, 100)]);
      expect(e.nextPartStart(100, 1000), 500);
      expect(e.nextPartStart(500, 1000), 1000);
      expect(e.nextPartStart(600, 1000), 1000);
    });

    test('ranges merge two runs that meet', () {
      final e = entry([part(0, 100), part(100, 100)]);
      expect(e.ranges.contiguousEndFrom(0), 200);
    });

    test('fraction is zero when the length is not known yet, never NaN', () {
      // A zero total is the normal state of a cold entry, and 0/0 rendered
      // into a progress bar is the kind of thing that crashes a list.
      expect(entry(<CachePart>[], total: 0).fraction, 0);
      expect(entry([part(0, 250)], total: 1000).fraction, 0.25);
    });

    test('fraction never exceeds one', () {
      expect(entry([part(0, 2000)], total: 1000).fraction, 1.0);
    });
  });

  group('streamCacheId', () {
    test('the same title, asset and rung give the same name every time', () {
      final a = streamCacheId(titleId: 't1', assetId: 'a1', height: 720);
      final b = streamCacheId(titleId: 't1', assetId: 'a1', height: 720);
      expect(a, b);
    });

    test('a different rung is a different file and a different name', () {
      // THE ONE THAT MATTERS. Two rungs are two different encodes; writing
      // both into one set of byte ranges does not produce a video.
      final a = streamCacheId(titleId: 't1', assetId: 'a1', height: 720);
      final b = streamCacheId(titleId: 't1', assetId: 'a1', height: 360);
      expect(a, isNot(b));
    });

    test('a clip and its title do not share a name', () {
      expect(streamCacheId(titleId: 't1', height: 720),
          isNot(streamCacheId(titleId: 't1', assetId: 'a1', height: 720)));
    });

    test('the name carries no title id anyone could read off a disk', () {
      // A directory listing of somebody's phone should not be a list of
      // what they have watched.
      final id = streamCacheId(titleId: 'my-secret-title', height: 720);
      expect(id.contains('my-secret-title'), isFalse);
      expect(id.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(id), isTrue);
    });
  });
}
