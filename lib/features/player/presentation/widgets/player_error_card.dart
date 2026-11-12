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
  });

  final String title;
  final String message;
  final String retryLabel;
  final String backLabel;
  final VoidCallback onRetry;
  final VoidCallback onBack;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final card = Material(
      color: PlayerUi.surface,
      shape: PlayerUi.dialogShape,
      clipBehavior: Clip.antiAlias,
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
                    decoration: const BoxDecoration(
                      color: Color(0x29FF6B6B),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.error_outline_rounded,
                        color: PlayerUi.danger, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(title, style: PlayerUi.title),
                    ),
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
                child: card,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
