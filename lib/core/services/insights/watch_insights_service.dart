import 'package:flutter/foundation.dart';
import '../../../features/user_data/domain/user_data_models.dart';

/// Summary statistics computed from the user's watch history.
///
/// Every field is derived locally from existing HistoryEntry records;
/// no network calls, no analytics services, no telemetry. The screen
/// that surfaces this is meant to feel like a personal weekly recap,
/// not a metrics dashboard.
class WatchInsights {
  /// Estimated cumulative watch time across all entries. The estimate
  /// assumes any `watchCount > 1` means the user finished the video
  /// the first (n-1) times and only the latest session reached
  /// `lastPosition`. It is conservative for non-completers and
  /// generous for skip-around viewers, but tends to land in the right
  /// order of magnitude for typical use.
  final Duration totalWatchTime;

  /// Number of distinct videos that appear in history with any
  /// non-zero position recorded.
  final int videosWatched;

  /// Number of distinct calendar days that appear at least once in
  /// the `lastWatched` timestamps. A rough "how often do I open the
  /// app" proxy.
  final int activeDays;

  /// Consecutive-day streak ending today (or yesterday if the user
  /// hasn't watched anything yet today). Zero if there was no
  /// activity in the last two days.
  final int currentStreakDays;

  /// Average percentage completion across entries with a valid
  /// duration. Useful as a "do I actually finish what I start?"
  /// signal. Reported in 0..100 range.
  final double averageCompletionPercent;

  /// Top single video by `watchCount` (the most-rewatched title).
  /// Null if history is empty.
  final HistoryEntry? mostRewatched;

  /// Top folder by aggregate watch count, formatted as the folder's
  /// display name. Folders are derived from the URI path.
  final String? mostWatchedFolder;
  final int mostWatchedFolderCount;

  /// Watch time over the last seven calendar days, including today.
  /// Index 0 is six days ago, index 6 is today. Each entry is the
  /// per-day estimated minutes watched. Useful for a sparkline /
  /// bar chart.
  final List<int> lastSevenDaysMinutes;

  const WatchInsights({
    required this.totalWatchTime,
    required this.videosWatched,
    required this.activeDays,
    required this.currentStreakDays,
    required this.averageCompletionPercent,
    required this.mostRewatched,
    required this.mostWatchedFolder,
    required this.mostWatchedFolderCount,
    required this.lastSevenDaysMinutes,
  });

  static const empty = WatchInsights(
    totalWatchTime: Duration.zero,
    videosWatched: 0,
    activeDays: 0,
    currentStreakDays: 0,
    averageCompletionPercent: 0,
    mostRewatched: null,
    mostWatchedFolder: null,
    mostWatchedFolderCount: 0,
    lastSevenDaysMinutes: <int>[0, 0, 0, 0, 0, 0, 0],
  );
}

/// Stateless helpers that turn a list of [HistoryEntry] into a
/// [WatchInsights] snapshot. Kept as pure functions so they can be
/// unit-tested without any Flutter dependencies.
class WatchInsightsService {
  /// Build the snapshot. Callers should pass `now` so tests can pin
  /// the reference date; in production the provider will pass
  /// `DateTime.now()`.
  static WatchInsights compute(
    List<HistoryEntry> entries, {
    DateTime? now,
  }) {
    if (entries.isEmpty) return WatchInsights.empty;
    final ref = now ?? DateTime.now();

    // ───── totalWatchTime ─────
    // For each entry, estimate total seconds watched as:
    //   (watchCount - 1) * totalDuration + lastPosition
    // Cap each multiplier at totalDuration so a malformed entry
    // (lastPosition > totalDuration) doesn't blow up the sum.
    var totalSeconds = 0;
    var completionSum = 0.0;
    var completionCount = 0;
    HistoryEntry? topRewatched;
    final folderCounts = <String, int>{};

    for (final e in entries) {
      final totalSec = e.totalDuration.inSeconds;
      final posSec = e.lastPosition.inSeconds.clamp(0, totalSec).toInt();
      final priorCompletions = (e.watchCount - 1).clamp(0, 1000);
      totalSeconds += priorCompletions * totalSec + posSec;

      if (totalSec > 0) {
        completionSum += posSec / totalSec;
        completionCount++;
      }

      if (topRewatched == null || e.watchCount > topRewatched.watchCount) {
        topRewatched = e;
      }

      // Folder = last path segment of the parent directory.
      final folder = _folderName(e.videoUri);
      if (folder != null) {
        folderCounts.update(folder, (n) => n + e.watchCount,
            ifAbsent: () => e.watchCount);
      }
    }

    // ───── activeDays + currentStreakDays + lastSevenDaysMinutes ─────
    final dayKeys = <String>{};
    final dayKeyByEntry = <String, int>{};
    for (final e in entries) {
      final k = _dayKey(e.lastWatched);
      dayKeys.add(k);
      // Track this entry's contribution to that day for the seven-day
      // sparkline. We attribute the *latest* session estimate (posSec)
      // to lastWatched's date.
      dayKeyByEntry.update(k,
          (m) => m + e.lastPosition.inSeconds.clamp(0, 999999).toInt(),
          ifAbsent: () => e.lastPosition.inSeconds
              .clamp(0, 999999)
              .toInt());
    }

    final lastSeven = <int>[];
    for (var i = 6; i >= 0; i--) {
      final day = ref.subtract(Duration(days: i));
      final k = _dayKey(day);
      final secs = dayKeyByEntry[k] ?? 0;
      lastSeven.add((secs / 60).round());
    }

    // Streak: walk backward from today until a day has no activity.
    var streak = 0;
    for (var i = 0;; i++) {
      final day = ref.subtract(Duration(days: i));
      final k = _dayKey(day);
      if (dayKeys.contains(k)) {
        streak++;
      } else {
        // Allow today to be missing as long as yesterday counts.
        if (i == 0) continue;
        break;
      }
      if (i > 365) break; // safety
    }

    // ───── most-watched folder ─────
    String? topFolder;
    var topFolderCount = 0;
    folderCounts.forEach((name, count) {
      if (count > topFolderCount) {
        topFolder = name;
        topFolderCount = count;
      }
    });

    final avgCompletion = completionCount == 0
        ? 0.0
        : (completionSum / completionCount) * 100.0;

    return WatchInsights(
      totalWatchTime: Duration(seconds: totalSeconds),
      videosWatched: entries.length,
      activeDays: dayKeys.length,
      currentStreakDays: streak,
      averageCompletionPercent: avgCompletion,
      mostRewatched: topRewatched,
      mostWatchedFolder: topFolder,
      mostWatchedFolderCount: topFolderCount,
      lastSevenDaysMinutes: lastSeven,
    );
  }

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}';

  static String? _folderName(String uri) {
    // file:///storage/.../Movies/Naruto/ep1.mkv → "Naruto"
    // /sdcard/Music/Album/track.mp3 → "Album"
    String path = uri;
    if (uri.startsWith('file://')) {
      try {
        path = Uri.parse(uri).toFilePath();
      } catch (e) { if (kDebugMode) debugPrint('watch_insights_service.best-effort: $e'); }
    }
    // Strip filename.
    final lastSlash = path.lastIndexOf('/');
    if (lastSlash <= 0) return null;
    final parent = path.substring(0, lastSlash);
    final prevSlash = parent.lastIndexOf('/');
    if (prevSlash < 0) return parent;
    final folder = parent.substring(prevSlash + 1);
    return folder.isEmpty ? null : folder;
  }
}
