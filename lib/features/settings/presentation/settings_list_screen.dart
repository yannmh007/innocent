import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/saf/saf_service.dart';
import '../../../core/services/adb/adb_service.dart';
import 'adb_connect_screen.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/tablet_constrained_width.dart';
import '../../local_browser/presentation/library_provider.dart';
import 'settings_dialogs.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > List screen matching MX Player (UI PDF page 14 right panel)
/// Appearance section + Scan section.
///
/// Phase 41: every toggle now persists via [playerSettingsProvider] so the
/// user's choices survive an app restart.
class SettingsListScreen extends ConsumerWidget {
  const SettingsListScreen({super.key});

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).settingsList)),
      // Phase 45 (audit): cap content width on tablets.
      body: TabletConstrainedWidth(
        child: ListView(
          children: [
          const SettingsSectionHeader('Appearance'),
          _toggle(ref,
              title: 'Last media in each folder',
              subtitle: 'Mark last played media in each folder.',
              setting: PlayerSetting.listLastMediaInFolder),
          _toggle(ref,
              title: 'Scroll down to last media',
              subtitle: 'Auto-scroll to position of the last played media.',
              setting: PlayerSetting.listScrollToLastMedia),
          _toggle(ref,
              title: 'Select thumbnail',
              subtitle:
                  'Switch to selection mode by touching the thumbnail or icon.',
              setting: PlayerSetting.listSelectThumbnail),
          _toggle(ref,
              title: 'Floating button',
              subtitle:
                  'Place a floating button on the bottom right corner of the screen to start last played media.',
              setting: PlayerSetting.listFloatingButton),
          // Phase 45 (audit): MX Player's `new_tagged_period` is an
          // editable INT (days, default 7), not a boolean. We expose it
          // properly via the IntSetting.newTaggedPeriod we already have.
          Builder(builder: (ctx) {
            final days = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.newTaggedPeriod);
            return SettingsNavTile(
              title: 'Period tagged as "NEW"',
              subtitle:
                  '"NEW" tag will be displayed if the file was modified within this period. Currently: $days day${days == 1 ? "" : "s"}',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Days for "NEW" Tag',
                  currentValue: days.toDouble(),
                  min: 0,
                  max: 90,
                  divisions: 90,
                  valueLabel: (v) =>
                      v.round() == 0 ? 'Disabled' : '${v.round()} days',
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setInt(IntSetting.newTaggedPeriod, picked.round());
                }
              },
            );
          }),
          const SettingsSectionHeader('Scan'),
          // Phase 45 (audit refined, build 64): wire Folders multi-select
          // to a SharedPreferences-backed string list (CSV in
          // StringSetting.scanFolders). Default = Internal storage only.
          Builder(builder: (ctx) {
            final raw = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.scanFolders);
            final selected = raw.isEmpty
                ? <String>['Internal storage']
                : raw.split('|');
            return SettingsNavTile(
              title: 'Folders',
              subtitle: selected.length == 1
                  ? selected.first
                  : '${selected.length} folders selected',
              onTap: () async {
                final picked = await showSettingsMultiSelectDialog(
                  context: context,
                  title: 'Folders',
                  options: const [
                    'Internal storage',
                    'SD Card',
                    'USB Storage'
                  ],
                  selectedValues: selected,
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.scanFolders,
                          picked.join('|'));
                }
              },
            );
          }),
          // Phase 45 (audit refined, build 64): wire File extensions
          // multi-select. Stored as pipe-separated CSV in
          // StringSetting.scanExtensions.
          Builder(builder: (ctx) {
            final raw = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.scanExtensions);
            const defaults = [
              '.mp4', '.mkv', '.avi', '.mov', '.webm'
            ];
            final selected =
                raw.isEmpty ? defaults : raw.split('|');
            return SettingsNavTile(
              title: 'File extensions',
              subtitle: '${selected.length} extensions enabled',
              onTap: () async {
                final picked = await showSettingsMultiSelectDialog(
                  context: context,
                  title: 'File Extensions',
                  options: const [
                    '.mp4',
                    '.mkv',
                    '.avi',
                    '.mov',
                    '.flv',
                    '.wmv',
                    '.webm',
                    '.3gp',
                    '.ts',
                    '.m4v'
                  ],
                  selectedValues: selected,
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.scanExtensions,
                          picked.join('|'));
                }
              },
            );
          }),
          // These two used to write PlayerSetting keys that nothing read,
          // while the Videos list's own sort/view sheet had switches with the
          // SAME labels driving `libraryPreferences` — the state the library
          // filter actually consults. Two screens, one feature, one of them
          // connected, and the two disagreeing about what was selected. Both
          // now drive the same state.
          Consumer(builder: (context, ref, _) {
            final libPrefs = ref.watch(libraryPreferencesProvider);
            return Column(children: [
              SettingsToggleTile(
                title: 'Recognize .nomedia',
                subtitle:
                    'Exclude any media file from a video list if a ".nomedia" file exists in that folder or a parent folder.',
                value: libPrefs.recognizeNomedia,
                onChanged: (v) => ref
                    .read(libraryPreferencesProvider.notifier)
                    .setAdvanced(recognizeNomedia: v),
              ),
              SettingsToggleTile(
                title: 'Show hidden files and folders',
                subtitle:
                    'Show hidden folders and files starting with "." (dot).',
                value: libPrefs.showHidden,
                onChanged: (v) => ref
                    .read(libraryPreferencesProvider.notifier)
                    .setAdvanced(showHidden: v),
              ),
            ]);
          }),
          // Phase 63: SAF grant for OS-restricted folders (Android/data). Only
          // meaningful with "Show hidden files" on — that's when the granted
          // videos are folded into Local.
          Consumer(builder: (context, ref, _) {
            final api = _androidApiLevel();
            final trees = ref.watch(safGrantedTreesProvider).maybeWhen(
                  data: (t) => t,
                  orElse: () => const <String>[],
                );
            final count = trees.length;
            final String subtitle;
            if (count > 0) {
              subtitle =
                  'Granted: ${trees.map(_prettyTree).join(", ")}. Tap to add '
                  'another folder.';
            } else if (api >= 33) {
              subtitle =
                  'Android $api restricts Android/data — the system may block '
                  'selecting it. Grant it here; if it returns 0 videos, only '
                  'Shizuku or root can reach it. Also turn on "Show hidden '
                  'files".';
            } else if (api >= 30) {
              subtitle =
                  'Grant Android/data (e.g. Telegram cache) to reveal its '
                  'videos in Local. Also turn on "Show hidden files". '
                  'Grants belong to the installed app, so a reinstall clears '
                  'them and they have to be given again.';
            } else if (api > 0) {
              subtitle =
                  'Not required on Android $api — hidden folders are read '
                  'directly. Just turn on "Show hidden files".';
            } else {
              subtitle =
                  'Reveal videos inside Android/data and other restricted '
                  'folders. Also turn on "Show hidden files".';
            }
            return SettingsNavTile(
              title: 'Grant access to restricted folders',
              subtitle: subtitle,
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final granted = await SafService.instance.pickTree(
                    initialUri: SafService.androidDataInitialUri);
                ref.invalidate(safGrantedTreesProvider);
                if (granted == null) {
                  messenger
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(
                      content: Text(
                          'No folder was granted (cancelled or blocked by '
                          'Android).'),
                      duration: Duration(seconds: 3),
                      behavior: SnackBarBehavior.floating,
                    ));
                  return;
                }
                ref.invalidate(safVideosProvider);
                // Diagnostic: how many videos did the grant actually expose?
                final vids = await SafService.instance.listVideos();
                messenger
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                    content: Text(vids.isEmpty
                        ? 'Granted "${_prettyTree(granted)}", but found 0 '
                            'videos inside. On Android 13+ the system usually '
                            'blocks Android/data itself — Shizuku or root is '
                            'needed there.'
                        : 'Granted "${_prettyTree(granted)}" — found '
                            '${vids.length} video${vids.length == 1 ? "" : "s"}.'),
                    duration: const Duration(seconds: 5),
                    behavior: SnackBarBehavior.floating,
                  ));
              },
            );
          }),
          Consumer(builder: (context, ref, _) {
            final count = ref.watch(safGrantedTreesProvider).maybeWhen(
                  data: (t) => t.length,
                  orElse: () => 0,
                );
            if (count == 0) return const SizedBox.shrink();
            return SettingsNavTile(
              title: 'Clear granted folders',
              subtitle: 'Revoke all $count granted folder'
                  '${count == 1 ? "" : "s"}.',
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                await SafService.instance.releaseAll();
                ref.invalidate(safGrantedTreesProvider);
                ref.invalidate(safVideosProvider);
                messenger
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(
                    content: Text('Granted folders cleared'),
                    duration: Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ));
              },
            );
          }),
          // Phase 64 / M1a: ADB engine self-test. Builds/loads the client key
          // + certificate natively and reports whether the libadb-android
          // foundation works on this device — before any pairing is wired.
          SettingsNavTile(
            title: 'ADB engine self-test (experimental)',
            subtitle: 'Check the embedded ADB engine builds its key & '
                'certificate on this device. Groundwork for Android/data '
                'access — no connection yet.',
            onTap: () async {
              final ctx = context;
              final status = await AdbService.instance.init();
              if (!ctx.mounted) return;
              showDialog<void>(
                context: ctx,
                builder: (dialogCtx) => AlertDialog(
                  title: const Text('ADB engine self-test'),
                  content: Text(status),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogCtx).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            },
          ),
          // Phase 64 / M1b-B: opens the pairing + connect screen.
          SettingsNavTile(
            title: 'ADB connection (experimental)',
            subtitle: 'Pair & connect over wireless debugging — the path to '
                'reading videos inside Android/data.',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AdbConnectScreen(),
                ),
              );
            },
          ),
        ],
        ),
      ),
    );
  }
}

/// Best-effort Android API level parsed from the platform version string
/// (e.g. "Android 13 (API 33), …"). Returns 0 if it can't be parsed or the
/// platform isn't Android — callers treat 0 as "unknown, show generic copy".
int _androidApiLevel() {
  if (!Platform.isAndroid) return 0;
  try {
    final m = RegExp(r'API (\d+)').firstMatch(Platform.operatingSystemVersion);
    if (m != null) return int.parse(m.group(1)!);
  } catch (_) {/* fall through to 0 */}
  return 0;
}

/// Decode a SAF tree URI into a human-readable folder path, e.g.
/// "content://….documents/tree/primary%3AAndroid%2Fdata" →
/// "Internal storage/Android/data". Falls back to the raw URI on any surprise.
String _prettyTree(String uri) {
  try {
    final decoded = Uri.decodeFull(uri);
    final idx = decoded.indexOf('/tree/');
    if (idx >= 0) {
      var docId = decoded.substring(idx + 6);
      final docPart = docId.indexOf('/document/');
      if (docPart >= 0) docId = docId.substring(0, docPart);
      final colon = docId.indexOf(':');
      if (colon >= 0) {
        final vol = docId.substring(0, colon);
        final rel = docId.substring(colon + 1);
        final root = vol == 'primary' ? 'Internal storage' : vol;
        return rel.isEmpty ? root : '$root/$rel';
      }
      return docId;
    }
  } catch (_) {/* fall through */}
  return uri;
}
