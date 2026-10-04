import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/tablet_constrained_width.dart';
import '../../local_browser/domain/video.dart';
import '../../local_browser/presentation/library_provider.dart';
import '../../local_browser/presentation/grid_tiles.dart';
import '../../local_browser/presentation/video_list_item.dart';
import '../../user_data/presentation/history_screen.dart';
import '../../user_data/user_data_providers.dart';
import '../../video_hub/domain/byte_size.dart';

import '../../../core/localization/app_strings.dart';
/// What Android says about this phone's storage — see "storageSummary" in
/// MainActivity. Every size is in bytes; -1 means "not known" (no permission
/// for that kind of media, or the read failed), and the screen says so
/// rather than printing a number.
class StorageSummary {
  const StorageSummary({
    required this.total,
    required this.free,
    required this.video,
    required this.audio,
    required this.image,
  });

  final int total, free, video, audio, image;

  int get used => total - free;

  static const MethodChannel _channel = MethodChannel('mx_clone/media_scan');

  static Future<StorageSummary?> read() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('storageSummary');
      if (m == null) return null;
      int v(String k) => (m[k] as num?)?.toInt() ?? -1;
      return StorageSummary(
        total: v('total'),
        free: v('free'),
        video: v('video'),
        audio: v('audio'),
        image: v('image'),
      );
    } catch (_) {
      return null;
    }
  }
}

final storageSummaryProvider =
    FutureProvider.autoDispose<StorageSummary?>((ref) => StorageSummary.read());

/// The library's videos that have never been played, newest first.
List<Video> unplayedVideos(List<Video> all, Iterable<String> playedUris) {
  String norm(String u) {
    var x = u.trim();
    if (x.startsWith('file://')) {
      try {
        x = Uri.parse(x).toFilePath();
      } catch (_) {
        x = x.replaceFirst('file://', '');
      }
    }
    return x;
  }

  final played = {for (final u in playedUris) norm(u)};
  final out = [for (final v in all) if (!played.contains(norm(v.uri))) v];
  out.sort((a, b) {
    final da = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
    final db = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
    return db.compareTo(da);
  });
  return out;
}

enum _Sheet { largest, recent, unplayed }

/// Media Manager, laid out as MX Player's (UI PDF page 9): the phone's
/// storage, three shortcuts, and the videos not played yet.
///
/// EVERY NUMBER HERE IS REAL. Until 1.64.54 this screen was the mock-up it
/// was drawn from: "0.91 TB of 1.02 TB", "621 GB" of video and "592 GB can be
/// cleaned up" on every phone, a Clean button that only said "Scanning…",
/// a Recently Played card that only said "Opening…", and four empty boxes
/// under Haven't Played. The storage figures now come from Android, the
/// clean-up banner is gone (there is no cleaner behind it to promise), and
/// both cards and the grid open real lists.
class MediaManagerScreen extends ConsumerWidget {
  const MediaManagerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final summary = ref.watch(storageSummaryProvider);
    final library = ref.watch(allVideosProvider);
    final history = ref.watch(historyProvider);
    final unplayed = library.whenData(
        (all) => unplayedVideos(all, history.map((e) => e.videoUri)));
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(s.mediaManager)),
      // A phone-width column on a tablet or TV, as the settings screens.
      body: TabletConstrainedWidth(
        maxWidth: 840,
        child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ─── STORAGE CARD ───
          _StorageCard(summary: summary.valueOrNull, loading: summary.isLoading),
          const SizedBox(height: 16),

          // ─── 3 SHORTCUTS (as dark surface cards, MX parity) ───
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _shortcutCard(
                  Icons.play_circle,
                  Icons.access_time,
                  s.mmRecentlyPlayed,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const HistoryScreen()),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _shortcutCard(
                  Icons.pie_chart,
                  null,
                  s.mmLargeFiles,
                  // Audit P3: now scans real file sizes and lists the
                  // biggest videos (sizeBytes is lazy/0 in the library,
                  // so we stat each file on demand here).
                  onTap: () => _showVideoSheet(context, ref, _Sheet.largest),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _shortcutCard(
                  Icons.add_circle,
                  Icons.access_time,
                  s.recentlyAdded,
                  // Audit P3: now sorts the library by dateAdded
                  // (createDateTime) and shows the newest videos.
                  onTap: () => _showVideoSheet(context, ref, _Sheet.recent),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ─── HAVEN'T PLAYED ───
          InkWell(
            onTap: () => _showVideoSheet(context, ref, _Sheet.unplayed),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      s.mmHaventPlayed,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if ((unplayed.valueOrNull?.length ?? 0) > 0)
                    Text('${unplayed.valueOrNull!.length}',
                        style: const TextStyle(
                            color: AppColors.white50, fontSize: 13)),
                  const Icon(Icons.chevron_right, color: AppColors.white50),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          unplayed.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) => const SizedBox.shrink(),
            data: (vids) {
              if (vids.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    (library.valueOrNull?.isEmpty ?? true)
                        ? s.noVideosFound
                        : s.mmAllPlayed,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.white55),
                  ),
                );
              }
              final shown = vids.take(wide ? 6 : 4).toList();
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: VideoGridDelegate(
                  textScaler: MediaQuery.textScalerOf(context),
                  crossAxisSpacing: 16,
                ),
                itemCount: shown.length,
                itemBuilder: (_, i) => VideoGridTile(
                  video: shown[i],
                  onTap: () => _play(context, shown[i]),
                ),
              );
            },
          ),
        ],
      ),
      ),
    );
  }

  static void _play(BuildContext context, Video v) {
    context.push(Routes.player, extra: {'uri': v.uri, 'title': v.title});
  }

  // Phase 30: Rectangular dark-surface card with a stacked icon at top
  // and label below — replaces the floating circular avatars.
  static Widget _shortcutCard(
      IconData primary, IconData? overlay, String label,
      {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(
          color: AppColors.darkSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: Stack(
                children: [
                  Center(
                  child: Icon(primary,
                      color: AppColors.primaryBlue, size: 36),
                ),
                if (overlay != null)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: AppColors.primaryBlue,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(overlay,
                          color: Colors.white, size: 12),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    ),
    );
  }

  /// Audit P3: shared bottom sheet for "Large Files" (scans real file
  /// sizes), "Recently Added" (sorts by dateAdded) and "Haven't Played". Reads the library
  /// once, builds the list, and lets the user tap straight into playback.
  static void _showVideoSheet(BuildContext context, WidgetRef ref, _Sheet kind) {
    // Build the list ONCE, before the sheet opens. DraggableScrollableSheet's
    // builder runs on every drag frame, so creating the future inside it made
    // the whole library re-read (and, for "Largest", re-stat every file) dozens
    // of times a second while dragging — enough to lock the app up.
    final listFuture = _buildList(ref, kind);
    final s = AppStrings.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (ctx, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.white20,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                          switch (kind) {
                            _Sheet.largest => Icons.pie_chart,
                            _Sheet.recent => Icons.add_circle,
                            _Sheet.unplayed => Icons.video_library_outlined,
                          },
                          color: AppColors.accentBlue,
                          size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          switch (kind) {
                            _Sheet.largest => s.mmLargestVideos,
                            _Sheet.recent => s.recentlyAdded,
                            _Sheet.unplayed => s.mmHaventPlayed,
                          },
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<Video>>(
                    future: listFuture,
                    builder: (ctx, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Center(
                            child: CircularProgressIndicator());
                      }
                      final vids = snap.data ?? const <Video>[];
                      if (vids.isEmpty) {
                        return Center(
                          child: Text(AppStrings.of(context).noVideosFound,
                              style: const TextStyle(color: AppColors.white55)),
                        );
                      }
                      return ListView.builder(
                        controller: scrollController,
                        itemCount: vids.length,
                        itemBuilder: (ctx, i) {
                          final v = vids[i];
                          return VideoListItem(
                            video: v,
                            onTap: () {
                              Navigator.of(sheetCtx).pop();
                              _play(context, v);
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Build the list for the sheet. Large Files stats each file's real
  /// size (the library leaves sizeBytes at 0 for speed) and returns the
  /// top 100 by size; Recently Added sorts by dateAdded descending.
  static Future<List<Video>> _buildList(WidgetRef ref, _Sheet kind) async {
    final all = await ref.read(allVideosProvider.future);
    if (kind == _Sheet.unplayed) {
      return unplayedVideos(
          all, ref.read(historyProvider).map((e) => e.videoUri));
    }
    if (kind == _Sheet.recent) {
      final sorted = [...all]..sort((a, b) {
          final da = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          final db = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          return db.compareTo(da);
        });
      return sorted.take(100).toList();
    }
    // Read sizes in bounded batches. `Future.wait` over the whole library
    // opened one file handle per video at once, which on a large library
    // spikes memory and can exhaust the descriptor limit; 48 at a time is
    // still fully parallel but stays well inside safe limits.
    final sized = <Video>[];
    const batch = 48;
    for (var i = 0; i < all.length; i += batch) {
      final slice = all.skip(i).take(batch).toList();
      final part = await Future.wait(slice.map((v) async {
        try {
          final len = await File(v.uri).length();
          return v.copyWith(sizeBytes: len);
        } catch (_) {
          return v.copyWith(sizeBytes: 0);
        }
      }));
      sized.addAll(part);
    }
    sized.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    return sized.where((v) => v.sizeBytes > 0).take(100).toList();
  }
}

/// The phone's storage: how full, how much is free, and what videos, music
/// and pictures take — MX's card, with Android's numbers.
class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.summary, required this.loading});

  final StorageSummary? summary;
  final bool loading;

  static const _orange = Color(0xFFFF9800);

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final m = summary;
    final known = m != null && m.total > 0 && m.free >= 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title and figures share a line when they fit and take two when
          // they do not (a 320 dp phone, Burmese, a large system font).
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(s.deviceStorage,
                  style: const TextStyle(color: Colors.white70, fontSize: 14)),
              if (known)
                Text(
                  s.mmUsedOf(formatBytes(m.used), formatBytes(m.total)),
                  style: const TextStyle(
                    color: _orange,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                )
              else if (!loading)
                Text(s.mmStorageUnknown,
                    style: const TextStyle(
                        color: AppColors.white50, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: LinearProgressIndicator(
                // Indeterminate while Android answers; empty if it cannot.
                value: loading
                    ? null
                    : known
                        ? (m.used / m.total).clamp(0.0, 1.0)
                        : 0,
                backgroundColor: AppColors.white10,
                valueColor: const AlwaysStoppedAnimation<Color>(_orange),
              ),
            ),
          ),
          if (known) ...[
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text(s.mmFree(formatBytes(m.free)),
                  style:
                      const TextStyle(color: AppColors.white50, fontSize: 11)),
            ),
          ],
          const SizedBox(height: 12),
          // Videos / Music / Images with dividers (MX parity). No
          // IntrinsicHeight: each column decides its layout from its width.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _TypeColumn(Icons.play_circle_outline, s.mmVideos, m?.video,
                  s.mmNoAccess),
              Container(width: 1, height: 36, color: AppColors.white08),
              _TypeColumn(
                  Icons.music_note, s.mmMusic, m?.audio, s.mmNoAccess),
              Container(width: 1, height: 36, color: AppColors.white08),
              _TypeColumn(
                  Icons.image_outlined, s.images, m?.image, s.mmNoAccess),
            ],
          ),
        ],
      ),
    );
  }
}

/// One of the three size columns. Icon beside the text where a column has
/// room, above it where it does not — on a 320 dp phone a third of the card
/// is 85 dp, and the icon beside it left "Vide / o" to wrap a letter at a
/// time.
class _TypeColumn extends StatelessWidget {
  const _TypeColumn(this.icon, this.label, this.bytes, this.noAccess);

  final IconData icon;
  final String label;
  final int? bytes;
  final String noAccess;

  @override
  Widget build(BuildContext context) {
    final b = bytes;
    final value = b == null ? '—' : (b < 0 ? noAccess : formatBytes(b));
    final badge = Container(
      width: 28,
      height: 28,
      decoration: const BoxDecoration(
        color: AppColors.white08,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: AppColors.white70, size: 16),
    );
    final texts = <Widget>[
      Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
      const SizedBox(height: 2),
      Text(value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white54, fontSize: 11)),
    ];
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: LayoutBuilder(builder: (context, c) {
          final room = c.maxWidth - 36;
          final beside = room >=
              MediaQuery.textScalerOf(context).scale(64);
          if (beside) {
            return Row(children: [
              badge,
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: texts,
                ),
              ),
            ]);
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              badge,
              const SizedBox(height: 6),
              ...texts,
            ],
          );
        }),
      ),
    );
  }
}
