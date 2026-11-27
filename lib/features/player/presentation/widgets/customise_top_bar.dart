import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// The controls the viewer may show or hide, in MX 3.4.3's Customise
/// Items order (the reference lab, runs 45862946745 and 45886561831:
/// Hardware Acceleration, Playing Queue, Audio Track, Subtitles, Popup
/// Window, Zoom). The first four sit on the top bar (in the bar's order:
/// queue, ♪, CC, decoder, before ⋮); Popup Window and Zoom are the bottom
/// row's last two buttons, picture-in-picture and the screen mode.
enum TopBarItem {
  decoder,
  queue,
  audio,
  subtitle,
  pip,
  screenMode;

  /// MX's own: every one but the playing queue.
  static const Set<TopBarItem> defaults = {
    decoder,
    audio,
    subtitle,
    pip,
    screenMode,
  };

  static Set<TopBarItem> parse(String raw) {
    final byName = {for (final e in TopBarItem.values) e.name: e};
    return {
      for (final n in raw.split('|'))
        if (byName[n.trim()] != null) byName[n.trim()]!,
    };
  }

  static String write(Set<TopBarItem> items) =>
      TopBarItem.values.where(items.contains).map((e) => e.name).join('|');

  IconData get icon => switch (this) {
        TopBarItem.decoder => Icons.memory_rounded,
        TopBarItem.queue => Icons.queue_music,
        TopBarItem.audio => Icons.music_note,
        TopBarItem.subtitle => Icons.subtitles_outlined,
        TopBarItem.pip => Icons.picture_in_picture_alt_outlined,
        TopBarItem.screenMode => Icons.crop_landscape_outlined,
      };

  String labelIn(AppStrings s) => switch (this) {
        TopBarItem.decoder => s.pmDecoder,
        TopBarItem.queue => s.playingQueue,
        TopBarItem.audio => s.audioTrack,
        TopBarItem.subtitle => s.subtitle,
        TopBarItem.pip => s.pmPip,
        TopBarItem.screenMode => s.pmScreenMode,
      }
          .replaceAll('\n', ' ');
}

/// MX's Customise Items (its shortcut; the owner, 26 Nov 2026: "as MX"):
/// the controls stay, the film dimmed under them, each place a control
/// can be shown in marked with a dashed box ([EditSlot]); over them a card
/// with its hint, the six controls in a row, each with a check while it is
/// shown, and Cancel / Apply. A tap on one takes it on or off; Cancel (or
/// a tap outside) leaves the controls as they were. MX's measures on the
/// owner's phone sideways (run 45886561831): the card 567.5 dp wide,
/// centred, 2.6 dp under the top bar; 25.6 dp in; a control 86 dp wide,
/// its disc 40.5. Innocent's colours: the shade's black, the accent's
/// check, Innocent's dialog buttons.
class CustomiseTopBarCard extends StatefulWidget {
  const CustomiseTopBarCard({
    super.key,
    required this.initial,
    required this.top,
    required this.onApply,
    required this.onCancel,
  });

  final Set<TopBarItem> initial;

  /// Where the card's top goes: just under the top bar.
  final double top;
  final ValueChanged<Set<TopBarItem>> onApply;
  final VoidCallback onCancel;

  @override
  State<CustomiseTopBarCard> createState() => _CustomiseTopBarCardState();
}

class _CustomiseTopBarCardState extends State<CustomiseTopBarCard> {
  late final Set<TopBarItem> _on = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final pad = MediaQuery.paddingOf(context);
    return Stack(
      children: [
        // Everything under it: a tap cancels (MX's), and the controls
        // under the card take no tap meanwhile.
        Positioned.fill(
          child: Semantics(
            label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
            child: GestureDetector(
              onTap: widget.onCancel,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        // It scrolls rather than run off a short window (a phone sideways
        // at 1.3x text, a split screen).
        Positioned(
          top: widget.top,
          left: 16 + pad.left,
          right: 16 + pad.right,
          bottom: pad.bottom + 8,
          child: Align(
            alignment: Alignment.topCenter,
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 568),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xB3000000),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(shadows: PlayerUi.ink),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.pmCustomiseHint,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: PlayerUi.textPrimary, fontSize: 14),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            alignment: WrapAlignment.center,
                            runSpacing: 8,
                            children: [
                              for (final item in TopBarItem.values)
                                _Choice(
                                  item: item,
                                  on: _on.contains(item),
                                  onTap: () => setState(() {
                                    _on.contains(item)
                                        ? _on.remove(item)
                                        : _on.add(item);
                                  }),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Flexible(
                                child: PlayerDialogButton(
                                  label: s.cancel,
                                  onPressed: widget.onCancel,
                                ),
                              ),
                              const SizedBox(width: 17),
                              Flexible(
                                child: PlayerDialogButton(
                                  label: s.apply,
                                  primary: true,
                                  onPressed: () => widget.onApply({..._on}),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One control of the card: a disc, its name, a check while it is shown.
class _Choice extends StatelessWidget {
  const _Choice({required this.item, required this.on, required this.onTap});

  final TopBarItem item;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Semantics(
      button: true,
      selected: on,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          // MX's 86: six to a row on its card.
          width: 86,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 40.5,
                      height: 40.5,
                      decoration: BoxDecoration(
                        color: const Color(0x4D000000),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: on ? PlayerUi.accent : PlayerUi.tileRing,
                            width: 1.2),
                      ),
                      child: Icon(item.icon,
                          size: 22, color: PlayerUi.textPrimary),
                    ),
                    if (on)
                      const Positioned(
                        right: -2,
                        top: -2,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: PlayerUi.accent,
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(1),
                            child: Icon(Icons.check_rounded,
                                size: 12, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  item.labelIn(s),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: PlayerUi.tileLabelIn(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// While Customise Items is open: a control the viewer can show or hide,
/// in MX's dashed 40.5 dp box (its edit_p1..p5).
class EditSlot extends StatelessWidget {
  const EditSlot({super.key, required this.editing, required this.child});

  final bool editing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!editing) return child;
    return Stack(
      alignment: Alignment.center,
      children: [
        child,
        const IgnorePointer(
          child: SizedBox(
            width: 40.5,
            height: 40.5,
            child: CustomPaint(painter: _DashedBox()),
          ),
        ),
      ],
    );
  }
}

class _DashedBox extends CustomPainter {
  const _DashedBox();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = PlayerUi.textPrimary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, const Radius.circular(4)));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 7) {
        canvas.drawPath(metric.extractPath(d, d + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox oldDelegate) => false;
}
