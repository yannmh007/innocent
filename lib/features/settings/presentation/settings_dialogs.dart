import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
/// Reusable settings dialog widgets for MX Player settings sub-pages

/// Single-selection list dialog (e.g. Resume, Audio output, Character encoding)
Future<String?> showSettingsListDialog({
  required BuildContext context,
  required String title,
  required List<String> options,
  required String currentValue,
}) async {
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.darkSurface,
      title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 17)),
      contentPadding: const EdgeInsets.only(top: 12),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: options.length,
          itemBuilder: (_, i) {
            final selected = options[i] == currentValue;
            return RadioListTile<String>(
              value: options[i],
              groupValue: currentValue,
              title: Text(
                options[i],
                style: TextStyle(
                  color: selected ? AppColors.primaryBlue : Colors.white,
                  fontSize: 14,
                ),
              ),
              activeColor: AppColors.primaryBlue,
              onChanged: (v) => Navigator.of(context).pop(v),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.of(context).cancel, style: TextStyle(color: Colors.white70)),
        ),
      ],
    ),
  );
}

/// Slider dialog (e.g. Default playback speed, Audio delay, Bluetooth audio delay)
Future<double?> showSettingsSliderDialog({
  required BuildContext context,
  required String title,
  required double currentValue,
  required double min,
  required double max,
  int divisions = 20,
  String Function(double)? valueLabel,
}) async {
  double tempValue = currentValue;
  return showDialog<double>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final label = valueLabel?.call(tempValue) ?? tempValue.toStringAsFixed(1);
        return AlertDialog(
          backgroundColor: AppColors.darkSurface,
          title: Text(title,
              style: const TextStyle(color: Colors.white, fontSize: 17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.primaryBlue,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: AppColors.primaryBlue,
                  inactiveTrackColor: AppColors.white20,
                  thumbColor: AppColors.primaryBlue,
                  overlayColor: AppColors.primaryBlue.withOpacity(0.2),
                ),
                child: Slider(
                  value: tempValue,
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: (v) => setDialogState(() => tempValue = v),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    valueLabel?.call(min) ?? min.toStringAsFixed(1),
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  Text(
                    valueLabel?.call(max) ?? max.toStringAsFixed(1),
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(AppStrings.of(context).cancel, style: TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(tempValue),
              child: Text(AppStrings.of(context).ok, style: TextStyle(color: AppColors.primaryBlue)),
            ),
          ],
        );
      },
    ),
  );
}

/// Text input dialog (e.g. Http User-Agent, Calibrate playback position)
Future<String?> showSettingsTextDialog({
  required BuildContext context,
  required String title,
  String? subtitle,
  String currentValue = '',
  String hintText = '',
}) async {
  final controller = TextEditingController(text: currentValue);
  final result = await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.darkSurface,
      title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 17)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle != null) ...[
            Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle: const TextStyle(color: Colors.white30),
              filled: true,
              fillColor: AppColors.white06,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.of(context).cancel, style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: Text(AppStrings.of(context).ok, style: TextStyle(color: AppColors.primaryBlue)),
        ),
      ],
    ),
  );
  // Dispose the controller once the dialog is gone — otherwise every
  // invocation of this dialog leaks one TextEditingController.
  controller.dispose();
  return result;
}

/// Multi-checkbox selection dialog (e.g. HW+ video/audio codecs, File extensions)
Future<List<String>?> showSettingsMultiSelectDialog({
  required BuildContext context,
  required String title,
  required List<String> options,
  required List<String> selectedValues,
}) async {
  final selected = Set<String>.from(selectedValues);
  return showDialog<List<String>>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        return AlertDialog(
          backgroundColor: AppColors.darkSurface,
          title: Text(title,
              style: const TextStyle(color: Colors.white, fontSize: 17)),
          contentPadding: const EdgeInsets.only(top: 12),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: options.length,
              itemBuilder: (_, i) {
                final checked = selected.contains(options[i]);
                return CheckboxListTile(
                  value: checked,
                  title: Text(
                    options[i],
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  activeColor: AppColors.primaryBlue,
                  checkColor: Colors.white,
                  onChanged: (v) {
                    setDialogState(() {
                      if (v == true) {
                        selected.add(options[i]);
                      } else {
                        selected.remove(options[i]);
                      }
                    });
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(AppStrings.of(context).cancel, style: TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(selected.toList()),
              child: Text(AppStrings.of(context).ok, style: TextStyle(color: AppColors.primaryBlue)),
            ),
          ],
        );
      },
    ),
  );
}
