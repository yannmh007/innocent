import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/services/preferences/extra_settings_service.dart';
import '../../../user_data/user_data_providers.dart';
import '../../domain/new_badge.dart';
import '../library_provider.dart';
import '../../../../core/utils/async_value_extensions.dart';

import '../../../../core/localization/app_strings.dart';
/// Horizontal carousel of recently-added videos (last 7 days).
class RecentlyAddedSection extends ConsumerWidget {
  const RecentlyAddedSection({super.key});

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allVideos = ref.watch(allVideosProvider);
    final playedUris = ref.watch(playedUrisProvider);
    // Same window the NEW tag uses, so this row and the badges agree instead
    // of one being hard-coded to seven days while the other follows Settings.
    final windowDays = ref
        .watch(extraSettingsProvider)
        .getInt(IntSetting.newTaggedPeriod);

    return allVideos.whenOrFallback(
      data: (videos) {
        final effectiveDays = windowDays > 0 ? windowDays : 7;
        final now = DateTime.now();
        final cutoff = now.subtract(Duration(days: effectiveDays));
        // BUG FIX — `.take(10)` used to run BEFORE the sort, so this was not
        // "the ten most recent videos" at all: it took the first ten the
        // library happened to hand over and then sorted those ten among
        // themselves. Copy ten new episodes onto a phone with a large library
        // and the row could miss every one of them. Filter, sort, then take.
        //
        // It also measured against dateAdded alone; freshestDate is the later
        // of "copied" and "modified", which is what MX Player's window means.
        final recent = videos
            .where((v) {
              final d = v.freshestDate;
              return d != null && d.isAfter(cutoff);
            })
            .toList()
          ..sort((a, b) => (b.freshestDate ?? DateTime(0))
              .compareTo(a.freshestDate ?? DateTime(0)));
        final shown = recent.take(10).toList();

        if (shown.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.fiber_new_outlined,
                        color: AppColors.success, size: 18),
                    const SizedBox(width: 8),
                    Text(AppStrings.of(context).recentlyAdded,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) {
                    final v = shown[i];
                    // The badge follows the real rule. It used to be painted
                    // unconditionally on every tile in this row, so a video
                    // you had just finished watching still announced itself as
                    // new — the exact complaint the tag exists to avoid.
                    // The video stays in the row either way: "recently added"
                    // is a fact about the file, "NEW" is a fact about you.
                    final isNew = NewBadge.applies(
                      video: v,
                      periodDays: windowDays,
                      playedUris: playedUris,
                      normalize: normalizeMediaUri,
                      now: now,
                    );
                    return GestureDetector(
              key: ValueKey(v.uri),
                      onTap: () => context.push(
                        Routes.player,
                        extra: {'uri': v.uri, 'title': v.title},
                      ),
                      child: SizedBox(
                        width: 140,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Stack(
                              children: [
                                Container(
                                  height: 82,
                                  decoration: BoxDecoration(
                                    color: AppColors.darkSurfaceVariant,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  alignment: Alignment.center,
                                  child: const Icon(
                                    Icons.movie_outlined,
                                    color: Colors.white38,
                                    size: 32,
                                  ),
                                ),
                                if (isNew)
                                Positioned(
                                  top: 4,
                                  left: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: AppColors.success,
                                      borderRadius:
                                          BorderRadius.circular(2),
                                    ),
                                    child: Text(AppStrings.of(context).newBadge,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  bottom: 4,
                                  right: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color:
                                          AppColors.black65,
                                      borderRadius:
                                          BorderRadius.circular(2),
                                    ),
                                    child: Text(
                                      _fmtDuration(v.duration),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              v.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}
