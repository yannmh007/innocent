import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// Resume banner / dialog (MX Player V3 parity, refined Phase 45 audit).
///
/// Has TWO modes:
///
/// 1. **Confirmation toast mode** ([isAskMode] = false): a thin bottom
///    banner that auto-dismisses after 5s. The video has ALREADY
///    auto-resumed from the saved position by the time this is shown —
///    the banner just confirms it and offers a "START OVER" escape hatch.
///    This mode is used when `resume_last` setting is set to 'resume'.
///
/// 2. **Ask mode** ([isAskMode] = true): a centered modal dialog with
///    the exact MX Player wording "Do you wish to resume from where you
///    stopped?" plus [Resume] and [Start over] buttons, and a
///    "Use by default" checkbox (Phase 45 audit, verified against
///    decompiled `ask_resume.xml`). The video has NOT yet been
///    auto-seeked — playback continues from t=0 until the user makes a
///    choice. This mode is used when `resume_last` setting is set to
///    'ask' (the MX Player default).
class ResumeDialog extends StatefulWidget {
  final Duration savedPosition;

  /// Tapped when the user picks Resume. Caller seeks to [savedPosition].
  final void Function({required bool useByDefault}) onResume;

  /// Tapped when the user picks Start over. Caller seeks to 0.
  final void Function({required bool useByDefault}) onStartOver;
  final bool isAskMode;

  const ResumeDialog({
    super.key,
    required this.savedPosition,
    required this.onResume,
    required this.onStartOver,
    this.isAskMode = false,
  });

  @override
  State<ResumeDialog> createState() => _ResumeDialogState();
}

class _ResumeDialogState extends State<ResumeDialog> {
  bool _useByDefault = false;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    if (widget.isAskMode) {
      // Stays until a choice is made: the film waits at 0 for it.
      return PlayerDialog(
        title: s.resumeTitle,
        icon: Icons.history_rounded,
        maxWidth: 380,
        actions: [
          PlayerDialogButton(
            label: s.startOver,
            onPressed: () => widget.onStartOver(useByDefault: _useByDefault),
          ),
          PlayerDialogButton(
            label: s.resume,
            primary: true,
            icon: Icons.play_arrow_rounded,
            onPressed: () => widget.onResume(useByDefault: _useByDefault),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(s.resumeBody, style: PlayerUi.body),
              const SizedBox(height: 4),
              Text(
                s.savedAt(_fmt(widget.savedPosition)),
                style: PlayerUi.rowValue.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 8),
              // Phase 45 (audit): "Use by default" persists the choice as
              // the resume_last setting (MX Player V3 `ask_resume.xml`).
              PanelCheckRow(
                label: s.useByDefault,
                value: _useByDefault,
                onChanged: (v) => setState(() => _useByDefault = v),
              ),
            ],
          ),
        ),
      );
    }

    // Confirmation mode: the film has already resumed. A card floating
    // above the controls, not a black strip over the seek bar.
    final insets = MediaQuery.paddingOf(context);
    return Positioned(
      left: 16 + insets.left,
      right: 16 + insets.right,
      bottom: 96 + insets.bottom,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Material(
            color: PlayerUi.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PlayerUi.tileRadius),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 8, 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: PlayerUi.textSecondary, size: 20),
                    onPressed: () => widget.onResume(useByDefault: false),
                    tooltip: s.dismiss,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      s.continueFromStopped,
                      style: const TextStyle(
                          color: PlayerUi.textPrimary, fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => widget.onStartOver(useByDefault: false),
                    style: TextButton.styleFrom(
                      foregroundColor: PlayerUi.accent,
                      minimumSize: const Size(48, 40),
                      shape: const StadiumBorder(),
                    ),
                    child: Text(
                      s.startOver,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
