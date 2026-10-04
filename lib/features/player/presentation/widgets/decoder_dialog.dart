import 'package:flutter/material.dart';

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
        // MX: a translucent slate card 11 dp from the screen edges (capped
        // on wide screens), nearly square corners.
        Center(
          child: Container(
            width: (MediaQuery.of(context).size.width - 22).clamp(0.0, 520.0),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xF0414249),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
                  child: Text(AppStrings.of(context).selectDecoder,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w400,
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
        // MX: 48 dp rows, white rings, the chosen one in MX's cyan, the
        // label 73 dp in.
        padding: const EdgeInsets.symmetric(horizontal: 23, vertical: 12),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: isSelected ? const Color(0xFF6AE6FF) : Colors.white,
              size: 24,
            ),
            const SizedBox(width: 26),
            Text(
              _label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
