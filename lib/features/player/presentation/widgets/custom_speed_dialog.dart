import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

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
      setState(() => _error = AppStrings.of(context).pwBadNumber);
      return;
    }
    if (value < 0.25 || value > 4.0) {
      setState(() => _error = AppStrings.of(context).pwSpeedRange);
      return;
    }
    widget.onSpeedSet(value);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Scrolls: sideways, with the keyboard up, there is little more than
      // the field's own height of screen left, and the range line and the
      // buttons ran off it.
      scrollable: true,
      backgroundColor: PlayerUi.surface,
      surfaceTintColor: Colors.transparent,
      shape: PlayerUi.dialogShape,
      title: Row(
        children: [
          const Icon(Icons.speed_rounded, color: PlayerUi.accent, size: 22),
          const SizedBox(width: 12),
          Flexible(
            child: Text(AppStrings.of(context).customSpeedTitle,
                style: PlayerUi.title),
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
                color: PlayerUi.accent,
                fontSize: 20,
              ),
              hintText: '1.00',
              hintStyle: const TextStyle(color: PlayerUi.textDisabled),
              filled: true,
              fillColor: PlayerUi.raised,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(PlayerUi.tileRadius),
                borderSide: BorderSide.none,
              ),
              errorText: _error,
            ),
            onSubmitted: (_) => _apply(),
          ),
          const SizedBox(height: 12),
          Text(AppStrings.of(context).speedRangeHint,
              textAlign: TextAlign.center, style: PlayerUi.rowValue),
        ],
      ),
      actions: [
        PlayerDialogButton(
          label: AppStrings.of(context).cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        PlayerDialogButton(
          label: AppStrings.of(context).apply,
          primary: true,
          onPressed: _apply,
        ),
      ],
    );
  }
}
