import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/ui/app_snackbar.dart';
import '../player_provider.dart';

import '../../../../core/localization/app_strings.dart';
/// Bottom sheet for managing skip intro/outro markers (Phase 14).
class SkipMarkersSheet extends ConsumerWidget {
  const SkipMarkersSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const SkipMarkersSheet(),
    );
  }

  String _fmt(int? ms) {
    if (ms == null) return 'Not set';
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerControllerProvider);
    final controller = ref.read(playerControllerProvider.notifier);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  const Icon(Icons.skip_next_outlined,
                      color: AppColors.accentBlue, size: 20),
                  const SizedBox(width: 12),
                  Text(AppStrings.of(context).skipIntroOutro,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Set markers at current playback position. Will auto-skip on next play.',
                style: TextStyle(
                  color: AppColors.darkOnSurfaceMuted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 20),
              _MarkerRow(
                label: 'Intro ends at',
                value: _fmt(state.introEndMs),
                isSet: state.introEndMs != null,
                onSet: () async {
                  await controller.setIntroMarker();
                  // Report the marker that was actually stored rather than
                  // re-deriving it from the UI position — the two could differ
                  // by a second, and the stored one is the truth.
                  final markerMs =
                      ref.read(playerControllerProvider).introEndMs ?? 0;
                  if (context.mounted) Navigator.of(context).pop();
                  // Phase 41: route via the root messenger so the toast
                  // doesn't depend on the popped sheet's context.
                  AppSnackbar.global(
                    'Intro marker set at ${_fmt(markerMs)}',
                  );
                },
              ),
              const SizedBox(height: 12),
              _MarkerRow(
                label: 'Outro starts at',
                value: _fmt(state.outroStartMs),
                isSet: state.outroStartMs != null,
                onSet: () async {
                  await controller.setOutroMarker();
                  final markerMs =
                      ref.read(playerControllerProvider).outroStartMs ?? 0;
                  if (context.mounted) Navigator.of(context).pop();
                  // Phase 41: root messenger to survive the pop.
                  AppSnackbar.global(
                    'Outro marker set at ${_fmt(markerMs)}',
                  );
                },
              ),
              const SizedBox(height: 20),
              if (state.introEndMs != null || state.outroStartMs != null)
                TextButton.icon(
                  onPressed: () async {
                    await controller.clearSkipMarkers();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.delete_outline,
                      color: AppColors.error, size: 18),
                  label: Text(AppStrings.of(context).clearAllMarkers,
                    style: TextStyle(color: AppColors.error),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MarkerRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isSet;
  final VoidCallback onSet;

  const _MarkerRow({
    required this.label,
    required this.value,
    required this.isSet,
    required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.darkSurfaceVariant,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.darkOnSurfaceMuted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    color: isSet ? AppColors.accentBlue : Colors.white70,
                    fontSize: 15,
                    fontWeight:
                        isSet ? FontWeight.w600 : FontWeight.w400,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: onSet,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 8),
            ),
            child: Text(isSet ? 'Update' : 'Set'),
          ),
        ],
      ),
    );
  }
}
