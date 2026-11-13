// The list and form screens Phase 1 left at full width (docs/devices_2026_11.md),
// with the user data a phone holds: on a tablet, a Chromebook or a TV each
// is capped at a readable 840 dp; on a phone nothing moves.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/me/presentation/cloud_drive_screen.dart';
import 'package:innocent/features/me/presentation/custom_popup_play_screen.dart';
import 'package:innocent/features/network_stream/presentation/network_stream_screen.dart';
import 'package:innocent/features/user_data/presentation/favourites_screen.dart';
import 'package:innocent/features/user_data/presentation/history_screen.dart';
import 'package:innocent/features/user_data/presentation/playlists_screen.dart';
import 'package:innocent/features/user_data/presentation/recycle_bin_screen.dart';
import 'package:innocent/features/user_data/presentation/watch_insights_screen.dart';
import 'package:innocent/features/user_data/presentation/watch_later_screen.dart';
import 'package:innocent/features/video_hub/presentation/stream_cache_screen.dart';

import 'fakes.dart';
import 'harness.dart';

final _now = DateTime(2026, 11, 12, 20);

/// What a phone's preferences hold after a week of watching: the shapes
/// the user-data service writes (core/services/user_data).
Map<String, Object> _watched() {
  final v = videos();
  return {
    'user_history_v1': jsonEncode([
      for (final (i, x) in v.indexed)
        {
          'videoUri': x.uri,
          'videoTitle': x.title,
          'lastPositionMs': x.duration.inMilliseconds * (i + 1) ~/ 12,
          'totalDurationMs': x.duration.inMilliseconds,
          'lastWatched':
              _now.subtract(Duration(hours: i * 9)).millisecondsSinceEpoch,
          'watchCount': 1 + i % 3,
        },
    ]),
    'user_favourites_v1': [for (final x in v.take(4)) x.uri],
    'user_watch_later_v1': [for (final x in v.skip(2).take(4)) x.uri],
    'user_playlists_v1': jsonEncode([
      {
        'id': 'p1',
        'name': 'ညဘက် ကြည့်ဖို့',
        'videoUris': [for (final x in v.take(3)) x.uri],
        'createdAt': _now.subtract(const Duration(days: 5)).millisecondsSinceEpoch,
        'updatedAt': _now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
      },
      {
        'id': 'p2',
        'name': 'Weekend films',
        'videoUris': [for (final x in v.skip(3).take(2)) x.uri],
        'createdAt': _now.subtract(const Duration(days: 9)).millisecondsSinceEpoch,
        'updatedAt': _now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      },
    ]),
  };
}

void main() {
  setUpAll(loadScreenFonts);
  setUp(reportOverflowsInsteadOfFailing);

  const wide = [tabletLand, large];
  screens('history', () => const HistoryScreen(),
      overrides: libraryOverrides, prefs: _watched(), phones: wide);
  screens('favourites', () => const FavouritesScreen(),
      overrides: libraryOverrides, prefs: _watched(), phones: wide);
  screens('watch_later', () => const WatchLaterScreen(),
      overrides: libraryOverrides, prefs: _watched(), phones: wide);
  screens('playlists', () => const PlaylistsScreen(),
      overrides: libraryOverrides, prefs: _watched(), phones: wide);
  screens('recycle_bin', () => const RecycleBinScreen(),
      overrides: libraryOverrides, phones: wide);
  screens('watch_insights', () => const WatchInsightsScreen(),
      overrides: libraryOverrides, prefs: _watched(), phones: wide);
  screens('cloud_drive', () => const CloudDriveScreen(), phones: wide);
  screens('network_stream', () => const NetworkStreamScreen(), phones: wide);
  screens('stream_cache', () => const StreamCacheScreen(), phones: wide);
  screens('custom_popup', () => const CustomPopupPlayScreen(), phones: wide);
}
