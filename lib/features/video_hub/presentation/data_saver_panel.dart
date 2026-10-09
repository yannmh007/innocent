import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/network/connection_kind.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import 'video_hub_theme.dart';
import 'widgets/vh_insets.dart';
import '../../../core/theme/tab_title.dart';

/// The connection the phone is on now, for the saver's status line.
///
/// Read when the panel is shown, not watched: Android has no cheap change
/// stream behind [ConnectionInfo], and a line that says what the connection
/// was a moment ago is still the right answer to "is it saving now?".
final currentConnectionProvider =
    FutureProvider.autoDispose<ConnectionKind>((ref) => ConnectionInfo.read());

/// The data saver's whole control: the switch, where it applies, and whether
/// it is saving right now.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY "WHERE IT APPLIES" IS A CHOICE AND NOT A SWITCH
/// ═══════════════════════════════════════════════════════════════════════
///
/// The first version had a second switch, "Also on Wi-Fi", off by default and
/// shown only once the saver was on — so a viewer on Wi-Fi turned the saver on
/// and watched it do nothing. In Myanmar much of the Wi-Fi is a SIM router or
/// a plan sold by the gigabyte; "Wi-Fi is free" is not true here. The two
/// options are now named for what they mean, side by side, with "all
/// connections" first and chosen by default, and a status line says whether
/// the saver is working on the connection the phone is on this minute. A
/// setting whose effect cannot be seen is a setting people assume is broken.
class DataSaverPanel extends ConsumerWidget {
  const DataSaverPanel({super.key, this.showHow = false});

  /// The three-line explanation underneath. On the dedicated screen, not
  /// where the panel is one row among others.
  final bool showHow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final settings = ref.watch(playerSettingsProvider);
    final on = settings.get(PlayerSetting.albumDataSaver);
    final everywhere = settings.get(PlayerSetting.albumDataSaverOnWifi);
    final notifier = ref.read(playerSettingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          decoration: BoxDecoration(
            color: VH.surface1,
            borderRadius: BorderRadius.circular(VH.rCard),
            border: Border.all(color: on ? _green.withValues(alpha: 0.35) : VH.hairline),
          ),
          padding: const EdgeInsets.fromLTRB(VH.s4, VH.s3, VH.s2, VH.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _Badge(on: on),
                  const SizedBox(width: VH.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(s.vhDataSaver,
                            style: VH.title.copyWith(fontSize: 15.5)),
                        const SizedBox(height: 2),
                        Text(s.vhDataSaverHint,
                            style: VH.meta.copyWith(fontSize: 11.5, height: 1.35)),
                      ],
                    ),
                  ),
                  Switch(
                    key: const ValueKey('data-saver-switch'),
                    value: on,
                    activeColor: Colors.white,
                    activeTrackColor: _green,
                    onChanged: (v) =>
                        notifier.setValue(PlayerSetting.albumDataSaver, v),
                  ),
                ],
              ),
              AnimatedSize(
                duration: VH.normal,
                curve: VH.ease,
                alignment: Alignment.topCenter,
                child: !on
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: VH.s3, right: VH.s2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            _ModeOption(
                              key: const ValueKey('saver-mode-all'),
                              icon: Icons.public_rounded,
                              title: s.vhSaverModeAll,
                              hint: s.vhSaverModeAllHint,
                              selected: everywhere,
                              onTap: () => notifier.setValue(
                                  PlayerSetting.albumDataSaverOnWifi, true),
                            ),
                            const SizedBox(height: VH.s2),
                            _ModeOption(
                              key: const ValueKey('saver-mode-mobile'),
                              icon: Icons.signal_cellular_alt_rounded,
                              title: s.vhSaverModeMobile,
                              hint: s.vhSaverModeMobileHint,
                              selected: !everywhere,
                              onTap: () => notifier.setValue(
                                  PlayerSetting.albumDataSaverOnWifi, false),
                            ),
                            const SizedBox(height: VH.s3),
                            _StatusLine(everywhere: everywhere),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
        if (showHow) ...<Widget>[
          const SizedBox(height: VH.s5),
          Text(s.vhSaverHowTitle, style: VH.heading),
          const SizedBox(height: VH.s3),
          _HowStep(n: 1, icon: Icons.blur_on_rounded, text: s.vhSaverHow1),
          _HowStep(n: 2, icon: Icons.touch_app_rounded, text: s.vhSaverHow2),
          _HowStep(n: 3, icon: Icons.offline_pin_rounded, text: s.vhSaverHow3),
          _HowStep(n: 4, icon: Icons.movie_outlined, text: s.vhSaverHow4),
        ],
      ],
    );
  }
}

const Color _green = Color(0xFF2EBD6B);

class _Badge extends StatelessWidget {
  const _Badge({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: VH.normal,
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? _green.withValues(alpha: 0.16) : VH.surface3,
      ),
      child: Icon(
        Icons.data_saver_on_rounded,
        size: 21,
        color: on ? _green : VH.textSecondary,
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? VH.surface3 : VH.surface2,
        borderRadius: BorderRadius.circular(VH.rControl),
        child: InkWell(
          borderRadius: BorderRadius.circular(VH.rControl),
          onTap: onTap,
          child: AnimatedContainer(
            duration: VH.fast,
            padding: const EdgeInsets.symmetric(horizontal: VH.s3, vertical: VH.s2 + 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(VH.rControl),
              border: Border.all(
                  color: selected ? _green.withValues(alpha: 0.7) : Colors.transparent,
                  width: 1.2),
            ),
            child: Row(
              children: <Widget>[
                Icon(icon, size: 19, color: selected ? _green : VH.textTertiary),
                const SizedBox(width: VH.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: VH.label.copyWith(fontSize: 13.5)),
                      const SizedBox(height: 1),
                      Text(hint, style: VH.meta.copyWith(fontSize: 11)),
                    ],
                  ),
                ),
                const SizedBox(width: VH.s2),
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  size: 20,
                  color: selected ? _green : VH.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Saving now · Wi-Fi", or why not. The answer to "is it working?".
class _StatusLine extends ConsumerWidget {
  const _StatusLine({required this.everywhere});
  final bool everywhere;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final conn = ref.watch(currentConnectionProvider).valueOrNull;
    if (conn == null) return const SizedBox(height: 18);
    final name = conn.isOffline
        ? s.vhConnOffline
        : conn.isWifi
            ? s.vhConnWifi
            : conn.transport == 'cellular'
                ? s.vhConnMobile
                : s.vhConnOther;
    // The same rule albumSaverProvider applies, so the line cannot disagree
    // with what the album actually does.
    final saving = everywhere || conn.metered;
    return Row(
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: saving ? _green : VH.textTertiary,
          ),
        ),
        const SizedBox(width: VH.s2),
        Expanded(
          child: Text(
            saving ? s.vhSaverNowOn(name) : s.vhSaverNowOff(name),
            style: VH.meta.copyWith(
                fontSize: 11.5,
                color: saving ? VH.textSecondary : VH.textTertiary),
          ),
        ),
      ],
    );
  }
}

class _HowStep extends StatelessWidget {
  const _HowStep({required this.n, required this.icon, required this.text});
  final int n;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: VH.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(color: VH.surface2, shape: BoxShape.circle),
            child: Icon(icon, size: 16, color: VH.textSecondary),
          ),
          const SizedBox(width: VH.s3),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(text, style: VH.body.copyWith(fontSize: 13, height: 1.45)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The data saver on a page of its own, reached from the account screen.
class DataSaverScreen extends StatelessWidget {
  const DataSaverScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Scaffold(
      backgroundColor: VH.canvas,
      appBar: AppBar(
        backgroundColor: VH.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(s.vhDataSaver, style: kAppBarTitleStyle.copyWith(color: VH.textPrimary)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: VH.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            VH.gutter, VH.s3, VH.gutter, VhInsets.scrollBottom(context)),
        children: const <Widget>[DataSaverPanel(showHow: true)],
      ),
    );
  }
}

/// The slim line above a frosted album: what is happening, and the way out.
///
/// The header's saver icon alone did not say what it was; a viewer who found
/// the album blurred had to guess why. This says it in words, once, where the
/// effect is, and turns it off in one tap.
class DataSaverBanner extends ConsumerWidget {
  const DataSaverBanner({super.key, required this.onTurnOff});
  final VoidCallback onTurnOff;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(VH.s3, VH.s1, VH.s1, VH.s1),
      decoration: BoxDecoration(
        color: _green.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(VH.rControl),
        border: Border.all(color: _green.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.data_saver_on_rounded, size: 17, color: _green),
          const SizedBox(width: VH.s2),
          Expanded(
            child: Text(s.vhSaverBanner,
                style: VH.meta.copyWith(
                    fontSize: 11.5, color: VH.textSecondary, height: 1.3)),
          ),
          TextButton(
            key: const ValueKey('saver-banner-off'),
            onPressed: onTurnOff,
            style: TextButton.styleFrom(
              foregroundColor: _green,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: VH.s2),
            ),
            child: Text(s.vhSaverTurnOff,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}
