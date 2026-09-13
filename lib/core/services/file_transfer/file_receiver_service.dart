import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_isolate.dart';
import 'received_history.dart';
import 'transfer_discovery.dart';
import 'transfer_foreground_service.dart';
import 'turbo_link_service.dart';

/// The sender wants a PIN (or the one we sent was wrong).
class PinRequired implements Exception {
  const PinRequired();
  @override
  String toString() => 'PIN required';
}

/// One file advertised by a sender's /manifest endpoint.
class RemoteFile {
  final int index;
  final String name;
  final int size;

  /// Position inside a sent folder (`Holiday/2024/beach.jpg`), or '' for a
  /// loose file. Present only when the sender shared a whole folder.
  final String relPath;

  const RemoteFile({
    required this.index,
    required this.name,
    required this.size,
    this.relPath = '',
  });

  factory RemoteFile.fromJson(Map<String, dynamic> j) => RemoteFile(
        index: (j['index'] as num).toInt(),
        name: j['name'] as String? ?? 'file_${j['index']}',
        size: (j['size'] as num?)?.toInt() ?? 0,
        relPath: (j['rel'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'name': name,
        'size': size,
        if (relPath.isNotEmpty) 'rel': relPath,
      };
}

/// Download progress for a single remote file.
class ReceiveProgress {
  final int received;
  final int total;
  final bool done;
  final String? savedPath;
  final String? error;
  // Live transfer rate in bytes/second (0 until enough data to estimate).
  final double bytesPerSec;
  /// True when the file was already on disk with a matching size, so nothing
  /// was transferred. Re-sending a batch shouldn't re-download what's there.
  final bool skipped;
  /// The sender has this share paused. Shown differently from a stall on
  /// purpose — a frozen bar with no explanation reads as a crash.
  final bool pausedBySender;
  const ReceiveProgress({
    this.received = 0,
    this.total = 0,
    this.done = false,
    this.savedPath,
    this.error,
    this.bytesPerSec = 0,
    this.skipped = false,
    this.pausedBySender = false,
  });

  double get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;

  ReceiveProgress copyWith({
    int? received,
    int? total,
    bool? done,
    String? savedPath,
    String? error,
    double? bytesPerSec,
    bool? skipped,
    bool? pausedBySender,
  }) =>
      ReceiveProgress(
        received: received ?? this.received,
        total: total ?? this.total,
        done: done ?? this.done,
        savedPath: savedPath ?? this.savedPath,
        error: error ?? this.error,
        bytesPerSec: bytesPerSec ?? this.bytesPerSec,
        skipped: skipped ?? this.skipped,
        pausedBySender: pausedBySender ?? this.pausedBySender,
      );
}

class ReceiverState {
  final bool connecting;
  final bool connected;
  final String? baseUrl;
  final List<RemoteFile> files;
  final Map<int, ReceiveProgress> progress; // keyed by RemoteFile.index
  final String? error;
  final String? saveDir;
  // True when an interrupted download from a previous run was found on launch
  // and can be resumed.
  final bool resumeAvailable;
  /// Name of the phone we're pulling from, once paired.
  final String? senderName;
  /// Devices currently visible over UDP discovery.
  final List<DiscoveredDevice> nearby;
  /// True while a batch is running — drives the Cancel button.
  final bool batchRunning;
  /// The user paused this side. Distinct from [senderPaused]: partial files
  /// are kept either way, but only this one has a Resume button here.
  final bool userPaused;
  /// The sender is holding the share.
  final bool senderPaused;
  /// Set when the sender wants a PIN, so the UI can ask for it.
  final DiscoveredDevice? pinNeededFor;
  /// True while this phone is pinned to a sender's Turbo link. Worth showing
  /// prominently: the whole app has no internet in this state, and the user
  /// needs an obvious way out.
  final bool turboJoined;
  final String turboMode;
  /// Set while joining, so the UI can show the right spinner text — the system
  /// permission dialog appears during this and it is not instant.
  final bool turboJoining;

  const ReceiverState({
    this.connecting = false,
    this.connected = false,
    this.baseUrl,
    this.files = const [],
    this.progress = const {},
    this.error,
    this.saveDir,
    this.resumeAvailable = false,
    this.senderName,
    this.nearby = const [],
    this.batchRunning = false,
    this.turboJoined = false,
    this.turboMode = '',
    this.turboJoining = false,
    this.userPaused = false,
    this.senderPaused = false,
    this.pinNeededFor,
  });

  bool get isDownloading =>
      progress.values.any((pr) => !pr.done && pr.error == null && pr.total > 0);

  /// Bytes received across the whole batch (finished files counted in full).
  int get receivedBytes {
    var n = 0;
    for (final f in files) {
      final pr = progress[f.index];
      if (pr == null) continue;
      n += pr.done ? f.size : pr.received;
    }
    return n;
  }

  /// Total bytes of every file in the batch.
  int get totalBytes {
    var n = 0;
    for (final f in files) {
      n += f.size;
    }
    return n;
  }

  /// Combined rate of whatever is transferring right now.
  /// True when anything in flight is waiting on the sender.
  bool get anyPausedBySender =>
      progress.values.any((pr) => pr.pausedBySender && !pr.done);

  double get currentSpeed {
    var s = 0.0;
    for (final pr in progress.values) {
      if (!pr.done && pr.error == null) s += pr.bytesPerSec;
    }
    return s;
  }

  /// Seconds left for the whole batch, or null when there's nothing to
  /// estimate from yet.
  int? get etaSeconds {
    final speed = currentSpeed;
    if (speed < 1024) return null;
    final left = totalBytes - receivedBytes;
    if (left <= 0) return 0;
    return (left / speed).round();
  }

  int get doneCount =>
      files.where((f) => progress[f.index]?.done ?? false).length;

  ReceiverState copyWith({
    bool? connecting,
    bool? connected,
    String? baseUrl,
    List<RemoteFile>? files,
    Map<int, ReceiveProgress>? progress,
    String? error,
    String? saveDir,
    bool? resumeAvailable,
    String? senderName,
    List<DiscoveredDevice>? nearby,
    bool? batchRunning,
    bool? turboJoined,
    String? turboMode,
    bool? turboJoining,
    bool? userPaused,
    bool? senderPaused,
    DiscoveredDevice? pinNeededFor,
    bool clearError = false,
    bool clearPinPrompt = false,
  }) =>
      ReceiverState(
        connecting: connecting ?? this.connecting,
        connected: connected ?? this.connected,
        baseUrl: baseUrl ?? this.baseUrl,
        files: files ?? this.files,
        progress: progress ?? this.progress,
        error: clearError ? null : (error ?? this.error),
        saveDir: saveDir ?? this.saveDir,
        resumeAvailable: resumeAvailable ?? this.resumeAvailable,
        senderName: senderName ?? this.senderName,
        nearby: nearby ?? this.nearby,
        batchRunning: batchRunning ?? this.batchRunning,
        turboJoined: turboJoined ?? this.turboJoined,
        turboMode: turboMode ?? this.turboMode,
        turboJoining: turboJoining ?? this.turboJoining,
        userPaused: userPaused ?? this.userPaused,
        senderPaused: senderPaused ?? this.senderPaused,
        pinNeededFor:
            clearPinPrompt ? null : (pinNeededFor ?? this.pinNeededFor),
      );
}

/// Pulls files from another Innocent device's transfer server (same
/// Wi-Fi). Pure Dart over HTTP — no native, no browser. Streams each
/// download to disk with progress so a dropped connection surfaces
/// instead of hanging.
class FileReceiverService {
  // The byte-moving engine lives in download_isolate.dart and, when the
  // device allows it, runs on a BACKGROUND ISOLATE.
  //
  // Why that matters: the download loop wakes hundreds of times a second at
  // 25 MB/s, and on the UI isolate it was taking turns with every widget
  // rebuild — a busy frame throttled the socket and a fast socket janked the
  // list. Same code either way (one TransferEngine), so the fallback can never
  // drift from the fast path.
  IsolateDownloader? _worker;
  bool _workerTried = false;
  /// Used when no isolate could be spawned. Identical implementation.
  TransferEngine? _inProcess;
  bool _cancelled = false;

  Future<void> _ensureWorker() async {
    if (_workerTried) return;
    _workerTried = true;
    _worker = await IsolateDownloader.spawn();
  }

  TransferEngine _fallbackEngine() => _inProcess ??= TransferEngine();

  /// Close the pooled sockets once a batch is finished. Leaving them open
  /// would hold the sender's server (and the Wi-Fi radio) busier than needed.
  void endBatch() {
    _worker?.closeClient();
    _inProcess?.closeClient();
  }

  /// How many concurrent range requests to use for a file of [size].
  ///
  /// Two phones share one channel's airtime, so the gain flattens out — but 8
  /// streams on a multi-gigabyte file still keeps the pipe fuller than 4 when
  /// one stream stalls on loss.
  static int segmentsFor(int size) {
    if (size >= 512 * 1024 * 1024) return 8;
    if (size >= 128 * 1024 * 1024) return 6;
    if (size >= 32 * 1024 * 1024) return 4;
    if (size >= 12 * 1024 * 1024) return 3;
    return 2;
  }

  /// Normalise the pasted/scanned URL: must look like
  /// http://host:port/<token>. Trailing slash trimmed.
  static String normalizeBase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Future<List<RemoteFile>> fetchManifest(String baseUrl) async {
    final uri = Uri.parse('$baseUrl/manifest');
    final resp = await http.get(uri).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('Sender responded ${resp.statusCode}. '
          'Check the address and that the share is still open.');
    }
    final decoded = jsonDecode(resp.body);
    final raw = (decoded is Map && decoded['files'] is List)
        ? decoded['files'] as List
        : const [];
    return raw
        .map((e) => RemoteFile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Ask a discovered device for permission to receive. Returns the base URL
  /// (origin + token) and the file list in one round trip.
  ///
  /// This is the discovery path: the UDP beacon deliberately carries no token,
  /// so a phone that merely hears the broadcast can't pull anything until the
  /// sender hands it over here.
  Future<({String baseUrl, List<RemoteFile> files})> pair(
      DiscoveredDevice device, {
    String pin = '',
  }) async {
    final id = await TransferDiscovery.instance.deviceId();
    final name = await TransferDiscovery.instance.deviceName();
    final uri = Uri.parse('${device.origin}/pair').replace(queryParameters: {
      'id': id,
      'name': name,
      if (pin.isNotEmpty) 'pin': pin,
    });
    // Long enough to cover the sender tapping Accept when approval is on.
    final resp = await http.get(uri).timeout(const Duration(seconds: 50));
    if (resp.statusCode == 401) {
      // A dedicated type, not a message: the UI has to tell "ask for the PIN"
      // apart from every other failure, and matching on English prose would
      // break the moment someone translates it.
      throw const PinRequired();
    }
    if (resp.statusCode == 403) {
      throw Exception('The other phone declined the request.');
    }
    if (resp.statusCode != 200) {
      throw Exception('Could not connect (HTTP ${resp.statusCode}).');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final token = j['token'] as String?;
    if (token == null || token.isEmpty) {
      throw Exception('The other phone did not send a valid share code.');
    }
    final files = ((j['files'] as List?) ?? const [])
        .map((e) => RemoteFile.fromJson(e as Map<String, dynamic>))
        .toList();
    return (baseUrl: '${device.origin}/$token', files: files);
  }

  /// Fetch the manifest, tolerating a link that has only just come up.
  ///
  /// Straight after joining a Wi-Fi Direct group the interface exists but DHCP
  /// may not have handed out an address yet, so the first connect attempt can
  /// fail on a link that is about to work perfectly. One shot with a 10-second
  /// timeout would send the user back to rescan the QR for no reason.
  Future<List<RemoteFile>> fetchManifestWithRetry(
    String baseUrl, {
    int attempts = 5,
    Duration gap = const Duration(milliseconds: 900),
  }) async {
    Object? last;
    for (var i = 0; i < attempts; i++) {
      if (_cancelled) break;
      try {
        return await fetchManifest(baseUrl);
      } catch (e) {
        last = e;
        if (i < attempts - 1) await Future<void>.delayed(gap);
      }
    }
    throw last ?? Exception('Could not reach the sender.');
  }

  /// Cheap liveness check used before resuming a saved session.
  Future<bool> ping(String baseUrl) async {
    try {
      final origin = Uri.parse(baseUrl).replace(path: '/ping');
      final resp =
          await http.get(origin).timeout(const Duration(seconds: 4));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// The public "Innocent" folder on internal storage, visible in any file
  /// manager (not the hidden Android/data sandbox). Received files are
  /// sorted into category subfolders under it (Videos / Photos / Music /
  /// Documents / Others) so they land next to similar media. Needs
  /// all-files access (MANAGE_EXTERNAL_STORAGE), which the app already
  /// requests for the vault's Files browser; if that public path can't be
  /// created we fall back to the app-specific external dir so a transfer
  /// never fails outright.
  static const String _publicRoot = '/storage/emulated/0/Innocent';

  /// Map a filename to its category subfolder.
  static String categoryFor(String name) {
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    const video = {
      'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', '3gp',
      'ts', 'mpg', 'mpeg', 'm2ts', 'vob', 'ogv'
    };
    const image = {
      'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif', 'tiff',
      'svg', 'raw', 'dng'
    };
    const audio = {
      'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma', 'opus', 'amr',
      'mid', 'midi', 'aiff'
    };
    const doc = {
      'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf',
      'odt', 'ods', 'odp', 'csv', 'epub', 'md'
    };
    if (video.contains(ext)) return 'Videos';
    if (image.contains(ext)) return 'Photos';
    if (audio.contains(ext)) return 'Music';
    if (doc.contains(ext)) return 'Documents';
    if (ext == 'apk') return 'Apps';
    return 'Others';
  }

  /// Resolve the public "Innocent" root on primary external storage. Most
  /// devices expose this at /storage/emulated/0, but rather than hardcode
  /// that everywhere we derive the real primary-storage root from the
  /// app-specific external dir (…/Android/data/<pkg>/files) by walking up to
  /// the volume root, then append /Innocent. Falls back to the well-known
  /// path if that derivation isn't possible.
  String? _rootCache;
  Future<String> _resolvePublicRoot() async {
    final cached = _rootCache;
    if (cached != null) return cached;
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        // ext.path is typically /storage/emulated/0/Android/data/<pkg>/files
        final idx = ext.path.indexOf('/Android/');
        if (idx > 0) {
          _rootCache = p.join(ext.path.substring(0, idx), 'Innocent');
          return _rootCache!;
        }
      }
    } catch (_) {}
    _rootCache = _publicRoot;
    return _rootCache!;
  }

  /// Per-category destination cache. Resolving the directory used to run a
  /// platform call plus a create-file/delete-file write probe FOR EVERY FILE;
  /// on a 500-photo batch that is 500 pointless probes competing with the
  /// download for I/O. The filesystem doesn't change mid-batch, so resolve
  /// each category once.
  final Map<String, Directory> _dirCache = {};

  /// Turn a sender-supplied relative path into something safe to join onto
  /// our storage root.
  ///
  /// This is the one place a remote peer gets to influence a filesystem path,
  /// so it is treated as hostile: absolute paths, drive letters, `..`, `.`,
  /// empty segments and control characters all go. A manifest claiming
  /// `../../../../data/data/com.example/databases/x` must not be able to
  /// escape, and dropping the segments rather than rejecting the file keeps a
  /// merely-odd folder name from failing an otherwise fine transfer.
  static String sanitizeRelDir(String rel) {
    if (rel.isEmpty) return '';
    final parts = rel.replaceAll('\\', '/').split('/');
    final safe = <String>[];
    // The last part is the filename; only the directories matter here.
    for (var i = 0; i < parts.length - 1; i++) {
      final seg = _safeName(parts[i]).trim();
      if (seg.isEmpty || seg == '.' || seg == '..') continue;
      safe.add(seg);
      // A folder nested deeper than this is almost certainly a mistake, and
      // some filesystems cap total path length.
      if (safe.length >= 12) break;
    }
    return safe.join('/');
  }

  /// Destination for a file that arrived as part of a folder: the tree is
  /// rebuilt under the public root instead of being sorted by media type.
  final Map<String, Directory> _relDirCache = {};
  Future<Directory> receiveDirForRel(String rel) async {
    final sub = sanitizeRelDir(rel);
    if (sub.isEmpty) return receiveDirFor(p.basename(rel));
    final cached = _relDirCache[sub];
    if (cached != null) return cached;
    final root = await _resolvePublicRoot();
    try {
      final dir = Directory(p.join(root, sub));
      if (!await dir.exists()) await dir.create(recursive: true);
      _relDirCache[sub] = dir;
      return dir;
    } catch (_) {
      // Public storage refused; fall back to the app-specific dir, keeping
      // the tree.
      final base = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(base.path, 'Innocent_Received', sub));
      if (!await dir.exists()) await dir.create(recursive: true);
      _relDirCache[sub] = dir;
      return dir;
    }
  }

  /// Where a given remote file should land.
  Future<Directory> destinationFor(RemoteFile f) =>
      f.relPath.isEmpty ? receiveDirFor(f.name) : receiveDirForRel(f.relPath);

  /// Resolve the destination directory for a given file, creating the
  /// category subfolder as needed. [name] decides the category.
  Future<Directory> receiveDirFor(String name) async {
    final category = categoryFor(name);
    final cached = _dirCache[category];
    if (cached != null) return cached;
    final root = await _resolvePublicRoot();
    // Try the public Innocent/<Category> folder first.
    try {
      final dir = Directory(p.join(root, category));
      if (!await dir.exists()) await dir.create(recursive: true);
      // Confirm it's actually writable (all-files access may be missing).
      final probe = File(p.join(dir.path, '.wtest'));
      await probe.writeAsString('', flush: true);
      await probe.delete();
      _dirCache[category] = dir;
      return dir;
    } catch (_) {
      // Fall back to the app-specific external dir (no permission needed).
      final base = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(base.path, 'Innocent_Received', category));
      if (!await dir.exists()) await dir.create(recursive: true);
      _dirCache[category] = dir;
      return dir;
    }
  }

  /// The folder shown to the user as the save location. Prefers the public
  /// Innocent/ root (where categorized files land); falls back to the
  /// app-specific dir if public storage isn't writable.
  Future<Directory> receiveRootForDisplay() async {
    final root = await _resolvePublicRoot();
    try {
      final dir = Directory(root);
      if (!await dir.exists()) await dir.create(recursive: true);
      final probe = File(p.join(dir.path, '.wtest'));
      await probe.writeAsString('', flush: true);
      await probe.delete();
      return dir;
    } catch (_) {
      final base = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      return Directory(p.join(base.path, 'Innocent_Received'));
    }
  }

  /// Legacy single-folder accessor kept for callers that don't have a
  /// filename yet. Prefer [receiveDirFor].
  Future<Directory> receiveDir() async {
    final base = (await getExternalStorageDirectory()) ??
        await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'Innocent_Received'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Free bytes on the volume we save to, or -1 when the platform can't say.
  /// dart:io has no free-space API, so this goes through the native side.
  Future<int> freeSpaceBytes() async {
    if (kIsWeb) return -1;
    try {
      final dir = await receiveRootForDisplay();
      final v = await _mediaScanChannel
          .invokeMethod<int>('freeBytes', {'dir': dir.path});
      return v ?? -1;
    } catch (e) {
      if (kDebugMode) debugPrint('file_receiver_service.freeSpace: $e');
      return -1;
    }
  }

  /// True when a completed file of exactly this name and size already sits in
  /// the destination — re-running a share shouldn't re-pull what's there.
  Future<String?> existingCompleteFile(RemoteFile f) async {
    if (f.size <= 0) return null;
    try {
      final dir = await destinationFor(f);
      final path = p.join(dir.path, _safeName(f.name));
      final file = File(path);
      if (await file.exists() && await file.length() == f.size) {
        return path;
      }
    } catch (_) {}
    return null;
  }

  /// Stream one file to disk. [onProgress] is called as bytes arrive.
  /// Returns the saved path. Partial files are deleted on failure.
  Future<String> downloadFile(
    String baseUrl,
    RemoteFile f,
    void Function(int received, int total, double bytesPerSec, bool paused)
        onProgress, {
    bool scanNow = true,
  }) async {
    if (kIsWeb) {
      throw StateError('Receiving needs a native Android build.');
    }
    final dir = await destinationFor(f);
    final finalPath = p.join(dir.path, _safeName(f.name));
    // Download into a ".part" sidecar, renamed to the final name only when the
    // file is verified complete. This is what makes resume-across-restart
    // correct: a leftover ".part" means "an interrupted download to continue",
    // while an existing FINAL file means "a real duplicate to rename around".
    // (The old code renamed around the partial itself, so a resumed session
    // started over and orphaned the partial.)
    final partPath = '$finalPath.part';
    var destFinal = finalPath;
    // Only treat a FINISHED file as a duplicate. A .part with the same base is
    // ours to resume, so don't bump the name for it.
    if (await File(finalPath).exists() && !await File(partPath).exists()) {
      final base = p.basenameWithoutExtension(finalPath);
      final ext = p.extension(finalPath);
      destFinal = p.join(
          dir.path, '$base-${DateTime.now().millisecondsSinceEpoch}$ext');
    }
    final destPath = partPath;

    // Resume-capable download, run by TransferEngine (background isolate when
    // one could be spawned). Every path is already resolved here: the engine
    // only ever sees an absolute ".part" path, so nothing on the far side has
    // to touch path_provider or a platform channel.
    await _ensureWorker();
    final job = TransferJob(
      baseUrl: baseUrl,
      index: f.index,
      partPath: destPath,
      size: f.size,
      segments: segmentsFor(f.size),
    );
    void bridge(int received, int total, double bps, bool paused) =>
        onProgress(received, total, bps, paused);
    final worker = _worker;
    if (worker != null && worker.isAlive) {
      await worker.run(job, bridge);
    } else {
      await _fallbackEngine().run(job, bridge);
    }
    final saved = destPath;
    // Verified-complete → promote the .part to its real name (renaming around
    // a duplicate final if one appeared meanwhile).
    return _finalizePart(saved, destFinal, scanNow: scanNow);
  }

  /// Rename a completed ".part" download to its final name, then media-scan it.
  Future<String> _finalizePart(String partPath, String finalPath,
      {bool scanNow = true}) async {
    try {
      var target = finalPath;
      if (await File(finalPath).exists()) {
        final base = p.basenameWithoutExtension(finalPath);
        final ext = p.extension(finalPath);
        target = p.join(p.dirname(finalPath),
            '$base-${DateTime.now().millisecondsSinceEpoch}$ext');
      }
      await File(partPath).rename(target);
      if (scanNow) {
        await mediaScan([target]);
      } else {
        // Batch mode: one scan call for the whole run instead of one platform
        // round trip per file.
        _pendingScans.add(target);
      }
      return target;
    } catch (_) {
      // If the rename fails (rare), the .part file is still a complete,
      // playable file — hand back its path rather than failing the transfer.
      return partPath;
    }
  }

  final List<String> _pendingScans = [];

  /// Flush the batched media-scan queue. Called once at the end of a batch.
  Future<void> flushMediaScans() async {
    if (_pendingScans.isEmpty) return;
    final paths = List<String>.of(_pendingScans);
    _pendingScans.clear();
    await mediaScan(paths);
  }

  void cancel() {
    _cancelled = true;
    _worker?.cancel();
    _inProcess?.cancel();
  }

  /// Clear the cancel flag before a fresh (batch) download so a previous
  /// abort doesn't immediately stop the new run.
  void resetCancel() {
    _cancelled = false;
    _worker?.resetCancel();
    _inProcess?.resetCancel();
  }

  bool get isCancelled => _cancelled;

  /// Tear the worker down for good (app/provider shutdown).
  Future<void> shutdown() async {
    cancel();
    final w = _worker;
    _worker = null;
    _workerTried = false;
    await w?.dispose();
  }

  static const MethodChannel _mediaScanChannel =
      MethodChannel('mx_clone/media_scan');

  /// Ask the OS MediaScanner to index newly-written public files so they show
  /// up in Gallery / file managers right away. Best-effort, and batched: the
  /// native side takes a list, so a 500-file transfer costs one platform call
  /// instead of 500.
  Future<void> mediaScan(List<String> paths) async {
    if (paths.isEmpty) return;
    try {
      await _mediaScanChannel.invokeMethod('scan', {'paths': paths});
    } catch (e) {
      if (kDebugMode) debugPrint('file_receiver_service.mediaScan: $e');
    }
  }

  /// Exposed so the fuzz in `test/transfer_sanitize_test.dart` can reach it.
  ///
  /// README records a 30,000-case fuzz that found the `..` survivor, and a
  /// 60,000-case re-fuzz that found none — but neither lives in this repo, so
  /// nothing has re-run them since and nothing would notice a regression. A
  /// test that cannot be re-run does not protect anything; this makes it one
  /// CI runs on every push.
  @visibleForTesting
  static String safeNameForTest(String name) => _safeName(name);

  static String _safeName(String name) {
    // Strip path separators / quotes a malicious manifest might send.
    final stripped = name.replaceAll(RegExp(r'[/\\\x00-\x1f"]'), '_');
    // Stripping separators is not enough by itself: "." and ".." contain none
    // and still resolve to this folder and its PARENT. A fuzz of the upload
    // path found exactly this one survivor, and the same manifest field feeds
    // both, so both get the same guard.
    if (stripped == '.' || stripped == '..' || stripped.trim().isEmpty) {
      return 'file-${DateTime.now().millisecondsSinceEpoch}';
    }
    return stripped;
  }
}

final fileReceiverServiceProvider = Provider<FileReceiverService>((ref) {
  final svc = FileReceiverService();
  // shutdown(), not cancel(): a live background isolate would otherwise
  // outlive the provider with its sockets still open.
  ref.onDispose(svc.shutdown);
  return svc;
});

class ReceiverNotifier extends StateNotifier<ReceiverState> {
  final FileReceiverService _svc;
  final Ref _ref;
  StreamSubscription<List<DiscoveredDevice>>? _nearbySub;
  Timer? _turboIdleTimer;

  ReceiverNotifier(this._svc, this._ref) : super(const ReceiverState()) {
    // On construction (app launch / Transfer tab first built), look for an
    // interrupted download to offer to resume.
    _loadResumeSession();
    _nearbySub = TransferDiscovery.instance.devices.listen((list) {
      if (!mounted) return;
      state = state.copyWith(nearby: list);
    });
  }

  // ---- Nearby-device discovery ---------------------------------------

  /// Start/stop the UDP radar. Driven by the Receive tab becoming visible, so
  /// the socket and its MulticastLock are only alive while someone is looking.
  Future<void> startDiscovery() => TransferDiscovery.instance.startListening();
  Future<void> stopDiscovery() => TransferDiscovery.instance.stopListening();
  Future<void> refreshDiscovery() => TransferDiscovery.instance.probe();

  /// One-tap connect to a device found on the radar: ask it for the share
  /// token, then list its files. This is the path that replaces typing an IP.
  Future<void> connectToDevice(DiscoveredDevice device,
      {String pin = ''}) async {
    state = state.copyWith(
        connecting: true,
        clearError: true,
        connected: false,
        files: [],
        clearPinPrompt: true);
    try {
      final res = await _svc.pair(device, pin: pin);
      final dir = await _svc.receiveRootForDisplay();
      if (!mounted) return;
      state = state.copyWith(
        connecting: false,
        connected: true,
        baseUrl: res.baseUrl,
        files: res.files,
        progress: {},
        saveDir: dir.path,
        senderName: device.name,
      );
      // Start pulling straight away. Both sides have already consented — the
      // sender chose these files and pressed Start, the receiver tapped this
      // specific phone — and an extra "now press Download" step is the thing
      // that makes a transfer app feel slow even when it isn't. Cancel is one
      // tap away for the whole batch.
      await downloadAll();
    } on PinRequired {
      if (!mounted) return;
      // Not an error state — a question. A red banner here would make a
      // working, deliberately-protected share look broken.
      state = state.copyWith(
          connecting: false, connected: false, pinNeededFor: device);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
          connecting: false, connected: false, error: _friendly(e));
    }
  }

  void dismissPinPrompt() => state = state.copyWith(clearPinPrompt: true);

  /// Re-read the sender's manifest without dropping anything already pulled.
  ///
  /// The sender can now add files to a live share, and indices are append-only
  /// precisely so this is safe: existing entries keep their index, so the
  /// progress map still lines up and finished files stay finished.
  Future<void> refreshManifest() async {
    final base = state.baseUrl;
    if (base == null || state.batchRunning) return;
    try {
      final fresh = await _svc.fetchManifest(base);
      if (!mounted || fresh.isEmpty) return;
      state = state.copyWith(files: fresh, clearError: true);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(error: _friendly(e));
    }
  }

  // ---- Turbo direct link ---------------------------------------------

  /// Join the sender's private radio link, then pull from it.
  ///
  /// Order matters and is not obvious: the UDP radar has to stop FIRST,
  /// because joining pins the whole process to a network with no internet and
  /// a socket bound to the old one just goes deaf. The invite already carries
  /// the token, so once the link is up this skips /pair entirely and goes
  /// straight to the manifest.
  Future<void> connectFromInvite(TurboInvite invite) async {
    state = state.copyWith(
        turboJoining: true,
        connecting: true,
        clearError: true,
        connected: false,
        files: []);
    await TransferDiscovery.instance.stopListening();
    final turbo = TurboLink.instance;
    try {
      final pre = await turbo.preconditions();
      if (!pre.supported) {
        _turboFailed('turbo_unsupported');
        return;
      }
      if (!pre.wifiOn) {
        _turboFailed('wifi_off');
        return;
      }
      if (!pre.locationOn) {
        _turboFailed('location_off');
        return;
      }
      if (!await turbo.ensurePermission()) {
        _turboFailed('permission_denied');
        return;
      }
      final res = await turbo.joinStart(invite.ssid, invite.passphrase);
      if (!res.ok) {
        // A refused or timed-out request leaves the NetworkCallback
        // registered. Left there it can fire onAvailable later and silently
        // pin the process to a link the user already gave up on.
        await turbo.joinStop();
        _turboFailed(res.reason);
        return;
      }
      if (!mounted) {
        await turbo.joinStop();
        return;
      }
      state = state.copyWith(
          turboJoining: false, turboJoined: true, turboMode: invite.mode);
      _armTurboIdleTimer();
      // DHCP on the group owner needs a beat after the link reports available;
      // connecting on the very first millisecond fails on plenty of devices.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final files = await _svc.fetchManifestWithRetry(invite.baseUrl);
      final dir = await _svc.receiveRootForDisplay();
      if (!mounted) return;
      state = state.copyWith(
        connecting: false,
        connected: true,
        baseUrl: invite.baseUrl,
        files: files,
        progress: {},
        saveDir: dir.path,
        senderName: invite.senderName,
      );
      await downloadAll();
    } catch (e) {
      // Joined the radio but couldn't talk over it — never leave the phone
      // pinned to a dead, internet-less network.
      await turbo.joinStop();
      if (!mounted) return;
      state = state.copyWith(
        turboJoining: false,
        turboJoined: false,
        turboMode: '',
        connecting: false,
        connected: false,
        error: _friendly(e),
      );
    }
  }

  void _turboFailed(String reason) {
    if (!mounted) return;
    state = state.copyWith(
      turboJoining: false,
      turboJoined: false,
      turboMode: '',
      connecting: false,
      connected: false,
      error: 'turbo:$reason',
    );
  }

  /// While Turbo is joined this phone has NO internet — every other feature in
  /// the app fails. The banner offers a Disconnect button, but people put the
  /// phone in their pocket and forget, and "my internet broke after I used
  /// that app" is the kind of bug that never gets reported, only uninstalled.
  /// So: if nothing is transferring for three minutes, let go by ourselves.
  void _armTurboIdleTimer() {
    _turboIdleTimer?.cancel();
    _turboIdleTimer = Timer(const Duration(minutes: 3), () {
      if (!mounted) return;
      if (!state.turboJoined || state.batchRunning) {
        // Still busy — check again rather than dropping a live transfer.
        if (state.turboJoined) _armTurboIdleTimer();
        return;
      }
      unawaited(leaveTurbo());
    });
  }

  /// Called when the Transfer screen is torn down. A transfer deliberately
  /// keeps running in the background, so this only releases the link when
  /// nothing is actually in flight.
  void releaseTurboIfIdle() {
    if (!state.turboJoined || state.batchRunning) return;
    unawaited(leaveTurbo());
  }

  /// Unpin from the sender's link and give the phone its normal network back.
  /// Called on cancel, on reset, and when the Transfer tab goes away — leaving
  /// this out would break every other network feature in the app until the
  /// next reboot.
  Future<void> leaveTurbo() async {
    _turboIdleTimer?.cancel();
    _turboIdleTimer = null;
    await TurboLink.instance.joinStop();
    if (!mounted) return;
    state = state.copyWith(turboJoined: false, turboMode: '');
  }

  static String _friendly(Object e) {
    final s = '$e';
    if (s.contains('TimeoutException')) {
      return 'The other phone did not answer. Make sure it is still sharing '
          'and both phones are on the same Wi-Fi or hotspot.';
    }
    return s.replaceFirst('Exception: ', '');
  }

  // ---- Resume-across-restart persistence -----------------------------
  // A batch download writes its plan (sender URL + file list + which files
  // are already done) to SharedPreferences, so if the app is swiped away or
  // killed mid-transfer, reopening it can pick up exactly where it stopped.
  // Partial files already sit on disk under their final names, and the
  // sender honours Range, so "resume" just re-runs downloadFile — it fetches
  // only the bytes not yet written.
  static const String _kResumeKey = 'transfer_resume_session_v1';

  // Writing the whole plan after every file turns a 500-file batch into 500
  // JSON encodes of a growing list — O(n^2) work competing with the transfer.
  // Throttle to a few seconds; the worst case a crash costs is re-checking a
  // handful of files whose bytes are already on disk anyway.
  DateTime _lastResumeSave = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _saveResumeSession({bool force = false}) async {
    if (!force) {
      final now = DateTime.now();
      if (now.difference(_lastResumeSave).inMilliseconds < 3000) return;
      _lastResumeSave = now;
    } else {
      _lastResumeSave = DateTime.now();
    }
    try {
      final base = state.baseUrl;
      if (base == null || state.files.isEmpty) return;
      final doneIdx = <int>[
        for (final f in state.files)
          if (state.progress[f.index]?.done ?? false) f.index,
      ];
      // Nothing left to resume → clear instead of saving.
      if (doneIdx.length == state.files.length) {
        await _clearResumeSession();
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kResumeKey,
        jsonEncode({
          'base': base,
          'saveDir': state.saveDir,
          'sender': state.senderName,
          'files': [for (final f in state.files) f.toJson()],
          'done': doneIdx,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {
      // Persistence is best-effort — a transfer never fails because we
      // couldn't write the resume record.
    }
  }

  Future<void> _clearResumeSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kResumeKey);
    } catch (_) {}
  }

  /// Load a saved session (if any) and surface it as a "resume available"
  /// state, without auto-downloading — the user taps Resume. Sessions older
  /// than a day, or whose sender is unreachable, are discarded.
  Future<void> _loadResumeSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kResumeKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final ts = (j['ts'] as num?)?.toInt() ?? 0;
      // Stale after 24h — a sender that old is almost certainly gone.
      if (DateTime.now().millisecondsSinceEpoch - ts > 86400000) {
        await _clearResumeSession();
        return;
      }
      final base = j['base'] as String?;
      final fileList = (j['files'] as List?) ?? const [];
      if (base == null || fileList.isEmpty) return;
      final files = fileList
          .map((e) => RemoteFile.fromJson(e as Map<String, dynamic>))
          .toList();
      final done = ((j['done'] as List?) ?? const [])
          .map((e) => (e as num).toInt())
          .toSet();
      final progress = <int, ReceiveProgress>{
        for (final f in files)
          if (done.contains(f.index))
            f.index: ReceiveProgress(
                received: f.size, total: f.size, done: true),
      };
      if (!mounted) return;
      state = state.copyWith(
        baseUrl: base,
        files: files,
        progress: progress,
        saveDir: j['saveDir'] as String?,
        senderName: j['sender'] as String?,
        resumeAvailable: true,
      );
    } catch (_) {
      await _clearResumeSession();
    }
  }

  /// Reconnect to the saved sender and continue the unfinished downloads.
  /// If the sender is gone, surface a clear message but keep the partial
  /// files so a later attempt still resumes.
  Future<void> resumeSaved() async {
    final base = state.baseUrl;
    if (base == null) return;
    state = state.copyWith(connecting: true, clearError: true);
    try {
      // Re-fetch the manifest to confirm the sender is still up and the file
      // set still matches; if it fails, the sender has stopped sharing.
      final fresh = await _svc.fetchManifest(base);
      if (!mounted) return;
      state = state.copyWith(
        connecting: false,
        connected: true,
        files: fresh.isNotEmpty ? fresh : state.files,
        resumeAvailable: false,
      );
      await downloadAll();
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        connecting: false,
        error: 'Could not reach the sender to resume. Make sure the other '
            'phone is still sharing on the same Wi-Fi, then try again.',
      );
    }
  }

  /// Discard a saved session the user doesn't want to resume.
  Future<void> dismissResume() async {
    await _clearResumeSession();
    if (mounted) {
      state = state.copyWith(resumeAvailable: false);
    }
  }

  // True while a batch download holds the foreground service, so the
  // per-file progress callback knows to push notification updates.
  bool _fgActive = false;
  // Android throttles apps that update a notification many times a second —
  // and at 20+ MB/s the progress callback fires several times a second.
  // Rate-limit the notification to once a second; the in-app progress bar
  // still updates live.
  DateTime _lastNotif = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> connect(String rawUrl) async {
    final base = FileReceiverService.normalizeBase(rawUrl);
    if (base.isEmpty) {
      state = state.copyWith(error: 'Enter the sender address first.');
      return;
    }
    state = state.copyWith(
        connecting: true, clearError: true, connected: false, files: []);
    try {
      final files = await _svc.fetchManifest(base);
      final dir = await _svc.receiveRootForDisplay();
      if (!mounted) return;
      state = state.copyWith(
        connecting: false,
        connected: true,
        baseUrl: base,
        files: files,
        progress: {},
        saveDir: dir.path,
      );
      await downloadAll();
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
          connecting: false, connected: false, error: _friendly(e));
    }
  }

  Future<void> downloadOne(RemoteFile f) async {
    final base = state.baseUrl;
    if (base == null) return;
    // The engine runs one job at a time. A per-file tap during a batch would
    // hit that limit and surface "a job is already running" on the row, which
    // says nothing useful to anyone — the row is simply not tappable yet.
    // (_fgActive is set only by downloadAll, so the batch's own calls pass.)
    if (state.batchRunning && !_fgActive) return;
    // A previous cancel leaves the shared service flagged. Without this, the
    // next single-file tap silently lost the parallel fast path (and its
    // retries) because every guard reads the stale flag.
    _svc.resetCancel();
    _setProgress(f.index, ReceiveProgress(total: f.size), force: true);
    try {
      final path =
          await _svc.downloadFile(base, f, (rec, total, speed, paused) {
        _setProgress(
            f.index,
            ReceiveProgress(
                received: rec,
                total: total,
                bytesPerSec: paused ? 0 : speed,
                pausedBySender: paused),
            // A pause must land on screen immediately. It is not a stall, and
            // the whole point is that the user stops wondering whether the
            // transfer died.
            force: paused);
        // Mirror this file's progress into the notification (already
        // throttled by the engine's ~120 ms onProgress gate).
        if (_fgActive) {
          final now = DateTime.now();
          if (now.difference(_lastNotif).inMilliseconds < 1000) return;
          _lastNotif = now;
          final pct = total > 0 ? ((rec / total) * 100).round() : -1;
          final rate = speed > 0 && !paused ? ' • ${_fmtSpeed(speed)}' : '';
          TransferForegroundService.update(
            title: paused ? 'Paused by sender' : 'Receiving files',
            text: pct >= 0 ? '${f.name} • $pct%$rate' : f.name,
            progress: pct,
          );
        }
      }, scanNow: !_fgActive);
      _setProgress(
          f.index,
          ReceiveProgress(
              received: f.size, total: f.size, done: true, savedPath: path),
          force: true);
      // A single-file tap isn't part of a batch, so nothing else would ever
      // log it — or close the sockets the pool just opened.
      if (!_fgActive) {
        _recordHistory();
        await _svc.flushMediaScans();
        _svc.endBatch();
      }
    } catch (e) {
      _setProgress(f.index,
          ReceiveProgress(error: _friendly(e), total: f.size),
          force: true);
    }
  }

  Future<void> downloadAll() async {
    // A connect now auto-starts the batch, so this can be reached twice at
    // once (auto-start plus an impatient tap on Download all). Two loops over
    // the same files would fight for the same ".part" handles.
    if (state.batchRunning) return;
    if (mounted) state = state.copyWith(userPaused: false);
    final pending = state.files
        .where((f) => !(state.progress[f.index]?.done ?? false))
        .toList();
    if (pending.isEmpty) return;

    // Work out what is genuinely missing BEFORE the space check. Re-sharing a
    // folder to a phone that already has most of it is the common case, and
    // counting bytes that will never be written would refuse a batch that
    // actually fits.
    final alreadyHere = <int, String>{};
    var needed = 0;
    for (final f in pending) {
      final existing = await _svc.existingCompleteFile(f);
      if (existing != null) {
        alreadyHere[f.index] = existing;
      } else {
        needed += f.size;
      }
    }
    if (needed > 0) {
      final free = await _svc.freeSpaceBytes();
      if (free >= 0 && free < needed + (64 * 1024 * 1024)) {
        if (!mounted) return;
        state = state.copyWith(
          error: 'Not enough space: ${_fmtSize(needed)} needed, '
              '${_fmtSize(free)} free. Free some space and try again.',
        );
        return;
      }
    }

    // Fresh batch → clear any leftover cancel flag from a previous run.
    _svc.resetCancel();
    // Persist the plan so a swipe-away / kill can be resumed on relaunch.
    await _saveResumeSession(force: true);
    // Keep the download alive across backgrounding + show a notification.
    _fgActive = true;
    if (mounted) state = state.copyWith(batchRunning: true, clearError: true);
    final n = state.files.length;
    await TransferForegroundService.start(
      title: 'Receiving file${n == 1 ? '' : 's'}',
      text: 'Starting\u2026',
    );
    try {
      for (final f in state.files) {
        // Stop the whole batch if the user cancelled mid-way.
        if (_svc.isCancelled) break;
        final pr = state.progress[f.index];
        if (pr != null && pr.done) continue;
        // Already on disk, byte-for-byte (decided in the pass above, so the
        // filesystem is not stat'ed twice per file).
        final existing = alreadyHere[f.index];
        if (existing != null) {
          _setProgress(
              f.index,
              ReceiveProgress(
                  received: f.size,
                  total: f.size,
                  done: true,
                  savedPath: existing,
                  skipped: true),
              force: true);
          continue;
        }
        await downloadOne(f);
        // Record progress as we go (throttled) so a crash loses at most the
        // partially-downloaded current file, which itself resumes by byte.
        await _saveResumeSession();
      }
    } finally {
      _fgActive = false;
      // One MediaScanner call for the whole batch instead of one per file.
      await _svc.flushMediaScans();
      _recordHistory();
      // Release the pooled sockets now the batch is done.
      _svc.endBatch();
      await TransferForegroundService.stop();
      if (mounted) state = state.copyWith(batchRunning: false);
      // If everything finished, drop the resume record; otherwise persist
      // exactly where we stopped.
      final allDone = state.files
          .every((f) => state.progress[f.index]?.done ?? false);
      if (allDone) {
        await _clearResumeSession();
      } else {
        await _saveResumeSession(force: true);
      }
      // The ongoing notification disappears with the service, so a user who
      // backgrounded the app during a 2 GB transfer would get no signal at all
      // that it finished. Post a dismissible one instead.
      final got = state.files
          .where((f) => (state.progress[f.index]?.done ?? false))
          .length;
      if (state.turboJoined) _armTurboIdleTimer();
      if (got > 0 && !_svc.isCancelled) {
        await TransferForegroundService.notifyDone(
          title: allDone ? 'Transfer complete' : 'Transfer stopped',
          text: '$got file${got == 1 ? '' : 's'} saved to Innocent',
        );
      }
    }
  }

  /// Write whatever finished into the received-files list. Called once per
  /// batch, not once per file: this is a pointer list, and a transfer that was
  /// cancelled half way still deserves an entry for the files that did land.
  void _recordHistory() {
    final items = <ReceivedItem>[];
    final now = DateTime.now();
    for (final f in state.files) {
      final pr = state.progress[f.index];
      final path = pr?.savedPath;
      if (pr == null || !pr.done || path == null || path.isEmpty) continue;
      // A file that was already here wasn't "received" — logging it would fill
      // the list with things the user never got.
      if (pr.skipped) continue;
      items.add(ReceivedItem(
        name: f.name,
        path: path,
        sizeBytes: f.size,
        senderName: state.senderName,
        receivedAt: now,
      ));
    }
    if (items.isEmpty) return;
    try {
      unawaited(_ref.read(receivedHistoryProvider.notifier).addAll(items));
    } catch (e) {
      if (kDebugMode) debugPrint('ReceiverNotifier.recordHistory: $e');
    }
  }

  /// Hold this side. Everything in flight stops at once, but the ".part"
  /// files stay exactly where they are, so Resume continues by byte rather
  /// than starting over — the difference between a pause and a cancel is
  /// entirely in what happens next, not in what is thrown away.
  Future<void> pauseBatch() async {
    if (!state.batchRunning) return;
    _svc.cancel();
    if (!mounted) return;
    state = state.copyWith(userPaused: true, batchRunning: false);
    await _saveResumeSession(force: true);
    await TransferForegroundService.stop();
  }

  /// Continue a batch this side paused.
  Future<void> resumeBatch() async {
    if (!state.userPaused) return;
    // Drop the per-file error rows the pause left behind. They were an abort,
    // not a fault, and leaving them red would tell the user files failed at
    // the exact moment they are about to continue.
    final cleaned = <int, ReceiveProgress>{};
    state.progress.forEach((k, v) {
      if (v.done) cleaned[k] = v;
    });
    state = state.copyWith(userPaused: false, progress: cleaned);
    await downloadAll();
  }

  /// Stop everything in flight. The partial files stay on disk so the same
  /// batch can be resumed later — only the per-file X discards one.
  Future<void> cancelAll() async {
    _svc.cancel();
    _recordHistory();
    await TransferForegroundService.stop();
    if (!mounted) return;
    state = state.copyWith(batchRunning: false);
    await _saveResumeSession(force: true);
  }

  // Rebuilding the whole file list on every progress tick is real work: at
  // 10 ticks a second with 200 rows on screen it competes with the socket for
  // the same isolate. Coalesce to ~150 ms, but never delay a terminal state
  // (done / error), which the UI must show immediately.
  DateTime _lastStateWrite = DateTime.fromMillisecondsSinceEpoch(0);
  Map<int, ReceiveProgress>? _pendingProgress;

  void _setProgress(int index, ReceiveProgress pr, {bool force = false}) {
    if (!mounted) return;
    final next =
        Map<int, ReceiveProgress>.from(_pendingProgress ?? state.progress);
    next[index] = pr;
    _pendingProgress = next;
    final now = DateTime.now();
    if (!force && now.difference(_lastStateWrite).inMilliseconds < 150) {
      return;
    }
    _lastStateWrite = now;
    _pendingProgress = null;
    final paused = next.values.any((v) => v.pausedBySender && !v.done);
    state = state.copyWith(progress: next, senderPaused: paused);
  }

  /// Format a bytes/second rate as a compact human string (e.g. "23.4 MB/s").
  static String _fmtSpeed(double bytesPerSec) {
    if (bytesPerSec >= 1024 * 1024) {
      return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSec >= 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${bytesPerSec.toStringAsFixed(0)} B/s';
  }

  static String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  void reset() {
    _svc.cancel();
    _svc.resetCancel();
    // Fire-and-forget on purpose: reset() is called from build-time callbacks
    // that can't await, and joinStop is idempotent.
    if (state.turboJoined) unawaited(TurboLink.instance.joinStop());
    state = const ReceiverState();
  }

  @override
  void dispose() {
    _turboIdleTimer?.cancel();
    _nearbySub?.cancel();
    _svc.cancel();
    // The pin is process-wide. If this notifier goes away while still joined,
    // nothing else would ever release it.
    unawaited(TurboLink.instance.joinStop());
    super.dispose();
  }
}

final receiverProvider =
    StateNotifierProvider<ReceiverNotifier, ReceiverState>((ref) {
  final svc = ref.watch(fileReceiverServiceProvider);
  return ReceiverNotifier(svc, ref);
});
