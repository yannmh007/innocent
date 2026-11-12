import 'package:flutter/material.dart';

import '../shortcut_item.dart';
import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// Decoder selection dialog (Default / HW / HW+ / SW): the player's
/// dialog (player_ui.dart), the chosen decoder checked.
///
/// It was MX's translucent slate card with square corners and cyan radio
/// rings — one more style beside the others (12 Nov 2026).
class DecoderDialog extends StatelessWidget {
  final DecoderType current;
  final ValueChanged<DecoderType> onSelect;
  final VoidCallback onDismiss;

  const DecoderDialog({
    super.key,
    required this.current,
    required this.onSelect,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return PlayerDialog(
      title: AppStrings.of(context).selectDecoder,
      icon: Icons.memory_rounded,
      onDismiss: onDismiss,
      maxWidth: 360,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final type in DecoderType.values)
            _DecoderOption(
              type: type,
              isSelected: type == current,
              onTap: () => onSelect(type),
            ),
        ],
      ),
    );
  }
}

class _DecoderOption extends StatelessWidget {
  final DecoderType type;
  final bool isSelected;
  final VoidCallback onTap;

  const _DecoderOption({
    required this.type,
    required this.isSelected,
    required this.onTap,
  });

  String _label(AppStrings s) {
    switch (type) {
      case DecoderType.defaultMode:
        return s.plDecoderDefault;
      case DecoderType.hw:
        return s.pwHwDecoder;
      case DecoderType.hwPlus:
        return s.pwHwPlusDecoder;
      case DecoderType.sw:
        return s.pwSwDecoder;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PanelRow(
      choice: true,
      title: _label(AppStrings.of(context)),
      selected: isSelected,
      onTap: onTap,
    );
  }
}
