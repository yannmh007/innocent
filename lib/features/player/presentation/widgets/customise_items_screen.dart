import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../player_provider.dart';
import '../shortcut_item.dart';

import '../../../../core/localization/app_strings.dart';
/// Customise Items screen — toggle which shortcuts appear in shortcut row
class CustomiseItemsScreen extends ConsumerWidget {
  const CustomiseItemsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerControllerProvider);
    final controller = ref.read(playerControllerProvider.notifier);
    final visible = state.visibleShortcuts;
    const allItems = ShortcutItem.values;

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        title: Text(AppStrings.of(context).shortcuts),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Switch(
              value: visible.isNotEmpty,
              activeColor: AppColors.accentBlue,
              onChanged: (enabled) {
                if (enabled) {
                  controller.updateVisibleShortcuts(allItems.toSet());
                } else {
                  controller.updateVisibleShortcuts({});
                }
              },
            ),
          ),
        ],
      ),
      body: GridView.count(
        crossAxisCount: 2,
        childAspectRatio: 4,
        padding: const EdgeInsets.all(8),
        children: allItems.map((item) {
          final isChecked = visible.contains(item);
          return CheckboxListTile(
            value: isChecked,
            activeColor: AppColors.accentBlue,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              item.label.replaceAll('\n', ' '),
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            onChanged: (newVal) {
              final newSet = Set<ShortcutItem>.from(visible);
              if (newVal == true) {
                newSet.add(item);
              } else {
                newSet.remove(item);
              }
              controller.updateVisibleShortcuts(newSet);
            },
          );
        }).toList(),
      ),
    );
  }
}
