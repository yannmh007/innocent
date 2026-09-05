import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/tablet_constrained_width.dart';
import 'settings_audio_screen.dart';
import 'settings_decoder_screen.dart';
import 'settings_development_screen.dart';
import 'settings_diagnostics_screen.dart';
import 'settings_general_screen.dart';
import 'settings_language_screen.dart';
import 'settings_list_screen.dart';
import 'settings_player_screen.dart';
import 'settings_subtitle_screen.dart';
import '../../updater/presentation/app_update_screen.dart';

/// Settings screen matching MX Player (UI PDF page 14)
/// 8 items with specific icons matching the real app exactly
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _selectedIndex = -1;

  void _open(int index, Widget screen) {
    setState(() => _selectedIndex = index);
    // Code-quality audit: was .then() without onError or mounted
    // check. The push future completes when the user returns to this
    // screen; if they navigated away in the meantime calling setState
    // on a disposed State would throw. Guard both paths.
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen))
        .then((_) {
      if (!mounted) return;
      setState(() => _selectedIndex = -1);
    }, onError: (e) {
      if (kDebugMode) debugPrint('Settings nav push failed: $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final items = <_SettingsEntry>[
      _SettingsEntry(Icons.list_alt, s.settingsList),
      _SettingsEntry(Icons.hexagon_outlined, s.settingsPlayer),
      // Phase 30: Decoder uses chip/memory icon (verified against MX recording)
      _SettingsEntry(Icons.memory, s.settingsDecoder),
      // Phase 30: Audio uses music-note-in-square icon
      _SettingsEntry(Icons.audiotrack, s.settingsAudio),
      _SettingsEntry(Icons.subtitles_outlined, s.settingsSubtitle),
      _SettingsEntry(Icons.error_outline, s.settingsGeneral),
      _SettingsEntry(Icons.data_object, s.settingsDevelopment),
      // v1.61. Not localised on purpose: every line it shows is a raw Android
      // record in English, so three translations of the label around it would
      // be decoration. See SettingsDiagnosticsScreen.
      _SettingsEntry(Icons.bug_report_outlined, 'Diagnostics'),
      // Phase 30: App Language uses translate icon (the "A" with arrow)
      _SettingsEntry(Icons.translate, s.settingsAppLanguage),
      // updater_plan.md step 2. NEVER HIDDEN, even when up to date - this is
      // where someone goes after dismissing a prompt, and the only place they
      // can confirm the app is not stale.
      _SettingsEntry(Icons.system_update, s.settingsAppUpdate),
    ];

    final screens = <Widget>[
      const SettingsListScreen(),
      const SettingsPlayerScreen(),
      const SettingsDecoderScreen(),
      const SettingsAudioScreen(),
      const SettingsSubtitleScreen(),
      const SettingsGeneralScreen(),
      const SettingsDevelopmentScreen(),
      const SettingsDiagnosticsScreen(),
      const SettingsLanguageScreen(),
      const AppUpdateScreen(),
    ];

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(s.settings)),
      // Phase 45 (audit): cap content width on tablets/foldables so
      // the list doesn't sprawl edge-to-edge. No-op on phones.
      body: TabletConstrainedWidth(
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (_, i) {
            final item = items[i];
            final isSelected = _selectedIndex == i;
            return InkWell(
              key: ValueKey(item.title),
              onTap: () => _open(i, screens[i]),
              child: Container(
                color: isSelected
                    ? AppColors.primaryBlue.withOpacity(0.12)
                    : Colors.transparent,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                child: Row(
                  children: [
                    Icon(
                      item.icon,
                      color: AppColors.primaryBlue,
                      size: 22,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        item.title,
                        style: TextStyle(
                          color: isSelected
                              ? AppColors.primaryBlue
                              : Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SettingsEntry {
  final IconData icon;
  final String title;
  const _SettingsEntry(this.icon, this.title);
}
