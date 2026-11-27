// ♪ on a catalogue film and MX's ♪ items (27 Nov 2026,
// docs/handoff_2026_11_27_beyond_mx.md P4): the ladder's audio tracks as
// ExoPlayer reports them (♪ said "no audio tracks" there), and the rows the
// owner chose — Disable, Stereo mode, Volume boost, Night sound — each doing
// what it says.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/core/services/video_player/exo_engine.dart';
import 'package:innocent/core/services/video_player/models/audio_track_info.dart';
import 'package:innocent/features/player/presentation/widgets/player_ui.dart';
import 'package:innocent/features/player/presentation/widgets/track_selection_sheet.dart';

Widget _app(Widget child) => MaterialApp(
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: AppStrings.localizationsDelegates,
      theme: ThemeData.dark(),
      home: Scaffold(backgroundColor: Colors.black, body: child),
    );

void main() {
  group('the ladder reports its audio tracks', () {
    test('an audio event is the list ♪ shows, the playing one marked', () {
      final e = ExoEngine.forTest();
      final got = <List<AudioTrackInfo>>[];
      e.audioTracksStream.listen(got.add);
      e.debugEvent(<Object?, Object?>{
        'e': 'audio',
        'id': 0,
        'off': false,
        'tracks': <Object?>[
          <Object?, Object?>{
            'id': '1:0', 'title': null, 'lang': 'en', 'codec': 'mp4a.40.2',
            'ch': 2, 'on': true, 'ok': true,
          },
          <Object?, Object?>{
            'id': '2:0', 'title': 'Commentary', 'lang': 'en',
            'codec': 'mp4a.40.2', 'ch': 2, 'on': false, 'ok': true,
          },
        ],
      });
      expect(e.audioTracks.map((t) => t.id), ['1:0', '2:0']);
      expect(e.audioTrackOn, '1:0');
      expect(e.audioOff, isFalse);
      expect(e.audioTracks.last.displayName, contains('Commentary'));
      e.debugEvent(<Object?, Object?>{
        'e': 'audio', 'id': 0, 'off': true, 'tracks': <Object?>[],
      });
      expect(e.audioOff, isTrue);
      expect(e.audioTracks, isEmpty);
      return Future<void>.delayed(Duration.zero).then((_) {
        expect(got.length, 2);
      });
    });
  });

  group('♪ rows', () {
    const tracks = [
      AudioTrackInfo(id: '1:0', language: 'en', codec: 'aac', channels: 2),
    ];

    testWidgets('each of MX\'s items is there and does something',
        (tester) async {
      final did = <String>[];
      await tester.pumpWidget(_app(TrackSelectionSheet<AudioTrackInfo>(
        title: 'Audio',
        tracks: tracks,
        currentTrack: tracks.first,
        labelFor: (t) => t.displayName,
        idFor: (t) => t.id,
        onSelect: (t) => did.add('track ${t?.id}'),
        delayMs: 150,
        onDelay: () => did.add('delay'),
        onDisable: () => did.add('disable'),
        stereoLabel: 'Mono',
        onStereo: () => did.add('stereo'),
        boostLabel: '150 %',
        onBoost: () => did.add('boost'),
        onNight: (on) => did.add('night $on'),
      )));
      for (final w in [
        'Disable', 'Audio delay', '+150 ms', 'Stereo mode', 'Mono',
        'Volume boost', '150 %', 'Night sound',
      ]) {
        expect(find.text(w), findsOneWidget, reason: w);
      }
      await tester.tap(find.text('Disable'));
      await tester.tap(find.text('Stereo mode'));
      await tester.tap(find.text('Volume boost'));
      await tester.tap(find.text('Night sound'));
      await tester.pump();
      // The switch moves at once (the sheet is drawn once).
      final sw = tester.widget<PanelSwitchRow>(find.byType(PanelSwitchRow));
      expect(sw.value, isTrue);
      await tester.tap(find.text('Night sound'));
      await tester.pump();
      expect(did, ['disable', 'stereo', 'boost', 'night true', 'night false']);
    });

    testWidgets('Disable marked: no track is', (tester) async {
      await tester.pumpWidget(_app(TrackSelectionSheet<AudioTrackInfo>(
        title: 'Audio',
        tracks: tracks,
        currentTrack: tracks.first,
        labelFor: (t) => t.displayName,
        idFor: (t) => t.id,
        onSelect: (_) {},
        disabled: true,
        onDisable: () {},
      )));
      final rows = tester.widgetList<PanelRow>(find.byType(PanelRow)).toList();
      final disable = rows.singleWhere((r) => r.title == 'Disable');
      expect(disable.selected, isTrue);
      expect(rows.where((r) => r.selected), [disable]);
    });

    testWidgets('a player without them shows the tracks and the delay alone',
        (tester) async {
      await tester.pumpWidget(_app(TrackSelectionSheet<AudioTrackInfo>(
        title: 'Audio',
        tracks: tracks,
        currentTrack: tracks.first,
        labelFor: (t) => t.displayName,
        idFor: (t) => t.id,
        onSelect: (_) {},
        onDelay: () {},
      )));
      for (final w in ['Disable', 'Stereo mode', 'Volume boost', 'Night sound']) {
        expect(find.text(w), findsNothing, reason: w);
      }
      expect(find.text('Audio delay'), findsOneWidget);
    });
  });

  group('Stereo mode and Volume boost', () {
    testWidgets('three modes, the one on marked, a tap picks', (tester) async {
      final picked = <int>[];
      await tester.pumpWidget(_app(Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => StereoModeSheet(mode: 2, onPick: picked.add),
        ),
      )));
      final rows = tester.widgetList<PanelRow>(find.byType(PanelRow)).toList();
      expect(rows.map((r) => r.title),
          ['Stereo', 'Mono', 'Left and right swapped']);
      expect(rows.map((r) => r.selected), [false, false, true]);
      await tester.tap(find.text('Mono'));
      await tester.pump();
      expect(picked, [1]);
    });

    testWidgets('the boost steps by 10 %, from 100 % to its ceiling',
        (tester) async {
      final got = <int>[];
      await tester.pumpWidget(_app(AudioBoostSheet(
          initialPct: 180, maxPct: 200, onChanged: got.add)));
      expect(find.text('180 %'), findsOneWidget);
      final plus = find.byIcon(Icons.add_rounded);
      await tester.tap(plus);
      await tester.pump();
      await tester.tap(plus);
      await tester.pump();
      await tester.tap(plus); // at the ceiling: nothing more
      await tester.pump();
      expect(find.text('200 %'), findsOneWidget);
      await tester.tap(find.text('200 %')); // back to 100 %
      await tester.pump();
      expect(find.text('100 %'), findsOneWidget);
      expect(got, [190, 200, 100]);
    });

    test('the labels in three languages', () {
      for (final l in AppStrings.supportedLocales) {
        final s = AppStrings(l);
        expect({
          StereoModeSheet.label(s, 0),
          StereoModeSheet.label(s, 1),
          StereoModeSheet.label(s, 2),
        }.length, 3, reason: '$l');
        expect(s.audNight, isNotEmpty);
        expect(s.audDisable, isNotEmpty);
      }
    });
  });
}
