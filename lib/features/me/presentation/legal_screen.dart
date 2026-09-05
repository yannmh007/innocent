import 'package:flutter/material.dart';

import '../../../core/app_version.dart';
import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
/// Legal screen — Privacy Policy, Terms of Service, Open Source Licenses
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).legal)),
      body: ListView(
        children: [
          _legalTile(
            context,
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppStrings.of(context).openingPrivacyPolicy)),
              );
            },
          ),
          const Divider(height: 0, color: Colors.white10),
          _legalTile(
            context,
            icon: Icons.description_outlined,
            title: 'Terms of Service',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppStrings.of(context).openingTerms)),
              );
            },
          ),
          const Divider(height: 0, color: Colors.white10),
          _legalTile(
            context,
            icon: Icons.code,
            title: 'Open Source Licenses',
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Innocent',
              applicationVersion: AppVersion.name,
            ),
          ),
          const Divider(height: 0, color: Colors.white10),
          _legalTile(
            context,
            icon: Icons.info_outline,
            title: 'About',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const _AboutPage(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legalTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: AppColors.primaryBlue, size: 22),
      title: Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 15)),
      trailing: const Icon(Icons.chevron_right,
          color: AppColors.darkOnSurfaceMuted, size: 20),
      onTap: onTap,
    );
  }
}

class _AboutPage extends StatelessWidget {
  const _AboutPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).about)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 32),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.primaryBlue,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.play_arrow, color: Colors.white, size: 48),
            ),
            const SizedBox(height: 16),
            const Text(
              'Innocent',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(AppStrings.of(context).versionOf(AppVersion.name),
              style: TextStyle(
                color: AppColors.white50,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 24),
            Text(AppStrings.of(context).personalPlayerApp,
              style: TextStyle(
                color: AppColors.white60,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
