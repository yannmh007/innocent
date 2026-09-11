import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';

import '../../../../core/localization/app_strings.dart';
/// Custom playback speed input dialog (Phase 11).
/// Allows typing any speed between 0.25x and 4.0x.
class CustomSpeedDialog extends StatefulWidget {
  final double currentSpeed;
  final ValueChanged<double> onSpeedSet;

  const CustomSpeedDialog({
    super.key,
    required this.currentSpeed,
    required this.onSpeedSet,
  });

  static Future<void> show(
    BuildContext context, {
    required double currentSpeed,
    required ValueChanged<double> onSpeedSet,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => CustomSpeedDialog(
        currentSpeed: currentSpeed,
        onSpeedSet: onSpeedSet,
      ),
    );
  }

  @override
  State<CustomSpeedDialog> createState() => _CustomSpeedDialogState();
}

class _CustomSpeedDialogState extends State<CustomSpeedDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.currentSpeed.toStringAsFixed(2));
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply() {
    final text = _controller.text.trim();
    final value = double.tryParse(text);
    if (value == null) {
      setState(() => _error = 'Invalid number');
      return;
    }
    if (value < 0.25 || value > 4.0) {
      setState(() => _error = 'Speed must be 0.25 - 4.0');
      return;
    }
    widget.onSpeedSet(value);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.darkSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      title: Row(
        children: [
          const Icon(Icons.speed, color: AppColors.accentBlue, size: 22),
          const SizedBox(width: 12),
          Text(AppStrings.of(context).customSpeedTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d{0,1}\.?\d{0,2}')),
            ],
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              suffixText: 'x',
              suffixStyle: const TextStyle(
                color: AppColors.accentBlue,
                fontSize: 20,
              ),
              hintText: '1.00',
              hintStyle: const TextStyle(color: Colors.white24),
              filled: true,
              fillColor: AppColors.darkSurfaceVariant,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              errorText: _error,
            ),
            onSubmitted: (_) => _apply(),
          ),
          const SizedBox(height: 12),
          Text(AppStrings.of(context).speedRangeHint,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.darkOnSurfaceMuted,
              fontSize: 12,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.of(context).cancel,
              style: const TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: _apply,
          child: Text(AppStrings.of(context).apply,
            style: const TextStyle(
              color: AppColors.accentBlue,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
