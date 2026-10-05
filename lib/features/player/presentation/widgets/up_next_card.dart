import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';

/// The end-of-video card: "Up next" with the next title, Play now and a
/// close button, and — when autoplay is on and somebody has touched the
/// phone recently — a countdown that plays it by itself (Netflix's
/// post-play, YouTube's autoplay).
///
/// TEN SECONDS, NOT FIVE. Netflix moved to five because shorter countdowns
/// raise hours watched; the University of Chicago study of autoplay (2024)
/// found the same shorter window leaves "hardly enough time to reconsider".
/// Ten is long enough to read the title and decide, and the close button
/// is always there. With [askFirst] (three unattended in a row) there is no
/// countdown at all: "Still watching?" waits for a tap.
class UpNextCard extends StatefulWidget {
  const UpNextCard({
    super.key,
    required this.title,
    required this.onPlay,
    required this.onClose,
    this.countdown = const Duration(seconds: 10),
    this.autoplay = true,
    this.askFirst = false,
  });

  final String title;

  /// [byItself] is true when the countdown ran out.
  final void Function({required bool byItself}) onPlay;
  final VoidCallback onClose;
  final Duration countdown;
  final bool autoplay;
  final bool askFirst;

  @override
  State<UpNextCard> createState() => _UpNextCardState();
}

class _UpNextCardState extends State<UpNextCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock =
      AnimationController(vsync: this, duration: widget.countdown);
  bool _done = false;

  bool get _counting => widget.autoplay && !widget.askFirst;

  @override
  void initState() {
    super.initState();
    if (_counting) {
      _clock.forward();
      _clock.addStatusListener((s) {
        if (s == AnimationStatus.completed && !_done) {
          _done = true;
          widget.onPlay(byItself: true);
        }
      });
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  void _play() {
    if (_done) return;
    _done = true;
    widget.onPlay(byItself: false);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Material(
      color: const Color(0xE6202226),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 300,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.askFirst ? s.vhStillWatching : s.vhUpNext,
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white70, size: 20),
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onClose,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: AnimatedBuilder(
                    animation: _clock,
                    builder: (context, _) {
                      final left = (widget.countdown.inSeconds *
                              (1 - _clock.value))
                          .ceil();
                      final label = widget.askFirst
                          ? s.vhKeepWatching
                          : _counting
                              ? s.vhUpNextIn(left)
                              : s.vhPlayNow;
                      // The fill sweeping across the button IS the
                      // countdown (Netflix's colour wipe): one control,
                      // nothing extra to read.
                      return Stack(
                        children: <Widget>[
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: _counting ? _clock.value : 1,
                                // Light grey under white: the black label
                                // reads on both halves of the wipe.
                                backgroundColor: const Color(0xFFB8B8B8),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                    Colors.white),
                              ),
                            ),
                          ),
                          Material(
                            type: MaterialType.transparency,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: _play,
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: <Widget>[
                                    const Icon(Icons.play_arrow_rounded,
                                        color: Colors.black, size: 22),
                                    const SizedBox(width: 4),
                                    Text(label,
                                        style: const TextStyle(
                                            color: Colors.black,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
