import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/extra_settings_service.dart';
import '../../user_data/user_data_providers.dart';
import '../domain/new_badge.dart';
import 'library_provider.dart';

/// Lives in its own file on purpose.
///
/// `user_data_providers.dart` already imports `library_provider.dart`, so
/// putting this next to the other library providers would have made the two
/// import each other. Dart tolerates that, but a cycle between two files this
/// central is the kind of thing that quietly makes later refactors painful.
/// This file depends on both and neither depends on it.
/// Folder path → how many videos in it currently carry the NEW tag.
///
/// Derived from the video list the app already holds, so it costs no extra
/// scan, and it applies exactly the same rule as the per-file badge — which is
/// the point. The old count came from the data source and was a guess: it
/// looked at one asset per folder, hard-coded seven days, ignored playback
/// records entirely, and could only ever report the number 1. A folder with
/// six unwatched new episodes showed a badge reading "1", and a folder whose
/// videos had all been watched still showed it.
///
/// Returns an empty map while the library is still loading, so the bubble
/// simply does not appear rather than appearing with a wrong number and
/// correcting itself a moment later.
final folderNewCountsProvider = Provider<Map<String, int>>((ref) {
  final videosAsync = ref.watch(allVideosProvider);
  final played = ref.watch(playedUrisProvider);
  final periodDays =
      ref.watch(extraSettingsProvider).getInt(IntSetting.newTaggedPeriod);
  if (periodDays <= 0) return const {};
  return videosAsync.maybeWhen(
    data: (videos) {
      final now = DateTime.now();
      final counts = <String, int>{};
      for (final v in videos) {
        if (NewBadge.applies(
          video: v,
          periodDays: periodDays,
          playedUris: played,
          normalize: normalizeMediaUri,
          now: now,
        )) {
          counts[v.folderPath] = (counts[v.folderPath] ?? 0) + 1;
        }
      }
      return counts;
    },
    orElse: () => const {},
  );
});

