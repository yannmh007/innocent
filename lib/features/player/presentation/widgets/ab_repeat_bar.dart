import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import '../shortcut_item.dart';
import 'player_ui.dart';

/// A-B repeat, as MX Player 3.4.3 shows it when its A-B shortcut is tapped
/// (the owner, 26 Nov 2026: "every shortcut as MX's"; reference lab run
/// 45862946745): a small card under the shortcut row on the right, its
/// name and a close, then [A] → [B]. A sets A where the film is; B sets B
/// after it and the loop starts; close lets both go. MX's measures on the
/// owner's phone sideways: 234 x 102 dp, the buttons 88 x 48, 12 dp in.
/// MX's B ran under the navigation buttons; this one keeps clear of them.
/// Innocent's colours: the card on the shade's black (60 %), a set point
/// on the accent with its time.
class ABRepeatBar extends StatelessWidget {
  const ABRepeatBar({
    super.key,
    required this.pointA,
    required this.pointB,
    required this.onA,
    required this.onB,
    required this.onClose,
    required this.format,
  });

  final Duration? pointA;
  final Duration? pointB;
  final VoidCallback onA;
  final VoidCallback onB;
  final VoidCallback onClose;
  final String Function(Duration) format;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return SizedBox(
      width: 234,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x99000000),
          borderRadius: BorderRadius.circular(12),
        ),
        child: DefaultTextStyle.merge(
          style: const TextStyle(shadows: PlayerUi.shadeInk),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      ShortcutItem.abRepeat.labelIn(s).replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: PlayerUi.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded,
                        size: 20, color: PlayerUi.textPrimary,
                        shadows: PlayerUi.shadeInk),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: _Point(
                          name: 'A',
                          at: pointA == null ? null : format(pointA!),
                          onTap: onA),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.arrow_forward_rounded,
                          size: 18, color: PlayerUi.textSecondary),
                    ),
                    Expanded(
                      child: _Point(
                          name: 'B',
                          at: pointB == null ? null : format(pointB!),
                          onTap: onB),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A or B: a 48 dp button, on the accent once set, with its time.
class _Point extends StatelessWidget {
  const _Point({required this.name, required this.at, required this.onTap});

  final String name;
  final String? at;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final set = at != null;
    return Semantics(
      button: true,
      selected: set,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: set ? PlayerUi.accent.withValues(alpha: 0.16) : PlayerUi.raised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: set ? PlayerUi.accent : Colors.transparent, width: 1.2),
          ),
          child: Text(
            set ? '$name  $at' : name,
            maxLines: 1,
            style: const TextStyle(
              color: PlayerUi.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}
