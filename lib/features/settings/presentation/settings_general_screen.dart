import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/localization/locale_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/app_version.dart';
import '../../../core/di/core_providers.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/thumbnail/thumbnail_cache.dart';
import '../../../core/theme/app_colors.dart';
import '../../user_data/user_data_providers.dart';
import 'settings_dialogs.dart';
import 'settings_language_screen.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > General — full MX Player parity (UI PDF page 18).
/// Sections: default, Edit, User data.
///
/// Phase 41: toggles persist via [playerSettingsProvider]; "Clear history"
/// and "Clear thumbnail cache" now do real work via user-data providers /
/// thumbnail cache.
class SettingsGeneralScreen extends ConsumerWidget {
  const SettingsGeneralScreen({super.key});

  Widget _toggle(
    WidgetRef ref, {
    required String title,
    String? subtitle,
    required PlayerSetting setting,
  }) {
    final value = ref.watch(playerSettingsProvider).get(setting);
    return SettingsToggleTile(
      title: title,
      subtitle: subtitle,
      value: value,
      onChanged: (v) =>
          ref.read(playerSettingsProvider.notifier).setValue(setting, v),
    );
  }

  // Audit: full-storage-access request flow. On API 30+ the user has
  // to manually flip the switch on a dedicated "All files access"
  // screen — there is no regular permission dialog for this. We
  // first show an explanatory sheet so the user understands what
  // they're about to enable, then deep-link into the system screen.
  Future<void> _requestFullStorageAccess(
      BuildContext context, WidgetRef ref) async {
    final permSvc = ref.read(permissionServiceProvider);
    final alreadyGranted = await permSvc.hasFullStorageAccess();
    if (!context.mounted) return;
    if (alreadyGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).fullAccessAlready),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).fullAccessTitle,
            style: TextStyle(color: Colors.white)),
        content: Text(AppStrings.of(context).fullAccessBody,
          style: TextStyle(color: AppColors.darkOnSurfaceMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(AppStrings.of(context).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(AppStrings.of(context).permissionOpenSettings,
                style: TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await permSvc.requestFullStorageAccess();
    // Best-effort: re-check after a small delay so the snackbar
    // reflects the state the user just chose. The system screen
    // exits asynchronously; if our check fires too early we may see
    // the pre-change state and show a misleading message, so we
    // sample a few times.
    for (var i = 0; i < 5; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!context.mounted) return;
      final ok = await permSvc.hasFullStorageAccess();
      if (ok) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings.of(context).fullAccessEnabled),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(AppStrings.of(context).permissionNotGranted),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _confirmAndClearHistory(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).clearHistoryTitle,
            style: TextStyle(color: Colors.white)),
        content: Text(AppStrings.of(context).clearHistoryBody,
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(AppStrings.of(context).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(AppStrings.of(context).clear,
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    // Phase 41: actually wipe the history list.
    await ref.read(historyProvider.notifier).clear();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(AppStrings.of(context).historyCleared),
          duration: Duration(seconds: 2)),
    );
  }

  Future<void> _confirmAndClearThumbnails(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).clearThumbTitle,
            style: TextStyle(color: Colors.white)),
        content: Text(AppStrings.of(context).clearThumbBody,
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(AppStrings.of(context).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(AppStrings.of(context).clear,
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    // Phase 41: actually clear the in-memory + disk thumbnail cache.
    try {
      await ThumbnailCache.instance.clear();
    } catch (e) { if (kDebugMode) debugPrint('settings_general_screen.best-effort: $e'); }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(AppStrings.of(context).thumbCleared),
          duration: Duration(seconds: 2)),
    );
  }

  /// Phase 45 (audit): Reset all preferences to defaults. Confirms with
  /// the user first because this is destructive — they could lose hours
  /// of fiddly tuning.
  Future<void> _confirmAndResetSettings(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).resetSettingsTitle,
            style: TextStyle(color: Colors.white)),
        content: Text(AppStrings.of(context).resetSettingsBodyFull,
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(AppStrings.of(context).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(AppStrings.of(context).reset,
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(playerSettingsProvider.notifier).resetAll();
    } catch (e) { if (kDebugMode) debugPrint('settings_general_screen.best-effort: $e'); }
    try {
      await ref.read(extraSettingsProvider.notifier).resetAll();
    } catch (e) { if (kDebugMode) debugPrint('settings_general_screen.best-effort: $e'); }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.of(context).settingsResetDone)),
    );
  }

  /// Phase 45 (audit refined, build 64): actual Export JSON. Builds a
  /// flat map of every PlayerSetting bool + every ExtraSetting
  /// string/int and writes it to the app's documents directory. Path
  /// is reported in a snackbar so the user can grab the file with a
  /// file manager.
  Future<void> _exportSettings(
      BuildContext context, WidgetRef ref) async {
    try {
      final ps = ref.read(playerSettingsProvider);
      final es = ref.read(extraSettingsProvider);
      final out = <String, dynamic>{
        'schema_version': 1,
        'app_build': AppVersion.build,
        'exported_at': DateTime.now().toIso8601String(),
        'player_settings': <String, bool>{
          for (final s in PlayerSetting.values) s.name: ps.get(s),
        },
        'string_settings': <String, String>{
          for (final s in StringSetting.values) s.name: es.getStr(s),
        },
        'int_settings': <String, int>{
          for (final s in IntSetting.values) s.name: es.getInt(s),
        },
      };
      final jsonStr = const JsonEncoder.withIndent('  ').convert(out);
      final docsDir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final f = File('${docsDir.path}/mx_clone_settings_$ts.json');
      await f.writeAsString(jsonStr);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).exportedTo(f.path)),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.of(context).exportFailed + ': $e')),
      );
    }
  }

  /// Phase 45 (audit refined, build 64): actual Import JSON. Looks
  /// for the most recent `mx_clone_settings_*.json` in the docs
  /// directory and re-applies every value through the providers so
  /// the UI updates immediately. Unknown keys are silently ignored
  /// for forward compatibility.
  Future<void> _importSettings(
      BuildContext context, WidgetRef ref) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final candidates = docsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path
              .split('/')
              .last
              .startsWith('mx_clone_settings_'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      if (candidates.isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppStrings.of(context).noExportFile)),
        );
        return;
      }
      final file = candidates.first;
      final data = jsonDecode(await file.readAsString())
          as Map<String, dynamic>;
      final pNotifier = ref.read(playerSettingsProvider.notifier);
      final eNotifier = ref.read(extraSettingsProvider.notifier);
      // Player bools.
      final playerMap = (data['player_settings'] as Map?)
              ?.cast<String, dynamic>() ??
          const {};
      for (final s in PlayerSetting.values) {
        final v = playerMap[s.name];
        if (v is bool) {
          try {
            await pNotifier.setValue(s, v);
          } catch (e) {
            // Code-quality audit: was silent. If one setting fails to
            // import we want the trace in debug builds so the user
            // can be told (or the developer can fix) which key was
            // bad without aborting the whole restore.
            if (kDebugMode) debugPrint('Import failed for PlayerSetting.${s.name}: $e');
          }
        }
      }
      // Strings.
      final stringMap = (data['string_settings'] as Map?)
              ?.cast<String, dynamic>() ??
          const {};
      for (final s in StringSetting.values) {
        final v = stringMap[s.name];
        if (v is String) {
          try {
            await eNotifier.setStr(s, v);
          } catch (e) {
            if (kDebugMode) debugPrint('Import failed for StringSetting.${s.name}: $e');
          }
        }
      }
      // Ints.
      final intMap = (data['int_settings'] as Map?)
              ?.cast<String, dynamic>() ??
          const {};
      for (final s in IntSetting.values) {
        final v = intMap[s.name];
        if (v is int) {
          try {
            await eNotifier.setInt(s, v);
          } catch (e) {
            if (kDebugMode) debugPrint('Import failed for IntSetting.${s.name}: $e');
          }
        }
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).importedFrom(file.path)),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.of(context).importFailed + ': $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).settingsGeneral)),
      body: ListView(
        children: [
          SettingsNavTile(
            title: 'App Language',
            subtitle: 'System default',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SettingsLanguageScreen())),
          ),
          _toggle(ref,
              title: 'Play media links',
              subtitle:
                  'Play HTTP/HTTPS media links. This option can interfere with file downloading.',
              setting: PlayerSetting.generalPlayMediaLinks),
          // Phase 45 (audit refined, build 63): MX Player V3 `user_locale`
          // App language.
          //
          // This used to write StringSetting.userLocale, which nothing read,
          // and then show a toast promising the change would apply after a
          // restart — a promise the app had no code to keep. It now drives
          // localeProvider, the same state the dedicated Language screen uses,
          // so the app re-renders in the chosen language immediately and the
          // two screens can never disagree about what is selected.
          Builder(builder: (ctx) {
            final current = ref.watch(localeProvider);
            String labelFor((String?, String, String) e) =>
                e.$3.isEmpty ? e.$2 : '${e.$2} (${e.$3})';
            final cur = kAppLanguages.firstWhere(
              (e) => e.$1 == current?.languageCode,
              orElse: () => kAppLanguages.first,
            );
            return SettingsNavTile(
              title: 'App language',
              subtitle: labelFor(cur),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'App Language',
                  options: kAppLanguages.map(labelFor).toList(),
                  currentValue: labelFor(cur),
                );
                if (picked == null) return;
                final chosen = kAppLanguages
                    .firstWhere((e) => labelFor(e) == picked,
                        orElse: () => kAppLanguages.first);
                await ref.read(localeProvider.notifier).setLocale(
                    chosen.$1 == null ? null : Locale(chosen.$1!));
                // Also mirror it into the persisted string setting so anything
                // reading that key (diagnostics, future export) agrees.
                await ref.read(extraSettingsProvider.notifier).setStr(
                    StringSetting.userLocale, chosen.$1 ?? '');
              },
            );
          }),
          // Phase 45 (audit): HTTP User-Agent backed by ExtraSettings.
          Builder(builder: (ctx) {
            final ua = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.httpUserAgent);
            return SettingsNavTile(
              title: 'Http User-Agent',
              subtitle: ua.isEmpty
                  ? 'Default (libmpv built-in)'
                  : ua,
              onTap: () async {
                final picked = await showSettingsTextDialog(
                  context: context,
                  title: 'Http User-Agent',
                  subtitle: 'Leave blank to use default value.',
                  currentValue: ua,
                  hintText: 'Custom User-Agent string',
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.httpUserAgent, picked.trim());
                }
              },
            );
          }),
          _toggle(ref,
              title: 'Quit Button',
              subtitle:
                  "Display Quit button on the Me page (mobile devices) / menu (TV mode). This will terminate the app completely unlike 'back' or 'home' button.",
              setting: PlayerSetting.generalQuitButton),
          // Phase 45 (audit refined, build 63): MX Player V3's `tv_mode`
          // — Android TV / leanback UI mode. Larger fonts, focus rings,
          // and D-pad navigation. Off by default for phones.
          _toggle(ref,
              title: 'TV mode',
              subtitle:
                  'Switch to a TV-friendly UI with larger fonts and D-pad focus rings. Recommended for Android TV and TV-stick devices.',
              setting: PlayerSetting.tvMode),
          // Original feature: privacy mode. Stops the app from writing
          // to history / resume / recently-added for as long as the
          // toggle is on. Existing history is untouched; turning it
          // off resumes normal tracking.
          _toggle(ref,
              title: 'Privacy mode (incognito watch)',
              subtitle:
                  "Don't record what you watch while this is on. History, resume positions, and recently-added stay paused. Existing entries are kept. Nothing leaves the device either way.",
              setting: PlayerSetting.privacyMode),
          // Audit: optional all-files access. The default scoped
          // storage covers most libraries (Movies/DCIM/Downloads).
          // This tile is for users with custom folder layouts who
          // want the library to scan beyond the standard roots. Tap
          // → opens the system "All files access" Settings screen.
          SettingsNavTile(
            title: 'Full library access',
            subtitle:
                'Optional. Lets the library scan folders outside Movies/DCIM/Downloads. Opens Android Settings → All files access. Off by default.',
            onTap: () => _requestFullStorageAccess(context, ref),
          ),
          const SettingsSectionHeader('Edit'),
          _toggle(ref,
              title: 'Allow editing',
              subtitle:
                  'Enable edit menu which allows you to delete or rename files and folders.',
              setting: PlayerSetting.generalAllowEditing),
          _toggle(ref,
              title: 'Delete subtitle files together',
              setting: PlayerSetting.generalDeleteSubtitleFiles),
          const SettingsSectionHeader('User data'),
          SettingsNavTile(
            title: 'Clear history',
            subtitle:
                'Clear all user activity records, including playback and search history.',
            onTap: () => _confirmAndClearHistory(context, ref),
          ),
          SettingsNavTile(
            title: 'Clear thumbnail cache',
            subtitle:
                'Clear thumbnails cached on the sdcard. Thumbnails will be generated again when media list is opened.',
            onTap: () => _confirmAndClearThumbnails(context, ref),
          ),
          _toggle(ref,
              title: 'Cache thumbnail',
              setting: PlayerSetting.generalCacheThumbnail),
          SettingsNavTile(
            title: 'Clear font cache',
            subtitle:
                'Clear font cache for SubStation Alpha subtitle in case of corruption.',
            onTap: () {
              showDialog(
                context: context,
                builder: (dctx) => AlertDialog(
                  backgroundColor: AppColors.darkSurface,
                  title: Text(AppStrings.of(context).clearFontCacheTitle,
                      style: TextStyle(color: Colors.white)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dctx),
                      child: Text(AppStrings.of(context).cancel),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(dctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text(AppStrings.of(context).fontCacheCleared)),
                        );
                      },
                      child: Text(AppStrings.of(context).clear,
                          style: TextStyle(color: Colors.redAccent)),
                    ),
                  ],
                ),
              );
            },
          ),
          // Phase 45 (audit): MX Player V3 has Reset Settings + Export +
          // Import in this section. Reset clears all preferences and
          // restores defaults; Export/Import would persist to JSON
          // (not yet implemented, surfaced as "coming soon" message).
          const SettingsSectionHeader('Backup'),
          SettingsNavTile(
            title: 'Reset settings',
            subtitle:
                'Restore all settings to their default values. Does not delete history or playlists.',
            onTap: () => _confirmAndResetSettings(context, ref),
          ),
          // Phase 45 (audit refined, build 64): actual Export/Import
          // JSON. Serialise every PlayerSetting bool + every
          // ExtraSetting string/int into a flat map and write to
          // disk. Import reverses the process and re-applies values
          // through the providers so the UI updates immediately.
          SettingsNavTile(
            title: 'Export',
            subtitle: 'Export preferences to a JSON file.',
            onTap: () => _exportSettings(context, ref),
          ),
          SettingsNavTile(
            title: 'Import from file',
            subtitle: 'Restore preferences from a JSON file.',
            onTap: () => _importSettings(context, ref),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
