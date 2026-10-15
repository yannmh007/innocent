import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/settings/presentation/adb_connect_screen.dart';
import '../localization/app_strings.dart';
import '../services/adb/adb_service.dart';
import '../services/adb/adb_setup_state.dart';
import '../theme/app_colors.dart';
import 'nav_bar_space.dart';

/// What a folder inside Android/data shows while the ADB connection is down,
/// in place of its files — and what Hidden files shows when it opens with
/// no connection ([hiddenFiles]).
///
/// HIDDEN FILES USED TO SPIN. Opened without ADB, it waited on a folder
/// listing that tried to reconnect — twice, thirty seconds each — behind a
/// bare spinner, and nobody could tell why or what to do. Now the screen
/// asks first (a few seconds at most) and, when the answer is no, says so
/// here: what Hidden files needs and why, where the phone stands (Wi-Fi,
/// Wireless debugging), one button to connect and one to check again.
///
/// IT USED TO SAY "NO FILES IN THIS FOLDER". A dropped connection — Wireless
/// debugging switched off by a Wi-Fi change or a restart — listed as an empty
/// folder, which reads as "the files are gone". This says what actually
/// happened, offers the one place to fix it, and WATCHES: every few seconds it
/// asks whether the connection is back, and the moment it is, the folder
/// opens by itself ([onBack]) — turning Wireless debugging on from the quick
/// settings tile is all the viewer has to do.
class AdbLostCard extends StatefulWidget {
  const AdbLostCard({
    super.key,
    required this.onBack,
    this.firstTime = false,
    this.hiddenFiles = false,
  });

  /// Called once the connection is live again: re-read the folder.
  final VoidCallback onBack;

  /// ADB was never set up on this phone: "set up once", not "it dropped".
  final bool firstTime;

  /// Hidden files, opened with no connection: "Hidden files need ADB",
  /// rather than "the connection dropped".
  final bool hiddenFiles;

  @override
  State<AdbLostCard> createState() => _AdbLostCardState();
}

class _AdbLostCardState extends State<AdbLostCard> {
  /// Often enough to feel immediate after the switch is flipped; each check is
  /// one short shell round trip, bounded at three seconds.
  static const Duration _every = Duration(seconds: 4);

  /// While the phone refuses the key, asking every four seconds only makes
  /// the engine sweep for a port that will refuse again; it asks this often
  /// instead, in case the person pairs from the notification meanwhile.
  static const Duration _everWhileRefused = Duration(seconds: 20);

  Timer? _timer;
  bool _checking = false;
  bool _done = false;

  /// "Check again" was tapped and has not been answered yet.
  bool _asked = false;
  DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);

  /// Where the phone stands: Wi-Fi, Wireless debugging. Null until read.
  AdbSetupState? _setup;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_every, (_) => _check());
    AdbService.instance.pairingNeeded.addListener(_onPairing);
    unawaited(_readSetup());
  }

  @override
  void dispose() {
    _timer?.cancel();
    AdbService.instance.pairingNeeded.removeListener(_onPairing);
    super.dispose();
  }

  void _onPairing() {
    if (mounted) setState(() {});
  }

  Future<void> _readSetup() async {
    final st = await AdbService.instance.setupState();
    if (mounted) setState(() => _setup = st);
  }

  Future<void> _check({bool now = false}) async {
    if (_checking || _done) return;
    if (!now &&
        AdbService.instance.pairingNeeded.value &&
        DateTime.now().difference(_lastCheck) < _everWhileRefused) {
      return;
    }
    _lastCheck = DateTime.now();
    _checking = true;
    try {
      final ok = await AdbService.instance.isConnected(timeoutMs: 3000);
      if (ok && mounted && !_done) {
        _done = true;
        _timer?.cancel();
        widget.onBack();
        return;
      }
      // Not yet: what changed on the phone meanwhile (the switch was
      // flipped, Wi-Fi came back) shows on the card.
      unawaited(_readSetup());
    } catch (_) {
      // Not back yet; the next tick asks again.
    } finally {
      _checking = false;
      if (_asked && mounted) setState(() => _asked = false);
    }
  }

  Future<void> _checkNow() async {
    if (_asked) return;
    setState(() => _asked = true);
    // A periodic check already under way answers this one too.
    if (_checking) {
      while (_checking && mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (mounted) setState(() => _asked = false);
      return;
    }
    await _check(now: true);
  }

  Future<void> _openSettings() async {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const AdbConnectScreen()),
    );
    if (mounted) unawaited(_check(now: true));
  }

  Future<void> _openWirelessDebugging() async {
    final r = await AdbService.instance.openDevOptions();
    // Developer options is off (or nothing opened): the ADB screen walks
    // through turning it on.
    if (r != 'opened' && mounted) await _openSettings();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    // The phone refused the key: no reconnect will come, so say "pair again".
    final refused =
        !widget.firstTime && AdbService.instance.pairingNeeded.value;
    final title = widget.firstTime
        ? (widget.hiddenFiles ? s.hfNeedTitle : s.adbHeroNew)
        : widget.hiddenFiles
            ? s.hfNeedTitle
            : s.adbLostTitle;
    final body = refused
        ? s.adbPairingRefused
        : widget.hiddenFiles
            ? s.hfNeedBody
            : widget.firstTime
                ? s.adbHeroNewSub
                : s.adbLostBody;
    final action = refused
        ? s.adbPairAgain
        : widget.firstTime
            ? s.hfSetUp
            : s.hfConnect;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24)
            .plusNavBar(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (refused ? AppColors.warning : AppColors.primaryBlue)
                      .withValues(alpha: 0.14),
                ),
                child: Icon(
                  widget.hiddenFiles
                      ? Icons.folder_special_rounded
                      : Icons.link_off_rounded,
                  color: refused ? AppColors.warning : AppColors.accentBlueLight,
                  size: 32,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.white70, fontSize: 13.5, height: 1.55),
              ),
              const SizedBox(height: 18),
              _StatusPanel(
                refused: refused,
                setup: _setup,
                onTurnOn: _openWirelessDebugging,
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _openSettings,
                  icon: Icon(
                      refused
                          ? Icons.qr_code_2_rounded
                          : Icons.settings_ethernet_rounded,
                      size: 18),
                  label: Text(action),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _asked ? null : _checkNow,
                  icon: _asked
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        )
                      : const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(_asked ? s.adbHeroChecking : s.hfCheckAgain),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const _Pulse(),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(s.hfWatching,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AppColors.white55, fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where the phone stands: the connection, Wi-Fi, Wireless debugging — the
/// two things that are off when a connection cannot be made, and a button
/// to the switch that is.
class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.refused,
    required this.setup,
    required this.onTurnOn,
  });

  final bool refused;
  final AdbSetupState? setup;
  final VoidCallback onTurnOn;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final st = setup;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.circle,
                  size: 9,
                  color: refused ? AppColors.warning : AppColors.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  refused ? s.hfPairingNeeded : s.hfNotConnected,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (st != null) ...<Widget>[
            const SizedBox(height: 6),
            const Divider(height: 1, color: AppColors.darkDivider),
            _StateRow(
              icon: Icons.wifi_rounded,
              label: 'Wi-Fi',
              on: st.wifi,
              onLabel: s.hfOn,
              offLabel: s.hfOff,
            ),
            _StateRow(
              icon: Icons.developer_mode_rounded,
              label: s.hfWirelessDebugging,
              on: st.wirelessDebugging,
              onLabel: s.hfOn,
              offLabel: s.hfOff,
              action: st.wirelessDebugging
                  ? null
                  : TextButton(
                      onPressed: onTurnOn,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      child: Text(s.hfTurnOn),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StateRow extends StatelessWidget {
  const _StateRow({
    required this.icon,
    required this.label,
    required this.on,
    required this.onLabel,
    required this.offLabel,
    this.action,
  });

  final IconData icon;
  final String label;
  final bool on;
  final String onLabel;
  final String offLabel;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: AppColors.white55),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: const TextStyle(color: AppColors.white70, fontSize: 13)),
          ),
          Text(on ? onLabel : offLabel,
              style: TextStyle(
                  color: on ? AppColors.success : AppColors.warning,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
          if (action != null) ...<Widget>[
            const SizedBox(width: 4),
            action!,
          ] else
            const SizedBox(width: 6),
        ],
      ),
    );
  }
}

/// A slow breathing dot: the card is watching for the connection.
class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.25, end: 1).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: AppColors.accentBlueLight,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
