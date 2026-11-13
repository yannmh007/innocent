import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'player_ui.dart';

/// A playback error: a card in the middle of the dimmed picture saying what
/// went wrong, with the two ways on — try again, or go back. A tap beside
/// it (or Back) puts it away.
///
/// 12 Nov 2026: it was a red slab 80 dp from the top, over the shortcut
/// row, with a 20 dp ✕ and two small buttons — the loudest thing the player
/// ever drew. The owner's screenshot of it was the first of the four that
/// asked for a calmer, premium player.
class PlayerErrorCard extends StatelessWidget {
  const PlayerErrorCard({
    super.key,
    required this.title,
    required this.message,
    required this.retryLabel,
    required this.backLabel,
    required this.onRetry,
    required this.onBack,
    required this.onDismiss,
    this.modal = true,
    this.top = 16,
  });

  final String title;
  final String message;
  final String retryLabel;
  final String backLabel;
  final VoidCallback onRetry;
  final VoidCallback onBack;
  final VoidCallback onDismiss;

  /// The film has stopped: the card in the middle of the dimmed picture,
  /// the controls away until it is answered. False while the film still
  /// moves (libmpv logged something it survived): the card sits at [top],
  /// no scrim, with a ✕, and the controls stay in reach.
  final bool modal;
  final double top;

  static const Color _warning = Color(0xFFFFB74D);

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final card = PlayerGlass(
      borderRadius: BorderRadius.circular(PlayerUi.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: (modal ? PlayerUi.danger : _warning)
                          .withValues(alpha: 0.16),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                        modal
                            ? Icons.error_outline_rounded
                            : Icons.warning_amber_rounded,
                        color: modal ? PlayerUi.danger : _warning,
                        size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(title, style: PlayerUi.title),
                    ),
                  ),
                  if (!modal)
                    IconButton(
                      onPressed: onDismiss,
                      tooltip: MaterialLocalizations.of(context)
                          .closeButtonTooltip,
                      icon: const Icon(Icons.close_rounded,
                          size: 20, color: PlayerUi.textSecondary),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // The message scrolls rather than pushing the buttons off a
            // phone held sideways at a large font size.
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(right: 8),
                child: Text(message, style: PlayerUi.body),
              ),
            ),
            const SizedBox(height: 14),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 8,
              overflowSpacing: 4,
              children: [
                TextButton(
                  onPressed: onBack,
                  style: TextButton.styleFrom(
                    foregroundColor: PlayerUi.textPrimary,
                    minimumSize: const Size(64, 44),
                    shape: const StadiumBorder(),
                  ),
                  child: Text(backLabel),
                ),
                FilledButton.icon(
                  onPressed: onRetry,
                  style: FilledButton.styleFrom(
                    backgroundColor: PlayerUi.accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(64, 44),
                    shape: const StadiumBorder(),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(retryLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    // Said when it appears: TalkBack reads a live region as it arrives.
    final announced = Semantics(
      liveRegion: true,
      container: true,
      child: card,
    );
    if (!modal) {
      return Positioned(
        top: top + safe.top,
        left: 16 + safe.left,
        right: 16 + safe.right,
        child: Center(
          child: ConstrainedBox(
            // As tall as the screen leaves below it: a fixed 260 cut a
            // Burmese title of two lines and the stacked buttons on a
            // 320 dp phone at the largest font.
            constraints: BoxConstraints(
              maxWidth: 480,
              maxHeight: math.max(
                  160.0,
                  MediaQuery.sizeOf(context).height -
                      top -
                      safe.top -
                      safe.bottom -
                      16),
            ),
            child: announced,
          ),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: Semantics(
            label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
            child: GestureDetector(
              onTap: onDismiss,
              behavior: HitTestBehavior.opaque,
              child: const ColoredBox(color: PlayerUi.scrim),
            ),
          ),
        ),
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16 + safe.left,
              16 + safe.top,
              16 + safe.right,
              16 + safe.bottom,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: announced,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
