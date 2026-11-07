// What a playback was like, in numbers — and the reports that carry it.
//
// WHY (7 Nov 2026). Stalls on the ladder engine (the main streaming path)
// were written only to the phone's own trail, so the server saw none after
// 24 Oct and "no stalls" looked like smoothness. These pin the arithmetic of
// the per-playback summary and the three reports that now leave the phone:
// the summary once, errors as codes (never a message), ladder stalls.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/player/domain/playback_qoe.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/event_sender.dart';
import 'package:innocent/features/video_hub/data/api/playback_reporter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Capture extends EventSender {
  _Capture()
      : super(ApiClient(httpClient: MockClient((http.Request r) async {
          fail('nothing is posted in these tests');
        })));
  final List<(String, Map<String, dynamic>?)> logged = [];

  @override
  void log(String kind,
      {String? titleId,
      String? assetId,
      int? positionS,
      int? durationS,
      Map<String, dynamic>? meta}) {
    logged.add((kind, meta));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  final t0 = DateTime(2026, 11, 7, 12);

  group('PlaybackQoe', () {
    test('stalls and jump fills are counted apart, with the longest stall', () {
      final q = PlaybackQoe()
        ..firstFrame(ms: 640, engineName: 'ladder')
        ..stallEnded(1200)
        ..stallEnded(3400)
        ..jumpFillEnded(800);
      final m = q.toMeta(t0);
      expect(m['engine'], 'ladder');
      expect(m['open_ms'], 640);
      expect(m['stalls'], 2);
      expect(m['frozen_ms'], 4600);
      expect(m['longest_ms'], 3400);
      expect(m['jumps'], 1);
      expect(m['jump_ms'], 800);
    });

    test('the first open time stays: a reopen does not replace it', () {
      final q = PlaybackQoe()
        ..firstFrame(ms: 500, engineName: 'ladder')
        ..firstFrame(ms: 90, engineName: 'mpv');
      expect(q.toMeta(t0)['open_ms'], 500);
      expect(q.toMeta(t0)['engine'], 'ladder');
    });

    test('playing time adds up, including a stretch still running at the end', () {
      final q = PlaybackQoe()
        ..playing(true, t0)
        ..playing(false, t0.add(const Duration(seconds: 50)))
        ..playing(true, t0.add(const Duration(seconds: 60)));
      expect(q.toMeta(t0.add(const Duration(seconds: 70)))['played_s'], 60);
    });

    test('rung changes count moves, not sightings; low and high are kept', () {
      final q = PlaybackQoe()
        ..rung(720)
        ..rung(720)
        ..rung(480)
        ..rung(240)
        ..rung(720)
        ..rung(null);
      final m = q.toMeta(t0);
      expect(m['rung_changes'], 3);
      expect(m['rung_low'], 240);
      expect(m['rung_high'], 720);
    });

    test('a playback that never showed a picture says so by what it lacks', () {
      final q = PlaybackQoe()..error('would_not_start');
      final m = q.toMeta(t0);
      expect(m.containsKey('open_ms'), isFalse);
      expect(m.containsKey('engine'), isFalse);
      expect(m.containsKey('longest_ms'), isFalse);
      expect(m['errors'], 'would_not_start');
      expect(m['stalls'], 0);
    });

    test('reset starts a new viewing from nothing', () {
      final q = PlaybackQoe()
        ..firstFrame(ms: 1, engineName: 'mpv')
        ..stallEnded(9)
        ..rung(480)
        ..error('offline')
        ..reset();
      expect(q.toMeta(t0), <String, dynamic>{
        'played_s': 0, 'stalls': 0, 'frozen_ms': 0, 'jumps': 0,
      });
    });
  });

  group('PlaybackReporter: summary, errors, ladder stalls', () {
    test('the summary goes once, and not after finish', () {
      final s = _Capture();
      final r = PlaybackReporter(s, titleId: 't');
      r.reportSummary(<String, dynamic>{'stalls': 1});
      r.reportSummary(<String, dynamic>{'stalls': 2});
      r.finish();
      r.reportSummary(<String, dynamic>{'stalls': 3});
      final summaries = s.logged.where((e) => e.$1 == Ev.playSummary).toList();
      expect(summaries, hasLength(1));
      expect(summaries.single.$2, <String, dynamic>{'stalls': 1});
    });

    test('an error is a code, once per code, three at most', () {
      final s = _Capture();
      final r = PlaybackReporter(s, titleId: 't');
      for (final c in ['player_error', 'player_error', 'offline', 'stalled', 'link_expired']) {
        r.reportError(c);
      }
      final errors = s.logged.where((e) => e.$1 == Ev.error).toList();
      expect(errors.map((e) => e.$2!['code']), ['player_error', 'offline', 'stalled']);
      expect(errors.every((e) => e.$2!['where'] == 'player' && e.$2!.length == 2), isTrue,
          reason: 'only where and code: nothing else from the player travels');
    });

    test('a ladder stall travels as play_stall, numbered, six at most', () {
      final s = _Capture();
      final r = PlaybackReporter(s, titleId: 't');
      for (var i = 0; i < 8; i++) {
        r.reportStall(<String, dynamic>{'reason': 'ladder', 'frozen_ms': 1000 + i, 'res': 480});
      }
      final stalls = s.logged.where((e) => e.$1 == Ev.playStall).toList();
      expect(stalls, hasLength(6));
      expect(stalls.first.$2, <String, dynamic>{'reason': 'ladder', 'frozen_ms': 1000, 'res': 480, 'n': 1});
    });
  });
}
