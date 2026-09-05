import 'package:flutter/material.dart';

import '../../../../core/services/video_player/models/audio_track_info.dart';
import '../../../../core/services/video_player/models/subtitle_track_info.dart';
import '../../../../core/theme/app_colors.dart';

import '../../../../core/localization/app_strings.dart';
/// Bottom sheet for selecting audio or subtitle tracks
class TrackSelectionSheet<T> extends StatelessWidget {
  final String title;
  final List<T> tracks;
  final T? currentTrack;
  final String Function(T) labelFor;
  final ValueChanged<T?> onSelect;
  final VoidCallback? onLoadExternal; // null for audio
  final bool allowNone;

  const TrackSelectionSheet({
    super.key,
    required this.title,
    required this.tracks,
    required this.currentTrack,
    required this.labelFor,
    required this.onSelect,
    this.onLoadExternal,
    this.allowNone = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (allowNone)
                    _TrackTile(
                      label: 'None',
                      isSelected: currentTrack == null,
                      onTap: () => onSelect(null),
                    ),
                  ...tracks.map(
                    (t) => _TrackTile(
                      label: labelFor(t),
                      isSelected: t == currentTrack,
                      onTap: () => onSelect(t),
                    ),
                  ),
                  if (tracks.isEmpty && !allowNone)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(AppStrings.of(context).noTracksAvailable,
                        style: const TextStyle(color: Colors.white54),
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
            if (onLoadExternal != null) ...[
              const Divider(height: 1, color: Colors.white12),
              InkWell(
                onTap: onLoadExternal,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: Row(
                    children: [
                      const Icon(Icons.folder_open_outlined,
                          color: AppColors.accentBlue, size: 22),
                      const SizedBox(width: 16),
                      Text(AppStrings.of(context).loadExternalSubtitle,
                        style: const TextStyle(
                          color: AppColors.accentBlue,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Helper for showing audio track selection
  static Future<void> showAudio(
    BuildContext context, {
    required List<AudioTrackInfo> tracks,
    required AudioTrackInfo? current,
    required ValueChanged<AudioTrackInfo?> onSelect,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => TrackSelectionSheet<AudioTrackInfo>(
        title: 'Audio track',
        tracks: tracks,
        currentTrack: current,
        labelFor: (t) => t.displayName,
        onSelect: (t) {
          onSelect(t);
          Navigator.of(context).pop();
        },
      ),
    );
  }

  /// Helper for showing subtitle track selection
  static Future<void> showSubtitle(
    BuildContext context, {
    required List<SubtitleTrackInfo> tracks,
    required SubtitleTrackInfo? current,
    required ValueChanged<SubtitleTrackInfo?> onSelect,
    required VoidCallback onLoadExternal,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => TrackSelectionSheet<SubtitleTrackInfo>(
        title: 'Subtitle track',
        tracks: tracks,
        currentTrack: current,
        labelFor: (t) => t.displayName,
        onSelect: (t) {
          onSelect(t);
          Navigator.of(context).pop();
        },
        onLoadExternal: () {
          Navigator.of(context).pop();
          onLoadExternal();
        },
        allowNone: true,
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _TrackTile({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.check : Icons.radio_button_unchecked,
              color: isSelected ? AppColors.accentBlue : Colors.white38,
              size: 20,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? AppColors.accentBlue : Colors.white,
                  fontSize: 15,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
