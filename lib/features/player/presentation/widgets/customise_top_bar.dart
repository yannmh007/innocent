import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// The icons the player's top bar can carry, in their order on the bar
/// (before ⋮). As MX 3.4.3's Customise Items offers them (the reference
/// lab, run 45862946745: Hardware Acceleration, Playing Queue, Audio Track,
/// Subtitles, Popup Window, Zoom), Innocent's own: the decoder, the playing
/// queue, ♪, CC, picture-in-picture, the screen mode.
enum TopBarItem {
  queue,
  audio,
  subtitle,
  decoder,
  pip,
  screenMode;

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
        TopBarItem.queue => Icons.queue_music,
        TopBarItem.audio => Icons.music_note,
        TopBarItem.subtitle => Icons.subtitles_outlined,
        TopBarItem.decoder => Icons.memory_rounded,
        TopBarItem.pip => Icons.picture_in_picture_alt_outlined,
        TopBarItem.screenMode => Icons.crop_landscape_outlined,
      };

  String labelIn(AppStrings s) => switch (this) {
        TopBarItem.queue => s.playingQueue,
        TopBarItem.audio => s.audioTrack,
        TopBarItem.subtitle => s.subtitle,
        TopBarItem.decoder => s.pmDecoder,
        TopBarItem.pip => s.pmPip,
        TopBarItem.screenMode => s.pmScreenMode,
      }
          .replaceAll('\n', ' ');
}

/// MX's Customise Items (its shortcut, 26 Nov 2026: "as MX"): a card over
/// the picture, its hint, then the top bar's icons in a row, each with a
/// check on it while it is on the bar; a tap takes it on or off; Cancel
/// leaves the bar as it was, Apply sets it. MX's card sits under the top
/// bar, centred, Cancel and APPLY at its foot. Innocent's colours: the card
/// on the shade's black, a chosen icon's check on the accent.
class CustomiseTopBarCard extends StatefulWidget {
  const CustomiseTopBarCard({
    super.key,
    required this.initial,
    required this.onApply,
    required this.onCancel,
  });

  final Set<TopBarItem> initial;
  final ValueChanged<Set<TopBarItem>> onApply;
  final VoidCallback onCancel;

  @override
  State<CustomiseTopBarCard> createState() => _CustomiseTopBarCardState();
}

class _CustomiseTopBarCardState extends State<CustomiseTopBarCard> {
  late Set<TopBarItem> _on = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final pad = MediaQuery.paddingOf(context);
    return Stack(
      children: [
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
        // Under the top bar, as MX's; it scrolls rather than run off a
        // short window (a phone sideways at 1.3x text, a split screen).
        Positioned(
          top: pad.top + 64,
          left: 16 + pad.left,
          right: 16 + pad.right,
          bottom: pad.bottom + 8,
          child: Align(
            alignment: Alignment.topCenter,
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xB3000000),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    child: DefaultTextStyle.merge(
                      style: const TextStyle(shadows: PlayerUi.shadeInk),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.pmCustomiseHint,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: PlayerUi.textPrimary, fontSize: 14),
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 4,
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
                          const SizedBox(height: 14),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Flexible(
                                child: PlayerDialogButton(
                                  label: s.cancel,
                                  onPressed: widget.onCancel,
                                ),
                              ),
                              const SizedBox(width: 12),
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

/// One icon of the card: a disc, its name, a check while it is on the bar.
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
          // Six to a row on MX's 480 dp card, as its one row.
          width: 68,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
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
                        right: -4,
                        top: -4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: PlayerUi.accent,
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(1),
                            child: Icon(Icons.check_rounded,
                                size: 14, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  item.labelIn(s),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: PlayerUi.tileLabel,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
