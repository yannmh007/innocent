import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player_provider.dart';
import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// The sheet a long press on Next opens: Loop one / Loop all / Shuffle,
/// what is on marked in the accent with a check (MX Player parity).
class LoopMenuSheet extends ConsumerWidget {
  const LoopMenuSheet({super.key});

  static Future<void> show(BuildContext context) =>
      showPlayerSheet<void>(context, builder: (_) => const LoopMenuSheet());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerControllerProvider);
    final controller = ref.read(playerControllerProvider.notifier);
    final s = AppStrings.of(context);

    final loopOneActive = state.loopMode == LoopMode.one;
    final loopAllActive = state.loopMode == LoopMode.all;
    final shuffleActive = state.isShuffleEnabled;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerSheetHeader(title: s.scLoop),
        // Scrolls on a short screen (sideways, large font) instead of
        // cutting off its last rows.
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                PlayerUi.pad(context) - 4, 8, PlayerUi.pad(context) - 4, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PanelRow(
                  icon: Icons.repeat_one_rounded,
                  title: s.pwLoopOne,
                  selected: loopOneActive,
                  onTap: () {
                    controller.setLoopMode(
                        loopOneActive ? LoopMode.off : LoopMode.one);
                    Navigator.of(context).pop();
                  },
                ),
                PanelRow(
                  icon: Icons.repeat_rounded,
                  title: s.pwLoopAll,
                  selected: loopAllActive,
                  onTap: () {
                    controller.setLoopMode(
                        loopAllActive ? LoopMode.off : LoopMode.all);
                    Navigator.of(context).pop();
                  },
                ),
                PanelRow(
                  icon: Icons.shuffle_rounded,
                  title: s.mpShuffle,
                  selected: shuffleActive,
                  onTap: () {
                    controller.setShuffleEnabled(!shuffleActive);
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
