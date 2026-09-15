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
    final s = AppStrings.of(context);
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(s.subtitleTextTitle)),
      body: ListView(
        children: [
          SettingsSectionHeader(s.subFont),
          // Phase 45 (audit refined, build 64): wire Font picker.
          // 'Default' = libmpv system font. Other options set a
          // specific font family name. 'Custom' lets the user enter a
          // .ttf path from their typeface_dir.
          Builder(builder: (ctx) {
            // Labels localised, VALUES untouched: the stored preference is
            // the map's value, and the reverse lookup below compares values,
            // so translating the keys cannot change what is saved.
            final fontMap = <String, String>{
              s.subFontDefault: '',
              s.subFontSansSerif: 'sans-serif',
              s.subFontSerif: 'serif',
              s.subFontMonospace: 'monospace',
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
                      ? MapEntry(s.subFontDefault, '')
                      : MapEntry(
                          cur.length > 24
                              ? '...${cur.substring(cur.length - 24)}'
                              : cur,
                          cur),
                )
                .key;
            return SettingsNavTile(
              title: s.subFont,
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.subFont,
                  options: [...fontMap.keys, s.subFontCustomEnter],
                  currentValue: fontMap.containsValue(cur)
                      ? fontMap.entries
                          .firstWhere((e) => e.value == cur)
                          .key
                      : s.subFontDefault,
                );
                if (picked == null) return;
                if (picked == s.subFontCustomEnter) {
                  if (!context.mounted) return;
                  final entered = await showSettingsTextDialog(
                    context: context,
                    title: s.subFontCustom,
                    subtitle:
                        s.subFontCustomHint,
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
            final opts = [s.sizeTiny, s.sizeSmall, s.sizeMedium, s.sizeLarge, s.sizeHuge];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleFontSize);
            final curLabel = opts[cur.clamp(0, 4)];
            return SettingsNavTile(
              title: s.subSize,
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.subFontSize,
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
              title: s.subBold,
              subtitle: s.subBoldDesc,
              setting: PlayerSetting.subTextBold),
          SettingsSectionHeader(s.subSecColor),
          // Phase 45 (audit refined, build 63): wire Text color to
          // IntSetting.subtitleTextColor (6-preset palette matching
          // MX Player V3). Applied to libmpv `sub-color` on every play.
          Builder(builder: (ctx) {
            final opts = [s.colourWhite, s.colourYellow, s.colourCyan, s.colourGreen, s.colourRed, s.colourBlack];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleTextColor);
            final curLabel = opts[cur.clamp(0, 5)];
            return SettingsNavTile(
              title: s.subTextColor,
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.subTextColorTitle,
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
          SettingsSectionHeader(s.subSecBorder),
          // Phase 45 (audit refined, build 64): wire Border style to
          // IntSetting.subtitleBorderStyle. 5 options (None/Outline/
          // Drop shadow/Raised/Depressed). Applied via libmpv's
          // sub-border-size + sub-shadow-offset on every play.
          Builder(builder: (ctx) {
            final opts = [
              s.borderNone,
              s.borderOutline,
              s.borderDropShadow,
              s.borderRaised,
              s.borderDepressed,
            ];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleBorderStyle);
            final curLabel = opts[cur.clamp(0, 4)];
            return SettingsNavTile(
              title: s.subBorderStyle,
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.subBorderStyleTitle,
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
            final opts = [s.colourWhite, s.colourYellow, s.colourCyan, s.colourGreen, s.colourRed, s.colourBlack];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleBorderColor);
            final curLabel = opts[cur.clamp(0, 5)];
            return SettingsNavTile(
              title: s.subBorderColor,
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.subBorderColorTitle,
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
          SettingsSectionHeader(s.subSecAppearance),
          // Phase 45 (audit refined, build 63): wire Scale to
          // IntSetting.subtitleScale (stored as percent 10-200, default
          // 100 = 1.0x). Applied to libmpv `sub-scale` on every play.
          Builder(builder: (ctx) {
            final scalePct = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleScale);
            return SettingsNavTile(
              title: s.subScale,
              subtitle: '${(scalePct / 100).toStringAsFixed(2)}x',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: s.subScaleTitle,
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
            final opts = [s.borderNone, s.shadowSubtle, s.shadowDefault, s.shadowStrong];
            final lvl = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleShadow);
            final curLabel = opts[lvl.clamp(0, 3)];
            return SettingsNavTile(
              title: s.subShadow,
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.subShadow,
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
            final opts = [s.bgTransparent, s.bgTranslucent, s.bgOpaque];
            final lvl = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleBackgroundOpacity);
            final curLabel = opts[lvl.clamp(0, 2)];
            return SettingsNavTile(
              title: s.subBackground,
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.subBackground,
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
            final opts = [s.colourWhite, s.colourYellow, s.colourCyan, s.colourGreen, s.colourRed, s.colourBlack];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleBackgroundColor);
            final curLabel = opts[cur.clamp(0, 5)];
            return SettingsNavTile(
              title: s.subBackgroundColor,
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.subBackgroundColor,
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
            final opts = [s.alignLeft, s.alignCenter, s.alignRight];
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleAlignment);
            final curLabel = opts[cur.clamp(0, 2)];
            return SettingsNavTile(
              title: s.subAlignment,
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.subTextAlignment,
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
              title: s.subBottomMargins,
              subtitle: pct == 0
                  ? '0% (touching bottom edge)'
                  : '$pct% of screen height',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: s.subBottomMarginsTitle,
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
              title: s.subImproveStroke,
              subtitle:
                  s.subImproveStrokeDesc,
              setting: PlayerSetting.subTextImproveStroke),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
