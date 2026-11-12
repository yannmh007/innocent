import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// The Playing queue (⋮): what Next plays through — the film's folder, in
/// order — the playing one marked; a tap plays another.
///
/// 12 Nov 2026: it was handed only the film's own title, so it always
/// listed one video under "1 items" (English, and wrong), with a drag
/// handle on a row that could not be dragged. A film from the catalogue or
/// the network has no folder: the sheet shows it alone.
class PlayingQueueSheet extends StatelessWidget {
  final String currentTitle;
  final List<String> queue;
  final List<Duration> durations;
  final int currentIndex;
  final ValueChanged<int>? onPick;

  const PlayingQueueSheet({
    super.key,
    this.currentTitle = '',
    this.queue = const [],
    this.durations = const [],
    this.currentIndex = 0,
    this.onPick,
  });

  static Future<void> show(
    BuildContext context, {
    String currentTitle = '',
    List<String> queue = const [],
    List<Duration> durations = const [],
    int currentIndex = 0,
    ValueChanged<int>? onPick,
  }) {
    return showPlayerSheet<void>(
      context,
      builder: (sheet) => PlayingQueueSheet(
        currentTitle: currentTitle,
        queue: queue,
        durations: durations,
        currentIndex: currentIndex,
        onPick: onPick == null
            ? null
            : (i) {
                Navigator.of(sheet).pop();
                onPick(i);
              },
      ),
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final titles = queue.isEmpty
        ? [currentTitle.isEmpty ? s.pwCurrentVideo : currentTitle]
        : queue;
    final playing = queue.isEmpty ? 0 : currentIndex;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerSheetHeader(
          title: s.playingQueueTitle,
          trailing: Text(s.itemsCount(titles.length), style: PlayerUi.rowValue),
        ),
        Flexible(
          child: ListView.builder(
            // A short list is as tall as it is; a folder of hundreds fills
            // the sheet and is built as it scrolls, from the playing one.
            shrinkWrap: titles.length <= 12,
            controller: ScrollController(
              initialScrollOffset:
                  playing > 2 && titles.length > 12 ? (playing - 2) * 56.0 : 0,
            ),
            padding: EdgeInsets.fromLTRB(
                PlayerUi.pad(context) - 8, 8, PlayerUi.pad(context) - 8, 16),
            itemCount: titles.length,
            itemBuilder: (_, i) {
              final isPlaying = i == playing;
              final d = i < durations.length ? durations[i] : Duration.zero;
              return Semantics(
                selected: isPlaying,
                child: Material(
                  color:
                      isPlaying ? PlayerUi.accentContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap:
                        isPlaying || onPick == null ? null : () => onPick!(i),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 52),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 28,
                              child: isPlaying
                                  ? const Icon(Icons.equalizer_rounded,
                                      color: PlayerUi.accent, size: 20)
                                  : Text(
                                      '${i + 1}',
                                      textAlign: TextAlign.center,
                                      style: PlayerUi.rowValue.copyWith(
                                        fontFeatures: const [
                                          FontFeature.tabularFigures()
                                        ],
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                titles[i],
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: PlayerUi.rowTitle.copyWith(
                                  fontSize: 14,
                                  color: isPlaying
                                      ? PlayerUi.accent
                                      : PlayerUi.textPrimary,
                                ),
                              ),
                            ),
                            if (d > Duration.zero) ...[
                              const SizedBox(width: 12),
                              Text(
                                _fmt(d),
                                style: PlayerUi.rowValue.copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
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
