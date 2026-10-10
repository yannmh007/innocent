import 'dart:async';
import 'package:device_info_plus/device_info_plus.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/core_providers.dart';
import '../../../core/localization/app_strings.dart';
import '../../../core/router/routes.dart';
import '../../../core/services/adb/adb_service.dart';
import '../../../core/services/adb/adb_setup_state.dart';
import '../../../core/services/adb/wireless_adb_risk.dart';
import '../../../core/theme/app_colors.dart';
import '../../local_browser/presentation/android_data_sync.dart';

/// Android/data access: pairing with, and connecting to, this phone's own
/// Wireless debugging.
///
/// Primary flow (easy): the user enters ONLY the 6-digit pairing code; the app
/// discovers the pairing and connect ports itself over mDNS. This works when
/// the network allows mDNS (i.e. no VPN forcing a link-local 169.254.x.x
/// address). Manual IP:Port entry stays available under "Advanced" as a
/// fallback for networks where mDNS is blocked. A successful `id` (uid=2000,
/// shell) proves the path works; the last working address is remembered so the
/// screen reconnects by itself next time.
class AdbConnectScreen extends ConsumerStatefulWidget {
  const AdbConnectScreen({super.key});

  @override
  ConsumerState<AdbConnectScreen> createState() => _AdbConnectScreenState();
}

class _AdbConnectScreenState extends ConsumerState<AdbConnectScreen>
    with WidgetsBindingObserver {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _pairAddr = TextEditingController();
  final TextEditingController _connectAddr = TextEditingController();

  String _output = '';
  bool _busy = false;

  bool _pairedBefore = false;

  /// Already paired, and asked to pair again anyway: the pairing card,
  /// which is folded away once a phone is paired, is open.
  bool _pairAgain = false;
  bool _showManual = false;
  List<String> _found = [];
  bool _autoEnableGranted = false;
  bool _autoEnableOn = false;

  /// What the last post-boot restore did, and when (audit_adb.md A5). Empty
  /// until one has run.
  String _lastBoot = '';
  int _lastBootAt = 0;
  // null = unknown/checking, true = a shell round-trip works, false = not usable.
  bool? _connected;
  // v0.89: whether the notification pairing service is currently running.
  bool _pairingServiceOn = false;

  /// CVE-2026-0073: this phone's wireless debugging may let a device on the
  /// same Wi-Fi in without pairing (see [wirelessAdbPossiblyExposed]), and
  /// its security patch level, for the warning's own words.
  bool _exposed = false;
  String _patch = '';

  /// What Settings says is done so far (the checklist at the top), read on
  /// resume and every [_setupEvery] while the screen is open.
  AdbSetupState? _setup;
  Timer? _setupTimer;
  static const Duration _setupEvery = Duration(seconds: 2);

  /// Turn raw engine output into something a non-technical user can act on.
  /// Normal users should never see "IOException: Stream closed".
  String _friendly(String raw) {
    // If we KNOW the current state (a round-trip just succeeded/failed), trust
    // that over keyword-matching stale output — otherwise a leftover
    // failure-ish string can render "Not connected" under a green "Connected"
    // badge (and vice-versa).
    if (_connected == true &&
        (raw.startsWith('OK') ||
            raw.toLowerCase().contains('uid=') ||
            raw.toLowerCase().contains('connected') ||
            raw.toLowerCase().contains('scanning') ||
            raw.toLowerCase().contains('found') ||
            raw.toLowerCase().contains('playing') ||
            raw.toLowerCase().contains('preparing'))) {
      // Keep the real message (scan progress, playback, etc.) as-is.
      return raw.startsWith('OK') ? 'Connected — the device is reachable.' : raw;
    }
    final low = raw.toLowerCase();
    if (low.contains('stream closed') ||
        low.contains('not connected') ||
        low.contains("couldn't reach") ||
        low.contains('connect failed') ||
        low.contains('timed out') ||
        low.contains('timeout')) {
      return "Not connected. Tap Connect — if that doesn't work, open Wireless "
          "debugging (button above) and make sure it's still on, then try again.";
    }
    if (raw.startsWith('OK') || low.contains('uid=')) {
      return 'Connected — the device is reachable.';
    }
    return raw;
  }

  @override
  void initState() {
    super.initState();
    // v0.89: receive results from the notification pairing service.
    AdbService.instance.setPairResultListener(_onPairServiceResult);
    WidgetsBinding.instance.addObserver(this);
    _loadAndAutoConnect();
    _checkExposure();
    _refreshSetup();
    _setupTimer = Timer.periodic(_setupEvery, (_) => _refreshSetup());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Settings: tick what was just done at once, not two seconds on.
    if (state == AppLifecycleState.resumed) _refreshSetup();
  }

  Future<void> _refreshSetup() async {
    final st = await AdbService.instance.setupState();
    if (!mounted) return;
    final was = _setup;
    if (was != null &&
        was.devOptions == st.devOptions &&
        was.wirelessDebugging == st.wirelessDebugging &&
        was.wifi == st.wifi &&
        was.notifications == st.notifications &&
        was.secureSettings == st.secureSettings) {
      return;
    }
    setState(() => _setup = st);
  }

  Future<void> _checkExposure() async {
    try {
      final a = await DeviceInfoPlugin().androidInfo;
      final patch = a.version.securityPatch ?? '';
      final exposed = wirelessAdbPossiblyExposed(
          sdkInt: a.version.sdkInt, securityPatch: patch);
      if (!mounted) return;
      setState(() {
        _exposed = exposed;
        _patch = patch;
      });
    } catch (_) {
      // No device info: no warning rather than a wrong one.
    }
  }

  /// Shown at the top of the screen on a phone [_exposed] to CVE-2026-0073.
  Widget _exposureWarning() {
    final when = _patch.isEmpty ? 'unknown' : _patch;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.gpp_maybe_outlined, color: Colors.orange, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Update your phone before leaving Wireless debugging on',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'This phone\u2019s security update is from $when. Android 14 '
            'to 16 need the May 2026 update (or a newer Google Play system '
            'update) to close a Wireless debugging flaw (CVE-2026-0073): '
            'without it, a device on the same Wi-Fi can get in without '
            'pairing. Until you update, turn Wireless debugging off when '
            'you are not using it, and leave auto-reconnect after reboot '
            'off.',
            style: const TextStyle(fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // With WRITE_SECURE_SETTINGS (auto-reconnect set up), one tap
              // closes it — and keeps it closed across a reboot.
              if (_autoEnableGranted)
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _turnOffWirelessDebugging,
                  icon: const Icon(Icons.wifi_off, size: 18),
                  label: const Text('Turn it off now'),
                ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _openWirelessDebugging,
                icon: const Icon(Icons.settings, size: 18),
                label: const Text('Open Wireless debugging'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Close the network door on an exposed phone: Wireless debugging off,
  /// and auto-reconnect off so a reboot does not open it again.
  Future<void> _turnOffWirelessDebugging() async {
    setState(() => _busy = true);
    try {
      final ok = await AdbService.instance.disableWirelessDebugging();
      if (ok && _autoEnableOn) {
        await AdbService.instance.setAutoEnable(false);
      }
      if (!mounted) return;
      setState(() {
        if (ok) {
          _connected = false;
          _autoEnableOn = false;
          _output = 'Wireless debugging is off, and auto-reconnect after '
              'reboot is off. Turn it on again from Wireless debugging when '
              'you next need Android/data — after updating the phone, '
              'ideally.';
        } else {
          _output = 'Could not switch it off from here. Open Wireless '
              'debugging and turn it off there.';
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Result of a pairing attempt made from the notification shade. Runs on
  /// the platform channel callback.
  void _onPairServiceResult(String result) {
    if (!mounted) return;
    final ok = result.startsWith('OK');
    setState(() {
      _pairedBefore = _pairedBefore || ok;
      _pairingServiceOn = false;
      _output = result;
    });
    // Pairing already auto-connects natively; this confirms/refreshes the live
    // status (fast, liveness-verified) so the badge is accurate.
    if (ok) _pairAndConnect();
  }

  /// If we connected successfully before, reconnect automatically so day-to-day
  /// use needs no typing at all.
  Future<void> _loadAndAutoConnect() async {
    // Claim busy immediately so a fast-tapping user can't start a manual
    // pair/connect that races this auto-reconnect on the shared connection.
    if (mounted) setState(() => _busy = true);
    // Everything below is wrapped so a failure anywhere still releases _busy —
    // otherwise the whole screen stays disabled and looks frozen.
    try {
      final st = await AdbService.instance.autoEnableStatus();
      if (mounted) {
        setState(() {
          _autoEnableGranted = st.granted;
          _autoEnableOn = st.on;
          _lastBoot = st.lastBoot;
          _lastBootAt = st.lastBootAt;
        });
      }
      final last = await AdbService.instance.lastConnect();
      if (!mounted || last.isEmpty) return;
      setState(() {
        _pairedBefore = true;
        _connectAddr.text = last;
        _output = 'Reconnecting…';
      });
      // Saved port first, then mDNS if it's stale (handles a changed port
      // after a reboot); also self-heals a stale "connected" socket.
      final r = await AdbService.instance.reconnectAndRun('id');
      if (!mounted) return;
      final ok = r.contains('uid=') || r.startsWith('OK');
      setState(() {
        _connected = ok;
        _output = ok
            ? 'Connected \u2014 the device is reachable.'
            : "Not connected yet. Tap Connect (you may need to re-open "
                "Wireless debugging first).";
      });
      if (ok) unawaited(_autoScanAfterConnect());
    } catch (e) {
      if (mounted) setState(() => _output = 'ERROR: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The Reconnect button: the remembered port, and when Wireless debugging
  /// has moved to a new one (it does every time it is switched on), the new
  /// port, found on the phone itself. No code: the phone is paired already.
  ///
  /// It used to try only the remembered port, so after a restart or a Wi-Fi
  /// change it failed every time — and people paired again, which did not
  /// help and took longer.
  Future<void> _reconnect() async {
    final s = AppStrings.of(context);
    setState(() {
      _busy = true;
      _output = s.adbReconnecting;
    });
    try {
      final r = await AdbService.instance.autoConnectAndRun('id');
      if (!mounted) return;
      final ok = r.contains('uid=') || r.startsWith('OK');
      setState(() {
        _connected = ok;
        _output = ok ? '' : r;
      });
      if (ok) unawaited(_autoScanAfterConnect());
    } catch (e) {
      if (mounted) setState(() => _output = 'ERROR: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _setupTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    AdbService.instance.setPairResultListener(null);
    // Don't leave the pairing notification lingering if the user leaves.
    if (_pairingServiceOn) AdbService.instance.stopPairingService();
    _code.dispose();
    _pairAddr.dispose();
    _connectAddr.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String> Function() op, String pending) async {
    setState(() {
      _busy = true;
      _output = pending;
    });
    // try/finally is essential: if op() throws (a dropped socket, a plugin
    // error), an unguarded body would leave _busy stuck at true — every button
    // on this screen is disabled while busy, so the screen would look dead
    // until the app was killed. The finally always releases it.
    var result = '';
    try {
      result = await op();
    } catch (e) {
      result = 'ERROR: $e';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _output = result;
        });
      }
    }
  }

  /// Splits "IP:Port" on the last colon. Returns null if malformed.
  List<Object>? _split(String raw) {
    final s = raw.trim();
    final idx = s.lastIndexOf(':');
    if (idx <= 0 || idx == s.length - 1) return null;
    final host = s.substring(0, idx).trim();
    final port = int.tryParse(s.substring(idx + 1).trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
    return [host, port];
  }

  // ---- notification pairing ----

  /// Scan Android/data right after connecting and refresh the Local library.
  /// Runs in the background (no busy spinner) so the screen stays responsive;
  /// failures are swallowed — the manual Scan button remains as a fallback.
  Future<void> _autoScanAfterConnect() async {
    // The same scan the connection itself sets off (see AndroidDataSync):
    // asking here shares it rather than running a second one.
    final paths =
        await ref.read(androidDataSyncProvider).sync(connected: true);
    if (!mounted || paths == null || paths.isEmpty) return;
    setState(() {
      _found = paths;
      _output = 'Found ${paths.length} video(s) — added to Local.';
    });
  }

  /// Start the notification pairing flow. A background service posts
  /// a reply notification; the user opens the system pairing dialog, reads the
  /// code, and types it into the shade — no split-screen. The result comes back
  /// via [_onPairServiceResult].
  Future<void> _startNotificationPairing() async {
    // CRITICAL on Android 13+: without POST_NOTIFICATIONS the foreground-service
    // notification is silently suppressed from the shade — which is exactly why
    // nothing appeared before. Ask for it first.
    final perm = ref.read(permissionServiceProvider);
    final granted = await perm.hasNotificationPermission() ||
        await perm.requestNotificationPermission();
    if (!mounted) return;
    if (!granted) {
      final permanently = await perm.isNotificationPermanentlyDenied();
      if (!mounted) return;
      setState(() {
        _output = permanently
            ? 'Notifications are turned off for Innocent, so the pairing '
                'notification can\u2019t appear. Open Settings \u2192 Apps \u2192 '
                'Innocent \u2192 Notifications and turn them on, then try again.'
            : 'Please allow notifications so the pairing code notification can '
                'appear, then tap "Pair from notification" again.';
      });
      if (permanently) {
        await perm.openSystemSettings();
      }
      return;
    }

    await AdbService.instance.startPairingService();
    if (!mounted) return;
    setState(() {
      _pairingServiceOn = true;
      _output = 'Ready to pair from the notification.\n\n'
          '1. Tap "Open Wireless debugging" below.\n'
          '2. Tap "Pair device with pairing code" — a 6-digit code appears.\n'
          '3. Pull down the notification shade, tap "Reply" on the '
          '"Enter the pairing code here" notification, type the code, and send.\n\n'
          'No split-screen needed — this screen keeps working in the background.';
    });
  }

  Future<void> _stopNotificationPairing() async {
    await AdbService.instance.stopPairingService();
    if (!mounted) return;
    setState(() {
      _pairingServiceOn = false;
      _output = 'Notification pairing stopped.';
    });
  }

  /// One-tap: grant WRITE_SECURE_SETTINGS over ADB so the app can re-enable
  /// wireless debugging by itself after a reboot (no PC, no root).
  Future<void> _setupAutoEnable() async {
    setState(() {
      _busy = true;
      _output = 'Setting up auto-reconnect after reboot…';
    });
    try {
      final r = await AdbService.instance.setupAutoEnable();
      final st = await AdbService.instance.autoEnableStatus();
      if (!mounted) return;
      setState(() {
        _output = r;
        _autoEnableGranted = st.granted;
        _autoEnableOn = st.on;
        _lastBoot = st.lastBoot;
        _lastBootAt = st.lastBootAt;
      });
    } catch (e) {
      if (mounted) setState(() => _output = 'ERROR: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleAutoEnable(bool on) async {
    await AdbService.instance.setAutoEnable(on);
    if (!mounted) return;
    setState(() => _autoEnableOn = on);
  }

  /// Give WRITE_SECURE_SETTINGS back (audit_adb.md A9).
  ///
  /// Confirmed first, because it needs a live ADB shell to work and the user
  /// should be told that before they press it rather than after it fails.
  Future<void> _revokeSecureSettings() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hand the permission back?'),
        content: const Text(
          'Innocent will give up WRITE_SECURE_SETTINGS and stop restoring '
          'Wireless debugging after a reboot. You can set it up again any '
          'time.\n\n'
          'Only the ADB shell can take this permission away, so this needs a '
          'live connection — connect first if you are not connected.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Hand it back'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() {
      _busy = true;
      _output = 'Handing the permission back…';
    });
    try {
      final r = await AdbService.instance.revokeSecureSettings();
      final st = await AdbService.instance.autoEnableStatus();
      if (!mounted) return;
      setState(() {
        _output = r;
        _autoEnableGranted = st.granted;
        _autoEnableOn = st.on;
      });
    } catch (e) {
      if (mounted) setState(() => _output = 'ERROR: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "3 hours ago" for the last boot restore. Coarse on purpose — the exact
  /// minute of a reboot is not information anyone needs.
  String _ago(int millis) {
    if (millis <= 0) return '';
    final d = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(millis),
    );
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  /// The label adapts: with a fresh 6-digit code we pair first; otherwise we
  /// just (re)connect. One button so users don't have to know the order.
  String _primaryLabel() {
    final s = AppStrings.of(context);
    final hasCode = _code.text.trim().length >= 6;
    return hasCode ? s.adbPairConnect : s.adbConnect;
  }

  /// One tap does the right thing: if a 6-digit code is present, pair first,
  /// wait a moment for the connect service to appear, then connect. If no code,
  /// just connect. The button is disabled while busy, so double-taps are inert.
  Future<void> _pairAndConnect() async {
    final code = _code.text.trim();
    setState(() {
      _busy = true;
      _output = code.length >= 6
          ? 'Pairing…\nKeep the "Pair device with pairing code" dialog visible '
              '(split-screen / pop-up window).'
          : 'Connecting…';
    });

    try {
      if (code.length >= 6) {
        final pairResult = await AdbService.instance.pairMdns(code);
        if (!mounted) return;
        if (pairResult.startsWith('ERROR')) {
          setState(() => _output = pairResult);
          return;
        }
        setState(() {
          _pairedBefore = true;
          _output = '$pairResult\nNow connecting…';
        });
        // The connect (adb-tls-connect) service is only advertised after the
        // pairing dialog closes; give it a moment before discovery.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
      }

      final connectResult = await AdbService.instance.autoConnectAndRun('id');
      if (!mounted) return;
      final ok =
          connectResult.contains('uid=') || connectResult.startsWith('OK');
      setState(() {
        _connected = ok;
        _output = connectResult;
      });
      // Connected: scan Android/data now, so the videos are in Local by the
      // time the user goes back — no separate tap on Scan.
      if (ok) unawaited(_autoScanAfterConnect());
    } catch (e) {
      if (mounted) setState(() => _output = 'ERROR: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One-tap jump to Wireless debugging. If Developer options is off, guide the
  /// user to unlock it (Build number ×7) with a shortcut to About phone.
  Future<void> _openWirelessDebugging() async {
    final r = await AdbService.instance.openDevOptions();
    if (!mounted) return;
    if (r == 'dev_options_off') {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Turn on Developer options first'),
          content: const Text(
            'Wireless debugging lives inside Developer options, which is '
            'hidden by default.\n\n'
            'To unlock it:\n'
            '1. Open About phone.\n'
            '2. Find "Build number" (sometimes under "Software information").\n'
            '3. Tap it 7 times until it says "You are now a developer".\n\n'
            'Then come back and tap "Open Wireless debugging" again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                AdbService.instance.openAboutPhone();
              },
              child: const Text('Open About phone'),
            ),
          ],
        ),
      );
    } else if (r == 'failed') {
      setState(() => _output =
          "Couldn't open settings automatically. Open Settings → Developer "
          'options → Wireless debugging manually.');
    }
  }

  /// Tap a found video: the player opens it as `adb://`, which streams it
  /// straight from Android/data over the connection and copies it out only
  /// if streaming fails — the same path a tap in Local takes.
  void _playAdbVideo(String path) {
    final name = path.split('/').last;
    setState(() => _output = 'Playing "$name".');
    context.push(Routes.player, extra: {'uri': 'adb://$path', 'title': name});
  }

  // ---- Fallback: manual IP:Port ----

  void _pair() {
    final hp = _split(_pairAddr.text);
    final code = _code.text.trim();
    if (hp == null) {
      setState(() => _output =
          'Enter the pairing address as IP:Port — copy it exactly from the '
          '"Pair device with pairing code" dialog, e.g. 192.168.1.5:42749');
      return;
    }
    if (code.length < 6) {
      setState(() => _output = 'Enter the 6-digit pairing code.');
      return;
    }
    _run(
      () => AdbService.instance.pair(hp[0] as String, hp[1] as int, code),
      'Pairing with ${hp[0]}:${hp[1]} …',
    );
  }

  Future<void> _connect() async {
    final hp = _split(_connectAddr.text);
    if (hp == null) {
      setState(() => _output =
          'Enter the connect address as IP:Port — copy it exactly from the '
          'main Wireless debugging screen, e.g. 192.168.1.5:32961');
      return;
    }
    await _run(
      () =>
          AdbService.instance.connectAndRun(hp[0] as String, hp[1] as int, 'id'),
      'Connecting to ${hp[0]}:${hp[1]} …',
    );
    // Connected by hand is connected: the checklist ticks, and Android/data is
    // scanned straight away, as after a code or a reconnect.
    if (!mounted) return;
    if (_output.contains('uid=') || _output.startsWith('OK')) {
      setState(() {
        _connected = true;
        _pairedBefore = true;
      });
      unawaited(_autoScanAfterConnect());
    }
  }

  // ---- Android/data ----

  Future<void> _scanAndroidData() async {
    setState(() {
      _busy = true;
      _found = [];
      _output = 'Scanning Android/data and Android/obb for videos…\n'
          '(this can take a while on a full device)';
    });
    try {
      // Through the sync, so the Video tab is refreshed with what it finds.
      final paths = await ref
          .read(androidDataSyncProvider)
          .sync(connected: true, force: true);
      if (!mounted) return;
      if (paths == null) throw Exception('scan failed — is ADB connected?');
      setState(() {
        _found = paths;
        _output = paths.isEmpty
            ? 'No videos found in Android/data or Android/obb.'
            : 'Found ${paths.length} video(s).';
      });
    } catch (e) {
      if (mounted) setState(() => _output = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- Layout ----
  //
  // ONE ANSWER FIRST, THEN THE ONE THING TO DO. The screen used to open on a
  // checklist, three walls of instructions, an IP:port form and a raw
  // command-output box, all at once. A viewer who came here because a folder
  // would not open needs two things: is it connected, and what do I tap. So
  // the hero card says the state in one line and carries the action for it;
  // the setup steps and the pairing card appear only while they are needed;
  // how to stay connected and how to switch ADB on and off are short cards
  // below; everything technical is under Advanced.

  /// Which state the hero card speaks for.
  _AdbHero get _hero {
    if (_connected == true) return _AdbHero.connected;
    if (_connected == null && _busy) return _AdbHero.checking;
    if (_pairedBefore) return _AdbHero.off;
    return _AdbHero.fresh;
  }

  Widget _card({required Widget child, EdgeInsetsGeometry? padding}) =>
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: padding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.045),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
        ),
        child: child,
      );

  Widget _heroCard() {
    final s = AppStrings.of(context);
    final hero = _hero;
    final (Color color, IconData icon, String title, String sub) =
        switch (hero) {
      _AdbHero.connected => (
          AppColors.success,
          Icons.verified_rounded,
          s.adbHeroConnected,
          s.adbHeroConnectedSub,
        ),
      _AdbHero.checking => (
          AppColors.accentBlue,
          Icons.sync_rounded,
          s.adbHeroChecking,
          '',
        ),
      _AdbHero.off => (
          AppColors.warning,
          Icons.link_off_rounded,
          s.adbHeroOff,
          s.adbHeroOffSub,
        ),
      _AdbHero.fresh => (
          AppColors.accentBlue,
          Icons.folder_special_rounded,
          s.adbHeroNew,
          s.adbHeroNewSub,
        ),
    };
    // The engine's own words only while something is happening, or when it
    // failed for a reason the card above does not already say. The full
    // text is always under Advanced → Details.
    final friendly = _output.isEmpty ? '' : _friendly(_output);
    final note = _busy ||
            (_output.startsWith('ERROR') && !friendly.startsWith('Not connected'))
        ? friendly
        : '';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            color.withValues(alpha: 0.24),
            color.withValues(alpha: 0.06),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: 0.2),
                ),
                child: hero == _AdbHero.checking
                    ? Padding(
                        padding: const EdgeInsets.all(15),
                        child: CircularProgressIndicator(
                            strokeWidth: 2.2, color: color),
                      )
                    : Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          if (sub.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(sub,
                style: const TextStyle(
                    color: AppColors.white70, fontSize: 13.5, height: 1.55)),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              if (hero == _AdbHero.connected)
                FilledButton.icon(
                  onPressed: _busy ? null : _scanAndroidData,
                  icon: const Icon(Icons.video_library_rounded, size: 18),
                  label: Text(s.adbFindVideos),
                ),
              if (hero == _AdbHero.off)
                FilledButton.icon(
                  onPressed: _busy ? null : _reconnect,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(s.adbReconnect),
                ),
              if (hero != _AdbHero.checking)
                (hero == _AdbHero.fresh
                    ? FilledButton.icon(
                        onPressed: _busy ? null : _openWirelessDebugging,
                        icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
                        label: Text(s.adbOpenWireless),
                      )
                    : OutlinedButton.icon(
                        onPressed: _busy ? null : _openWirelessDebugging,
                        icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
                        label: Text(s.adbOpenWireless),
                      )),
            ],
          ),
          if (note.isNotEmpty && hero != _AdbHero.connected) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              note,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.white55, fontSize: 12, height: 1.45),
            ),
          ],
        ],
      ),
    );
  }

  // ---- Setup steps ----

  /// Every step from Developer options to a live connection, ticked as it is
  /// done; the first one still to do is marked and carries the button that
  /// does it. Brand tips only on the phones they are about.
  Widget _setupChecklist() {
    final st = _setup;
    if (st == null) return const SizedBox.shrink();
    final s = AppStrings.of(context);
    if (!st.supported) {
      return _card(
        child: Text(s.adbNotSupported,
            style: const TextStyle(color: AppColors.warning)),
      );
    }
    final paired = _pairedBefore;
    final connected = _connected == true;
    final next = st.next(paired: paired, connected: connected);

    final steps = <({
      AdbSetupStep step,
      String label,
      bool done,
      String? action,
      VoidCallback? onAction,
    })>[
      (
        step: AdbSetupStep.devOptions,
        label: s.adbStepDevOptions,
        done: st.devOptions,
        action: s.adbStepHow,
        onAction: _openWirelessDebugging,
      ),
      (
        step: AdbSetupStep.wifi,
        label: s.adbStepWifi,
        done: st.wifi,
        action: null,
        onAction: null,
      ),
      (
        step: AdbSetupStep.wirelessDebugging,
        label: s.adbStepWireless,
        done: st.wirelessDebugging,
        action: s.adbStepOpen,
        onAction: _openWirelessDebugging,
      ),
      (
        step: AdbSetupStep.notifications,
        label: s.adbStepNotifications,
        done: st.notifications,
        action: s.adbStepOpen,
        onAction: AdbService.instance.openNotificationSettings,
      ),
      (
        step: AdbSetupStep.pair,
        label: s.adbStepPaired,
        done: paired,
        action: null,
        onAction: null,
      ),
      (
        step: AdbSetupStep.connect,
        label: s.adbStepConnected,
        done: connected,
        action: null,
        onAction: null,
      ),
    ];

    Widget row(int i) {
      final e = steps[i];
      final current = next == e.step;
      final last = i == steps.length - 1;
      final dotColor = e.done
          ? AppColors.success
          : current
              ? AppColors.accentBlue
              : Colors.white24;
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: 28,
              child: Column(
                children: <Widget>[
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: e.done || current
                          ? dotColor.withValues(alpha: e.done ? 0.9 : 1)
                          : Colors.transparent,
                      border: Border.all(color: dotColor, width: 1.5),
                    ),
                    child: e.done
                        ? const Icon(Icons.check_rounded,
                            size: 16, color: Colors.white)
                        : Text('${i + 1}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: current ? Colors.white : Colors.white54,
                            )),
                  ),
                  if (!last)
                    Expanded(
                      child: Container(
                        width: 2,
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        color: e.done
                            ? AppColors.success.withValues(alpha: 0.5)
                            : Colors.white12,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 3, bottom: last ? 0 : 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      e.label,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.4,
                        fontWeight:
                            current ? FontWeight.w700 : FontWeight.w500,
                        color: e.done || current
                            ? Colors.white
                            : Colors.white60,
                      ),
                    ),
                    if (e.step == AdbSetupStep.wifi && !st.wifi) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(s.adbWifiNeeded,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white60, height: 1.4)),
                    ],
                    if (current && e.action != null && e.onAction != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: FilledButton.tonal(
                          onPressed: _busy ? null : e.onAction,
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          child: Text(e.action!),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final tip = switch (st.brand) {
      AdbBrand.xiaomi => s.adbTipXiaomi,
      AdbBrand.oppo => s.adbTipOppo,
      AdbBrand.transsion => s.adbTipTranssion,
      _ => null,
    };
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(s.adbStepsTitle,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 15.5)),
          const SizedBox(height: 14),
          for (var i = 0; i < steps.length; i++) row(i),
          if (tip != null) ...<Widget>[
            const SizedBox(height: 12),
            _tipLine(Icons.tips_and_updates_outlined, tip),
          ],
        ],
      ),
    );
  }

  Widget _tipLine(IconData icon, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: AppColors.accentBlueLight),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.white70, height: 1.5)),
          ),
        ],
      );

  // ---- Pairing ----

  Widget _pairCard() {
    final s = AppStrings.of(context);
    // PAIRED ALREADY: pairing is once per phone, and doing it again is not a
    // fix for a connection that dropped — Reconnect is. The card folds to one
    // line that says so, with the way to pair again for the rare phone that
    // forgot (after "Revoke debugging authorisations", or a reset).
    if (_pairedBefore && !_pairAgain && !_pairingServiceOn) {
      return _card(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: <Widget>[
            const Icon(Icons.verified_user_rounded,
                color: AppColors.success, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(s.adbPairedAlready,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.white70, height: 1.45)),
            ),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _pairAgain = true),
              child: Text(s.adbPairAgain),
            ),
          ],
        ),
      );
    }
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.qr_code_2_rounded,
                  color: AppColors.accentBlueLight, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(s.adbPairTitle,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15.5)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(s.adbPairNotifSub,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.white70, height: 1.5)),
          const SizedBox(height: 12),
          if (!_pairingServiceOn)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _startNotificationPairing,
                icon: const Icon(Icons.notifications_active_rounded, size: 18),
                label: Text(s.adbPairNotif),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              decoration: BoxDecoration(
                color: AppColors.accentBlue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: <Widget>[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(s.adbPairWaiting,
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _stopNotificationPairing,
                    child: Text(s.cancel),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          Text(s.adbPairInApp,
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 8),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 18, letterSpacing: 6),
            decoration: InputDecoration(
              labelText: s.adbPairCodeLabel,
              hintText: '• • • • • •',
              counterText: '',
              isDense: true,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: _busy ? null : _pairAndConnect,
              child: Text(_primaryLabel()),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Staying connected, and switching ADB on and off ----

  Widget _stayCard() {
    final s = AppStrings.of(context);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(s.adbStayTitle,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
          const SizedBox(height: 12),
          _tipLine(Icons.wifi_rounded, s.adbStayWifi),
          const SizedBox(height: 10),
          _tipLine(Icons.cloud_sync_rounded, s.adbStayBackground),
          const SizedBox(height: 10),
          _tipLine(Icons.toggle_on_rounded, s.adbStayTile),
          const SizedBox(height: 10),
          _tipLine(Icons.battery_charging_full_rounded, s.adbStayBattery),
        ],
      ),
    );
  }

  Widget _guideCard() {
    final s = AppStrings.of(context);
    Widget step(int n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.accentBlue.withValues(alpha: 0.18),
                ),
                child: Text('$n',
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.accentBlueLight)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.white70, height: 1.5)),
              ),
            ],
          ),
        );
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 10),
          child: Text(text,
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700)),
        );
    final brands = s.adbGuideWhere.split('\n');
    return _card(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.power_settings_new_rounded,
              color: AppColors.accentBlueLight),
          title: Text(s.adbGuideTitle,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 15.5)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            heading(s.adbGuideOnTitle),
            step(1, s.adbGuideOn1),
            step(2, s.adbGuideOn2),
            step(3, s.adbGuideOn3),
            heading(s.adbGuideOffTitle),
            step(1, s.adbGuideOff1),
            step(2, s.adbGuideOff2),
            const SizedBox(height: 4),
            _tipLine(Icons.shield_outlined, s.adbGuideSafety),
            heading(s.adbGuideWhereTitle),
            for (final line in brands)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(
                        text: line.split(' — ').first,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                      if (line.contains(' — '))
                        TextSpan(
                            text:
                                ' — ${line.substring(line.indexOf(' — ') + 3)}'),
                    ],
                  ),
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.white70, height: 1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- Android/data ----

  Widget _androidDataCard() {
    final s = AppStrings.of(context);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(s.adbAndroidDataTitle,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
          const SizedBox(height: 8),
          Text(s.adbAndroidDataSub,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.white70, height: 1.5)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy || _connected != true ? null : _scanAndroidData,
            icon: const Icon(Icons.search_rounded, size: 18),
            label: Text(s.adbFindVideos),
          ),
          if (_found.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(s.adbFound(_found.length),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ..._found.take(200).map(_videoTile),
            if (_found.length > 200)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('… +${_found.length - 200}',
                    style: const TextStyle(color: Colors.white54)),
              ),
          ],
        ],
      ),
    );
  }

  // ---- UI helpers ----

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style:
                const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      );

  Widget _videoTile(String path) {
    final name = path.split('/').last;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _busy ? null : () => _playAdbVideo(path),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.play_circle_outline, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final needsSetup = _connected != true;
    return Scaffold(
      appBar: AppBar(title: Text(s.adbScreenTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (_exposed) _exposureWarning(),
          _heroCard(),
          if (needsSetup) _setupChecklist(),
          if (needsSetup) _pairCard(),
          _stayCard(),
          _guideCard(),
          _androidDataCard(),
          _card(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                leading: const Icon(Icons.tune_rounded,
                    color: AppColors.white55),
                title: Text(s.adbAdvanced,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15.5)),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: _advancedSection(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The controls a viewer rarely needs: restoring after a reboot, the
  /// manual IP:port fallback, and the engine's own words.
  List<Widget> _advancedSection() {
    final s = AppStrings.of(context);
    return [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _autoEnableGranted ? Icons.check_circle : Icons.autorenew,
                  size: 18,
                  color: _autoEnableGranted ? Colors.green : null,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Stay connected after a reboot',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _autoEnableGranted
                  ? 'Set up ✓ — after a reboot the app turns Wireless '
                      'debugging back on and reconnects by itself. No '
                      're-pairing, no re-typing.'
                  : 'Normally a reboot turns Wireless debugging off and you '
                      'have to set it up again. Tap below (once, while '
                      'connected) and the app will handle reboots itself — '
                      'no PC, no root.',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              s.adbGuideSafety,
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 8),
            if (_exposed)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Not advised on this phone until it has the May 2026 '
                  'security update — see the warning at the top.',
                  style: TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ),
            if (_autoEnableGranted)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Auto-reconnect after reboot'),
                value: _autoEnableOn,
                onChanged: _busy ? null : _toggleAutoEnable,
              )
            else
              FilledButton.tonalIcon(
                onPressed: _busy || _connected != true ? null : _setupAutoEnable,
                icon: const Icon(Icons.bolt),
                label: const Text('Set up auto-reconnect'),
              ),
            // audit_adb.md A5. The last reboot restore, in the user's own
            // words rather than in logcat. The old boot path could fail
            // completely and say nothing at all, and the user found out days
            // later by noticing missing videos.
            if (_lastBoot.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(Icons.history, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Last reboot: $_lastBoot'
                      '${_lastBootAt > 0 ? ' (${_ago(_lastBootAt)})' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
            // audit_adb.md A9. The permission gets its own line, not a
            // mention buried in the toggle above, and an exit that exists.
            // It is a permission to write ANY secure setting; holding it
            // silently and for ever was the finding.
            if (_autoEnableGranted) ...<Widget>[
              const Divider(height: 24),
              const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.shield_outlined, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Innocent holds WRITE_SECURE_SETTINGS. That is what '
                      'lets it switch Wireless debugging back on by itself. '
                      'It stays granted until you hand it back, even if the '
                      'switch above is off.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : _revokeSecureSettings,
                  icon: const Icon(Icons.undo, size: 18),
                  label: const Text('Hand the permission back'),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      // ---------- Details: the engine's own words ----------
      _sectionTitle(s.adbDetails),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            Expanded(
              child: SelectableText(
                _output.isEmpty ? '—' : _friendly(_output),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      // ---------- Manual IP:Port ----------
      TextButton.icon(
        onPressed: () => setState(() => _showManual = !_showManual),
        icon: Icon(_showManual ? Icons.expand_less : Icons.expand_more),
        label: Text(_showManual
            ? 'Hide manual IP:Port'
            : 'Manual IP:Port (if the code alone fails)'),
      ),
      if (_showManual) ...[
        const SizedBox(height: 8),
        const Text(
          'Use this if "Pair" with only the code fails — usually because '
          'the network blocks mDNS (e.g. a VPN forcing a 169.254.x.x '
          'address). Copy the IP:Port exactly as shown on screen.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        const Text('Pair (one time)',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _pairAddr,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Pairing IP:Port (from the pairing dialog)',
            hintText: 'e.g. 192.168.1.5:42749',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _pair,
          child: const Text('Pair (manual)'),
        ),
        const SizedBox(height: 20),
        const Text('Connect', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _connectAddr,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Connect IP:Port (from Wireless debugging screen)',
            hintText: 'e.g. 192.168.1.5:32961',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: const Text('Connect & run id (manual)'),
        ),
      ],
    ];
  }
}

/// The states the hero card has words for.
enum _AdbHero { checking, connected, off, fresh }
