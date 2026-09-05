import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
/// Help screen — FAQ items and support contact
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const _faqItems = [
    (
      'How to play a video?',
      'Open the Local tab, browse to a folder, and tap any video to start playback.'
    ),
    (
      'How to change the decoder?',
      'During playback, tap the decoder badge (HW/SW) at the top right of the player screen, or go to Settings > Decoder.'
    ),
    (
      'How to add subtitles?',
      'During playback, tap the subtitle icon in the top shortcut row. You can load subtitle files from your device storage.'
    ),
    (
      'How to lock files in Private Folder?',
      'Long press a video or tap the 3-dot menu > "Lock in Private Folder". Set a PIN on first use.'
    ),
    (
      'How to use Background Play?',
      'Enable it in Settings > Player > Background Play. When you switch apps, audio will continue playing.'
    ),
    (
      'How to adjust playback speed?',
      'During playback, tap the "1X" badge at the top left, or use the speed slider by swiping the shortcut row.'
    ),
    (
      'How to transfer files?',
      'Go to the Transfer tab. Tap SEND to share files, or RECEIVE to get files from another device.'
    ),
    (
      'How to use gestures?',
      'Swipe up/down on the left side to adjust brightness. Swipe up/down on the right side to adjust volume. Swipe left/right to seek.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).help)),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _faqItems.length,
        itemBuilder: (_, i) {
          final (question, answer) = _faqItems[i];
          return ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            iconColor: AppColors.primaryBlue,
            collapsedIconColor: Colors.white38,
            title: Text(
              question,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
                child: Text(
                  answer,
                  style: TextStyle(
                    color: AppColors.white60,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
