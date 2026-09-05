import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/core_providers.dart';
import '../../../core/router/routes.dart';
import '../../../core/services/adb/adb_service.dart';
import '../../local_browser/presentation/library_provider.dart';

/// Experimental ADB pairing/connect screen.
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

class _AdbConnectScreenState extends ConsumerState<AdbConnectScreen> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _pairAddr = TextEditingController();
  final TextEditingController _connectAddr = TextEditingController();

  String _output = '';
  bool _busy = false;
  bool _pairedBefore = false;
  bool _showManual = false;
  List<String> _found = [];
  bool _autoEnableGranted = false;
  bool _autoEnableOn = false;
  // null = unknown/checking, true = a shell round-trip works, false = not usable.
  bool? _connected;
  // v0.89: 'builtin' (embedded engine) or 'iadb' (bind to the iADB app — wired
  // in a later version). Loaded from native on open.
  String _backend = 'builtin';
  // v0.93: iADB-app backend state.
  bool _iadbConnected = false;
  bool _iadbInstalled = false;
  String _iadbStatus = '';
  // v0.89: whether the notification pairing service is currently running.
  bool _pairingServiceOn = false;

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
    // v0.93: receive iADB connect/disconnect events.
    AdbService.instance.setIadbStateListener(_onIadbState);
    _loadAndAutoConnect();
  }

  /// Result of a pairing attempt made from the notification shade (built-in
  /// backend, iADB-style). Runs on the platform channel callback.
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
      final backend = await AdbService.instance.getBackend();
      if (mounted) setState(() => _backend = backend);
      if (backend == 'iadb') {
        // iADB manages its own connection; skip the built-in autoconnect.
        await _refreshIadbStatus();
        return;
      }
      final st = await AdbService.instance.autoEnableStatus();
      if (mounted) {
        setState(() {
          _autoEnableGranted = st.granted;
          _autoEnableOn = st.on;
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
    } catch (e) {
      if (mounted) setState(() => _output = 'ERROR: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    AdbService.instance.setPairResultListener(null);
    AdbService.instance.setIadbStateListener(null);
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

  // ---- v0.89: backend + notification pairing ----

  Future<void> _setBackend(String backend) async {
    await AdbService.instance.setBackend(backend);
    if (!mounted) return;
    setState(() => _backend = backend);
    if (backend == 'iadb') {
      _refreshIadbStatus();
    }
  }

  // ---- v0.93: iADB-app backend ----

  void _onIadbState(bool _) {
    if (!mounted) return;
    // Native signalled a state change; read the real state on a worker thread.
    _refreshIadbStatus();
  }

  Future<void> _refreshIadbStatus() async {
    final status = await AdbService.instance.iadbStatus();
    final connected = await AdbService.instance.iadbConnected();
    final installed = await AdbService.instance.iadbInstalledAndRunning();
    if (!mounted) return;
    setState(() {
      _iadbStatus = status;
      _iadbConnected = connected;
      _iadbInstalled = installed;
    });
  }

  Future<void> _openIadbInStore() async {
    await AdbService.instance.iadbOpenInStore();
  }

  Future<void> _connectIadb() async {
    setState(() {
      _busy = true;
      _iadbStatus = 'Connecting to iADB…';
    });
    try {
      await AdbService.instance.iadbConnect();
      // The permission dialog / bind completes asynchronously; give it a beat,
      // then refresh. The state listener also updates us when it lands.
      await Future.delayed(const Duration(milliseconds: 800));
      await _refreshIadbStatus();
      // If we're now connected, immediately scan Android/data so the videos
      // appear in Local without the user having to tap "Scan" — the auto-scan
      // coordinator also handles this, but triggering it here makes it instant
      // and reliable right after the tap that connected.
      if (_iadbConnected) {
        unawaited(_autoScanAfterConnect());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Scan Android/data right after connecting and refresh the Local library.
  /// Runs in the background (no busy spinner) so the screen stays responsive;
  /// failures are swallowed — the manual Scan button remains as a fallback.
  Future<void> _autoScanAfterConnect() async {
    try {
      final paths = await AdbService.instance.scanAndroidDataVideos();
      if (!mounted) return;
      if (paths.isNotEmpty) {
        ref.invalidate(adbVideosProvider);
        setState(() {
          _found = paths;
          _output = 'Found ${paths.length} video(s) — added to Local.';
        });
      }
    } catch (_) {
      // Silent: the user can still tap "Scan Android/data for videos".
    }
  }

  Future<void> _disconnectIadb() async {
    setState(() => _busy = true);
    try {
      await AdbService.instance.iadbDisconnect();
      await _refreshIadbStatus();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Start the iADB-style notification pairing flow. A background service posts
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

  // ---- Primary: one-code (mDNS auto-discover) ----

  void _pairMdns() {
    final code = _code.text.trim();
    if (code.length < 6) {
      setState(() => _output = 'Enter the 6-digit pairing code first.');
      return;
    }
    _run(
      () => AdbService.instance.pairMdns(code),
      'Pairing…\nKeep the "Pair device with pairing code" dialog visible '
          '(split-screen / pop-up window).',
    );
  }

  void _connectMdns() {
    _run(
      () => AdbService.instance.autoConnectAndRun('id'),
      'Connecting automatically…',
    );
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

  /// The label adapts: with a fresh 6-digit code we pair first; otherwise we
  /// just (re)connect. One button so users don't have to know the order.
  String _primaryLabel() {
    final hasCode = _code.text.trim().length >= 6;
    if (hasCode) return _pairedBefore ? 'Re-pair & connect' : 'Pair & connect';
    return 'Connect';
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

  /// Tap a found video: copy it out of Android/data via ADB (the app can't read
  /// that folder directly), then play the readable local copy.
  Future<void> _playAdbVideo(String path) async {
    final name = path.split('/').last;
    setState(() {
      _busy = true;
      _output = 'Preparing "$name"…\nCopying out of Android/data (larger files '
          'take a moment).';
    });
    String local;
    try {
      local = await AdbService.instance.pullForPlayback(path);
    } catch (e) {
      local = 'ERROR: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (local.startsWith('ERROR:')) {
      setState(() => _output = 'Could not open "$name".\n$local');
      return;
    }
    setState(() => _output = 'Playing "$name".');
    context.push(Routes.player, extra: {'uri': local, 'title': name});
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

  void _connect() {
    final hp = _split(_connectAddr.text);
    if (hp == null) {
      setState(() => _output =
          'Enter the connect address as IP:Port — copy it exactly from the '
          'main Wireless debugging screen, e.g. 192.168.1.5:32961');
      return;
    }
    _run(
      () =>
          AdbService.instance.connectAndRun(hp[0] as String, hp[1] as int, 'id'),
      'Connecting to ${hp[0]}:${hp[1]} …',
    );
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
      final paths = await AdbService.instance.scanAndroidDataVideos();
      if (!mounted) return;
      // Refresh the Local library so the newly-scanned Android/data videos
      // show up there immediately (they're decoupled from "Show hidden").
      ref.invalidate(adbVideosProvider);
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
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
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
    return Scaffold(
      appBar: AppBar(title: const Text('ADB connection (experimental)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------- backend selector ----------
          _sectionTitle('How Innocent reads Android/data'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                RadioListTile<String>(
                  value: 'iadb',
                  groupValue: _backend,
                  onChanged: _busy
                      ? null
                      : (v) {
                          if (v != null) _setBackend(v);
                        },
                  title: const Text('Use the iADB app (recommended)'),
                  subtitle: const Text(
                    'Connects through the iADB app, like EX File Manager. Its '
                    'always-on server means you pair once and it stays '
                    'connected — even after Wi-Fi changes.',
                  ),
                ),
                const Divider(height: 1),
                RadioListTile<String>(
                  value: 'builtin',
                  groupValue: _backend,
                  onChanged: _busy
                      ? null
                      : (v) {
                          if (v != null) _setBackend(v);
                        },
                  title: const Text('Built-in (no extra app)'),
                  subtitle: const Text(
                    'Innocent pairs and connects on its own — no other app '
                    'needed. May need re-pairing after a reboot or Wi-Fi change.',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ---------- iADB backend UI (only) ----------
          if (_backend == 'iadb') ..._iadbSection(),

          // ---------- built-in backend UI (only) ----------
          if (_backend == 'builtin') ..._builtinSection(),

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),

          // ---------- Android/data access (shared) ----------
          _sectionTitle('Android/data access'),
          const Text(
            'Once connected, scan for videos inside Android/data and '
            'Android/obb (Telegram and other app caches) — folders the app '
            "itself can't read, but ADB can.",
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : _scanAndroidData,
            icon: const Icon(Icons.search),
            label: const Text('Scan Android/data for videos'),
          ),
          if (_found.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('${_found.length} video(s) found:',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ..._found.take(200).map(_videoTile),
            if (_found.length > 200)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('… and ${_found.length - 200} more',
                    style: const TextStyle(color: Colors.white54)),
              ),
          ],
        ],
      ),
    );
  }

  /// The iADB-app backend UI: a single premium status card + connect button,
  /// plus an install prompt when iADB isn't present. No built-in/LADB clutter.
  List<Widget> _iadbSection() {
    final installed = _iadbInstalled;
    return [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: (_iadbConnected ? Colors.green : Colors.orange)
              .withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _iadbConnected ? Icons.check_circle : Icons.link_off,
                  color: _iadbConnected ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _iadbConnected
                        ? 'Connected to iADB'
                        : (installed
                            ? 'iADB found — not connected'
                            : 'iADB app not installed'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _iadbStatus.isNotEmpty
                  ? _iadbStatus
                  : (installed
                      ? 'Tap Connect and allow access when iADB asks.'
                      : 'Install the iADB app, open it once and start its '
                          'server, then come back and tap Connect.'),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 14),
            if (!installed)
              FilledButton.icon(
                onPressed: _busy ? null : _openIadbInStore,
                icon: const Icon(Icons.shop),
                label: const Text('Get iADB on Play Store'),
              )
            else
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _connectIadb,
                    icon: const Icon(Icons.link),
                    label: Text(_iadbConnected ? 'Reconnect' : 'Connect'),
                  ),
                  const SizedBox(width: 8),
                  if (_iadbConnected)
                    TextButton(
                      onPressed: _busy ? null : _disconnectIadb,
                      child: const Text('Disconnect'),
                    ),
                ],
              ),
          ],
        ),
      ),
      if (_busy)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Working…'),
            ],
          ),
        ),
    ];
  }

  /// The built-in (libadb) backend UI — all the pairing/connect/reboot controls.
  /// Shown only when the built-in backend is selected, so it never clutters the
  /// iADB experience.
  List<Widget> _builtinSection() {
    return [
      if (_pairedBefore)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            '✓ This device was paired before — reconnecting automatically. '
            'You only need to pair again after a reboot (Wireless debugging '
            'turns itself off then).',
          ),
        ),
      _sectionTitle('Easy setup — just one code'),
      const Text(
        'First time only:\n'
        '1. Developer options → turn on Wireless debugging.\n'
        '2. Open this app and Settings side by side (split-screen or '
        'pop-up window) — Android needs the pairing dialog to stay '
        'visible.\n'
        '3. In Settings tap "Pair device with pairing code" — it shows a '
        '6-digit code.\n'
        '4. Type that code below and tap "Pair". No IP address needed.\n\n'
        'After pairing, tap "Connect" (next time this screen reconnects on '
        'its own).',
        style: TextStyle(fontSize: 13),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _busy ? null : _openWirelessDebugging,
        icon: const Icon(Icons.settings),
        label: const Text('Open Wireless debugging'),
      ),
      const SizedBox(height: 12),
      // iADB-style "pair from the notification" — no split-screen.
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.teal.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Easiest: pair from the notification',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'No split-screen. Start this, open the pairing dialog, then '
              'type the 6-digit code into the notification and send.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            if (!_pairingServiceOn)
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _startNotificationPairing,
                icon: const Icon(Icons.notifications_active),
                label: const Text('Pair from notification'),
              )
            else
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Waiting for the code in the notification…',
                      style:
                          TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _stopNotificationPairing,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        'Or pair with the code in-app (needs the pairing dialog visible):',
        style: TextStyle(fontSize: 12, color: Colors.white54),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _code,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Pairing code (6 digits)',
          hintText: 'e.g. 860163',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 10),
      FilledButton(
        onPressed: _busy ? null : _pairAndConnect,
        child: Text(_primaryLabel()),
      ),
      const SizedBox(height: 16),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.blue.withOpacity(0.10),
          borderRadius: BorderRadius.circular(8),
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
            const SizedBox(height: 8),
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
                onPressed: _busy ? null : _setupAutoEnable,
                icon: const Icon(Icons.bolt),
                label: const Text('Set up auto-reconnect'),
              ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      // ---------- Status (built-in only) ----------
      _sectionTitle('Status'),
      if (_connected != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Icon(
                _connected! ? Icons.check_circle : Icons.cancel,
                size: 18,
                color: _connected! ? Colors.green : Colors.redAccent,
              ),
              const SizedBox(width: 8),
              Text(
                _connected! ? 'Connected' : 'Not connected',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _connected! ? Colors.green : Colors.redAccent,
                ),
              ),
            ],
          ),
        ),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(8),
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
                _output.isEmpty ? '(no output yet)' : _friendly(_output),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      const Divider(),
      // ---------- Advanced: manual IP:Port (built-in only) ----------
      TextButton.icon(
        onPressed: () => setState(() => _showManual = !_showManual),
        icon: Icon(_showManual ? Icons.expand_less : Icons.expand_more),
        label: Text(_showManual
            ? 'Hide advanced (manual IP:Port)'
            : 'Advanced — manual IP:Port (if the code alone fails)'),
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
