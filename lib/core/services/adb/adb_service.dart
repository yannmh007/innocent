import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'adb_setup_state.dart';

export 'adb_setup_state.dart';

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

/// Parse one `stat -c '%F|%s|%n'` line from [AdbService.listAdbDir].
///
/// Returns null for a line that cannot be a directory entry, so the caller can
/// skip it rather than invent one.
///
/// Split on the FIRST TWO bars only: `%n` is the path and a path may itself
/// contain `|`. Everything after the second bar is the path, bars included.
/// `%F` is the human type ("directory", "regular file", "symbolic link"), so
/// the test is a substring rather than equality — `stat` on some devices
/// prints "directory" inside a longer phrase.
///
/// Extracted from the middle of [AdbService.listAdbDir] so it can be tested
/// (audit_adb.md A12). It was the kind of code that decays quietly: a careful
/// splitter, a real tolerance rule, and nothing anywhere exercising it.
AdbFileEntry? parseAdbDirLine(String raw) {
  final line = raw.trim();
  if (line.isEmpty) return null;
  final b1 = line.indexOf('|');
  if (b1 <= 0) return null;
  final b2 = line.indexOf('|', b1 + 1);
  if (b2 <= b1) return null;
  final kind = line.substring(0, b1);
  final sizeStr = line.substring(b1 + 1, b2);
  final path = line.substring(b2 + 1).trim();
  if (path.isEmpty) return null;
  final isDir = kind.contains('directory');
  final size = int.tryParse(sizeStr.trim()) ?? 0;
  final segments = path.split('/').where((s) => s.isNotEmpty);
  return AdbFileEntry(
    path: path,
    name: segments.isEmpty ? path : segments.last,
    isDir: isDir,
    // A directory's byte size is an implementation detail of the filesystem,
    // not something to show anyone.
    sizeBytes: isDir ? 0 : (size < 0 ? 0 : size),
  );
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

  /// Whether the connection was working the last time anything used it:
  /// null until something has, then true after any command that went through
  /// and false after one that could not reach the phone.
  ///
  /// The Video tab listens for it turning true. A connection made anywhere —
  /// the Hidden files browser, a picker opening Android/data, the ADB screen,
  /// Wireless debugging switched back on while the "connection lost" card
  /// waits — is then followed by a scan, so Android/data's videos show up in
  /// the Video tab without anybody asking for it.
  final ValueNotifier<bool?> live = ValueNotifier<bool?>(null);

  /// A connect-and-run reached the phone when its command ran (`id` prints
  /// `uid=`). Anything else says nothing either way: those calls answer
  /// with prose on failure, not a marker.
  void _sawConnect(String? out) {
    if (out != null && (out.contains('uid=') || out.startsWith('OK'))) {
      live.value = true;
    }
  }

  int _shellsRunning = 0;
  DateTime _lastShellEnd = DateTime.fromMillisecondsSinceEpoch(0);

  /// How long the connection has carried no command (zero while one runs).
  ///
  /// The engine runs one command at a time, a long Android/data scan
  /// included: a scan started while somebody browses Hidden files makes
  /// their next folder wait for it. Background scans wait for a pause.
  Duration get idleFor => _shellsRunning > 0
      ? Duration.zero
      : DateTime.now().difference(_lastShellEnd);

  Future<T> _counted<T>(Future<T> Function() body) async {
    _shellsRunning++;
    try {
      return await body();
    } finally {
      _shellsRunning--;
      _lastShellEnd = DateTime.now();
    }
  }

  void _saw(String out) {
    final failed = out.startsWith('ERROR') || out.startsWith('Channel error');
    live.value = !failed;
  }

  /// Set once by [setPairResultListener] so the native pairing-service result
  /// broadcast (`onPairResult`) reaches the ADB screen.
  void Function(String result)? _pairResultListener;
  bool _handlerInstalled = false;

  /// Progress of copies out of Android/data, by source path
  /// (`onPullProgress`): bytes so far, and the file's size (-1 unknown).
  final Map<String, void Function(int done, int total)> _pullListeners =
      <String, void Function(int done, int total)>{};

  /// Register a callback for results from the notification pairing service.
  /// The ADB screen calls this in initState and clears it in dispose. Installs
  /// the method-call handler lazily so we don't intercept anything until a
  /// listener actually wants the callback.
  void setPairResultListener(void Function(String result)? listener) {
    _pairResultListener = listener;
    _ensureHandler();
  }

  /// Install the single method-call handler (idempotent) that dispatches all
  /// native→Dart callbacks on this channel: pairing results.
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
        case 'onPullProgress':
          final args = call.arguments;
          if (args is Map && args['src'] is String) {
            final done = args['done'];
            final total = args['total'];
            _pullListeners[args['src'] as String]?.call(
              done is int ? done : 0,
              total is int ? total : -1,
            );
          }
          break;
      }
      return null;
    });
  }

  /// Start the pairing notification service: it discovers the pairing
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
      _sawConnect(r);
      return r ?? 'No response from ADB engine';
    } catch (e) {
      return 'Channel error: $e';
    }
  }

  /// The ADB engine's step-by-step log (see AdbLog.kt): every connect,
  /// reconnect, sweep and pairing attempt and why it failed. Empty when it
  /// cannot be read.
  Future<String> engineLog() async {
    try {
      return await _channel.invokeMethod<String>('adbLog') ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> clearEngineLog() async {
    try {
      await _channel.invokeMethod<bool>('adbLogClear');
    } catch (_) {}
  }

  /// A line from the app's side into the same log (what the screen showed).
  Future<void> noteInEngineLog(String text) async {
    try {
      await _channel.invokeMethod<bool>('adbLogNote', {'text': text});
    } catch (_) {}
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
  ///
  /// [timeoutMs] bounds the round trip, reconnect included: the library's
  /// refresh asks with a short one, so a phone with wireless debugging off
  /// costs a pull-to-refresh three seconds, not twelve.
  Future<bool> isConnected({int timeoutMs = 12000}) async {
    try {
      final r = await _counted(() => _channel.invokeMethod<String>('shell', {
            'command': 'echo ok',
            'timeoutMs': timeoutMs,
          }));
      final ok = r != null && r.contains('ok') && !r.startsWith('ERROR');
      live.value = ok;
      return ok;
    } catch (e) {
      live.value = false;
      return false;
    }
  }

  /// M2: run an arbitrary shell command over the ADB connection (reconnecting
  /// via the remembered address if needed). Returns raw stdout, or an
  /// "ERROR: …" string. [timeoutMs] bounds the native round-trip; the default
  /// suits quick commands, the scan passes a longer budget.
  Future<String> shell(String command, {int timeoutMs = 12000}) async {
    try {
      final r = await _counted(() => _channel.invokeMethod<String>('shell', {
            'command': command,
            'timeoutMs': timeoutMs,
          }));
      final out = r ?? '';
      _saw(out);
      return out;
    } catch (e) {
      live.value = false;
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

  /// Where the phone stands on the way to a connection (see [AdbSetupState]).
  Future<AdbSetupState> setupState() async {
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('adbSetupState');
      return AdbSetupState.fromMap(r);
    } catch (_) {
      return const AdbSetupState();
    }
  }

  /// Innocent's notification settings: the pairing code is typed into a
  /// notification, so with notifications off there is nowhere to type it.
  Future<String> openNotificationSettings() async {
    try {
      final r = await _channel.invokeMethod<String>('openNotificationSettings');
      return r ?? 'failed';
    } catch (_) {
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
    List<String> lines;
    try {
      // Same chunked scan as the Video tab: short commands a wireless-debugging
      // connection won't drop. Any failure here is just an empty picker tab.
      lines = await scanAndroidDataChunked(
        shell: (c) => shellRouted(c, timeoutMs: 20000),
        exts: exts,
      );
    } catch (_) {
      return const [];
    }
    final entries = <AdbFileEntry>[];
    for (final raw in lines) {
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
  Future<List<AdbFileEntry>> listAdbDir(String dirPath) async =>
      await listAdbDirOrNull(dirPath) ?? const <AdbFileEntry>[];

  /// [listAdbDir], but null when the folder could not be READ — no
  /// connection, a dropped one — as opposed to read and empty. A browser
  /// must not show the first as the second: "no files" for a dropped
  /// connection reads as "the files are gone".
  Future<List<AdbFileEntry>?> listAdbDirOrNull(String dirPath) async {
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
      return null;
    }
    if (out.startsWith('ERROR:') || out.startsWith('Channel error')) {
      return null;
    }
    final entries = <AdbFileEntry>[];
    for (final raw in out.split('\n')) {
      final e = parseAdbDirLine(raw);
      if (e != null) entries.add(e);
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
  ///
  /// The copy RESUMES: a connection that drops part way is re-established and
  /// the copy carries on from the bytes it already has, and a copy that
  /// still fails keeps them for the next call. It runs under a foreground
  /// service, so leaving the app or the screen going off does not stop it.
  Future<String> pullForPlayback(String srcPath,
      {void Function(int done, int total)? onProgress}) async {
    if (onProgress != null) {
      _ensureHandler();
      _pullListeners[srcPath] = onProgress;
    }
    try {
      final r = await _channel.invokeMethod<String>('pullForPlayback', {
        'src': srcPath,
      });
      return r ?? 'ERROR: no response';
    } catch (e) {
      return 'ERROR: channel error: $e';
    } finally {
      if (onProgress != null) _pullListeners.remove(srcPath);
    }
  }

  /// Copy an Android/data file straight into the private vault at
  /// [destPath] — no copy in the cache first, so it needs the file's size
  /// free, not twice it. Resumes like [pullForPlayback]. Null on success,
  /// or why it failed.
  Future<String?> pullToVault(String srcPath, String destPath,
      {void Function(int done, int total)? onProgress}) async {
    if (onProgress != null) {
      _ensureHandler();
      _pullListeners[srcPath] = onProgress;
    }
    try {
      final r = await _channel.invokeMethod<String>('pullToVault', {
        'src': srcPath,
        'dest': destPath,
      });
      if (r == null) return 'no response';
      return r == 'OK' ? null : r;
    } catch (e) {
      return 'channel error: $e';
    } finally {
      if (onProgress != null) _pullListeners.remove(srcPath);
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
  /// Run a shell command for a feature built on ADB (the scan, the file
  /// list). The app's own ADB engine is the only one since 1.64.59 — the
  /// separately installed iADB app is no longer used — so this is [shell];
  /// it stays a name of its own so the callers say what they mean.
  Future<String> shellRouted(String command, {int timeoutMs = 12000}) =>
      shell(command, timeoutMs: timeoutMs);

  static bool _shellFailed(String out) =>
      out.startsWith('ERROR:') || out.startsWith('Channel error');

  static List<String> _nonEmptyLines(String out) => out
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  /// Wrap a path for the shell: single-quoted, with embedded quotes escaped.
  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// SCAN ANDROID/DATA A HANDFUL OF APP DIRECTORIES AT A TIME, NOT ONE `find`
  /// ACROSS THE WHOLE TREE.
  ///
  /// A real phone (Samsung SM-S918B, Android 16) connected over Wireless
  /// debugging dropped the single whole-tree scan every time —
  /// `IOException: Stream closed.` about 1.7 s in — while short commands on the
  /// very same connection (the `id` probe, a folder listing) answered fine,
  /// even across fresh reconnects. A 45-second stream over a wireless-debugging
  /// TLS socket is the fragile unit, so "connected but Android/data comes back
  /// empty" was the result.
  ///
  /// So the scan is broken into short commands: first one that lists the app
  /// directories under Android/data and Android/obb, then a `find … -exec stat`
  /// over [chunk] of those directories at a time. Each finishes in about a
  /// second — as reliable as the probe that already works — and a chunk that
  /// still fails costs only its slice, not the whole scan. [shell] runs a
  /// command and returns its output (or an "ERROR:" / "Channel error" string).
  ///
  /// Returns the raw scan lines ("<bytes>|<path>", or a bare path from the
  /// older-toybox fallback). Throws only when nothing could be scanned at all
  /// (the directory listing failed AND the whole-tree fallback failed, or every
  /// single chunk failed on a phone that did have app directories) — so a
  /// caller can tell "nothing is there" (empty list) from "couldn't look"
  /// (throws), and never wipes the Video tab to empty on a dropped connection.
  @visibleForTesting
  static Future<List<String>> scanAndroidDataChunked({
    required Future<String> Function(String command) shell,
    required List<String> exts,
    int chunk = 24,
  }) async {
    if (exts.isEmpty) return <String>[];
    final nameTests = exts.map((e) => "-iname '*.$e'").join(' -o ');
    const roots =
        '/storage/emulated/0/Android/data /storage/emulated/0/Android/obb';

    // One short command to list the app directories under both roots.
    final dirsOut =
        await shell('find $roots -maxdepth 1 -mindepth 1 -type d 2>/dev/null');
    if (_shellFailed(dirsOut)) {
      // Couldn't even list the directories — fall back to the single
      // whole-tree find so this is never worse than the old behaviour. It
      // throws if that fails too.
      return _scanRootsSingle(shell, roots, nameTests);
    }
    final dirs =
        _nonEmptyLines(dirsOut).where((l) => l.startsWith('/')).toList();
    if (dirs.isEmpty) return <String>[]; // connected; nothing to scan

    final lines = <String>[];
    var chunks = 0;
    var failed = 0;
    for (var i = 0; i < dirs.length; i += chunk) {
      final end = i + chunk < dirs.length ? i + chunk : dirs.length;
      final quoted = dirs.sublist(i, end).map(_shQuote).join(' ');
      chunks++;
      // The engine already reconnects and retries once inside a single call,
      // so one try per chunk per form is enough.
      final statOut = await shell(
        "find $quoted -type f \\( $nameTests \\) -exec stat -c '%s|%n' {} + "
        '2>/dev/null',
      );
      if (_shellFailed(statOut)) {
        failed++;
        continue;
      }
      var got = _nonEmptyLines(statOut);
      if (got.isNotEmpty && !got.any((l) => l.contains('/'))) {
        // stat form unusable on this toybox — bare paths for this slice.
        final plain =
            await shell("find $quoted -type f \\( $nameTests \\) 2>/dev/null");
        if (!_shellFailed(plain)) got = _nonEmptyLines(plain);
      }
      lines.addAll(got);
    }
    // Every slice failed on a phone that did have app dirs → the connection
    // went down mid-scan. Say so rather than reporting "nothing there".
    if (chunks > 0 && failed == chunks) {
      throw Exception('ERROR: scan failed — connection lost mid-scan');
    }
    return lines;
  }

  /// The old single whole-tree scan, kept as the fallback for when the app
  /// directories can't be listed. Throws on failure.
  static Future<List<String>> _scanRootsSingle(
    Future<String> Function(String command) shell,
    String roots,
    String nameTests,
  ) async {
    var out = await shell(
      "find $roots -type f \\( $nameTests \\) -exec stat -c '%s|%n' {} + "
      '2>/dev/null',
    );
    if (_shellFailed(out)) throw Exception(out);
    var lines = _nonEmptyLines(out);
    if (!lines.any((l) => l.contains('/'))) {
      out = await shell("find $roots -type f \\( $nameTests \\) 2>/dev/null");
      if (_shellFailed(out)) throw Exception(out);
      lines = _nonEmptyLines(out);
    }
    return lines;
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
    // A handful of app directories per short command, not one long `find` over
    // the whole tree that a wireless-debugging connection drops. Throws when
    // the connection was down the whole time, so the Video tab keeps what it
    // already showed instead of being wiped to empty.
    final lines = await scanAndroidDataChunked(
      shell: (c) => shellRouted(c, timeoutMs: 20000),
      exts: exts,
    );
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

  /// Switch Wireless debugging off directly — possible once Innocent holds
  /// WRITE_SECURE_SETTINGS (the auto-reconnect set-up). False when it does
  /// not, or the write failed; the caller then sends the user to Settings.
  Future<bool> disableWirelessDebugging() async {
    try {
      return await _channel.invokeMethod<bool>('disableWirelessDebugging') ??
          false;
    } catch (_) {
      return false;
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
      _sawConnect(r);
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
      _sawConnect(r);
      return r ?? 'No response from ADB engine';
    } catch (e) {
      return 'Channel error: $e';
    }
  }
}
