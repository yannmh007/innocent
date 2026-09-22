import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/router/routes.dart';
import '../data/api/offline_library.dart';
import 'video_hub_provider.dart';
import 'widgets/hub_states.dart';
import 'widgets/poster_image.dart';
import 'widgets/vh_insets.dart';
import '../domain/video_content.dart';
import 'video_hub_theme.dart';

/// What is kept on this device.
///
/// The Downloads tile on the account screen used to open a "coming soon"
/// message. This is the screen behind it.
///
/// EVERYTHING HERE WORKS WITH NO NETWORK, which is the whole point and the
/// reason the list is built from [OfflineLibrary] rather than from the
/// catalogue: a viewer opening this on a train has no server to ask what a
/// title is called, so the name, the Burmese name and the poster URL were all
/// copied onto the shelf at download time.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final itemsAsync = ref.watch(offlineItemsProvider);

    return Scaffold(
      backgroundColor: VH.canvas,
      appBar: AppBar(
        backgroundColor: VH.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(s.vhLibraryDownloads, style: VH.heading),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: VH.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: itemsAsync.when(
        // No error state worth its own screen: items() swallows a broken index
        // and returns an empty list, because a shelf that cannot be read looks
        // exactly like an empty one to the person holding the phone.
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => HubEmptyState(message: s.vhLibraryDownloadsHint),
        data: (items) {
          if (items.isEmpty) {
            return HubEmptyState(message: s.vhLibraryDownloadsHint);
          }
          return ListView.separated(
            padding: EdgeInsets.fromLTRB(
                VH.gutter, VH.s3, VH.gutter, VhInsets.scrollBottom(context)),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: VH.s2),
            itemBuilder: (context, i) => _Row(
              item: items[i],
              languageCode: s.locale.languageCode,
            ),
          );
        },
      ),
    );
  }
}

class _Row extends ConsumerWidget {
  final OfflineItem item;
  final String languageCode;

  const _Row({required this.item, required this.languageCode});

  String get _shownTitle {
    if (languageCode != 'my') return item.title;
    final mm = item.titleMm?.trim();
    return (mm == null || mm.isEmpty) ? item.title : mm;
  }

  static String _size(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () => _play(context),
      borderRadius: BorderRadius.circular(VH.rControl),
      child: Padding(
        padding: const EdgeInsets.all(VH.s2),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 76,
              height: 56,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: PosterImage(
                  mediaRef: item.posterUrl == null
                      ? MediaRef.none
                      : MediaRef(provider: 'url', locator: item.posterUrl!),
                  title: _shownTitle,
                ),
              ),
            ),
            const SizedBox(width: VH.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(_shownTitle,
                      style: VH.label.copyWith(fontSize: 14.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  Text(_size(item.bytes), style: VH.meta.copyWith(fontSize: 12)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: VH.textTertiary),
              onPressed: () => _confirmDelete(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the local file.
  ///
  /// `ephemeral: false` — unlike a stream, this path IS a stable identity, so
  /// a resume point keyed on it works and is worth keeping. And no `titleId`:
  /// the playback reporter would have no network to flush to for the whole
  /// session, and a device that came back online hours later would post a
  /// burst of events timestamped to a viewing nobody can place. Offline
  /// viewing is deliberately not measured rather than measured badly.
  void _play(BuildContext context) {
    context.push(Routes.player, extra: <String, dynamic>{
      'uri': item.path,
      'title': _shownTitle,
      // Still capture-protected: it is the same paid content it was online.
      'secure': true,
    });
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final s = AppStrings.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VH.surface1,
        title: Text(_shownTitle, style: VH.label),
        content: Text(s.vhDeleteDownloadBody, style: VH.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            // The destructive action is coloured from the app's own error
            // role rather than a hex literal invented here — VH has no
            // danger colour, and inventing one would put a second red in
            // the app that drifts from the first.
            child: Text(
              s.delete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await ref.read(offlineLibraryProvider).drop(item.titleId);
    ref.invalidate(offlineItemsProvider);
  }
}
