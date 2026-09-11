import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/preferences_provider.dart';
import '../../../core/services/preferences/preferences_service.dart';
import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
/// App Theme picker matching MX Player (UI PDF page 13).
/// 3 special themes (Adaptive, Light, Dark) + Classic Themes color grid.
///
/// Phase 41: theme selection now persists via [preferencesProvider]
/// (`AppPreferences.themeMode`). The classic accent-color grid is decorative
/// for now — MX shows the same swatches and applies them as the seed colour,
/// but our themeing system only exposes light/dark/adaptive, so picking an
/// accent confirms the selection visually only.
class AppThemeScreen extends ConsumerWidget {
  const AppThemeScreen({super.key});

  static const _classicColors = <_Swatch>[
    // Row 1: solid bright colors
    _Swatch(Color(0xFFFF5252)),
    _Swatch(Color(0xFFFF9800)),
    _Swatch(Color(0xFFFFC107)),
    _Swatch(Color(0xFF795548)),
    _Swatch(Color(0xFFCDDC39)),
    _Swatch(Color(0xFF8BC34A)),
    // Row 2: solid
    _Swatch(Color(0xFF4CAF50)),
    _Swatch(Color(0xFF009688)),
    _Swatch(Color(0xFF03A9F4)),
    _Swatch(Color(0xFF2196F3)),
    _Swatch(Color(0xFF3F51B5)),
    _Swatch(Color(0xFF9C27B0)),
    // Row 3: solid + bi-color
    _Swatch(Color(0xFFE040FB)),
    _Swatch(Color(0xFFFF4081)),
    _Swatch(Color(0xFFEC407A)),
    _Swatch(Color(0xFFE0E0E0)),
    _Swatch(Color(0xFFFF5252), dark: true),
    _Swatch(Color(0xFFFF9800), dark: true),
    // Row 4: bi-color
    _Swatch(Color(0xFFFFC107), dark: true),
    _Swatch(Color(0xFF795548), dark: true),
    _Swatch(Color(0xFFCDDC39), dark: true),
    _Swatch(Color(0xFF8BC34A), dark: true),
    _Swatch(Color(0xFF4CAF50), dark: true),
    _Swatch(Color(0xFF009688), dark: true),
    // Row 5: bi-color
    _Swatch(Color(0xFF03A9F4), dark: true),
    _Swatch(Color(0xFF2196F3), dark: true),
    _Swatch(Color(0xFF3F51B5), dark: true),
    _Swatch(Color(0xFF9C27B0), dark: true),
    _Swatch(Color(0xFFE040FB), dark: true),
    _Swatch(Color(0xFFFF4081), dark: true),
    // Row 6: bi-color (partial)
    _Swatch(Color(0xFFEC407A), dark: true),
    _Swatch(Color(0xFFE0E0E0), dark: true),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentMode = ref.watch(preferencesProvider).themeMode;
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).appTheme)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Internet banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF2D3436),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    color: Colors.amber.withOpacity(0.8), size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(AppStrings.of(context).noInternetThemes,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                const Icon(Icons.chevron_right,
                    color: Colors.white38, size: 20),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // 3 special themes
          Row(
            children: [
              _buildThemeCard(
                context,
                ref,
                'Adaptive',
                AppThemeMode.adaptive,
                Colors.blueGrey,
                currentMode: currentMode,
                badge: currentMode == AppThemeMode.adaptive ? 'Using' : null,
                badgeColor: Colors.green,
              ),
              const SizedBox(width: 12),
              _buildThemeCard(
                context,
                ref,
                'Light Theme',
                AppThemeMode.light,
                Colors.white,
                currentMode: currentMode,
                badge: currentMode == AppThemeMode.light ? 'Using' : null,
                badgeColor: Colors.green,
                textDark: true,
              ),
              const SizedBox(width: 12),
              _buildThemeCard(
                context,
                ref,
                'Dark Theme',
                AppThemeMode.dark,
                const Color(0xFF1A1A2E),
                currentMode: currentMode,
                badge: currentMode == AppThemeMode.dark ? 'Using' : 'NEW',
                badgeColor: currentMode == AppThemeMode.dark
                    ? Colors.green
                    : Colors.redAccent,
              ),
            ],
          ),

          const SizedBox(height: 28),

          // Classic Themes header
          Text(AppStrings.of(context).classicThemes,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),

          // Color grid 6 columns. These are decorative — MX shows the same
          // swatches as seed accents but we only expose light/dark/adaptive
          // for now, so the toast simply confirms the selection.
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: _classicColors.length,
            itemBuilder: (_, i) {
              final sw = _classicColors[i];
              return GestureDetector(
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(AppStrings.of(context).themeApplied),
                      duration: const Duration(milliseconds: 800),
                    ),
                  );
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: sw.dark
                      ? Column(
                          children: [
                            Expanded(child: Container(color: sw.color)),
                            Expanded(
                              child: Container(
                                color: const Color(0xFF1A2438),
                              ),
                            ),
                          ],
                        )
                      : Container(color: sw.color),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildThemeCard(
    BuildContext context,
    WidgetRef ref,
    String label,
    AppThemeMode mode,
    Color bgColor, {
    required AppThemeMode currentMode,
    String? badge,
    Color? badgeColor,
    bool textDark = false,
  }) {
    final selected = currentMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () =>
            ref.read(preferencesProvider.notifier).setThemeMode(mode),
        child: Stack(
          children: [
            Container(
              height: 100,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(12),
                border: selected
                    ? Border.all(color: AppColors.primaryBlue, width: 2)
                    : Border.all(
                        color: AppColors.white10, width: 1),
              ),
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    color: textDark ? Colors.black87 : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            if (badge != null)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    badge,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Swatch {
  final Color color;
  final bool dark;
  const _Swatch(this.color, {this.dark = false});
}
