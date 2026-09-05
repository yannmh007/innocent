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

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: AppColors.lightBackground,
        primaryColor: AppColors.accentBlue,
        fontFamily: 'Roboto',
        colorScheme: const ColorScheme.light(
          primary: AppColors.accentBlue,
          secondary: AppColors.accentBlueLight,
          surface: AppColors.lightSurface,
          onSurface: AppColors.lightOnSurface,
          error: AppColors.error,
        ),
      );
}
