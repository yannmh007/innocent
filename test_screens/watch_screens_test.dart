import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/widgets/up_next_card.dart';
import 'package:innocent/features/video_hub/data/demo_content_datasource.dart';
import 'package:innocent/features/video_hub/data/demo_content_repository.dart';
import 'package:innocent/features/video_hub/data/watch_state_store.dart';
import 'package:innocent/features/video_hub/presentation/content_detail_screen.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_provider.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_screen.dart';

import 'fakes.dart';
import 'harness.dart';

// Continue watching, Resume / Start over, More like this and Up next, drawn
// from the demo catalogue with a few viewings already on the phone.
void main() {
  setUpAll(loadScreenFonts);
  setUp(reportOverflowsInsteadOfFailing);

  final demo = const DemoContentDataSource().all();
  final film = demo.firstWhere((c) => c.episodeCount == null, orElse: () => demo.last);
  final now = DateTime.now();
  var ledger = WatchLedger.empty;
  for (var i = 0; i < 4; i++) {
    ledger = ledger.record(WatchPoint(
      titleId: demo[i].id,
      positionS: 600 + 700 * i,
      durationS: 5400,
      at: now.subtract(Duration(minutes: 10 * i)),
    ));
  }
  ledger = ledger.record(WatchPoint(
      titleId: film.id, positionS: 2723, durationS: 6120, at: now));
  final prefs = <String, Object>{'vh.watch_points.v1': ledger.encode()};

  hub() => [
        contentRepositoryProvider.overrideWithValue(DemoContentRepository()),
        ...libraryOverrides(),
      ];

  screens('hub_continue', () => const VideoHubScreen(), overrides: hub, prefs: prefs);
  screens('detail_resume', () => ContentDetailScreen(content: film),
      overrides: hub, prefs: prefs, scrolls: 1, phones: const [small]);
  screens(
      'up_next',
      () => Container(
            color: Colors.black,
            alignment: Alignment.bottomRight,
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
              UpNextCard(
                title: 'Demo Series 1 · 3 of 12',
                countdown: const Duration(hours: 1),
                onPlay: ({required bool byItself}) {},
                onClose: () {},
              ),
              const SizedBox(height: 12),
              UpNextCard(
                title: 'Demo Series 1 · 4 of 12',
                askFirst: true,
                onPlay: ({required bool byItself}) {},
                onClose: () {},
              ),
            ]),
          ),
      phones: const [small]);
}
