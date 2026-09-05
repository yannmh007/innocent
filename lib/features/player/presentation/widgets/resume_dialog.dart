import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

import '../../../../core/localization/app_strings.dart';
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
    if (widget.isAskMode) {
      return Positioned.fill(
        child: Container(
          color: Colors.black54,
          alignment: Alignment.center,
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 360),
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.darkSurface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppStrings.of(context).resumeTitle,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(AppStrings.of(context).resumeBody,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(AppStrings.of(context).savedAt(_fmt(widget.savedPosition)),
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Phase 45 (audit): "Use by default" checkbox lets the
                  // user persist their choice as the new resume_last
                  // setting (matches MX Player V3 `ask_resume.xml`).
                  InkWell(
                    onTap: () => setState(() {
                      _useByDefault = !_useByDefault;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: Checkbox(
                              value: _useByDefault,
                              onChanged: (v) => setState(() {
                                _useByDefault = v ?? false;
                              }),
                              activeColor: AppColors.accentBlue,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(AppStrings.of(context).useByDefault,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => widget.onStartOver(
                            useByDefault: _useByDefault),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        child: Text(AppStrings.of(context).startOver.toUpperCase(),
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      TextButton(
                        onPressed: () =>
                            widget.onResume(useByDefault: _useByDefault),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        child: Text(AppStrings.of(context).resume,
                          style: TextStyle(
                            color: AppColors.accentBlue,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Confirmation toast mode (legacy).
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          color: Colors.black87,
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => widget.onResume(useByDefault: false),
                tooltip: 'Dismiss',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(AppStrings.of(context).continueFromStopped,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => widget.onStartOver(useByDefault: false),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(AppStrings.of(context).startOver.toUpperCase(),
                  style: TextStyle(
                    color: AppColors.accentBlue,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
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
