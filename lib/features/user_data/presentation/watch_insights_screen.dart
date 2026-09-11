import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/watch_insights_provider.dart';
import '../../../core/services/insights/watch_insights_service.dart';
import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
/// Personal watch-history dashboard. Reads entirely from on-device
/// history; nothing leaves the device. Surface cards from highest
/// emotional weight (total time + streak) to most analytical
/// (completion rate + folder breakdown) so the screen reads top-down.
class WatchInsightsScreen extends ConsumerWidget {
  const WatchInsightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insights = ref.watch(watchInsightsProvider);

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        elevation: 0,
        title: Text(AppStrings.of(context).yourWatchInsights,
            style: const TextStyle(color: Colors.white, fontSize: 18)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: insights.videosWatched == 0
          ? const _EmptyState()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _HeroCard(insights: insights),
                const SizedBox(height: 12),
                _StreakCard(insights: insights),
                const SizedBox(height: 12),
                _SevenDayCard(insights: insights),
                const SizedBox(height: 12),
                if (insights.mostRewatched != null) ...[
                  _MostRewatchedCard(insights: insights),
                  const SizedBox(height: 12),
                ],
                if (insights.mostWatchedFolder != null) ...[
                  _FolderCard(insights: insights),
                  const SizedBox(height: 12),
                ],
                _CompletionCard(insights: insights),
                const SizedBox(height: 16),
                const _PrivacyFootnote(),
              ],
            ),
    );
  }
}

// ─── Empty state ───────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insights,
                size: 48, color: AppColors.white30),
            const SizedBox(height: 16),
            Text(AppStrings.of(context).noInsightsYet,
              style: const TextStyle(
                  color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              'Watch a few videos and come back — your weekly recap will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppColors.white60, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Shared card chrome ────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.white06),
      ),
      child: child,
    );
  }
}

// ─── Hero card: total time + videos count ──────────────────────────

class _HeroCard extends StatelessWidget {
  final WatchInsights insights;
  const _HeroCard({required this.insights});

  @override
  Widget build(BuildContext context) {
    final h = insights.totalWatchTime.inHours;
    final m = insights.totalWatchTime.inMinutes.remainder(60);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppStrings.of(context).totalTimeWatched,
              style: const TextStyle(
                  color: AppColors.white60, fontSize: 12)),
          const SizedBox(height: 6),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '$h',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(
                  text: ' h ',
                  style: TextStyle(
                    color: AppColors.white60,
                    fontSize: 18,
                  ),
                ),
                TextSpan(
                  text: '$m',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(
                  text: ' min',
                  style: TextStyle(
                    color: AppColors.white60,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: 'Videos',
                  value: '${insights.videosWatched}',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Stat(
                  label: 'Active days',
                  value: '${insights.activeDays}',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  color: AppColors.white50, fontSize: 11)),
        ],
      ),
    );
  }
}

// ─── Streak card ───────────────────────────────────────────────────

class _StreakCard extends StatelessWidget {
  final WatchInsights insights;
  const _StreakCard({required this.insights});
  @override
  Widget build(BuildContext context) {
    final s = insights.currentStreakDays;
    final msg = s == 0
        ? 'Start a new streak today!'
        : s == 1
            ? "You've watched today — keep it going."
            : "$s days in a row — nice rhythm.";
    return _Card(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: (s > 0 ? AppColors.accentBlue : Colors.white)
                  .withOpacity(0.15),
              borderRadius: BorderRadius.circular(22),
            ),
            alignment: Alignment.center,
            child: Icon(
              s > 0 ? Icons.local_fire_department : Icons.bedtime_outlined,
              color: s > 0 ? AppColors.accentBlue : Colors.white70,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s == 0 ? 'No streak yet' : '$s-day streak',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(msg,
                    style: const TextStyle(
                        color: AppColors.white60,
                        fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 7-day sparkline ────────────────────────────────────────────────

class _SevenDayCard extends StatelessWidget {
  final WatchInsights insights;
  const _SevenDayCard({required this.insights});
  @override
  Widget build(BuildContext context) {
    final maxV = insights.lastSevenDaysMinutes
        .fold<int>(1, (a, b) => b > a ? b : a);
    const labels = ['6d', '5d', '4d', '3d', '2d', 'Yd', 'To'];
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppStrings.of(context).last7Days,
              style: const TextStyle(
                  color: AppColors.white60, fontSize: 12)),
          const SizedBox(height: 14),
          SizedBox(
            height: 86,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 7; i++) ...[
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (insights.lastSevenDaysMinutes[i] > 0)
                          Text(
                            '${insights.lastSevenDaysMinutes[i]}',
                            style: const TextStyle(
                                color: AppColors.white60,
                                fontSize: 10),
                          ),
                        const SizedBox(height: 2),
                        Container(
                          height: insights.lastSevenDaysMinutes[i] == 0
                              ? 4
                              : 4 +
                                  (insights.lastSevenDaysMinutes[i] /
                                          maxV) *
                                      60,
                          decoration: BoxDecoration(
                            color: insights.lastSevenDaysMinutes[i] == 0
                                ? AppColors.white06
                                : (i == 6
                                    ? AppColors.accentBlue
                                    : AppColors.accentBlue
                                        .withOpacity(0.5)),
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(labels[i],
                            style: const TextStyle(
                                color: AppColors.white40,
                                fontSize: 10)),
                      ],
                    ),
                  ),
                  if (i < 6) const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Most rewatched ────────────────────────────────────────────────

class _MostRewatchedCard extends StatelessWidget {
  final WatchInsights insights;
  const _MostRewatchedCard({required this.insights});
  @override
  Widget build(BuildContext context) {
    final e = insights.mostRewatched!;
    return _Card(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.white08,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.replay,
                color: AppColors.darkOnSurfaceMuted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppStrings.of(context).mostRewatched,
                    style: const TextStyle(
                        color: AppColors.white60, fontSize: 11)),
                const SizedBox(height: 2),
                Text(
                  e.videoTitle,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${e.watchCount} ${e.watchCount == 1 ? "watch" : "watches"}',
                  style: const TextStyle(
                      color: AppColors.white50, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Folder card ───────────────────────────────────────────────────

class _FolderCard extends StatelessWidget {
  final WatchInsights insights;
  const _FolderCard({required this.insights});
  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.accentBlue15,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.folder_open,
                color: AppColors.accentBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppStrings.of(context).mostWatchedFolder,
                    style: const TextStyle(
                        color: AppColors.white60, fontSize: 11)),
                const SizedBox(height: 2),
                Text(
                  insights.mostWatchedFolder!,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${insights.mostWatchedFolderCount} ${insights.mostWatchedFolderCount == 1 ? "play" : "plays"}',
                  style: const TextStyle(
                      color: AppColors.white50, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Completion card ───────────────────────────────────────────────

class _CompletionCard extends StatelessWidget {
  final WatchInsights insights;
  const _CompletionCard({required this.insights});
  @override
  Widget build(BuildContext context) {
    final pct = insights.averageCompletionPercent;
    final message = pct >= 75
        ? "You're a finisher."
        : pct >= 40
            ? "Solid follow-through."
            : "Plenty of films half-watched.";
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppStrings.of(context).averageCompletion,
              style: const TextStyle(
                  color: AppColors.white60, fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                pct.toStringAsFixed(0),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              const Text('%',
                  style: TextStyle(
                      color: AppColors.white60, fontSize: 16)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(message,
                    style: const TextStyle(
                        color: AppColors.white60, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (pct / 100).clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: Colors.white12,
              valueColor:
                  const AlwaysStoppedAnimation(AppColors.accentBlue),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Privacy footnote ──────────────────────────────────────────────

class _PrivacyFootnote extends StatelessWidget {
  const _PrivacyFootnote();
  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline,
            size: 12, color: AppColors.white40),
        SizedBox(width: 6),
        Expanded(
          child: Text(
            'These numbers are computed entirely on your device. Nothing is uploaded.',
            style: TextStyle(
                color: AppColors.white40,
                fontSize: 11,
                height: 1.4),
          ),
        ),
      ],
    );
  }
}
