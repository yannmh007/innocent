import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Innocent theme configuration
class AppTheme {
  AppTheme._();

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.darkBackground,
        primaryColor: AppColors.accentBlue,
        fontFamily: 'Roboto',
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accentBlue,
          secondary: AppColors.accentBlueLight,
          surface: AppColors.darkSurface,
          onSurface: AppColors.darkOnSurface,
          error: AppColors.error,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.darkBackground,
          foregroundColor: AppColors.darkOnSurface,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: AppColors.darkOnSurface,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: AppColors.bottomNavBackground,
          selectedItemColor: AppColors.bottomNavSelected,
          unselectedItemColor: AppColors.bottomNavUnselected,
          type: BottomNavigationBarType.fixed,
          showUnselectedLabels: true,
          elevation: 8,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: AppColors.fabBackground,
          foregroundColor: AppColors.fabIcon,
        ),
        dividerTheme: const DividerThemeData(
          color: AppColors.darkDivider,
          thickness: 0.5,
          space: 0,
        ),
        listTileTheme: const ListTileThemeData(
          iconColor: AppColors.darkOnSurface,
          textColor: AppColors.darkOnSurface,
        ),
      );

  /// INNOCENT HAS NO LIGHT MODE, so this deliberately returns the dark one.
  ///
  /// That is a statement about the app as it is built, not a preference.
  /// **72 of its 76 `Scaffold`s hardcode a dark background** — `#0F0F0F`, or
  /// true black for the player and the local browser — and no widget anywhere
  /// outside this file reads `lightBackground`, `lightSurface` or
  /// `lightOnSurface`. Selecting "Light" never produced a light app. It
  /// produced a dark app wearing light foreground colours, which is the same
  /// thing as an unreadable one, in two mirrored ways:
  ///
  ///   * On the 83 files that paint their own dark surface, roughly **388
  ///     unstyled `Text` widgets** fall back to this theme's `onSurface`.
  ///     That rendered `#212121` on `#0F0F0F` — a contrast ratio of
  ///     **1.19:1**. Invisible. The four AppBars fixed in #15 were the tip of
  ///     this, and the only part a user happened to report.
  ///   * On the few screens that set no background and so inherited
  ///     `scaffoldBackgroundColor`, the failure inverted: `#FAFAFA` behind
  ///     text hardcoded `Colors.white54`. Also invisible.
  ///     `adb_connect_screen.dart` is the clearest case.
  ///
  /// Returning the dark theme fixes both directions at once, in one line,
  /// instead of auditing 388 call sites. The cost is honest and small: the
  /// Adaptive / Light / Dark picker in Me → App theme now renders the same
  /// way whichever the user chooses.
  ///
  /// TO BUILD A REAL LIGHT MODE, this is the line to delete — but deleting it
  /// alone re-opens every bug above. The surfaces have to stop being
  /// hardcoded first. `docs/light_mode_audit.md` has the measurements, the
  /// file-by-file counts and the order to do it in.
  static ThemeData get light => dark;
}
