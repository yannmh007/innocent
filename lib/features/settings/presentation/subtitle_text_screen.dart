import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_dialogs.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > Subtitle > Text
/// Font, size, color, border settings for subtitle text.
///
/// Phase 41: toggles persist via [playerSettingsProvider].
class SubtitleTextScreen extends ConsumerWidget {
  const SubtitleTextScreen({super.key});

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
      appBar: AppBar(title: Text(AppStrings.of(context).subtitleTextTitle)),
      body: ListView(
        children: [
          const SettingsSectionHeader('Font'),
          // Phase 45 (audit refined, build 64): wire Font picker.
          // 'Default' = libmpv system font. Other options set a
          // specific font family name. 'Custom' lets the user enter a
          // .ttf path from their typeface_dir.
          Builder(builder: (ctx) {
            const fontMap = <String, String>{
              'Default': '',
              'Sans-serif': 'sans-serif',
              'Serif': 'serif',
              'Monospace': 'monospace',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.typefaceDir);
            // If the stored value is in the map, show its label;
            // otherwise treat it as a custom font path/name.
            final curLabel = fontMap.entries
                .firstWhere(
                  (e) => e.value == cur,
                  orElse: () => cur.isEmpty
                      ? const MapEntry('Default', '')
                      : MapEntry(
                          cur.length > 24
                              ? '...${cur.substring(cur.length - 24)}'
                              : cur,
                          cur),
                )
                .key;
            return SettingsNavTile(
              title: 'Font',
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Font',
                  options: [...fontMap.keys, 'Custom (enter name)…'],
                  currentValue: fontMap.containsValue(cur)
                      ? fontMap.entries
                          .firstWhere((e) => e.value == cur)
                          .key
                      : 'Default',
                );
                if (picked == null) return;
                if (picked == 'Custom (enter name)…') {
                  if (!context.mounted) return;
                  final entered = await showSettingsTextDialog(
                    context: context,
                    title: 'Custom Font',
                    subtitle:
                        'Enter the font family name as installed on the device, or a full path to a .ttf / .otf file.',
                    currentValue: cur,
                    hintText: 'e.g. NotoSansMyanmar-Regular',
                  );
                  if (entered != null) {
                    await ref
                        .read(extraSettingsProvider.notifier)
                        .setStr(
                            StringSetting.typefaceDir, entered.trim());
                  }
                } else {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.typefaceDir,
                          fontMap[picked] ?? '');
                }
              },
            );
          }),
          // Phase 45 (audit refined, build 64): wire Size to
          // IntSetting.subtitleFontSize. Applied as a base preset
          // multiplied with the user's `subtitleScale` slider.
          Builder(builder: (ctx) {
            const opts = ['Tiny', 'Small', 'Medium', 'Large', 'Huge'];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleFontSize);
            final curLabel = opts[cur.clamp(0, 4)];
            return SettingsNavTile(
              title: 'Size',
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Font Size',
                  options: opts,
                  currentValue: curLabel,
                );
                if (picked != null) {
                  final idx = opts.indexOf(picked);
                  if (idx >= 0) {
                    await ref
                        .read(extraSettingsProvider.notifier)
                        .setInt(IntSetting.subtitleFontSize, idx);
                  }
                }
              },
            );
          }),
          _toggle(ref,
              title: 'Bold',
              subtitle: 'Use bold text for subtitles.',
              setting: PlayerSetting.subTextBold),
          const SettingsSectionHeader('Color'),
          // Phase 45 (audit refined, build 63): wire Text color to
          // IntSetting.subtitleTextColor (6-preset palette matching
          // MX Player V3). Applied to libmpv `sub-color` on every play.
          Builder(builder: (ctx) {
            const opts = ['White', 'Yellow', 'Cyan', 'Green', 'Red', 'Black'];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleTextColor);
            final curLabel = opts[cur.clamp(0, 5)];
            return SettingsNavTile(
              title: 'Text color',
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Text Color',
                  options: opts,
                  currentValue: curLabel,
                );
                if (picked != null) {
                  final idx = opts.indexOf(picked);
                  if (idx >= 0) {
                    await ref
                        .read(extraSettingsProvider.notifier)
                        .setInt(IntSetting.subtitleTextColor, idx);
                  }
                }
              },
            );
          }),
          const SettingsSectionHeader('Border'),
          // Phase 45 (audit refined, build 64): wire Border style to
          // IntSetting.subtitleBorderStyle. 5 options (None/Outline/
          // Drop shadow/Raised/Depressed). Applied via libmpv's
          // sub-border-size + sub-shadow-offset on every play.
          Builder(builder: (ctx) {
            const opts = [
              'None',
              'Outline',
              'Drop shadow',
              'Raised',
              'Depressed'
            ];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleBorderStyle);
            final curLabel = opts[cur.clamp(0, 4)];
            return SettingsNavTile(
              title: 'Border style',
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Border Style',
                  options: opts,
                  currentValue: curLabel,
                );
                if (picked != null) {
                  final idx = opts.indexOf(picked);
                  if (idx >= 0) {
                    await ref
                        .read(extraSettingsProvider.notifier)
                        .setInt(IntSetting.subtitleBorderStyle, idx);
                  }
                }
              },
            );
          }),
          // Phase 45 (audit refined, build 63): wire Border color to
          // IntSetting.subtitleBorderColor. Applied to libmpv
          // `sub-border-color` on every play.
          Builder(builder: (ctx) {
            const opts = ['White', 'Yellow', 'Cyan', 'Green', 'Red', 'Black'];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleBorderColor);
            final curLabel = opts[cur.clamp(0, 5)];
            return SettingsNavTile(
              title: 'Border color',
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Border Color',
                  options: opts,
                  currentValue: curLabel,
                );
                if (picked != null) {
                  final idx = opts.indexOf(picked);
                  if (idx >= 0) {
                    await ref
                        .read(extraSettingsProvider.notifier)
                        .setInt(IntSetting.subtitleBorderColor, idx);
                  }
                }
              },
            );
          }),
          // Phase 45 (audit): MX Player subtitle text settings include
          // Scale / Shadow / Background / Background Color / Alignment /
          // Bottom margins / Improve stroke rendering. Surface them all
          // for visual parity. Persistence wiring per setting can be
          // added in next phase; these are visible-only for now to
          // match MX Player's settings list 1:1.
          const SettingsSectionHeader('Appearance'),
          // Phase 45 (audit refined, build 63): wire Scale to
          // IntSetting.subtitleScale (stored as percent 10-200, default
          // 100 = 1.0x). Applied to libmpv `sub-scale` on every play.
          Builder(builder: (ctx) {
            final scalePct = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleScale);
            return SettingsNavTile(
              title: 'Scale',
              subtitle: '${(scalePct / 100).toStringAsFixed(2)}x',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Subtitle Scale',
                  currentValue: scalePct.toDouble(),
                  min: 10,
                  max: 200,
                  divisions: 19,
                  valueLabel: (v) => '${(v / 100).toStringAsFixed(2)}x',
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setInt(IntSetting.subtitleScale, picked.round());
                }
              },
            );
          }),
          // Phase 45 (audit refined, build 63): wire Shadow to
          // IntSetting.subtitleShadow (0=None, 1=Subtle, 2=Default,
          // 3=Strong). Applied to libmpv sub-shadow-color +
          // sub-shadow-offset.
          Builder(builder: (ctx) {
            const opts = ['None', 'Subtle', 'Default', 'Strong'];
            final lvl = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleShadow);
            final curLabel = opts[lvl.clamp(0, 3)];
            return SettingsNavTile(
              title: 'Shadow',
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Shadow',
                  options: opts,
                  currentValue: curLabel,
                );
                if (picked != null) {
                  final idx = opts.indexOf(picked);
                  if (idx >= 0) {
                    await ref
                        .read(extraSettingsProvider.notifier)
                        .setInt(IntSetting.subtitleShadow, idx);
                  }
                }
              },
            );
          }),
          // Phase 45 (audit refined, build 63): wire Background to
          // IntSetting.subtitleBackgroundOpacity (0=Transparent,
          // 1=Translucent, 2=Opaque). Applied to libmpv
          // sub-back-color alpha.
          Builder(builder: (ctx) {
            const opts = ['Transparent', 'Translucent', 'Opaque'];
            final lvl = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleBackgroundOpacity);
            final curLabel = opts[lvl.clamp(0, 2)];
            return SettingsNavTile(
              title: 'Background',
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Background',
                  options: opts,
                  currentValue: curLabel,
                );
                if (picked != null) {
                  final idx = opts.indexOf(picked);
                  if (idx >= 0) {
                    await ref
                        .read(extraSettingsProvider.notifier)
                        .setInt(
                            IntSetting.subtitleBackgroundOpacity, idx);
                  }
                }
              },
            );
          }),
          // Phase 45 (audit refined, build 63): wire Background Color
          // to IntSetting.subtitleBackgroundColor. Applied with the
          // chosen opacity to produce a proper ARGB on libmpv.
          Builder(builder: (ctx) {
            const opts = ['White', 'Yellow', 'Cyan', 'Green', 'Red', 'Black'];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleBackgroundColor);
            final curLabel = opts[cur.clamp(0, 5)];
            return SettingsNavTile(
              title: 'Background Color',
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Background Color',
                  options: opts,
                  currentValue: curLabel,
                );
                if (picked != null) {
                  final idx = opts.indexOf(picked);
                  if (idx >= 0) {
                    await ref
                        .read(extraSettingsProvider.notifier)
                        .setInt(IntSetting.subtitleBackgroundColor, idx);
                  }
                }
              },
            );
          }),
          // Phase 45 (audit refined, build 63): wire Alignment to
          // IntSetting.subtitleAlignment (0=Left, 1=Center, 2=Right).
          // Applied to libmpv `sub-align-x` on every play.
          Builder(builder: (ctx) {
            const opts = ['Left', 'Center', 'Right'];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleAlignment);
            final curLabel = opts[cur.clamp(0, 2)];
            return SettingsNavTile(
              title: 'Alignment',
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Text Alignment',
                  options: opts,
                  currentValue: curLabel,
                );
                if (picked != null) {
                  final idx = opts.indexOf(picked);
                  if (idx >= 0) {
                    await ref
                        .read(extraSettingsProvider.notifier)
                        .setInt(IntSetting.subtitleAlignment, idx);
                  }
                }
              },
            );
          }),
          // Phase 45 (audit refined, build 63): wire Bottom margins to
          // IntSetting.subtitleBottomMargin (0-20% of screen height).
          // Applied to libmpv sub-margin-y on every play.
          Builder(builder: (ctx) {
            final pct = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleBottomMargin);
            return SettingsNavTile(
              title: 'Bottom margins',
              subtitle: pct == 0
                  ? '0% (touching bottom edge)'
                  : '$pct% of screen height',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Bottom Margins',
                  currentValue: pct.toDouble(),
                  min: 0,
                  max: 20,
                  divisions: 20,
                  valueLabel: (v) => '${v.round()}%',
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setInt(IntSetting.subtitleBottomMargin,
                          picked.round());
                }
              },
            );
          }),
          _toggle(ref,
              title: 'Improve stroke rendering',
              subtitle:
                  'Render subtitle stroke at higher quality. Slightly more CPU.',
              setting: PlayerSetting.subTextImproveStroke),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
