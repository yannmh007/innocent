import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/preferences_provider.dart';
import '../../../core/services/preferences/preferences_service.dart';
import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/ui/tv_focus.dart';
import '../../../core/ui/nav_bar_space.dart';
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


  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentMode = ref.watch(preferencesProvider).themeMode;
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).appTheme)),
      body: ListView(
        padding: const EdgeInsets.all(16).plusNavBar(context),
        children: [
          // Internet banner
          // A banner promising "fresh themes" from the internet, with a
          // chevron that went nowhere, and a grid of 32 "classic" colours
          // whose every tap said "Theme applied" and changed nothing, used
          // to sit on this screen. Controls that pretend are worse than
          // none (screens harness, SCREEN_A11Y=1: 32 nameless swatches); the
          // three themes below are what the app has.

          // 3 special themes
          Row(
            children: [
              _buildThemeCard(
                context,
                ref,
                AppStrings.of(context).themeAdaptive,
                AppThemeMode.adaptive,
                Colors.blueGrey,
                currentMode: currentMode,
                badge: currentMode == AppThemeMode.adaptive
                    ? AppStrings.of(context).themeUsing
                    : null,
                badgeColor: Colors.green,
              ),
              const SizedBox(width: 12),
              // "Coming soon", ALWAYS — not only when unselected, and not
              // swapped for 'Using' when it is.
              //
              // Innocent has no light mode: 72 of its 76 Scaffolds paint their
              // own dark background, so `AppTheme.light` returns the dark
              // theme (see app_theme.dart). Picking this card is therefore a
              // no-op, and the moment a user most needs to be told that is
              // exactly the moment they have picked it and nothing changed.
              // Selection is still visible — `_buildThemeCard` draws a blue
              // border for it, independently of this badge.
              //
              // docs/light_mode_audit.md §6 is the route to making it real,
              // and this label is what should come off first when it is.
              _buildThemeCard(
                context,
                ref,
                AppStrings.of(context).themeLight,
                AppThemeMode.light,
                Colors.white,
                currentMode: currentMode,
                badge: AppStrings.of(context).themeComingSoon,
                badgeColor: Colors.orange,
                textDark: true,
              ),
              const SizedBox(width: 12),
              _buildThemeCard(
                context,
                ref,
                AppStrings.of(context).themeDark,
                AppThemeMode.dark,
                const Color(0xFF1A1A2E),
                currentMode: currentMode,
                badge: currentMode == AppThemeMode.dark
                    ? AppStrings.of(context).themeUsing
                    : AppStrings.of(context).themeNew,
                badgeColor: currentMode == AppThemeMode.dark
                    ? Colors.green
                    : Colors.redAccent,
              ),
            ],
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
      child: RemoteTappable(
        selected: selected,
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
