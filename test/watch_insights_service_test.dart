// Unit tests for WatchInsightsService — the pure-function analytics
// layer that turns a list of HistoryEntry into a WatchInsights
// snapshot. No Flutter dependencies, no I/O — exercises the
// arithmetic and date-bucketing logic directly.

import 'package:flutter_test/flutter_test.dart';

import 'package:innocent/core/services/insights/watch_insights_service.dart';
import 'package:innocent/features/user_data/domain/user_data_models.dart';

HistoryEntry _entry({
  required String uri,
  required String title,
  Duration position = const Duration(minutes: 30),
  Duration duration = const Duration(minutes: 60),
  required DateTime watchedAt,
  int watchCount = 1,
}) =>
    HistoryEntry(
      videoUri: uri,
      videoTitle: title,
      lastPosition: position,
      totalDuration: duration,
      lastWatched: watchedAt,
      watchCount: watchCount,
    );

void main() {
  group('WatchInsightsService.compute', () {
    final now = DateTime(2026, 6, 8, 14, 0);

    test('empty history returns the empty snapshot', () {
      final s = WatchInsightsService.compute([], now: now);
      expect(s.totalWatchTime, Duration.zero);
      expect(s.videosWatched, 0);
      expect(s.activeDays, 0);
      expect(s.currentStreakDays, 0);
      expect(s.mostRewatched, isNull);
      expect(s.mostWatchedFolder, isNull);
      expect(s.lastSevenDaysMinutes, [0, 0, 0, 0, 0, 0, 0]);
    });

    test('single entry watched once → totalWatchTime == lastPosition',
        () {
      final s = WatchInsightsService.compute([
        _entry(
          uri: 'file:///storage/Movies/film.mkv',
          title: 'Film',
          position: const Duration(minutes: 45),
          duration: const Duration(minutes: 90),
          watchedAt: now,
        ),
      ], now: now);
      expect(s.totalWatchTime, const Duration(minutes: 45));
      expect(s.videosWatched, 1);
    });

    test(
        'rewatched entry contributes (watchCount-1)*total + lastPosition',
        () {
      // 90-minute film, watched 3 times, last session reached 30m.
      // Expected total = 2 * 90 + 30 = 210 minutes.
      final s = WatchInsightsService.compute([
        _entry(
          uri: 'file:///storage/Movies/film.mkv',
          title: 'Film',
          position: const Duration(minutes: 30),
          duration: const Duration(minutes: 90),
          watchedAt: now,
          watchCount: 3,
        ),
      ], now: now);
      expect(s.totalWatchTime, const Duration(minutes: 210));
    });

    test('clamps lastPosition to totalDuration if storage is dirty',
        () {
      // Some bug elsewhere left position > duration. We must not
      // produce a negative or > total contribution.
      final s = WatchInsightsService.compute([
        _entry(
          uri: 'file:///x/y/garbage.mp4',
          title: 'Garbage',
          position: const Duration(minutes: 200),
          duration: const Duration(minutes: 60),
          watchedAt: now,
          watchCount: 1,
        ),
      ], now: now);
      expect(s.totalWatchTime.inMinutes, lessThanOrEqualTo(60));
    });

    test('activeDays counts distinct calendar dates', () {
      // Three entries spread across two distinct dates.
      final s = WatchInsightsService.compute([
        _entry(
            uri: 'file:///a.mkv',
            title: 'A',
            watchedAt: DateTime(2026, 6, 8, 9)),
        _entry(
            uri: 'file:///b.mkv',
            title: 'B',
            watchedAt: DateTime(2026, 6, 8, 22)),
        _entry(
            uri: 'file:///c.mkv',
            title: 'C',
            watchedAt: DateTime(2026, 6, 7, 10)),
      ], now: now);
      expect(s.activeDays, 2);
    });

    test('streak counts consecutive days ending today', () {
      // Today + yesterday + day-before — three-day streak.
      final s = WatchInsightsService.compute([
        _entry(
            uri: 'file:///a.mkv',
            title: 'A',
            watchedAt: DateTime(2026, 6, 8, 9)),
        _entry(
            uri: 'file:///b.mkv',
            title: 'B',
            watchedAt: DateTime(2026, 6, 7, 9)),
        _entry(
            uri: 'file:///c.mkv',
            title: 'C',
            watchedAt: DateTime(2026, 6, 6, 9)),
      ], now: now);
      expect(s.currentStreakDays, 3);
    });

    test('streak survives a missing-today (yesterday-anchored)', () {
      // No watch today, but yesterday + day before. Should still
      // report a 2-day streak ending yesterday.
      final s = WatchInsightsService.compute([
        _entry(
            uri: 'file:///a.mkv',
            title: 'A',
            watchedAt: DateTime(2026, 6, 7, 9)),
        _entry(
            uri: 'file:///b.mkv',
            title: 'B',
            watchedAt: DateTime(2026, 6, 6, 9)),
      ], now: now);
      expect(s.currentStreakDays, 2);
    });

    test('streak breaks on a gap', () {
      // Watch today + day before yesterday (gap on yesterday).
      // Only today counts.
      final s = WatchInsightsService.compute([
        _entry(
            uri: 'file:///a.mkv',
            title: 'A',
            watchedAt: DateTime(2026, 6, 8, 9)),
        _entry(
            uri: 'file:///b.mkv',
            title: 'B',
            watchedAt: DateTime(2026, 6, 6, 9)),
      ], now: now);
      expect(s.currentStreakDays, 1);
    });

    test('mostRewatched picks the highest watchCount', () {
      final s = WatchInsightsService.compute([
        _entry(
            uri: 'file:///a.mkv',
            title: 'A',
            watchedAt: now,
            watchCount: 2),
        _entry(
            uri: 'file:///b.mkv',
            title: 'B-favourite',
            watchedAt: now,
            watchCount: 9),
        _entry(
            uri: 'file:///c.mkv',
            title: 'C',
            watchedAt: now,
            watchCount: 1),
      ], now: now);
      expect(s.mostRewatched?.videoTitle, 'B-favourite');
    });

    test('mostWatchedFolder aggregates by parent directory name', () {
      // Two entries from "Naruto", one from "OnePiece" — Naruto wins.
      final s = WatchInsightsService.compute([
        _entry(
            uri: 'file:///storage/Anime/Naruto/ep1.mkv',
            title: 'N1',
            watchedAt: now,
            watchCount: 2),
        _entry(
            uri: 'file:///storage/Anime/Naruto/ep2.mkv',
            title: 'N2',
            watchedAt: now,
            watchCount: 3),
        _entry(
            uri: 'file:///storage/Anime/OnePiece/ep1.mkv',
            title: 'OP1',
            watchedAt: now,
            watchCount: 4),
      ], now: now);
      expect(s.mostWatchedFolder, 'Naruto');
      expect(s.mostWatchedFolderCount, 5);
    });

    test('averageCompletionPercent averages position/duration ratios',
        () {
      // 50% + 100% + 25% → average 58.3%.
      final s = WatchInsightsService.compute([
        _entry(
            uri: 'file:///a.mkv',
            title: 'A',
            position: const Duration(minutes: 30),
            duration: const Duration(minutes: 60),
            watchedAt: now),
        _entry(
            uri: 'file:///b.mkv',
            title: 'B',
            position: const Duration(minutes: 60),
            duration: const Duration(minutes: 60),
            watchedAt: now),
        _entry(
            uri: 'file:///c.mkv',
            title: 'C',
            position: const Duration(minutes: 15),
            duration: const Duration(minutes: 60),
            watchedAt: now),
      ], now: now);
      expect(s.averageCompletionPercent, closeTo(58.33, 0.1));
    });

    test('lastSevenDaysMinutes places today in slot 6, six-days-ago in 0',
        () {
      // 10 minutes watched today, 20 minutes three days ago.
      final s = WatchInsightsService.compute([
        _entry(
            uri: 'file:///a.mkv',
            title: 'A',
            position: const Duration(minutes: 10),
            duration: const Duration(minutes: 60),
            watchedAt: DateTime(2026, 6, 8, 12)),
        _entry(
            uri: 'file:///b.mkv',
            title: 'B',
            position: const Duration(minutes: 20),
            duration: const Duration(minutes: 60),
            watchedAt: DateTime(2026, 6, 5, 12)),
      ], now: now);
      // Index 6 = today, index 3 = three days ago.
      expect(s.lastSevenDaysMinutes.length, 7);
      expect(s.lastSevenDaysMinutes[6], 10);
      expect(s.lastSevenDaysMinutes[3], 20);
      // Days with no activity stay at 0.
      expect(s.lastSevenDaysMinutes[0], 0);
    });
  });
}
