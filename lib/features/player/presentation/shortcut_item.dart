import 'package:flutter/material.dart';

/// All 15 shortcuts available in player shortcut row.
///
/// Phase 45 (audit): order RE-VERIFIED against MX Player V3 v2.13.4
/// screen recordings 180939 frame 11 (landscape expanded) and 180939
/// frame 24 (portrait expanded). The LANDSCAPE order, left-to-right
/// when expanded, is:
///
///   Mute → Sleep Timer → A-B Repeat → Mirror Mode → Vertical Flip →
///   Audio Effect → Equalizer → Speed (1X) → Screenshot →
///   Background Play → Screen Rotation → Loop
///
/// PORTRAIT additionally shows Night Mode, Customise Items, Shuffle
/// before Mute (frame 24 left side). To keep one canonical enum order
/// we put these at the front so portrait shows them; landscape ignores
/// them via [defaultLandscapeShortcuts] filtering.
enum ShortcutItem {
  // Portrait-only first three (frame 24).
  nightMode,
  customiseItems,
  shuffle,
  // Common to both orientations, in MX Player order.
  mute,
  sleepTimer,
  abRepeat,
  mirrorMode,
  verticalFlip,
  audioEffect,
  equalizer,
  playbackSpeed,
  screenshot,
  backgroundPlay,
  screenRotation,
  loop;

  String get label {
    switch (this) {
      case ShortcutItem.screenRotation:
        return 'Screen\nRotation';
      case ShortcutItem.playbackSpeed:
        return 'Speed';
      case ShortcutItem.backgroundPlay:
        return 'Background\nPlay';
      case ShortcutItem.loop:
        return 'Loop';
      case ShortcutItem.mute:
        return 'Mute';
      case ShortcutItem.shuffle:
        return 'Shuffle';
      case ShortcutItem.equalizer:
        return 'Equalizer';
      case ShortcutItem.audioEffect:
        return 'Audio\nEffect';
      case ShortcutItem.sleepTimer:
        return 'Sleep\nTimer';
      case ShortcutItem.abRepeat:
        return 'A - B\nRepeat';
      case ShortcutItem.nightMode:
        return 'Night\nMode';
      case ShortcutItem.customiseItems:
        return 'Customise\nItems';
      case ShortcutItem.screenshot:
        return 'Screenshot';
      case ShortcutItem.mirrorMode:
        return 'Mirror\nMode';
      case ShortcutItem.verticalFlip:
        return 'Vertical\nFlip';
    }
  }

  IconData get icon {
    switch (this) {
      case ShortcutItem.screenRotation:
        return Icons.screen_rotation;
      case ShortcutItem.playbackSpeed:
        return Icons.speed;
      case ShortcutItem.backgroundPlay:
        return Icons.headphones;
      case ShortcutItem.loop:
        return Icons.repeat;
      case ShortcutItem.mute:
        return Icons.volume_off;
      case ShortcutItem.shuffle:
        return Icons.shuffle;
      case ShortcutItem.equalizer:
        return Icons.tune;
      case ShortcutItem.audioEffect:
        return Icons.graphic_eq;
      case ShortcutItem.sleepTimer:
        return Icons.bedtime_outlined;
      case ShortcutItem.abRepeat:
        return Icons.swap_horiz;
      case ShortcutItem.nightMode:
        return Icons.nights_stay_outlined;
      case ShortcutItem.customiseItems:
        return Icons.edit_outlined;
      case ShortcutItem.screenshot:
        return Icons.photo_camera_outlined;
      case ShortcutItem.mirrorMode:
        return Icons.flip;
      case ShortcutItem.verticalFlip:
        return Icons.flip_camera_android_outlined;
    }
  }
}

/// Decoder type.
/// Phase 45 (audit): MX Player V3 exposes 4 decoder choices in the
/// long-press → Decoder dialog:
///   - Default → engine picks the optimal mode (the safest choice for
///                most users; matches MX Player's "Default" abbreviation)
///   - HW      → hardware decoding (auto-safe in libmpv)
///   - HW+     → hardware decoding allowing risky codecs (auto)
///   - SW      → pure software decoding (no hwdec)
enum DecoderType {
  defaultMode('Default'),
  hw('HW'),
  hwPlus('HW+'),
  sw('SW');

  final String label;
  const DecoderType(this.label);
}
