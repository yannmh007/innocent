import 'package:flutter/services.dart';

/// Parse a scan line from [AdbService.scanAndroidDataVideos]. Lines are either
/// "<bytes>|<path>" (size-aware scan) or a bare "<path>" (older-device
/// fallback). Returns the path and a size (0 when unknown). Deliberately
/// tolerant: a change or quirk in the scan output degrades to "path, size 0"
/// rather than dropping the video.
({String path, int sizeBytes}) parseAdbScanLine(String line) {
  final t = line.trim();
  final bar = t.indexOf('|');
  if (bar > 0) {
    final size = int.tryParse(t.substring(0, bar));
    if (size != null && size >= 0) {
      final path = t.substring(bar + 1).trim();
      if (path.isNotEmpty) return (path: path, sizeBytes: size);
    }
  }
  return (path: t, sizeBytes: 0);
}

/// Thin bridge to the native ADB engine (`mx_clone/adb` channel).
///
/// Phase 64 / M1a: only [init] (key + certificate self-test) is wired. Pair /
/// connect / shell land in M1b once this foundation is confirmed on-device.
/// One entry in an Android/data directory listing read over ADB — used by the
/// picker's Files browser and the "browse app-data as a file manager" feature.
/// [isDir] distinguishes folders from files; [sizeBytes] is 0 for folders and
/// for files whose size couldn't be stat'd.
class AdbFileEntry {
  final String path;
  final String name;
  final bool isDir;
  final int sizeBytes;
  const AdbFileEntry({
    required this.path,
    required this.name,
    required this.isDir,
    required this.sizeBytes,
  });
}

class AdbService {
  AdbService._();
  static final AdbService instance = AdbService._();

  static const MethodChannel _channel = MethodChannel('mx_clone/adb');

  /// Set once by [setPairResultListener] so the native pairing-service result
  /// broadcast (`onPairResult`) reaches the ADB screen.
  void Function(String result)? _pairResultListener;
  bool _handlerInstalled = false;

  /// Register a callback for results from the notification pairing service.
  /// The ADB screen calls this in initState and clears it in dispose. Installs
  /// the method-call handler lazily so we don't intercept anything until a
  /// listener actually wants the callback.
  void setPairResultListener(void Function(String result)? listener) {
    _pairResultListener = listener;
    _ensureHandler();
  }

  /// Install the single method-call handler (idempotent) that dispatches all
  /// native→Dart callbacks on this channel: pairing results and iADB state.
  void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPairResult':
          final args = call.arguments;
          final res = (args is Map && args['result'] is String)
              ? args['result'] as String
              : '';
          _pairResultListener?.call(res);
          break;
        case 'onIadbState':
          // Native just signals "state changed"; re-query happens in each
          // listener (which calls the threaded iadbConnected/iadbStatus).
          _iadbStateListener?.call(true);
          for (final l in List<void Function(bool)>.of(_iadbStateListeners)) {
            l(true);
          }
          break;
      }
      return null;
    });
  }

  /// Which backend reads Android/data: 'builtin' (embedded libadb engine,
  /// default) or 'iadb' (bind to the installed iADB app — wired in a later
  /// version). Never throws.
  Future<String> getBackend() async {
    try {
      final r = await _channel.invokeMethod<String>('getBackend');
      return r ?? 'builtin';
    } catch (_) {
      return 'builtin';
    }
  }

  /// Persist the chosen backend ('builtin' | 'iadb').
  Future<void> setBackend(String backend) async {
    try {
      await _channel.invokeMethod<bool>('setBackend', {'backend': backend});
    } catch (_) {}
  }

  /// Start the iADB-style pairing notification service: it discovers the pairing
  /// service in the background and posts a "Enter pairing code" reply
  /// notification, so the user can type the 6-digit code from the shade with no
  /// split-screen. Results arrive via [setPairResultListener].
  Future<void> startPairingService() async {
    try {
      await _channel.invokeMethod<bool>('startPairingService');
    } catch (_) {}
  }

  /// Stop the pairing notification service.
  Future<void> stopPairingService() async {
    try {
      await _channel.invokeMethod<bool>('stopPairingService');
    } catch (_) {}
  }

  // ---- v0.93 Backend 2: iADB app client ----

  /// Human-readable status of the iADB-app connection. Never throws.
  Future<String> iadbStatus() async {
    try {
      return await _channel.invokeMethod<String>('iadbStatus') ?? '';
    } catch (_) {
      return '';
    }
  }

  /// True on Android 11+ with the iADB app installed and its server running.
  Future<bool> iadbInstalledAndRunning() async {
    try {
      return await _channel.invokeMethod<bool>('iadbInstalledAndRunning') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// True when our UserService binder is live inside the iADB server.
  Future<bool> iadbConnected() async {
    try {
      return await _channel.invokeMethod<bool>('iadbConnected') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Begin the iADB connect flow (may show iADB's permission dialog). State
  /// changes arrive via [setIadbStateListener].
  Future<void> iadbConnect() async {
    try {
      await _channel.invokeMethod<bool>('iadbConnect');
    } catch (_) {}
  }

  /// Tear down the iADB binding.
  Future<void> iadbDisconnect() async {
    try {
      await _channel.invokeMethod<bool>('iadbDisconnect');
    } catch (_) {}
  }

  /// Run a shell command through the iADB privileged process. "" on failure.
  Future<String> iadbExec(String command) async {
    try {
      return await _channel
              .invokeMethod<String>('iadbExec', {'command': command}) ??
          '';
    } catch (_) {
      return '';
    }
  }

  /// Open the iADB app's Play Store page (native intent; falls back to web).
  Future<void> iadbOpenInStore() async {
    try {
      await _channel.invokeMethod<bool>('iadbOpenInStore');
    } catch (_) {}
  }

  void Function(bool connected)? _iadbStateListener;

  /// Additional iADB state listeners (beyond the single UI one above), so a
  /// global coordinator — e.g. auto-scan on connect — can observe state
  /// changes at the same time as the ADB screen. Native fires "state changed";
  /// each listener re-queries the real state on a worker thread.
  final List<void Function(bool connected)> _iadbStateListeners = [];

  /// Register a persistent iADB state listener. Returns a disposer.
  void Function() addIadbStateListener(void Function(bool connected) listener) {
    _iadbStateListeners.add(listener);
    _ensureHandler();
    return () => _iadbStateListeners.remove(listener);
  }

  /// Register a callback for iADB connect/disconnect events.
  void setIadbStateListener(void Function(bool connected)? listener) {
    _iadbStateListener = listener;
    _ensureHandler();
  }

  /// Build or load the ADB client key + certificate natively and return a
  /// human-readable status string (never throws — errors come back as text).
  Future<String> init() async {
    try {
      final r = await _channel.invokeMethod<String>('init');
      return r ?? 'No response from ADB engine';
    } catch (e) {
      return 'Channel error: $e';
    }
  }

  /// Pair with the device using the port + 6-digit code shown by "Pair device
  /// with pairing code" in Wireless debugging. One-time.
  Future<String> pair(String host, int port, String code) async {
    try {
      final r = await _channel.invokeMethod<String>('pair', {
        'host': host,
        'port': port,
        'code': code,
      });
      return r ?? 'No response from ADB engine';
    } catch (e) {
      return 'Channel error: $e';
    }
  }

  /// Connect to the debug port on the main Wireless debugging screen and run a
  /// shell command, returning its output.
  Future<String> connectAndRun(String host, int port, String command) async {
    try {
      final r = await _channel.invokeMethod<String>('connectAndRun', {
        'host': host,
        'port': port,
        'command': command,
      });
      return r ?? 'No response from ADB engine';
    } catch (e) {
      return 'Channel error: $e';
    }
  }

  /// The last host:port that successfully connected (empty if never), so the
  /// UI can pre-fill it and reconnect without retyping.
  Future<String> lastConnect() async {
    try {
      final r = await _channel.invokeMethod<String>('lastConnect');
      return r ?? '';
    } catch (e) {
      return '';
    }
  }

  /// Quick liveness probe: runs `true` over the connection. Returns true only if
  /// a shell round-trip actually succeeds (so it reflects a *usable* connection,
  /// not just an optimistic flag). Used to show an honest "Connected ✓" state.
  Future<bool> isConnected() async {
    try {
      final r = await _channel.invokeMethod<String>('shell', {
        'command': 'echo ok',
      });
      return r != null && r.contains('ok') && !r.startsWith('ERROR');
    } catch (e) {
      return false;
    }
  }

  /// M2: run an arbitrary shell command over the ADB connection (reconnecting
  /// via the remembered address if needed). Returns raw stdout, or an
  /// "ERROR: …" string. [timeoutMs] bounds the native round-trip; the default
  /// suits quick commands, the scan passes a longer budget.
  Future<String> shell(String command, {int timeoutMs = 12000}) async {
    try {
      final r = await _channel.invokeMethod<String>('shell', {
        'command': command,
        'timeoutMs': timeoutMs,
      });
      return r ?? '';
    } catch (e) {
      return 'Channel error: $e';
    }
  }

  /// Jump the user to the Wireless debugging screen (or Developer options).
  /// Returns 'opened', 'dev_options_off' (Developer options is disabled), or
  /// 'failed'.
  Future<String> openDevOptions() async {
    try {
      final r = await _channel.invokeMethod<String>('openDevOptions');
      return r ?? 'failed';
    } catch (e) {
      return 'failed';
    }
  }

  /// Open the "About phone" screen so the user can tap Build number ×7 to
  /// unlock Developer options.
  Future<String> openAboutPhone() async {
    try {
      final r = await _channel.invokeMethod<String>('openAboutPhone');
      return r ?? 'failed';
    } catch (e) {
      return 'failed';
    }
  }

  /// Scan Android/data + Android/obb for files matching a set of extensions,
  /// over ADB, returning [AdbFileEntry] files (no directories). Used by the
  /// picker's Images / Audio tabs to surface app-data media of that type —
  /// MediaStore never indexes Android/data, so this is the only way to see it.
  /// Returns an empty list on any failure (never throws).
  Future<List<AdbFileEntry>> scanAndroidDataByExt(List<String> exts) async {
    if (exts.isEmpty) return const [];
    final nameTests = exts.map((e) => "-iname '*.$e'").join(' -o ');
    const roots =
        '/storage/emulated/0/Android/data /storage/emulated/0/Android/obb';
    final cmd =
        "find $roots -type f \\( $nameTests \\) -exec stat -c '%s|%n' {} + "
        '2>/dev/null';
    String out;
    try {
      out = await shellRouted(cmd, timeoutMs: 45000);
    } catch (_) {
      return const [];
    }
    if (out.startsWith('ERROR:') || out.startsWith('Channel error')) {
      return const [];
    }
    final entries = <AdbFileEntry>[];
    for (final raw in out.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final parsed = parseAdbScanLine(line);
      if (parsed.path.isEmpty) continue;
      entries.add(AdbFileEntry(
        path: parsed.path,
        name: parsed.path.split('/').last,
        isDir: false,
        sizeBytes: parsed.sizeBytes,
      ));
    }
    entries.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return entries;
  }

  /// List the immediate children of an Android/data directory over ADB, so the
  /// picker's Files browser can act like a real file manager inside app-data
  /// (which the app itself can't read via dart:io). Returns folders and files
  /// with sizes; an empty list on any failure (never throws — the browser just
  /// shows an empty/hint state). Uses the same proven find+stat approach as the
  /// video scan, but at depth 1 and for every entry type.
  ///
  /// Output line format: "<type>|<size>|<path>" where type is 'd' or 'f'.
  /// Path is last so spaces in names are preserved. Sorted folders-first then
  /// by name (case-insensitive).
  Future<List<AdbFileEntry>> listAdbDir(String dirPath) async {
    // Escape single quotes in the path for the shell (' → '\'').
    final safe = dirPath.replaceAll("'", "'\\''");
    // -maxdepth/-mindepth 1 = immediate children only. printf via stat gives a
    // stable, parseable line; %F is the human type ("directory"/"regular
    // file"), %s the size, %n the path. 2>/dev/null hides permission noise.
    final cmd =
        "find '$safe' -maxdepth 1 -mindepth 1 -exec stat -c '%F|%s|%n' {} + "
        '2>/dev/null';
    String out;
    try {
      out = await shellRouted(cmd, timeoutMs: 30000);
    } catch (e) {
      return const [];
    }
    if (out.startsWith('ERROR:') || out.startsWith('Channel error')) {
      return const [];
    }
    final entries = <AdbFileEntry>[];
    for (final raw in out.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      // Split on the FIRST two bars only, so paths containing '|' survive.
      final b1 = line.indexOf('|');
      if (b1 <= 0) continue;
      final b2 = line.indexOf('|', b1 + 1);
      if (b2 <= b1) continue;
      final kind = line.substring(0, b1);
      final sizeStr = line.substring(b1 + 1, b2);
      final path = line.substring(b2 + 1).trim();
      if (path.isEmpty) continue;
      final isDir = kind.contains('directory');
      final size = int.tryParse(sizeStr.trim()) ?? 0;
      final name = path.split('/').where((s) => s.isNotEmpty).isEmpty
          ? path
          : path.split('/').last;
      entries.add(AdbFileEntry(
        path: path,
        name: name,
        isDir: isDir,
        sizeBytes: isDir ? 0 : size,
      ));
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// M3: copy a file the app can't read directly (inside Android/data) out to a
  /// readable cache via ADB, and return the local path to play. Returns an
  /// "ERROR: …" string on failure.
  Future<String> pullForPlayback(String srcPath) async {
    // Route by the selected backend: the iADB app copies the file out of
    // Android/data through its privileged process; the built-in engine pulls it
    // over the ADB socket. Both return a local file path (or "ERROR:").
    final backend = await getBackend();
    if (backend == 'iadb') {
      try {
        final r = await _channel.invokeMethod<String>('iadbPullForPlayback', {
          'path': srcPath,
        });
        return r ?? 'ERROR: no response';
      } catch (e) {
        return 'ERROR: channel error: $e';
      }
    }
    try {
      final r = await _channel.invokeMethod<String>('pullForPlayback', {
        'src': srcPath,
      });
      return r ?? 'ERROR: no response';
    } catch (e) {
      return 'ERROR: channel error: $e';
    }
  }

  /// Faster than [pullForPlayback]: returns an http URL served by a local proxy
  /// that streams the Android/data file on demand over ADB (with Range/seek
  /// support), so playback starts immediately with no full pre-copy. Returns an
  /// "ERROR: …" string if streaming can't be set up (caller then falls back to
  /// [pullForPlayback]).
  Future<String> streamUrl(String srcPath) async {
    try {
      final r = await _channel.invokeMethod<String>('streamUrl', {
        'src': srcPath,
      });
      return r ?? 'ERROR: no response';
    } catch (e) {
      return 'ERROR: channel error: $e';
    }
  }

  /// M2: list video files inside Android/data (and Android/obb) via the ADB
  /// shell, which — unlike the app itself — is allowed to read those folders.
  /// Returns absolute paths, one per line. Persists the result (as "size|path"
  /// lines when sizes are available) so the Local library can show them — with
  /// real file sizes — without re-scanning.
  /// Run a shell command through whichever backend the user selected: the
  /// built-in libadb socket, or the iADB privileged process. Keeps the scan and
  /// any other shell-based feature backend-agnostic. Returns the same shape as
  /// [shell] (an "ERROR:" prefix on failure) so callers don't change.
  Future<String> shellRouted(String command, {int timeoutMs = 12000}) async {
    final backend = await getBackend();
    if (backend == 'iadb') {
      final out = await iadbExec(command);
      if (out.isEmpty) {
        return 'ERROR: iADB returned nothing — is iADB connected? '
            '(Open ADB connection and tap Connect.)';
      }
      return out;
    }
    return shell(command, timeoutMs: timeoutMs);
  }

  // Single-flight: if a scan is already running (e.g. auto-scan-on-connect and
  // a pull-to-refresh fired together), every caller shares the one in-flight
  // scan instead of each spawning a duplicate `find` over Android/data.
  Future<List<String>>? _scanInFlight;

  Future<List<String>> scanAndroidDataVideos() {
    final running = _scanInFlight;
    if (running != null) return running;
    final f = _scanAndroidDataVideos();
    _scanInFlight = f;
    return f.whenComplete(() {
      if (identical(_scanInFlight, f)) _scanInFlight = null;
    });
  }

  Future<List<String>> _scanAndroidDataVideos() async {
    const exts = [
      'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', '3gp', 'ts', 'flv', 'wmv',
    ];
    final nameTests = exts.map((e) => "-iname '*.$e'").join(' -o ');
    const roots =
        '/storage/emulated/0/Android/data /storage/emulated/0/Android/obb';
    // Size-aware scan: one "<bytes>|<path>" line per file. `-exec … {} +`
    // batches the stat calls; toybox on Android 11+ supports both -exec…+ and
    // `stat -c`. If a device's toybox doesn't, we fall back to bare paths below
    // so the scan can never come back empty because of the size flag.
    final statCmd =
        "find $roots -type f \\( $nameTests \\) -exec stat -c '%s|%n' {} + "
        "2>/dev/null";
    var out = await shellRouted(statCmd, timeoutMs: 45000);
    if (out.startsWith('ERROR:') || out.startsWith('Channel error')) {
      throw Exception(out);
    }
    var lines = out
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    // Fallback: if the size-aware form yielded nothing usable, re-run the plain
    // path-only scan (the proven command) so we still find videos.
    final usable = lines.any((l) => l.contains('/'));
    if (!usable) {
      final plain = 'find $roots -type f \\( $nameTests \\) 2>/dev/null';
      out = await shellRouted(plain, timeoutMs: 45000);
      if (out.startsWith('ERROR:') || out.startsWith('Channel error')) {
        throw Exception(out);
      }
      lines = out
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
    }
    await _saveScanned(lines);
    // Callers (the ADB screen list) want clean paths; sizes live in the
    // persisted lines, read back by the Local provider.
    return lines.map((l) => parseAdbScanLine(l).path).toList();
  }

  /// Persist the scanned Android/data video paths natively.
  Future<void> _saveScanned(List<String> paths) async {
    try {
      await _channel.invokeMethod<bool>('saveScanned', {'paths': paths});
    } catch (_) {}
  }

  /// The Android/data video paths remembered from the last scan (may be empty).
  Future<List<String>> savedScannedVideos() async {
    try {
      final out = await _channel.invokeMethod<String>('scannedVideos') ?? '';
      return out
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Grant this app WRITE_SECURE_SETTINGS over the existing ADB shell so it can
  /// re-enable wireless debugging after a reboot with no PC and no root.
  /// Returns a human-readable status string.
  Future<String> setupAutoEnable() async {
    try {
      final r = await _channel.invokeMethod<String>('setupAutoEnable');
      return r ?? 'No response';
    } catch (e) {
      return 'ERROR: channel error: $e';
    }
  }

  /// Whether the WRITE_SECURE_SETTINGS permission is granted, whether the user
  /// has auto-enable turned on, and what the last post-boot restore did.
  ///
  /// `lastBoot` is empty until a reboot restore has run at least once. It is
  /// carried all the way to the screen on purpose (audit_adb.md A5): the old
  /// boot path could fail completely and silently, and a user whose
  /// Android/data videos had vanished had nothing anywhere to read.
  Future<({bool granted, bool on, String lastBoot, int lastBootAt})>
      autoEnableStatus() async {
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>(
        'autoEnableStatus',
      );
      final at = r?['lastBootAt'];
      return (
        granted: r?['granted'] == true,
        on: r?['on'] == true,
        lastBoot: r?['lastBoot'] as String? ?? '',
        lastBootAt: at is int ? at : 0,
      );
    } catch (_) {
      return (granted: false, on: false, lastBoot: '', lastBootAt: 0);
    }
  }

  /// Hand WRITE_SECURE_SETTINGS back to the system (audit_adb.md A9).
  ///
  /// Needs the ADB shell — the same shell that granted it is the only thing
  /// that can take it away — so it can legitimately fail when nothing is
  /// connected. The returned string says which happened.
  Future<String> revokeSecureSettings() async {
    try {
      final r = await _channel.invokeMethod<String>('revokeSecureSettings');
      return r ?? 'No response';
    } catch (e) {
      return 'ERROR: channel error: $e';
    }
  }

  /// Turn the auto-enable-after-reboot behaviour on or off.
  Future<void> setAutoEnable(bool on) async {
    try {
      await _channel.invokeMethod<bool>('setAutoEnable', {'on': on});
    } catch (_) {}
  }

  /// Pair using ONLY the 6-digit code — the pairing host/port are discovered
  /// automatically over mDNS. The pairing-code dialog must stay open.
  Future<String> pairMdns(String code) async {
    try {
      final r = await _channel.invokeMethod<String>('pairMdns', {'code': code});
      return r ?? 'No response from ADB engine';
    } catch (e) {
      return 'Channel error: $e';
    }
  }

  /// Connect with no port typing — the connect host/port are discovered over
  /// mDNS — then run a shell command. Requires having paired once.
  Future<String> autoConnectAndRun(String command) async {
    try {
      final r = await _channel.invokeMethod<String>('autoConnectAndRun', {
        'command': command,
      });
      return r ?? 'No response from ADB engine';
    } catch (e) {
      return 'Channel error: $e';
    }
  }

  /// Daily reconnect used when the ADB screen opens: tries the remembered port
  /// first (fast, works through a VPN), then mDNS if it's stale (e.g. the port
  /// changed after a reboot). Self-heals a stale "connected" socket.
  Future<String> reconnectAndRun(String command) async {
    try {
      final r = await _channel.invokeMethod<String>('reconnectAndRun', {
        'command': command,
      });
      return r ?? 'No response from ADB engine';
    } catch (e) {
      return 'Channel error: $e';
    }
  }
}
