import 'package:flutter/material.dart';

import '../../core/app_version.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/innocent_logo.dart';

import '../../core/localization/app_strings.dart';
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).about)),
      body: ListView(
        children: [
          const SizedBox(height: 32),
          const Center(
            child: InnocentLogo(size: 96),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(AppStrings.of(context).appName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(AppStrings.of(context).versionOf(AppVersion.name),
              style: const TextStyle(
                color: AppColors.darkOnSurfaceMuted,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(AppStrings.of(context).personalVideoPlayer,
              style: const TextStyle(
                color: AppColors.darkOnSurfaceMuted,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(height: 32),
          const _SectionHeader('FEATURES'),
          const _AboutTile(
            icon: Icons.folder_special_outlined,
            title: 'Local browser',
            subtitle: 'Folder view, list/grid, search, sort 10 fields',
          ),
          const _AboutTile(
            icon: Icons.play_circle_outline,
            title: 'Media-kit player',
            subtitle: 'Hardware decoding, gestures, PiP, pinch zoom',
          ),
          const _AboutTile(
            icon: Icons.favorite_outline,
            title: 'User data',
            subtitle: 'Favourites, playlists, bookmarks, history',
          ),
          const _AboutTile(
            icon: Icons.tune,
            title: 'Equalizer',
            subtitle: 'Android AudioEffect with presets',
          ),
          const _AboutTile(
            icon: Icons.lock_outline,
            title: 'Private folder',
            subtitle: 'PIN-protected hidden videos',
          ),
          const SizedBox(height: 24),
          const _SectionHeader('TECHNOLOGY'),
          const _AboutTile(
            icon: Icons.flutter_dash,
            title: 'Flutter 3.22+',
            subtitle: 'Cross-platform UI toolkit',
          ),
          const _AboutTile(
            icon: Icons.code,
            title: 'media_kit (libmpv)',
            subtitle: 'Powerful media playback',
          ),
          const SizedBox(height: 24),
          const _SectionHeader('LEGAL'),
          ListTile(
            leading: const Icon(
              Icons.description_outlined,
              color: AppColors.accentBlue,
            ),
            title: Text(AppStrings.of(context).openSourceLicenses,
              style: const TextStyle(color: Colors.white),
            ),
            trailing: const Icon(
              Icons.chevron_right,
              color: AppColors.darkOnSurfaceMuted,
            ),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Innocent',
              applicationVersion: AppVersion.name,
              applicationLegalese: '© Personal project. All third-party '
                  'libraries are under their respective licenses.',
            ),
          ),
          const SizedBox(height: 32),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(AppStrings.of(context).personalProject,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.darkOnSurfaceMuted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.accentBlue,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _AboutTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _AboutTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppColors.accentBlue),
      title: Text(title, style: const TextStyle(color: Colors.white)),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: AppColors.darkOnSurfaceMuted,
          fontSize: 12,
        ),
      ),
    );
  }
}
