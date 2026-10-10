import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/settings/presentation/adb_connect_screen.dart';
import '../localization/app_strings.dart';
import '../services/adb/adb_service.dart';
import '../theme/app_colors.dart';

/// What a folder inside Android/data shows while the ADB connection is down,
/// in place of its files.
///
/// IT USED TO SAY "NO FILES IN THIS FOLDER". A dropped connection — Wireless
/// debugging switched off by a Wi-Fi change or a restart — listed as an empty
/// folder, which reads as "the files are gone". This says what actually
/// happened, offers the one place to fix it, and WATCHES: every few seconds it
/// asks whether the connection is back, and the moment it is, the folder
/// opens by itself ([onBack]) — turning Wireless debugging on from the quick
/// settings tile is all the viewer has to do.
class AdbLostCard extends StatefulWidget {
  const AdbLostCard({super.key, required this.onBack, this.firstTime = false});

  /// Called once the connection is live again: re-read the folder.
  final VoidCallback onBack;

  /// ADB was never set up on this phone: "set up once", not "it dropped".
  final bool firstTime;

  @override
  State<AdbLostCard> createState() => _AdbLostCardState();
}

class _AdbLostCardState extends State<AdbLostCard> {
  /// Often enough to feel immediate after the switch is flipped; each check is
  /// one short shell round trip, bounded at three seconds.
  static const Duration _every = Duration(seconds: 4);

  Timer? _timer;
  bool _checking = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_every, (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_checking || _done) return;
    _checking = true;
    try {
      final ok = await AdbService.instance.isConnected(timeoutMs: 3000);
      if (ok && mounted && !_done) {
        _done = true;
        _timer?.cancel();
        widget.onBack();
      }
    } catch (_) {
      // Not back yet; the next tick asks again.
    } finally {
      _checking = false;
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const AdbConnectScreen()),
    );
    if (mounted) unawaited(_check());
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.warning.withValues(alpha: 0.14),
              ),
              child: const Icon(Icons.link_off_rounded,
                  color: AppColors.warning, size: 30),
            ),
            const SizedBox(height: 16),
            Text(
              widget.firstTime ? s.adbHeroNew : s.adbLostTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.firstTime ? s.adbHeroNewSub : s.adbLostBody,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppColors.white70, fontSize: 13.5, height: 1.55),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
                const SizedBox(width: 10),
                Text(s.adbHeroChecking,
                    style: const TextStyle(
                        color: AppColors.white55, fontSize: 12.5)),
              ],
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_ethernet_rounded, size: 18),
              label: Text(s.adbLostAction),
            ),
          ],
        ),
      ),
    );
  }
}
