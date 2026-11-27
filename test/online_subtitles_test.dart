import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/player/data/online_subtitles.dart';
import 'package:innocent/features/player/presentation/widgets/online_subtitles_sheet.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/session_store.dart';

// CC → Online (P5, 28 Nov 2026): the film's hash as OpenSubtitles makes it,
// the name the search starts from, what the app sends to subtitles-online
// (docs/edge/subtitles-online.ts) and what it does with each answer.
class _Session extends SessionStore {
  @override
  Future<String?> accessToken() async => null;
  @override
  Future<String?> refreshToken() async => null;
  @override
  Future<bool> isExpired() async => false;
}

OnlineSubtitles _client(Future<http.Response> Function(http.Request) answer,
        List<Map<String, dynamic>> sent) =>
    OnlineSubtitles(
      ApiClient(
        session: _Session(),
        httpClient: MockClient((req) async {
          sent.add(jsonDecode(req.body) as Map<String, dynamic>);
          return answer(req);
        }),
      ),
      deviceId: () async => 'install-1',
    );

void main() {
  group('the hash', () {
    test('size plus the 64-bit sums of the two ends (OpenSubtitles)', () {
      // Worked out independently (python struct '<Q').
      final head = Uint8List(65536)..fillRange(0, 65536, 1);
      final tail = Uint8List.fromList(
          List<int>.generate(65536, (i) => i % 256));
      expect(movieHashOf(131072, head, tail), '7050300fefd1a000');
      expect(movieHashOf(131072, Uint8List(65536), Uint8List(65536)),
          '0000000000020000');
    });

    test('a file under 128 KiB has none', () async {
      final dir = await Directory.systemTemp.createTemp('mh');
      final f = File('${dir.path}/a.mp4')..writeAsBytesSync(Uint8List(1000));
      expect(await movieHash(f), isNull);
      await dir.delete(recursive: true);
    });
  });

  group('the name searched', () {
    test('a release name loses its tags, keeps its year', () {
      expect(cleanFilmName('The.Movie.Name.2019.1080p.WEB-DL.x264-GROUP.mkv'),
          'The Movie Name 2019');
      expect(cleanFilmName('Big_Buck_Bunny_720p.mp4'), 'Big Buck Bunny');
      expect(cleanFilmName('[YTS] Sintel (2010) [BluRay].mp4'), 'Sintel (2010)');
      expect(cleanFilmName('မြန်မာ ဇာတ်ကား.mp4'), 'မြန်မာ ဇာတ်ကား');
      expect(cleanFilmName('Sintel'), 'Sintel');
    });
  });

  group('the service', () {
    test('a search sends the name, hash, languages and install; reads rows',
        () async {
      final sent = <Map<String, dynamic>>[];
      final c = _client(
          (_) async => http.Response(
              jsonEncode({
                'results': [
                  {'file_id': 7, 'lang': 'my', 'release': 'R', 'name': 'r.srt', 'downloads': 1200, 'hash_match': true},
                  {'file_id': 0, 'lang': 'en'},
                ],
              }),
              200),
          sent);
      final rows = await c.search(
          query: ' Sintel ', moviehash: '0123456789abcdef', languages: ['my', 'en']);
      expect(sent.single, {
        'op': 'search',
        'query': 'Sintel',
        'moviehash': '0123456789abcdef',
        'languages': 'my,en',
        'device_id': 'install-1',
      });
      expect(rows.length, 1);
      expect(rows.single.hashMatch, isTrue);
      expect(rows.single.label, 'R');
    });

    test('each refusal is told apart', () async {
      Future<OnlineSubtitleFailure> failure(int status, String code) async {
        final c = _client(
            (_) async => http.Response(jsonEncode({'code': code, 'retry_after': 60}), status),
            <Map<String, dynamic>>[]);
        try {
          await c.search(query: 'x');
        } on OnlineSubtitleError catch (e) {
          return e.why;
        }
        fail('no error for $status $code');
      }

      expect(await failure(429, 'quota_day'), OnlineSubtitleFailure.dayUsedUp);
      expect(await failure(429, 'rate_limited'), OnlineSubtitleFailure.busy);
      expect(await failure(503, 'not_configured'), OnlineSubtitleFailure.notReady);
      expect(await failure(502, 'unavailable'), OnlineSubtitleFailure.unavailable);
    });

    test('a download is written as .srt, its name kept out of other folders',
        () async {
      final dir = await Directory.systemTemp.createTemp('os');
      final sent = <Map<String, dynamic>>[];
      final c = _client(
          (_) async => http.Response(
              jsonEncode({
                'name': '../x.srt',
                'format': 'srt',
                'data': base64Encode(utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nHi\n')),
              }),
              200),
          sent);
      final f = await c.download(
          const OnlineSubtitle(fileId: 9, lang: 'en', release: '', name: 'n.srt'), dir);
      expect(sent.single['op'], 'download');
      expect(sent.single['file_id'], 9);
      expect(f.parent.path, dir.path);
      expect(f.readAsStringSync(), contains('Hi'));
      await dir.delete(recursive: true);
    });
  });

  group('the sheet', () {
    testWidgets('it searches at once; a row tapped downloads and loads it',
        (t) async {
      // Real files: made and read outside the test's fake clock.
      final dir = (await t.runAsync(() => Directory.systemTemp.createTemp('oss')))!;
      final sent = <Map<String, dynamic>>[];
      final loaded = <String>[];
      final c = _client((req) async {
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        if (b['op'] == 'search') {
          return http.Response(
              jsonEncode({
                'results': [
                  {'file_id': 5, 'lang': 'en', 'release': 'Sintel.2010', 'name': 's.srt', 'downloads': 10},
                ],
              }),
              200);
        }
        return http.Response(
            jsonEncode({'name': 's.srt', 'format': 'srt', 'data': base64Encode(utf8.encode('x'))}),
            200);
      }, sent);
      await t.pumpWidget(MaterialApp(
        localizationsDelegates: AppStrings.localizationsDelegates,
        supportedLocales: AppStrings.supportedLocales,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: OnlineSubtitlesSheet(
            client: c,
            filmName: 'Sintel.2010.720p.mkv',
            onLoad: (p) async => loaded.add(p),
            cacheDir: dir,
          ),
        ),
      ));
      for (var i = 0; i < 5 && sent.isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pump();
      }
      await t.pump();
      expect(sent.first['query'], 'Sintel 2010');
      expect(sent.first['languages'], 'my,en');
      expect(find.text('Sintel.2010'), findsOneWidget);
      await t.tap(find.text('Sintel.2010'));
      for (var i = 0; i < 10 && loaded.isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pump();
      }
      expect(sent.last['op'], 'download');
      expect(loaded.single, endsWith('s.srt'));
      await t.runAsync(() => dir.delete(recursive: true));
    });
  });
}
