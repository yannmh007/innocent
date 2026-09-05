import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/localization/locale_provider.dart';
import '../../../core/theme/app_colors.dart';

/// App Language selection.
///
/// Drives [localeProvider], which re-renders the entire app in the chosen
/// language. Only locales we actually ship translations for are listed —
/// showing dozens of languages that don't change anything is misleading.
/// Add a row here (and a map in AppStrings) as new translations land.
class SettingsLanguageScreen extends ConsumerWidget {
  const SettingsLanguageScreen({super.key});

  // (locale code | null for "system", English name, native name)
  /// Shared with Settings → General so the two pickers can never disagree
  /// about which languages exist. See [kAppLanguages].
  static const List<(String?, String, String)> _options = kAppLanguages;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final current = ref.watch(localeProvider); // null = follow system
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(s.language)),
      body: ListView(
        children: [
          for (final (code, name, native) in _options)
            _LanguageRow(
              code: code,
              name: name,
              native: native,
              selected: code == null
                  ? current == null
                  : current?.languageCode == code,
              onTap: () => ref
                  .read(localeProvider.notifier)
                  .setLocale(code == null ? null : Locale(code)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(AppStrings.of(context).moreLanguagesOnWay,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _LanguageRow extends StatelessWidget {
  final String? code;
  final String name;
  final String native;
  final bool selected;
  final VoidCallback onTap;

  const _LanguageRow({
    required this.code,
    required this.name,
    required this.native,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        name,
        style: TextStyle(
          color: selected ? AppColors.primaryBlue : Colors.white,
          fontSize: 15,
        ),
      ),
      subtitle: native.isNotEmpty
          ? Text(native,
              style: const TextStyle(color: Colors.white54, fontSize: 13))
          : null,
      trailing: selected
          ? const Icon(Icons.check, color: AppColors.primaryBlue, size: 20)
          : null,
      onTap: onTap,
    );
  }
}
