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
                    child: Row(
                      children: [
                        Text(AppStrings.of(context).subtitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: onOnlineSubtitles,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                          ),
                          child: Text(AppStrings.of(context).onlineSubtitles,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _SubtitleOption(
                    icon: Icons.folder_open_outlined,
                    label: 'Open file',
                    onTap: onOpen,
                  ),
                  _SubtitleOption(
                    icon: Icons.subtitles_outlined,
                    label: 'Subtitle track',
                    onTap: onSettings,
                  ),
                  // UX-3 (audit): in-player access to the (already
                  // comprehensive) subtitle styling screens — previously
                  // reachable only via global Settings.
                  _SubtitleOption(
                    icon: Icons.text_fields,
                    label: 'Text style',
                    onTap: onTextStyle,
                  ),
                  _SubtitleOption(
                    icon: Icons.format_align_center,
                    label: 'Position & layout',
                    onTap: onLayout,
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
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
