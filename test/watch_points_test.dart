import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/watch_state_store.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:innocent/features/video_hub/presentation/continue_row.dart';

final _t0 = DateTime.utc(2026, 10, 5, 12);

WatchPoint _p(String t, int pos, int dur,
        {int minutes = 0, String? asset, bool finished = false}) =>
    WatchPoint(
      titleId: t,
      assetId: asset,
      positionS: pos,
      durationS: dur,
      at: _t0.add(Duration(minutes: minutes)),
      finished: finished,
    );

VideoContent _card(String id) => VideoContent(
      id: id,
      title: 'T$id',
      category: ContentCategory.movies,
      source: MediaRef(provider: 'server', locator: id),
    );

ContentRow _row(String key, List<String> ids,
        {Map<String, ResumeHint> resume = const {}}) =>
    ContentRow(
      key: key,
      fallbackTitle: key,
      items: [for (final i in ids) _card(i)],
      resume: resume,
    );

void main() {
  group('WatchPoint.resumable', () {
    test('past the opening, before the credits, not finished', () {
      expect(_p('a', 600, 3600).resumable, isTrue);
      expect(_p('a', 20, 3600).resumable, isFalse, reason: 'the first 30 s');
      expect(_p('a', 3590, 3600).resumable, isFalse, reason: 'the last 30 s');
      expect(_p('a', 600, 3600, finished: true).resumable, isFalse);
      expect(_p('a', 600, 0).resumable, isTrue, reason: 'length unknown');
    });
  });

  group('WatchLedger', () {
    test('the newer point wins, by clip', () {
      var l = WatchLedger.empty.record(_p('a', 600, 3600, minutes: 5));
      l = l.record(_p('a', 300, 3600, minutes: 1)); // older: ignored
      expect(l.pointFor('a', null)!.positionS, 600);
      l = l.record(_p('a', 50, 900, minutes: 9, asset: 'clip'));
      expect(l.pointFor('a', 'clip')!.positionS, 50);
      expect(l.latestFor('a')!.assetId, 'clip');
    });

    test('server merge keeps what is newer on either side', () {
      final l = WatchLedger.empty
          .record(_p('a', 600, 3600, minutes: 5))
          .merge([_p('a', 100, 3600, minutes: 1), _p('b', 400, 3600, minutes: 2)]);
      expect(l.pointFor('a', null)!.positionS, 600);
      expect(l.pointFor('b', null)!.positionS, 400);
    });

    test('Continue watching: one per title, newest first, hidden left out', () {
      final l = WatchLedger.empty
          .record(_p('a', 600, 3600, minutes: 1))
          .record(_p('b', 600, 3600, minutes: 3))
          .record(_p('c', 3599, 3600, minutes: 4)) // at the credits
          .record(_p('a', 60, 900, minutes: 2, asset: 'x'))
          .hide('b');
      expect([for (final p in l.continueWatching) p.titleId], ['a']);
      expect(l.continueWatching.single.assetId, 'x');
    });

    test('a new viewing brings a hidden title back', () {
      final l = WatchLedger.empty
          .record(_p('a', 600, 3600))
          .hide('a')
          .record(_p('a', 700, 3600, minutes: 1));
      expect(l.continueWatching.single.titleId, 'a');
    });

    test('survives a round trip through storage, and a corrupt blob', () {
      final l = WatchLedger.empty
          .record(_p('a', 600, 3600, asset: 'x'))
          .record(_p('b', 10, 0, finished: true))
          .hide('b');
      final back = WatchLedger.decode(l.encode());
      expect(back.pointFor('a', 'x')!.positionS, 600);
      expect(back.pointFor('b', null)!.finished, isTrue);
      expect(back.hidden, {'b'});
      expect(WatchLedger.decode('{not json').points, isEmpty);
    });

    test('is capped, oldest first out', () {
      var l = WatchLedger.empty;
      for (var i = 0; i < WatchLedger.cap + 20; i++) {
        l = l.record(_p('t$i', 100, 1000, minutes: i));
      }
      expect(l.points.length, WatchLedger.cap);
      expect(l.pointFor('t0', null), isNull);
      expect(l.pointFor('t${WatchLedger.cap + 19}', null), isNotNull);
    });

    test('reads my_watch_state rows', () {
      final p = WatchPoint.fromServer({
        'title_id': 'a',
        'asset_id': null,
        'position_s': 58,
        'duration_s': 1109,
        'last_at': '2026-10-05T11:52:04.640356+00:00',
        'finished': false,
      });
      expect(p!.positionS, 58);
      expect(p.assetId, isNull);
      expect(WatchPoint.fromServer({'title_id': 'a'}), isNull);
    });
  });

  group('withLocalContinue', () {
    test("this phone's order first, then the account's other phones", () {
      final rows = [
        _row(kRowContinue, ['s1', 'a'],
            resume: {'s1': const ResumeHint(positionS: 300, durationS: 3600)}),
        _row('trending', ['a', 'b', 'c']),
      ];
      final l = WatchLedger.empty
          .record(_p('b', 600, 3600, minutes: 2))
          .record(_p('a', 900, 3600, minutes: 1));
      final out = withLocalContinue(rows, l);
      final cw = out.first;
      expect(cw.key, kRowContinue);
      expect([for (final c in cw.items) c.id], ['b', 'a', 's1']);
      expect(cw.resume['b']!.positionS, 600);
      expect(cw.resume['s1']!.positionS, 300);
      expect(out.length, 2);
    });

    test('finished or removed here stays out, even if the server lists it', () {
      final rows = [_row(kRowContinue, ['a', 'b']), _row('trending', ['a', 'b'])];
      final l = WatchLedger.empty
          .record(_p('a', 3600, 3600, finished: true))
          .record(_p('b', 600, 3600))
          .hide('b');
      final out = withLocalContinue(rows, l);
      expect(out.where((r) => r.key == kRowContinue), isEmpty,
          reason: 'nothing left, so no row');
    });

    test('a row is added when the server has none yet', () {
      final rows = [_row('trending', ['a'])];
      final l = WatchLedger.empty.record(_p('a', 600, 3600));
      final out = withLocalContinue(rows, l);
      expect(out.first.key, kRowContinue);
      expect(out.first.items.single.id, 'a');
    });

    test('a title on no row is left out until the server carries it', () {
      final rows = [_row('trending', ['a'])];
      final l = WatchLedger.empty.record(_p('zz', 600, 3600));
      expect(withLocalContinue(rows, l).where((r) => r.key == kRowContinue),
          isEmpty);
    });
  });
}
