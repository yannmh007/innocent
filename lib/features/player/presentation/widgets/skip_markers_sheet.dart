import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/ui/app_snackbar.dart';
import '../player_provider.dart';
import '../../../../core/localization/app_strings.dart';
import 'player_toast.dart';
import 'player_ui.dart';

/// Bottom sheet for managing skip intro/outro markers (Phase 14).
class SkipMarkersSheet extends ConsumerWidget {
  const SkipMarkersSheet({super.key});

  static Future<void> show(BuildContext context) =>
      showPlayerSheet<void>(context, builder: (_) => const SkipMarkersSheet());

  String _fmt(int? ms) {
    if (ms == null) return AppStrings.current.pwNotSet;
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// In the player's own message place when the player is open (it always
  /// is, behind this sheet); the app's snackbar otherwise.
  static void _say(String text) {
    final toast = PlayerToastController.current;
    if (toast == null) {
      AppSnackbar.global(text);
      return;
    }
    toast.show(text,
        kind: PlayerToastKind.success, icon: Icons.skip_next_rounded);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerControllerProvider);
    final controller = ref.read(playerControllerProvider.notifier);
    final s = AppStrings.of(context);
    final pad = PlayerUi.pad(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerSheetHeader(title: s.skipIntroOutro, divider: false),
        // Scrolls: sideways the outro's row and the buttons were below the
        // screen.
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(s.pwMarkersHint, style: PlayerUi.body),
                const SizedBox(height: 16),
                _MarkerRow(
                  icon: Icons.login_rounded,
                  label: s.pwIntroEnds,
                  value: _fmt(state.introEndMs),
                  isSet: state.introEndMs != null,
                  onSet: () async {
                    await controller.setIntroMarker();
                    // Report the marker that was actually stored rather than
                    // re-deriving it from the UI position — the two could
                    // differ by a second, and the stored one is the truth.
                    final markerMs =
                        ref.read(playerControllerProvider).introEndMs ?? 0;
                    if (context.mounted) Navigator.of(context).pop();
                    _say(AppStrings.current.pwIntroSet(_fmt(markerMs)));
                  },
                ),
                const SizedBox(height: 10),
                _MarkerRow(
                  icon: Icons.logout_rounded,
                  label: s.pwOutroStarts,
                  value: _fmt(state.outroStartMs),
                  isSet: state.outroStartMs != null,
                  onSet: () async {
                    await controller.setOutroMarker();
                    final markerMs =
                        ref.read(playerControllerProvider).outroStartMs ?? 0;
                    if (context.mounted) Navigator.of(context).pop();
                    _say(AppStrings.current.pwOutroSet(_fmt(markerMs)));
                  },
                ),
                if (state.introEndMs != null || state.outroStartMs != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: () async {
                        await controller.clearSkipMarkers();
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: PlayerUi.danger,
                        shape: const StadiumBorder(),
                        minimumSize: const Size(48, 44),
                      ),
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      label: Text(s.clearAllMarkers),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One marker: what it is and where it is set, and the button that sets it
/// to the film's present moment.
class _MarkerRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool isSet;
  final VoidCallback onSet;

  const _MarkerRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.isSet,
    required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return PanelCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          Icon(icon, size: 22, color: PlayerUi.textSecondary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: PlayerUi.rowValue),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    color: isSet ? PlayerUi.accent : PlayerUi.textPrimary,
                    fontSize: 15,
                    fontWeight: isSet ? FontWeight.w600 : FontWeight.w400,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          PlayerDialogButton(
            label: isSet ? s.pwUpdate : s.pwSet,
            primary: true,
            onPressed: onSet,
          ),
        ],
      ),
    );
  }
}
