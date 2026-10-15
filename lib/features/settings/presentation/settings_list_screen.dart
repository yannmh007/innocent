import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/saf/saf_service.dart';
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
          SettingsSectionHeader(AppStrings.of(context).slAppearance),
          _toggle(ref,
              title: AppStrings.of(context).slFloating,
              subtitle:
                  AppStrings.of(context).slFloatingSub,
              setting: PlayerSetting.listFloatingButton),
          // Phase 45 (audit): MX Player's `new_tagged_period` is an
          // editable INT (days, default 7), not a boolean. We expose it
          // properly via the IntSetting.newTaggedPeriod we already have.
          Builder(builder: (ctx) {
            final days = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.newTaggedPeriod);
            return SettingsNavTile(
              title: AppStrings.of(context).slNewPeriod,
              subtitle:
                  AppStrings.of(context).slNewPeriodSub(days == 0 ? AppStrings.of(context).off : AppStrings.of(context).daysCount(days)),
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: AppStrings.of(context).slNewPeriod,
                  currentValue: days.toDouble(),
                  min: 0,
                  max: 90,
                  divisions: 90,
                  valueLabel: (v) => v.round() == 0
                      ? AppStrings.of(context).off
                      : AppStrings.of(context).daysCount(v.round()),
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setInt(IntSetting.newTaggedPeriod, picked.round());
                }
              },
            );
          }),
          SettingsSectionHeader(AppStrings.of(context).slScan),
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
              title: AppStrings.of(context).slExtensions,
              subtitle: AppStrings.of(context).slExtensionsOn(selected.length),
              onTap: () async {
                final picked = await showSettingsMultiSelectDialog(
                  context: context,
                  title: AppStrings.of(context).slExtensions,
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
                title: AppStrings.of(context).slNomedia,
                subtitle:
                    AppStrings.of(context).slNomediaSub,
                value: libPrefs.recognizeNomedia,
                onChanged: (v) => ref
                    .read(libraryPreferencesProvider.notifier)
                    .setAdvanced(recognizeNomedia: v),
              ),
              SettingsToggleTile(
                title: AppStrings.of(context).slShowHidden,
                subtitle:
                    AppStrings.of(context).slShowHiddenSub,
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
            final s = AppStrings.of(context);
            final api = _androidApiLevel();
            final trees = ref.watch(safGrantedTreesProvider).maybeWhen(
                  data: (t) => t,
                  orElse: () => const <String>[],
                );
            final count = trees.length;
            final String subtitle;
            if (count > 0) {
              subtitle = s.slSafGranted(trees.map(_prettyTree).join(', '));
            } else if (api >= 33) {
              subtitle = s.slSafBlocked;
            } else if (api >= 30) {
              subtitle = s.slSafGrant;
            } else if (api > 0) {
              subtitle = s.slSafNotNeeded(api);
            } else {
              subtitle = s.slSafGeneric;
            }
            return SettingsNavTile(
              title: s.slSafTitle,
              subtitle: subtitle,
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final granted = await SafService.instance.pickTree(
                    initialUri: SafService.androidDataInitialUri);
                ref.invalidate(safGrantedTreesProvider);
                if (granted == null) {
                  messenger
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(
                      content: Text(s.slSafNone),
                      duration: const Duration(seconds: 3),
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
                        ? s.slSafEmpty(_prettyTree(granted))
                        : s.slSafFound(_prettyTree(granted), vids.length)),
                    duration: const Duration(seconds: 5),
                    behavior: SnackBarBehavior.floating,
                  ));
              },
            );
          }),
          Consumer(builder: (context, ref, _) {
            final s = AppStrings.of(context);
            final count = ref.watch(safGrantedTreesProvider).maybeWhen(
                  data: (t) => t.length,
                  orElse: () => 0,
                );
            if (count == 0) return const SizedBox.shrink();
            return SettingsNavTile(
              title: s.slSafClear,
              subtitle: s.slSafClearSub(count),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                await SafService.instance.releaseAll();
                ref.invalidate(safGrantedTreesProvider);
                ref.invalidate(safVideosProvider);
                messenger
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                    content: Text(s.slSafCleared),
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ));
              },
            );
          }),
          // Phase 64 / M1b-B: opens the pairing + connect screen.
          SettingsNavTile(
            title: AppStrings.of(context).adbScreenTitle,
            subtitle: AppStrings.of(context).hfSettingsSub,
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
