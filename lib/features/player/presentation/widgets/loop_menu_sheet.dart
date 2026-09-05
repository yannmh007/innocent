import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../player_provider.dart';

/// Bottom sheet shown on long-press of the Next button.
/// MX Player parity: Loop One / Loop All / Shuffle with check marks.
/// Background: translucent dark.
class LoopMenuSheet extends ConsumerWidget {
  const LoopMenuSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => const LoopMenuSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerControllerProvider);
    final controller = ref.read(playerControllerProvider.notifier);

    final loopOneActive = state.loopMode == LoopMode.one;
    final loopAllActive = state.loopMode == LoopMode.all;
    final shuffleActive = state.isShuffleEnabled;

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.85),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _CheckRow(
              icon: Icons.repeat_one,
              label: 'Loop One',
              checked: loopOneActive,
              onTap: () {
                controller.setLoopMode(
                  loopOneActive ? LoopMode.off : LoopMode.one,
                );
                Navigator.of(context).pop();
              },
            ),
            _CheckRow(
              icon: Icons.repeat,
              label: 'Loop All',
              checked: loopAllActive,
              onTap: () {
                controller.setLoopMode(
                  loopAllActive ? LoopMode.off : LoopMode.all,
                );
                Navigator.of(context).pop();
              },
            ),
            _CheckRow(
              icon: Icons.shuffle,
              label: 'Shuffle',
              checked: shuffleActive,
              onTap: () {
                controller.setShuffleEnabled(!shuffleActive);
                Navigator.of(context).pop();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool checked;
  final VoidCallback onTap;

  const _CheckRow({
    required this.icon,
    required this.label,
    required this.checked,
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
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            Icon(
              checked ? Icons.check_box : Icons.check_box_outline_blank,
              color: checked ? AppColors.accentBlue : Colors.white54,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }
}
