import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../user_data/user_data_providers.dart';
import '../player_provider.dart';
import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// Bottom sheet listing bookmarks for the current video with tap-to-seek
class BookmarksSheet extends ConsumerWidget {
  final String videoUri;
  final ValueChanged<Duration> onSeek;

  const BookmarksSheet({
    super.key,
    required this.videoUri,
    required this.onSeek,
  });

  /// Audit fix (B1): pause playback while the bookmark list is open
  /// (frame-stable preview when the user taps a bookmark) and resume
  /// only if we were the ones who paused.
  static Future<void> show(
    BuildContext context,
    WidgetRef ref, {
    required String videoUri,
    required ValueChanged<Duration> onSeek,
  }) async {
    final controller = ref.read(playerControllerProvider.notifier);
    final wasPlaying = ref.read(playerControllerProvider).isPlaying;
    if (wasPlaying) {
      await controller.pause();
    }
    // `pause()` is an await, so the player screen can go away (back gesture,
    // PiP hand-off, swipe-kill) before the sheet ever opens. This is a static
    // method on a StatelessWidget, so `context.mounted` is the only check
    // available — there is no State to ask.
    //
    // Returning here deliberately leaves playback PAUSED and does not resume.
    // The alternative — undoing our own pause — would start audio playing
    // under a screen the user has just left, which is the worse of the two
    // surprises. A paused player is recoverable with one tap; unexpected
    // sound coming out of a phone is not.
    if (!context.mounted) return;
    await showPlayerSheet<void>(
      context,
      builder: (_) => BookmarksSheet(videoUri: videoUri, onSeek: onSeek),
    );
    if (wasPlaying) {
      try {
        await controller.play();
      } catch (e) { if (kDebugMode) debugPrint('bookmarks_sheet.best-effort: $e'); }
    }
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The list itself, watched: watching only the notifier never rebuilt,
    // so a bookmark deleted with its ✕ stayed on the list until the sheet
    // was opened again (12 Nov 2026).
    ref.watch(bookmarksProvider);
    final bookmarks = ref.read(bookmarksProvider.notifier).forVideo(videoUri);
    final s = AppStrings.of(context);
    final pad = PlayerUi.pad(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerSheetHeader(
          title: s.bookmarksTitle,
          trailing: bookmarks.isEmpty
              ? null
              : Text(s.itemsCount(bookmarks.length), style: PlayerUi.rowValue),
        ),
        if (bookmarks.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
            child: Column(
              children: [
                const Icon(Icons.bookmark_border_rounded,
                    size: 36, color: PlayerUi.textDisabled),
                const SizedBox(height: 10),
                Text(
                  s.pwNoBookmarks,
                  textAlign: TextAlign.center,
                  style: PlayerUi.body,
                ),
              ],
            ),
          )
        else
          // The list gives way when the sheet is short (a phone held
          // sideways, or a 320 dp one): it scrolls instead of running off
          // the screen.
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.fromLTRB(pad - 8, 8, pad - 12, 16),
              itemCount: bookmarks.length,
              itemBuilder: (_, i) {
                final b = bookmarks[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    onSeek(b.position);
                    Navigator.of(context).pop();
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 52),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.bookmark_rounded,
                              size: 20, color: PlayerUi.accent),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _fmt(b.position),
                                  style: const TextStyle(
                                    color: PlayerUi.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    fontFeatures: [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                                ),
                                if (b.label != null)
                                  Text(b.label!, style: PlayerUi.rowValue),
                              ],
                            ),
                          ),
                          IconButton(
                            // It deletes the bookmark: TalkBack said "Close".
                            tooltip: s.delete,
                            icon: const Icon(Icons.close_rounded,
                                color: PlayerUi.textSecondary, size: 20),
                            onPressed: () => ref
                                .read(bookmarksProvider.notifier)
                                .delete(b.id),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
