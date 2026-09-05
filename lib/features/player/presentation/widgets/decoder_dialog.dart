import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../shortcut_item.dart';

import '../../../../core/localization/app_strings.dart';
/// Decoder selection dialog (HW / HW+ / SW)
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
    return Stack(
      children: [
        // Dim backdrop
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            child: Container(color: Colors.black54),
          ),
        ),
        // Dialog card
        Center(
          child: Container(
            width: 380,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.darkSurfaceVariant,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Text(AppStrings.of(context).selectDecoder,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                ...DecoderType.values.map(
                  (type) => _DecoderOption(
                    type: type,
                    isSelected: type == current,
                    onTap: () => onSelect(type),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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

  String get _label {
    switch (type) {
      case DecoderType.defaultMode:
        return 'Default';
      case DecoderType.hw:
        return 'HW decoder';
      case DecoderType.hwPlus:
        return 'HW+ decoder';
      case DecoderType.sw:
        return 'SW decoder';
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: isSelected ? AppColors.accentBlue : Colors.white54,
              size: 22,
            ),
            const SizedBox(width: 16),
            Text(
              _label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
