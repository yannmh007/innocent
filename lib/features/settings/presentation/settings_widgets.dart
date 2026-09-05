import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
/// Section header for grouping settings
class SettingsSectionHeader extends StatelessWidget {
  final String title;
  const SettingsSectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFFFF9800), // MX Player orange section header
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Settings tile — navigation/category row
class SettingsNavTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback onTap;
  /// Audit fix: when true, render dimmed with an amber "SOON" trailing
  /// badge and intercept the tap with an honest snackbar instead of
  /// opening a dialog whose result wouldn't be persisted anywhere.
  final bool comingSoon;

  const SettingsNavTile({
    super.key,
    required this.title,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.comingSoon = false,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: comingSoon ? 0.55 : 1.0,
      child: ListTile(
        leading: icon != null
            ? Icon(icon, color: AppColors.darkOnSurface)
            : null,
        title: Text(
          title,
          style:
              const TextStyle(color: AppColors.darkOnSurface, fontSize: 15),
        ),
        subtitle: subtitle != null
            ? Text(
                subtitle!,
                style: const TextStyle(
                  color: AppColors.darkOnSurfaceMuted,
                  fontSize: 12,
                ),
              )
            : null,
        trailing: comingSoon
            ? Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(AppStrings.of(context).soonBadge,
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            : null,
        onTap: comingSoon
            ? () {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                    content: Text('$title — ' + AppStrings.of(context).comingSoon),
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ));
              }
            : onTap,
      ),
    );
  }
}

/// Settings tile — toggle checkbox (MX Player uses checkboxes, not switches)
class SettingsToggleTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsToggleTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      title: Text(
        title,
        style: const TextStyle(color: AppColors.darkOnSurface, fontSize: 15),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: const TextStyle(
                color: AppColors.darkOnSurfaceMuted,
                fontSize: 12,
              ),
            )
          : null,
      value: value,
      onChanged: (v) => onChanged(v ?? false),
      activeColor: AppColors.accentBlue,
      checkColor: Colors.white,
      controlAffinity: ListTileControlAffinity.trailing,
    );
  }
}

/// Settings tile — value display with tap action
class SettingsValueTile extends StatelessWidget {
  final String title;
  final String value;
  final VoidCallback onTap;

  const SettingsValueTile({
    super.key,
    required this.title,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        title,
        style: const TextStyle(color: AppColors.darkOnSurface, fontSize: 15),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: AppColors.darkOnSurfaceMuted,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(
            Icons.chevron_right,
            color: AppColors.darkOnSurfaceMuted,
            size: 20,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
