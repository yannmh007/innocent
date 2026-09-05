import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'file_receiver_service.dart';
import 'transfer_discovery.dart';
import 'transfer_foreground_service.dart';
import 'turbo_link_service.dart';

/// One file added to the share. Server keeps a list of these and
/// serves each at `/<token>/<idx>`.
class SharedFile {
  final String id;
  final String path;
  final String displayName;
  final int sizeBytes;

  /// Position inside a sent folder, e.g. `Holiday/2024/beach.jpg`. Empty for a
  /// loose file.
  ///
  /// Without this the receiver has no way to rebuild a folder: it sorts by
  /// file type, so a hundred-photo album arrives as a hundred photos dumped
  /// into Photos/ with their structure gone and their names colliding.
  final String relPath;

  const SharedFile({
    required this.id,
    required this.path,
    required this.displayName,
    required this.sizeBytes,
    this.relPath = '',
  });
}

/// Failed PIN attempts from one address.
class _PinAttempts {
  int fails = 0;
  DateTime? lockedUntil;
}

/// Length-independent comparison for the share PIN.
///
/// A plain `!=` returns as soon as two characters differ, so the time taken
/// leaks how many leading digits were right - which turns 10 000 guesses into
/// about 40. The cost of closing it is a few microseconds on a four-digit
/// string.
bool _pinEquals(String a, String b) {
  final x = a.codeUnits;
  final y = b.codeUnits;
  var diff = x.length ^ y.length;
  final n = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

/// A receiving device that has paired with this share.
///
/// The sender used to be blind — it could show "412 MB downloaded" and nothing
/// about who was downloading or how far along they were. Every fast-share app
/// shows the other phone by name, so we record each peer as it pairs.
class TransferPeer {
  final String id;
  final String name;
  final String ip;
  final DateTime connectedAt;
  const TransferPeer({
    required this.id,
    required this.name,
    required this.ip,
    required this.connectedAt,
  });
}

/// A device asking for permission to receive, when approval mode is on.
class PairRequest {
  final String deviceId;
  final String deviceName;
  final String ip;
  final Completer<bool> decision;
  PairRequest({
    required this.deviceId,
    required this.deviceName,
    required this.ip,
    required this.decision,
  });
}

class TransferState {
  final bool isRunning;
  final List<SharedFile> files;
  final String? ipAddress;
  final int? port;
  final int bytesServed;
  final String? error;
  /// Bytes served per file index — lets the sender show real per-file progress
  /// instead of one indeterminate total.
  final Map<int, int> servedPerFile;
  /// Receivers that have paired with this share.
  final List<TransferPeer> peers;
  /// Bytes delivered to each receiver, keyed by its IP.
  final Map<String, int> servedPerPeer;
  /// When true, a device must be approved by the sender before it gets the
  /// token. Off by default: one tap on the receiver is the fast path, and this
  /// is the same exposure model Zapya/SHAREit use.
  final bool requireApproval;
  /// Set while a device is waiting on the sender to tap Accept.
  final PairRequest? pending;
  /// This phone's name as other devices see it.
  final String? deviceName;
  /// Start was pressed and we are still bringing things up. Turbo's radio
  /// handshake can take most of half a minute on a slow device, and without
  /// this the screen sat there looking frozen with no way to tell whether the
  /// tap had registered.
  final bool starting;
  /// Sharing is live but held: receivers are told to come back shortly.
  final bool paused;
  /// Four digits a receiver must quote at /pair. Empty = no gate.
  final String pin;
  /// User asked for the direct radio link. Requested != active: the radio can
  /// refuse, and the share still has to work when it does.
  final bool turboRequested;
  final bool turboActive;
  /// 'p2p' (Wi-Fi Direct group) or 'lohs' (local-only hotspot).
  final String turboMode;
  /// Measured band of the live link: '5', '2.4' or '' when unknown.
  final String turboBand;
  /// This phone was on Wi-Fi when the link came up, which is what forces the
  /// band down on most chips. Used to explain a 2.4 GHz result honestly.
  final bool turboStaWasConnected;
  final String? turboSsid;
  final String? turboPass;
  /// Set when Turbo was asked for and could not start. Not an error — the
  /// share is live over ordinary Wi-Fi — but the user deserves the reason.
  final String? turboNotice;

  const TransferState({
    this.isRunning = false,
    this.files = const [],
    this.ipAddress,
    this.port,
    this.bytesServed = 0,
    this.error,
    this.servedPerFile = const {},
    this.peers = const [],
    this.servedPerPeer = const {},
    this.requireApproval = false,
    this.pending,
    this.deviceName,
    this.starting = false,
    this.paused = false,
    this.pin = '',
    this.turboRequested = false,
    this.turboActive = false,
    this.turboMode = '',
    this.turboBand = '',
    this.turboStaWasConnected = false,
    this.turboSsid,
    this.turboPass,
    this.turboNotice,
  });

  String get baseUrl => (ipAddress != null && port != null)
      ? 'http://$ipAddress:$port/'
      : '';

  /// Total bytes of every file in the share (for the header summary).
  int get totalBytes {
    var t = 0;
    for (final f in files) {
      t += f.sizeBytes;
    }
    return t;
  }

  TransferState copyWith({
    bool? isRunning,
    List<SharedFile>? files,
    String? ipAddress,
    int? port,
    int? bytesServed,
    String? error,
    Map<int, int>? servedPerFile,
    List<TransferPeer>? peers,
    Map<String, int>? servedPerPeer,
    bool? requireApproval,
    PairRequest? pending,
    String? deviceName,
    bool? starting,
    bool? paused,
    String? pin,
    bool? turboRequested,
    bool? turboActive,
    String? turboMode,
    String? turboBand,
    bool? turboStaWasConnected,
    String? turboSsid,
    String? turboPass,
    String? turboNotice,
    bool clearError = false,
    bool clearAddress = false,
    bool clearPending = false,
    bool clearTurbo = false,
    bool clearTurboNotice = false,
  }) {
    return TransferState(
      isRunning: isRunning ?? this.isRunning,
      files: files ?? this.files,
      ipAddress: clearAddress ? null : (ipAddress ?? this.ipAddress),
      port: clearAddress ? null : (port ?? this.port),
      bytesServed: bytesServed ?? this.bytesServed,
      error: clearError ? null : (error ?? this.error),
      servedPerFile: servedPerFile ?? this.servedPerFile,
      peers: peers ?? this.peers,
      servedPerPeer: servedPerPeer ?? this.servedPerPeer,
      requireApproval: requireApproval ?? this.requireApproval,
      pending: clearPending ? null : (pending ?? this.pending),
      deviceName: deviceName ?? this.deviceName,
      starting: starting ?? this.starting,
      paused: paused ?? this.paused,
      pin: pin ?? this.pin,
      turboRequested: turboRequested ?? this.turboRequested,
      turboActive: clearTurbo ? false : (turboActive ?? this.turboActive),
      turboMode: clearTurbo ? '' : (turboMode ?? this.turboMode),
      turboBand: clearTurbo ? '' : (turboBand ?? this.turboBand),
      turboStaWasConnected: clearTurbo
          ? false
          : (turboStaWasConnected ?? this.turboStaWasConnected),
      turboSsid: clearTurbo ? null : (turboSsid ?? this.turboSsid),
      turboPass: clearTurbo ? null : (turboPass ?? this.turboPass),
      turboNotice: clearTurboNotice ? null : (turboNotice ?? this.turboNotice),
    );
  }
}

/// Audit fix (Transfer tab real impl): same-Wi-Fi-network file sharing
/// built on a tiny `shelf` HTTP server. Not Wi-Fi-Direct — the simpler
/// "both phones on the same Wi-Fi" model, with UDP discovery on top so the
/// other phone appears by name instead of needing a typed address.
class FileTransferService {
  HttpServer? _server;
  final List<SharedFile> _files = [];
  String _token = '';
  int _bytesServed = 0;
  /// Bytes actually pushed out per file index, for the furthest-along
  /// receiver. Parallel range requests and retries can re-send bytes, so this
  /// is clamped to the file size — a progress indicator, not a ledger.
  final Map<int, int> _servedPerIndex = {};

  /// Per-receiver accounting, keyed by remote IP.
  ///
  /// A group send is already supported by the HTTP server — it serves any
  /// number of clients at once — but until now the sender lumped every peer's
  /// bytes into one total, so with two phones pulling, the numbers made no
  /// sense to anyone. Keeping them apart is what makes sending to a room of
  /// people legible.
  final Map<String, Map<int, int>> _servedPerPeer = {};

  final List<TransferPeer> _peers = [];
  bool requireApproval = false;

  /// Sender-side pause.
  ///
  /// The data plane is a pull, so "pause" cannot mean "stop sending" — it has
  /// to mean "tell the puller to come back later". While paused, file requests
  /// answer 503 with a Retry-After, and any stream already in flight stops at
  /// its next block boundary. The receiver treats 503 as a wait rather than an
  /// error, so no attempt budget is spent and every partial file survives.
  /// /ping, /pair and /manifest keep working, so the other phone can still
  /// tell we are alive and see WHY nothing is moving.
  bool paused = false;

  /// PIN gate for /pair. Empty means off.
  ///
  /// The realistic threat on a shared Wi-Fi is not someone cracking a 36-char
  /// token — it is a stranger seeing this phone in their radar and tapping it.
  /// Four digits shown on the sender's screen closes that, and costs one
  /// glance across the table.
  String pin = '';

  /// Raised when a device asks to pair and approval is required.
  final StreamController<PairRequest> _pairCtrl =
      StreamController<PairRequest>.broadcast();
  Stream<PairRequest> get pairRequests => _pairCtrl.stream;

  String get token => _token;
  int get bytesServed => _bytesServed;
  Map<int, int> get servedPerIndex => Map.unmodifiable(_servedPerIndex);
  Map<String, int> get servedPerPeerTotal => {
        for (final e in _servedPerPeer.entries)
          e.key: e.value.values.fold<int>(0, (a, b) => a + b),
      };
  List<TransferPeer> get peers => List.unmodifiable(_peers);
  bool get isRunning => _server != null;
  List<SharedFile> get files => List.unmodifiable(_files);

  /// Add files to a share that is ALREADY RUNNING.
  ///
  /// This was a real bug: `addFiles` updated the notifier's list but the
  /// server's own `_files` was only ever filled in `start()`. Picking more
  /// photos mid-share showed them on the sender's screen and served a stale
  /// manifest — the other phone could never see them and nothing said why.
  /// Indices are append-only on purpose: a receiver already holds indices for
  /// the files it is pulling, so reordering or renumbering would make it fetch
  /// the wrong ones.
  int appendFiles(List<SharedFile> extra) {
    if (_server == null || extra.isEmpty) return 0;
    final have = _files.map((f) => f.path).toSet();
    var added = 0;
    for (final f in extra) {
      if (have.contains(f.path)) continue;
      _files.add(f);
      added++;
    }
    return added;
  }

  /// Where a browser upload lands. Set by the notifier at start.
  Directory? uploadDir;
  /// Files pushed to us from a browser this session.
  final List<String> _uploaded = [];
  List<String> get uploaded => List.unmodifiable(_uploaded);

  // ─── PIN BRUTE-FORCE DEFENCE ───────────────────────────────────────────
  //
  // WHY: CVE-2018-19429 is exactly this failure in Xender - a PIN whose length
  // the UI limits but whose guessing nothing limits, letting an in-network
  // attacker enumerate it and join the transfer. A four-digit PIN is ten
  // thousand possibilities; over a LAN, unthrottled, that is seconds.
  //
  // Per SOURCE IP, not global: one clumsy neighbour must not be able to lock
  // the real receiver out by failing five times, which is a denial of service
  // dressed up as a security control.
  //
  // Cleared when sharing stops, so the map cannot grow across sessions.
  final Map<String, _PinAttempts> _pinAttempts = <String, _PinAttempts>{};

  static const int _kPinMaxFails = 5;
  static const int _kPinLockSeconds = 30;

  /// null when [ip] may try, or the seconds it must wait.
  int? _pinLockRemaining(String ip) {
    final a = _pinAttempts[ip];
    if (a == null || a.lockedUntil == null) return null;
    final left = a.lockedUntil!.difference(DateTime.now()).inSeconds;
    if (left <= 0) {
      // Lock expired: reset the count too, so a legitimate user who mistyped
      // is not one failure away from being locked out again an hour later.
      _pinAttempts.remove(ip);
      return null;
    }
    return left;
  }

  void _recordPinFailure(String ip) {
    final a = _pinAttempts.putIfAbsent(ip, () => _PinAttempts());
    a.fails++;
    if (a.fails >= _kPinMaxFails) {
      // Doubling each time: 30 s, 60 s, 120 s… A patient attacker is not
      // stopped by any fixed delay, only by one that grows.
      final multiplier = 1 << (a.fails - _kPinMaxFails).clamp(0, 6);
      a.lockedUntil = DateTime.now()
          .add(Duration(seconds: _kPinLockSeconds * multiplier));
    }
  }

  String _randomToken(int length) {
    const charset =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random.secure();
    return List.generate(
        length, (_) => charset[rnd.nextInt(charset.length)]).join();
  }

  List<Map<String, dynamic>> _manifestList() {
    final list = <Map<String, dynamic>>[];
    for (int i = 0; i < _files.length; i++) {
      list.add({
        'index': i,
        'name': _files[i].displayName,
        'size': _files[i].sizeBytes,
        if (_files[i].relPath.isNotEmpty) 'rel': _files[i].relPath,
      });
    }
    return list;
  }

  Router _router() {
    final r = Router();

    // Liveness probe. Cheap enough for a receiver to call before resuming a
    // saved session, so "sender has gone away" is reported in milliseconds
    // instead of after a manifest timeout.
    r.get('/ping', (Request req) {
      return Response.ok(
        jsonEncode({'app': 'innocent', 'ok': true}),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    // Pairing. Deliberately OUTSIDE the token path: a device found over UDP
    // discovery does not have the token yet — that is the whole point of the
    // handshake. It asks here, we decide, and only then does it learn the
    // token. The manifest rides along so the receiver needs one round trip,
    // not two.
    r.get('/pair', (Request req) async {
      final q = req.url.queryParameters;
      final devId = (q['id'] ?? '').trim();
      final devName = (q['name'] ?? '').trim();
      final ip = _remoteIp(req);

      // Checked BEFORE the PIN, so a locked-out address cannot keep guessing
      // and cannot learn anything from how long the answer takes.
      final lockLeft = _pinLockRemaining(ip);
      if (pin.isNotEmpty && lockLeft != null) {
        return Response(429,
            body: jsonEncode({'error': 'locked', 'retry_after': lockLeft}),
            headers: {
              'content-type': 'application/json; charset=utf-8',
              'retry-after': '$lockLeft',
            });
      }

      if (pin.isNotEmpty && !_pinEquals((q['pin'] ?? '').trim(), pin)) {
        _recordPinFailure(ip);
        // 401 and nothing else. Saying "wrong PIN" versus "no PIN" would let
        // someone probe whether a PIN is even set.
        return Response(401,
            body: jsonEncode({'error': 'pin'}),
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      // Correct PIN wipes the history: the person fumbling their own PIN is
      // the common case, and they should not carry a penalty afterwards.
      if (pin.isNotEmpty) _pinAttempts.remove(ip);
      if (requireApproval) {
        final decision = Completer<bool>();
        final pr = PairRequest(
          deviceId: devId.isEmpty ? ip : devId,
          deviceName: devName.isEmpty ? 'Unknown device' : devName,
          ip: ip,
          decision: decision,
        );
        _pairCtrl.add(pr);
        bool ok;
        try {
          // The receiver holds the request open while the sender decides.
          // A 45 s cap so an ignored prompt fails cleanly instead of leaving
          // the other phone spinning forever.
          ok = await decision.future.timeout(
            const Duration(seconds: 45),
            onTimeout: () => false,
          );
        } catch (_) {
          ok = false;
        }
        if (!ok) {
          return Response.forbidden(
            jsonEncode({'error': 'declined'}),
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
      }
      _recordPeer(devId.isEmpty ? ip : devId,
          devName.isEmpty ? 'Unknown device' : devName, ip);
      return Response.ok(
        jsonEncode({
          'token': _token,
          'files': _manifestList(),
        }),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    r.get('/$_token', (Request req) {
      return Response.ok(_indexHtml(),
          headers: {'content-type': 'text/html; charset=utf-8'});
    });

    // Browser -> phone upload.
    //
    // This is the cross-platform half Zapya has and we did not: an iPhone, a
    // Windows laptop, anything with a browser can now SEND to this phone
    // without installing anything. The page posts raw bytes with the name in
    // the query string rather than a multipart form, which means no multipart
    // parser and therefore no new package — `mime` is only a transitive
    // dependency here and pinning it directly has broken this project's
    // dependency solve before.
    r.post('/$_token/up', (Request req) async {
      final raw = (req.url.queryParameters['name'] ?? '').trim();
      if (raw.isEmpty) return Response(400, body: 'name required');
      final dir = uploadDir;
      if (dir == null) {
        return Response(503, body: 'Uploads are not ready yet');
      }
      // The name comes from a remote browser, so it is untrusted: strip every
      // separator and control character before it touches a path.
      var safe = raw.replaceAll(RegExp(r'[/\\\x00-\x1f"]'), '_');
      // Stripping separators is not enough on its own. A name of exactly "."
      // or ".." survives it untouched and then resolves to the folder itself
      // or its PARENT — the one input in a 30 000-case fuzz that still walked
      // out of the storage root.
      if (safe == '.' || safe == '..' || safe.trim().isEmpty) {
        safe = 'upload-${DateTime.now().millisecondsSinceEpoch}';
      }
      var target = File(p.join(dir.path, safe));
      if (await target.exists()) {
        final base = p.basenameWithoutExtension(safe);
        final ext = p.extension(safe);
        target = File(p.join(
            dir.path, '$base-${DateTime.now().millisecondsSinceEpoch}$ext'));
      }
      IOSink? sink;
      try {
        sink = target.openWrite();
        // addStream, not a manual loop: back-pressure keeps a fast uploader
        // from filling RAM faster than the flash can drain it.
        await sink.addStream(req.read());
        await sink.flush();
        await sink.close();
        sink = null;
        _uploaded.add(target.path);
        unawaited(FileReceiverService().mediaScan([target.path]));
        return Response.ok(
          jsonEncode({'ok': true, 'name': p.basename(target.path)}),
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      } catch (e) {
        try {
          await sink?.close();
        } catch (_) {}
        try {
          if (await target.exists()) await target.delete();
        } catch (_) {}
        return Response.internalServerError(body: 'upload failed: $e');
      }
    });
    // Machine-readable manifest for Innocent's in-app receiver (so a
    // second phone can list + pull files inside the app instead of via
    // a browser). Digit-only file route below can't collide with this.
    r.get('/$_token/manifest', (Request req) {
      return Response.ok(
        jsonEncode({'files': _manifestList()}),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    r.get('/$_token/<idx|[0-9]+>', (Request req, String idx) async {
      final peerIp = _remoteIp(req);
      final i = int.tryParse(idx);
      if (i == null || i < 0 || i >= _files.length) {
        return Response.notFound('File not found');
      }
      if (paused) {
        // Not an error — a wait. The receiver backs off and retries without
        // spending an attempt, so a five-minute pause costs nothing but time.
        return Response(503, body: 'Paused by sender', headers: {
          'retry-after': '2',
          'content-type': 'text/plain; charset=utf-8',
        });
      }
      final f = _files[i];
      final file = File(f.path);
      if (!await file.exists()) {
        return Response.notFound('File no longer on disk');
      }
      final totalSize = await file.length();
      // Audit fix (Transfer reliability): parse HTTP Range header so
      // the browser can resume a failed download instead of restarting
      // from 0. Without this, a Wi-Fi drop on a 2 GB video means the
      // receiver re-downloads from the start.
      final rangeHeader = req.headers['range'];
      int rangeStart = 0;
      int rangeEnd = totalSize - 1;
      bool isPartial = false;
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final spec = rangeHeader.substring(6).trim();
        if (!spec.contains(',')) {
          final parts = spec.split('-');
          if (parts.length == 2) {
            final rawStart = parts[0].trim();
            final rawEnd = parts[1].trim();
            if (rawStart.isEmpty && rawEnd.isNotEmpty) {
              // Suffix range ("bytes=-500" = the LAST 500 bytes). The old code
              // parsed '' as null and silently fell through to serving the
              // whole file with a 200 — a client asking for a tail got the
              // entire video instead. Media players and download managers do
              // use this form.
              final n = int.tryParse(rawEnd);
              if (n != null && n > 0) {
                rangeStart = n >= totalSize ? 0 : totalSize - n;
                rangeEnd = totalSize - 1;
                isPartial = true;
              }
            } else {
              final s = int.tryParse(rawStart);
              final e = rawEnd.isEmpty ? null : int.tryParse(rawEnd);
              if (s != null && s >= 0 && s < totalSize) {
                rangeStart = s;
                if (e != null && e >= s && e < totalSize) {
                  rangeEnd = e;
                }
                isPartial = true;
              } else if (s != null && s >= totalSize) {
                return Response(416, headers: {
                  'content-range': 'bytes */$totalSize',
                });
              }
            }
          }
        }
      }
      // openRead takes [start, end) — exclusive end. Our rangeEnd is
      // inclusive last byte, so add 1.
      // Throughput: stream the range in large (512 KB) blocks via a raw
      // RandomAccessFile instead of File.openRead(), whose default 64 KB
      // blocks generate ~8x more stream events + native round-trips. Fewer,
      // bigger reads let a fast 5 GHz Wi-Fi link run much closer to its
      // ceiling (the 20-30 MB/s range) instead of being capped by per-chunk
      // overhead flowing through shelf -> socket.
      final stream = _streamFileRange(file, rangeStart, rangeEnd, i, peerIp);
      final contentLength = (rangeEnd - rangeStart + 1).toString();
      return Response(
        isPartial ? 206 : 200,
        body: stream,
        headers: {
          'content-type': _mimeForExt(p.extension(f.displayName)),
          'content-length': contentLength,
          'accept-ranges': 'bytes',
          if (isPartial)
            'content-range': 'bytes $rangeStart-$rangeEnd/$totalSize',
          'content-disposition':
              "attachment; filename*=UTF-8''${Uri.encodeComponent(f.displayName)}",
          'cache-control': 'no-store',
        },
      );
    });
    return r;
  }

  static String _remoteIp(Request req) {
    try {
      final info = req.context['shelf.io.connection_info'];
      if (info is HttpConnectionInfo) return info.remoteAddress.address;
    } catch (_) {}
    return 'unknown';
  }

  void _recordPeer(String id, String name, String ip) {
    _peers.removeWhere((p) => p.id == id);
    _peers.add(TransferPeer(
      id: id,
      name: name,
      ip: ip,
      connectedAt: DateTime.now(),
    ));
  }

  String _indexHtml() {
    final rows = StringBuffer();
    for (int i = 0; i < _files.length; i++) {
      final f = _files[i];
      final sizeStr = _formatSize(f.sizeBytes);
      // Show the folder path when there is one, so a folder share reads as a
      // tree rather than a flat pile of names.
      final label = f.relPath.isEmpty
          ? _escapeHtml(f.displayName)
          : _escapeHtml(f.relPath);
      rows.writeln('<li>'
          '<a href="/$_token/$i" download="${_escapeHtml(f.displayName)}">'
          '$label'
          '</a> '
          '<span class="sz">($sizeStr)</span>'
          '</li>');
    }
    final empty = _files.isEmpty
        ? '<p class="sub">The sender has not shared any files yet.</p>'
        : '';
    // The upload half is what makes this page useful to an iPhone or a laptop
    // that will never install Innocent: it can send TO the phone, not only
    // pull from it. Raw bytes with the name in the query string, so the Dart
    // side needs no multipart parser and therefore no new package — `mime` is
    // only a transitive dependency here and pinning it directly has broken
    // this project's dependency solve before.
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Innocent Transfer</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif;
         background:#1a1a1a; color:#eee; margin:0 auto; padding:24px;
         max-width:640px; line-height:1.5; }
  h1 { font-size:20px; margin-bottom:6px; }
  h2 { font-size:15px; margin:28px 0 8px; color:#bbb;
       border-top:1px solid #333; padding-top:20px; }
  .sub { color:#888; font-size:13px; margin-bottom:20px; }
  ul { list-style:none; padding:0; }
  li { padding:12px; background:#2a2a2a; margin-bottom:8px;
       border-radius:6px; word-break:break-all; }
  a { color:#5b8def; text-decoration:none; font-weight:500; }
  a:hover { text-decoration:underline; }
  .sz { color:#888; }
  #drop { border:2px dashed #444; border-radius:10px; padding:22px;
          text-align:center; color:#999; font-size:14px; }
  #drop.hot { border-color:#5b8def; color:#5b8def; }
  #pick { display:none; }
  .btn { background:#5b8def; color:#fff; padding:10px 18px; border:0;
         border-radius:6px; font-weight:600; cursor:pointer; font-size:14px; }
  #list div { background:#2a2a2a; border-radius:6px; padding:10px;
              margin-top:8px; font-size:13px; word-break:break-all; }
  .bar { height:4px; background:#444; border-radius:2px; margin-top:6px;
         overflow:hidden; }
  .bar i { display:block; height:100%; width:0; background:#5b8def; }
  .bar.ok i { background:#4caf50; }
  .err { color:#e57373; }
  .footer { color:#666; font-size:12px; margin-top:32px; text-align:center; }
</style>
</head>
<body>
  <h1>Files shared with you</h1>
  <p class="sub">Tap a name to download. Files stay available only while the
     sender keeps this share open.</p>
  $empty
  <ul>$rows</ul>

  <h2>Send files to this phone</h2>
  <p class="sub">Works from any browser \u2014 iPhone, Windows, Mac, anything.
     Nothing to install.</p>
  <div id="drop">
    <input id="pick" type="file" multiple />
    <button class="btn" onclick="document.getElementById('pick').click()">
      Choose files
    </button>
    <div style="margin-top:10px;font-size:12px">or drop them here</div>
  </div>
  <div id="list"></div>

  <p class="footer">Innocent \u2014 local transfer, nothing leaves this network</p>

<script>
(function () {
  var pick = document.getElementById('pick');
  var drop = document.getElementById('drop');
  var list = document.getElementById('list');
  var TOKEN = ${jsonEncode(_token)};

  function human(n) {
    if (n < 1024) return n + ' B';
    if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
    if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
    return (n / 1073741824).toFixed(2) + ' GB';
  }

  // One at a time on purpose: several uploads at once only split the same
  // Wi-Fi airtime while multiplying writes on the phone's flash.
  var queue = [], busy = false;

  function pump() {
    if (busy || !queue.length) return;
    busy = true;
    var job = queue.shift();
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/' + TOKEN + '/up?name=' +
             encodeURIComponent(job.file.name));
    xhr.upload.onprogress = function (e) {
      if (!e.lengthComputable) return;
      job.fill.style.width = ((e.loaded / e.total) * 100).toFixed(1) + '%';
    };
    xhr.onload = function () {
      busy = false;
      if (xhr.status >= 200 && xhr.status < 300) {
        job.fill.style.width = '100%';
        job.bar.className = 'bar ok';
        job.label.textContent = job.file.name + ' \u2014 sent';
      } else {
        job.label.className = 'err';
        job.label.textContent = job.file.name + ' \u2014 failed (' + xhr.status + ')';
      }
      pump();
    };
    xhr.onerror = function () {
      busy = false;
      job.label.className = 'err';
      job.label.textContent = job.file.name + ' \u2014 connection lost';
      pump();
    };
    xhr.send(job.file);
  }

  function add(files) {
    for (var i = 0; i < files.length; i++) {
      var f = files[i];
      var row = document.createElement('div');
      var label = document.createElement('span');
      label.textContent = f.name + ' (' + human(f.size) + ')';
      var bar = document.createElement('div');
      bar.className = 'bar';
      var fill = document.createElement('i');
      bar.appendChild(fill);
      row.appendChild(label);
      row.appendChild(bar);
      list.appendChild(row);
      queue.push({ file: f, label: label, bar: bar, fill: fill });
    }
    pump();
  }

  pick.addEventListener('change', function () { add(pick.files); });
  ['dragenter', 'dragover'].forEach(function (ev) {
    drop.addEventListener(ev, function (e) {
      e.preventDefault();
      drop.className = 'hot';
    });
  });
  ['dragleave', 'drop'].forEach(function (ev) {
    drop.addEventListener(ev, function (e) {
      e.preventDefault();
      drop.className = '';
    });
  });
  drop.addEventListener('drop', function (e) {
    if (e.dataTransfer && e.dataTransfer.files) add(e.dataTransfer.files);
  });
})();
</script>
</body>
</html>
''';
  }

  static String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// Stream a file's byte range [start..end] (both inclusive) in large blocks
  /// for maximum throughput. Uses a raw RandomAccessFile with 512 KB reads —
  /// far fewer native round-trips and stream events than File.openRead()'s
  /// 64 KB default — and counts served bytes for the live speed display.
  Stream<List<int>> _streamFileRange(
      File file, int start, int end, int index, String peerIp) async* {
    const blockSize = 512 * 1024; // 512 KB
    final raf = await file.open();
    try {
      await raf.setPosition(start);
      var remaining = end - start + 1;
      while (remaining > 0) {
        // Cut the response short on pause. The receiver sees a truncated body,
        // fails its byte-count check, retries, and gets the 503 above — which
        // is exactly the path we want it on, with its partial file intact.
        if (paused) break;
        final toRead = remaining < blockSize ? remaining : blockSize;
        final data = await raf.read(toRead);
        if (data.isEmpty) break; // EOF / truncated — stop cleanly
        _bytesServed += data.length;
        _noteServed(index, data.length, peerIp);
        yield data;
        remaining -= data.length;
      }
    } finally {
      await raf.close();
    }
  }

  void _noteServed(int index, int n, String peerIp) {
    if (index < 0 || index >= _files.length) return;
    final size = _files[index].sizeBytes;
    int clamp(int v) => size > 0 && v > size ? size : v;
    final peer = _servedPerPeer.putIfAbsent(peerIp, () => <int, int>{});
    peer[index] = clamp((peer[index] ?? 0) + n);
    // The headline bar tracks whichever receiver is furthest along, rather
    // than a sum: with three phones pulling the same file, a sum would read
    // 300% and mean nothing.
    final best = _servedPerPeer.values
        .map((m) => m[index] ?? 0)
        .fold<int>(0, (a, b) => a > b ? a : b);
    _servedPerIndex[index] = clamp(best);
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _mimeForExt(String ext) {
    switch (ext.toLowerCase()) {
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      case '.mkv':
        return 'video/x-matroska';
      case '.webm':
        return 'video/webm';
      case '.mov':
        return 'video/quicktime';
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
        return 'audio/mp4';
      case '.flac':
        return 'audio/flac';
      case '.ogg':
        return 'audio/ogg';
      case '.wav':
        return 'audio/wav';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.apk':
        return 'application/vnd.android.package-archive';
      default:
        return 'application/octet-stream';
    }
  }

  Future<String?> _wifiIp() async {
    try {
      final info = NetworkInfo();
      final ip = await info.getWifiIP();
      if (ip != null && ip.isNotEmpty && !ip.startsWith('0.')) return ip;
    } catch (e) { if (kDebugMode) debugPrint('FileTransferService: $e'); }
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      bool isPrivate(String ip) =>
          ip.startsWith('192.168.') || ip.startsWith('10.') ||
          _isPrivate172(ip);
      // Compatibility pass: some phones expose several private IPv4s at
      // once (VPN tun, USB rndis, cellular clat…). Prefer the interface
      // that is actually the Wi-Fi radio or the hotspot AP — their names
      // contain wlan / ap / swlan on every Android OEM we know of — so
      // the QR always carries an address the other device can reach.
      for (final ni in interfaces) {
        final name = ni.name.toLowerCase();
        if (!(name.contains('wlan') ||
            name.contains('swlan') ||
            name.startsWith('ap'))) {
          continue;
        }
        for (final addr in ni.addresses) {
          if (isPrivate(addr.address)) return addr.address;
        }
      }
      for (final ni in interfaces) {
        for (final addr in ni.addresses) {
          if (isPrivate(addr.address)) return addr.address;
        }
      }
    } catch (e) { if (kDebugMode) debugPrint('FileTransferService: $e'); }
    return null;
  }

  /// The address on a direct link (Wi-Fi Direct group owner or hotspot),
  /// or null when there isn't one.
  ///
  /// Backstop for the native resolver. It matters that this is strict: with a
  /// Turbo group up AND the router connection still alive there are two valid
  /// addresses, and [_wifiIp]'s general interface preference could hand out
  /// the router one — the receiver would then be told to dial an address that
  /// isn't reachable from inside the group it just joined.
  static Future<String?> directLinkIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final ni in interfaces) {
        for (final addr in ni.addresses) {
          if (isHotspotAddress(addr.address)) return addr.address;
        }
      }
      for (final ni in interfaces) {
        final name = ni.name.toLowerCase();
        if (!(name.startsWith('p2p') ||
            name.startsWith('ap') ||
            name.contains('swlan') ||
            name.contains('softap'))) {
          continue;
        }
        for (final addr in ni.addresses) {
          return addr.address;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('FileTransferService.directLinkIp: $e');
    }
    return null;
  }

  /// True when the address we're serving on belongs to this phone's own
  /// hotspot rather than a router. Hotspot means one air hop instead of two,
  /// which is most of the speed difference against Zapya — worth telling the
  /// user which mode they're actually in instead of guessing.
  static bool isHotspotAddress(String? ip) {
    if (ip == null) return false;
    // Android's SoftAP has used 192.168.43.x for a decade; newer builds and
    // some OEMs use .49.x (Wi-Fi Direct group owner) or 192.168.4x.x.
    return ip.startsWith('192.168.43.') ||
        ip.startsWith('192.168.49.') ||
        ip.startsWith('192.168.44.') ||
        ip.startsWith('192.168.45.');
  }

  static bool _isPrivate172(String ip) {
    if (!ip.startsWith('172.')) return false;
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]) ?? -1;
    return second >= 16 && second <= 31;
  }

  /// [preferredIp] comes from the Turbo link when one is up. The native side
  /// already resolved it from the real p2p/AP interface, and it must win over
  /// [_wifiIp]: on a phone that kept its router connection alive there are two
  /// valid addresses, and advertising the router one would quietly send the
  /// receiver back over the slow path Turbo exists to avoid.
  Future<({String ip, int port})> start(
    List<SharedFile> files, {
    String? preferredIp,
  }) async {
    // Audit fix: dart:io's HttpServer / File / NetworkInterface aren't
    // available on web. Fail fast on web preview with a clear message.
    if (kIsWeb) {
      throw StateError(
          'File transfer needs a native Android build — not available '
          "on the web preview. Build an APK and try it on a phone.");
    }
    if (_server != null) {
      throw StateError('Transfer already running — stop first.');
    }
    if (files.isEmpty) {
      throw ArgumentError('Pick at least one file to share.');
    }
    final ip = (preferredIp != null && preferredIp.trim().isNotEmpty)
        ? preferredIp.trim()
        : await _wifiIp();
    if (ip == null) {
      throw StateError(
          'No Wi-Fi IP available. Connect both devices to the same '
          'Wi-Fi network and try again.');
    }
    _files
      ..clear()
      ..addAll(files);
    _bytesServed = 0;
    _servedPerIndex.clear();
    _servedPerPeer.clear();
    _peers.clear();
    paused = false;
    _token = _randomToken(36);

    HttpServer server;
    try {
      server = await shelf_io.serve(
        _router().call,
        InternetAddress.anyIPv4,
        8765,
        shared: false,
      );
    } on SocketException {
      server = await shelf_io.serve(
        _router().call,
        InternetAddress.anyIPv4,
        0,
        shared: false,
      );
    }
    _server = server;
    // Never gzip the response body. Media files (video/images/audio) are
    // already compressed, so on-the-fly gzip just burns CPU on both ends
    // and lowers throughput — turning it off is a straight speed win.
    server.autoCompress = false;
    // Keep a receiver's socket warm between files. A 300-photo batch used to
    // pay a fresh TCP handshake per photo; with keep-alive on both ends the
    // whole batch rides one connection per parallel stream.
    server.idleTimeout = const Duration(seconds: 60);
    return (ip: ip, port: server.port);
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _files.clear();
    _token = '';
    _bytesServed = 0;
    _servedPerIndex.clear();
    _servedPerPeer.clear();
    _peers.clear();
    // Lockouts are per SESSION. Carrying them across a stop would punish
    // someone for a mistake made against a share that no longer exists, and
    // the map would otherwise grow for as long as the app stayed open.
    _pinAttempts.clear();
    paused = false;
    pin = '';
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (e) { if (kDebugMode) debugPrint('FileTransferService: $e'); }
    }
  }

  void dispose() {
    stop();
    if (!_pairCtrl.isClosed) _pairCtrl.close();
  }
}

final fileTransferServiceProvider =
    Provider<FileTransferService>((ref) {
  final svc = FileTransferService();
  ref.onDispose(svc.dispose);
  return svc;
});

class TransferNotifier extends StateNotifier<TransferState> {
  final FileTransferService _svc;
  Timer? _progressTicker;
  StreamSubscription<PairRequest>? _pairSub;

  TransferNotifier(this._svc) : super(const TransferState()) {
    _pairSub = _svc.pairRequests.listen((req) {
      if (!mounted) return;
      state = state.copyWith(pending: req);
    });
    _loadDeviceName();
  }

  Future<void> _loadDeviceName() async {
    final name = await TransferDiscovery.instance.deviceName();
    if (!mounted) return;
    state = state.copyWith(deviceName: name);
  }

  Future<void> renameDevice(String name) async {
    await TransferDiscovery.instance.setDeviceName(name);
    if (!mounted) return;
    state = state.copyWith(deviceName: name.trim());
    // Re-announce under the new name straight away if a share is live.
    if (state.isRunning && state.port != null) {
      await TransferDiscovery.instance.startAnnouncing(SelfAnnouncement(
        port: state.port!,
        fileCount: state.files.length,
        totalBytes: state.totalBytes,
      ));
    }
  }

  void setRequireApproval(bool value) {
    _svc.requireApproval = value;
    state = state.copyWith(requireApproval: value);
  }

  /// Hold or release the share. Receivers already pulling stop at their next
  /// block and wait; nothing they have downloaded is thrown away.
  void setPaused(bool value) {
    if (!state.isRunning) return;
    _svc.paused = value;
    state = state.copyWith(paused: value);
  }

  /// Turn the PIN gate on (generating four digits) or off.
  void setPinEnabled(bool enabled) {
    if (!enabled) {
      _svc.pin = '';
      state = state.copyWith(pin: '');
      return;
    }
    if (state.pin.isNotEmpty) return;
    final rnd = Random.secure();
    final code = List.generate(4, (_) => rnd.nextInt(10)).join();
    _svc.pin = code;
    state = state.copyWith(pin: code);
  }

  /// Arm/disarm the direct radio link. Takes effect on the next Start — the
  /// group has to exist before the HTTP server picks an address, so flipping
  /// it mid-share would leave the QR pointing at the wrong network.
  void setTurboRequested(bool value) {
    if (state.isRunning) return;
    state = state.copyWith(turboRequested: value, clearTurboNotice: true);
  }

  /// Answer a pending pair request (approval mode).
  void respondToPair(bool accept) {
    final req = state.pending;
    state = state.copyWith(clearPending: true);
    if (req == null) return;
    if (!req.decision.isCompleted) req.decision.complete(accept);
  }

  void addFiles(List<SharedFile> picked) {
    if (picked.isEmpty) return;
    final existing = state.files.map((f) => f.path).toSet();
    final fresh = picked.where((f) => !existing.contains(f.path)).toList();
    if (fresh.isEmpty) return;
    // A running share has its own list inside the service. Without this the
    // new files appear on the sender's screen and are served by nobody.
    if (state.isRunning) {
      _svc.appendFiles(fresh);
    }
    state = state.copyWith(files: [...state.files, ...fresh], clearError: true);
    if (state.isRunning && state.port != null) {
      // Re-announce so the radar entry's file count and size stop lying.
      unawaited(TransferDiscovery.instance.startAnnouncing(SelfAnnouncement(
        port: state.port!,
        fileCount: state.files.length,
        totalBytes: state.totalBytes,
      )));
    }
  }

  void removeFile(String id) {
    // Not while sharing. A receiver already holds indices into this list, so
    // removing one would silently repoint every later file — the other phone
    // would download the wrong bytes under the right name, which is worse
    // than not being able to remove it.
    if (state.isRunning) return;
    state = state.copyWith(
      files: state.files.where((f) => f.id != id).toList(),
    );
  }

  void clearFiles() {
    if (state.isRunning) return;
    state = state.copyWith(files: const [], clearError: true);
  }

  Future<void> start() async {
    if (state.isRunning || state.starting) return;
    state = state.copyWith(starting: true, clearError: true);
    String? turboIp;
    String? notice;
    if (state.turboRequested) {
      final t = await _startTurbo();
      turboIp = t.$1;
      notice = t.$2;
      if (!mounted) {
        // Nothing will ever listen on this group now. Leaving it up would keep
        // the phone's Wi-Fi in AP mode with no UI anywhere to switch it off.
        await TurboLink.instance.hostStop();
        return;
      }
      state = state.copyWith(starting: true);
    }
    try {
      final result = await _svc.start(state.files, preferredIp: turboIp);
      // Give the server somewhere to put browser uploads. Best-effort: a
      // failure here only disables uploads, never the share itself.
      try {
        _svc.uploadDir = await FileReceiverService().receiveRootForDisplay();
      } catch (e) {
        if (kDebugMode) debugPrint('FileTransferService.uploadDir: $e');
      }
      state = state.copyWith(
        isRunning: true,
        starting: false,
        ipAddress: result.ip,
        port: result.port,
        bytesServed: 0,
        servedPerFile: const {},
        servedPerPeer: const {},
        peers: const [],
        clearError: true,
        turboNotice: notice,
        clearTurboNotice: notice == null,
      );
      _progressTicker?.cancel();
      _progressTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (state.isRunning) {
          state = state.copyWith(
            bytesServed: _svc.bytesServed,
            servedPerFile: _svc.servedPerIndex,
            servedPerPeer: _svc.servedPerPeerTotal,
            peers: _svc.peers,
          );
        }
      });
      // Announce over UDP so the other phone can just tap our name.
      await TransferDiscovery.instance.startAnnouncing(SelfAnnouncement(
        port: result.port,
        fileCount: state.files.length,
        totalBytes: state.totalBytes,
      ));
      // Keep the server alive if the user leaves the app, and show an
      // ongoing notification. The sender can't know the receiver's
      // progress, so the bar is indeterminate.
      final n = state.files.length;
      await TransferForegroundService.start(
        title: 'Sharing $n file${n == 1 ? '' : 's'}',
        text: 'Keep Innocent open to send',
      );
      // Compatibility: aggressive OEM Doze can park the Wi-Fi radio when
      // the screen sleeps mid-transfer; a receiver then sees the download
      // stall at random %. Hold a wakelock for the life of the share.
      try {
        await WakelockPlus.enable();
      } catch (e) { if (kDebugMode) debugPrint('FileTransferService: $e'); }
    } catch (e) {
      // The server failed to bind — don't strand a radio group with nothing
      // listening on it.
      if (state.turboActive) {
        await TurboLink.instance.hostStop();
        if (mounted) state = state.copyWith(clearTurbo: true);
      }
      if (mounted) {
        state = state.copyWith(
            error: '$e', isRunning: false, starting: false);
      }
    }
  }

  /// Bring the Turbo group up before the server binds. Returns
  /// (ip to advertise, notice to show) — a null ip just means "carry on over
  /// ordinary Wi-Fi", never a failed share.
  Future<(String?, String?)> _startTurbo() async {
    final turbo = TurboLink.instance;
    final pre = await turbo.preconditions();
    if (!pre.supported) return (null, 'turbo_unsupported');
    if (!pre.wifiOn) return (null, 'wifi_off');
    if (!pre.locationOn) return (null, 'location_off');
    if (!await turbo.ensurePermission()) return (null, 'permission_denied');
    final res = await turbo.hostStart();
    if (!res.ok) return (null, res.reason);
    // The group is up but we have no address on it. Advertising the router
    // address instead would produce a QR the other phone can scan, join, and
    // then fail to reach — the worst kind of failure, because everything
    // LOOKS like it worked. Take the group back down and say so.
    final ip = res.ip ?? await FileTransferService.directLinkIp();
    if (ip == null || ip.isEmpty) {
      await turbo.hostStop();
      return (null, 'no_direct_ip');
    }
    if (mounted) {
      state = state.copyWith(
        turboActive: true,
        turboMode: res.mode,
        turboBand: res.band,
        turboStaWasConnected: res.staWasConnected,
        turboSsid: res.ssid,
        turboPass: res.passphrase,
      );
    }
    return (ip, null);
  }

  Future<void> stop() async {
    _progressTicker?.cancel();
    _progressTicker = null;
    // Drop off other phones' radar before the socket goes away, so they don't
    // show a dead entry for the next six seconds.
    await TransferDiscovery.instance.stopAnnouncing();
    await _svc.stop();
    // Always release the radio, even if Turbo was never armed this run — a
    // group left over from a crashed session would keep the user's normal
    // Wi-Fi down with no UI anywhere to switch it off.
    await TurboLink.instance.hostStop();
    await TransferForegroundService.stop();
    try {
      await WakelockPlus.disable();
    } catch (e) { if (kDebugMode) debugPrint('FileTransferService: $e'); }
    state = state.copyWith(
      isRunning: false,
      clearAddress: true,
      bytesServed: 0,
      servedPerFile: const {},
      servedPerPeer: const {},
      peers: const [],
      starting: false,
      paused: false,
      pin: '',
      clearPending: true,
      clearTurbo: true,
      clearTurboNotice: true,
    );
  }

  /// Plain HTTP address. Always valid for a browser on the same network, and
  /// what gets copied to the clipboard.
  String get shareUrl {
    if (!state.isRunning) return '';
    return '${state.baseUrl}${_svc.token}';
  }

  /// What the QR actually encodes.
  ///
  /// Under Turbo the receiver cannot reach any URL until it has joined the
  /// group, so the credentials have to travel with the address; a plain
  /// http:// QR would just fail to load. Without Turbo the QR stays exactly
  /// what it always was, which is what keeps older builds of Innocent able to
  /// scan a new one.
  String get qrPayload {
    if (!state.isRunning) return '';
    final ssid = state.turboSsid;
    if (!state.turboActive || ssid == null || ssid.isEmpty) return shareUrl;
    return TurboInvite(
      ssid: ssid,
      passphrase: state.turboPass ?? '',
      host: state.ipAddress ?? '',
      port: state.port ?? 0,
      token: _svc.token,
      senderName: state.deviceName ?? 'Innocent phone',
      mode: state.turboMode,
    ).encode();
  }

  /// The PIN a discovered device must quote, or '' when the gate is off.
  /// Read by the receiver flow only after a 401.
  String get sharePin => state.pin;

  @override
  void dispose() {
    _progressTicker?.cancel();
    _pairSub?.cancel();
    super.dispose();
  }
}

final transferProvider =
    StateNotifierProvider<TransferNotifier, TransferState>((ref) {
  final svc = ref.watch(fileTransferServiceProvider);
  return TransferNotifier(svc);
});
