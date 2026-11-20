// A player screen pushed over another one takes the player over (15 Nov
// 2026).
//
// THE BUG, FROM THE DEVICE LAB (run 43675629684, flow reopen): a second
// player reached the screen while one was open, and the one below stayed
// mounted. Every 30 s it reported the NEW film's position against its own
// title (Big Buck Bunny "at 8 s of 653 s" — the other film's numbers), wrote
// that into its own resume point, and never sent its summary; closed later,
// it would have cleared the callbacks the screen on top had set. Now the
// screen below says its last as the newcomer arrives and touches nothing
// shared after.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/core/di/core_providers.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/player_screen.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/event_sender.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_player_service.dart';
import 'support/player_harness.dart';

/// Every event the screens send, kept instead of posted.
class _Events extends EventSender {
  _Events()
      : super(ApiClient(httpClient: MockClient((http.Request r) async {
          return http.Response('0', 200);
        })));

  final List<Map<String, dynamic>> seen = <Map<String, dynamic>>[];

  @override
  void enqueue(Map<String, dynamic> event, {void Function(bool sent)? onDone}) {
    seen.add(event);
  }

  List<Map<String, dynamic>> of(String kind, String title) =>
      seen.where((e) => e['kind'] == kind && e['title_id'] == title).toList();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('the screen below says its last once and reports nothing after',
      (WidgetTester tester) async {
    quietPlatform(tester);
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(720, 1600);
    addTearDown(tester.view.reset);
    final engine = FakePlayerService();
    final events = _Events();
    final container = ProviderContainer(overrides: [
      videoPlayerServiceProvider.overrideWithValue(engine),
      eventSenderProvider.overrideWithValue(events),
    ]);
    addTearDown(container.dispose);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: nav,
        theme: playerTestTheme(),
        localizationsDelegates: AppStrings.localizationsDelegates,
        supportedLocales: AppStrings.supportedLocales,
        home: const Scaffold(body: Text('home')),
      ),
    ));
    Route<void> player(String id, Duration at) => MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
            videoUri: 'https://example.invalid/$id.m3u8',
            title: id,
            titleId: id,
            startAt: at));
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    final a = player('film-a', const Duration(seconds: 100));
    nav.currentState!.push(a);
    await settle();
    expect(events.of('play_summary', 'film-a'), isEmpty);

    // A second player arrives over the first: the first says its last now,
    // with its own position.
    nav.currentState!.push(player('film-b', const Duration(seconds: 3000)));
    await settle();
    final aSummary = events.of('play_summary', 'film-a');
    expect(aSummary, hasLength(1), reason: "the first screen's summary");
    expect(aSummary.single['position_s'], 100);
    final aLast = events
        .of('play_progress', 'film-a')
        .where((e) => (e['meta'] as Map?)?['final'] == true)
        .toList();
    expect(aLast, hasLength(1));
    expect(aLast.single['position_s'], 100);

    // A minute of the second film: nothing more under the first title.
    final before = events.seen.where((e) => e['title_id'] == 'film-a').length;
    await tester.pump(const Duration(seconds: 61));
    expect(events.seen.where((e) => e['title_id'] == 'film-a').length, before,
        reason: "the second film's position reported against the first");
    expect(events.of('play_progress', 'film-b'), isNotEmpty);

    // The first screen goes from under the second: the second's callbacks
    // stay.
    final ctrl = container.read(playerControllerProvider.notifier);
    expect(ctrl.onFirstFrame, isNotNull);
    nav.currentState!.removeRoute(a);
    await settle();
    expect(ctrl.onFirstFrame, isNotNull,
        reason: "the first screen cleared the second's callbacks");
    expect(events.of('play_summary', 'film-a'), hasLength(1));

    // And the second closes as usual.
    nav.currentState!.pop();
    await settle();
    expect(events.of('play_summary', 'film-b'), hasLength(1));
    await tester.pump(const Duration(minutes: 5));
  });
}
