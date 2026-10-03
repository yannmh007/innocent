import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/demo_content_repository.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_provider.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_screen.dart';

import 'harness.dart';

void main() {
  setUpAll(loadScreenFonts);
  setUp(reportOverflowsInsteadOfFailing);

  screens('hub', () => const VideoHubScreen(),
      overrides: () => [
            contentRepositoryProvider.overrideWithValue(DemoContentRepository()),
          ]);
}
