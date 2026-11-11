import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

import '../../../../core/localization/app_strings.dart';

/// Right-side panel for subtitle options (Open / Settings / Online subtitles)
class SubtitlePanel extends StatelessWidget {
  final VoidCallback onOpen;
  final VoidCallback onSettings;
  final VoidCallback onTextStyle;
  final VoidCallback onLayout;
  final VoidCallback onOnlineSubtitles;
  final VoidCallback onDismiss;

  const SubtitlePanel({
    super.key,
    required this.onOpen,
    required this.onSettings,
    required this.onTextStyle,
    required this.onLayout,
    required this.onOnlineSubtitles,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final panelWidth = (width * 0.5).clamp(320.0, 480.0);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.opaque,
            child: Container(color: Colors.black54),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: panelWidth,
          child: Material(
            color: AppColors.playerOverlayDarker,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header row: title + online subtitles link
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
                    // Both texts give way, so a larger system font or a
                    // 320 dp phone does not push the link off the panel.
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          flex: 2,
                          child: Text(
                            AppStrings.of(context).subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          flex: 3,
                          child: TextButton(
                            onPressed: onOnlineSubtitles,
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                            ),
                            child: Text(
                              AppStrings.of(context).onlineSubtitles,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // The options scroll: a phone held sideways is about
                  // 320–360 dp tall, and four rows under the header did not
                  // fit it at a large font size (test/player_layout_test.dart).
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        _SubtitleOption(
                          icon: Icons.folder_open_outlined,
                          label: AppStrings.of(context).pwOpenFile,
                          onTap: onOpen,
                        ),
                        _SubtitleOption(
                          icon: Icons.subtitles_outlined,
                          label: AppStrings.of(context).pwSubTrack,
                          onTap: onSettings,
                        ),
                        // UX-3 (audit): in-player access to the (already
                        // comprehensive) subtitle styling screens — previously
                        // reachable only via global Settings.
                        _SubtitleOption(
                          icon: Icons.text_fields,
                          label: AppStrings.of(context).pwTextStyle,
                          onTap: onTextStyle,
                        ),
                        _SubtitleOption(
                          icon: Icons.format_align_center,
                          label: AppStrings.of(context).pwPosLayout,
                          onTap: onLayout,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SubtitleOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SubtitleOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(width: 20),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
