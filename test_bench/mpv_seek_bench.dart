// A bench, run like a test: the test-only hooks are the point of it.
// ignore_for_file: invalid_use_of_visible_for_testing_member, avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/diagnostics/playback_log.dart';
import 'package:innocent/core/services/video_player/media_kit_player_service.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_server.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// WHAT A SEEK COSTS ON THE PHONE: the real libmpv reading through the real
/// stream proxy, over a line with a speed and a round trip.
///
/// The playback check measured a one-frame seek at 7.8 MB for ffmpeg and
/// 72.9 MB for mpv, through a relay that counted what it pushed into a
/// socket, not what the player read. This measures the path a phone takes:
///
///   mpv (the app's stream options)  →  StreamCacheServer  →  the "Worker"
///
/// The Worker here serves a film in the ladder's layout (made with the
/// ladder's own ffmpeg flags) through ONE shared line — a rate cap for all
/// connections together and a round trip per response — and its sockets
/// keep a small send buffer, so what it counts is what crossed the line.
///
/// For each mpv option set it plays eight seconds, then makes the jumps a
/// viewer makes, and for each reports how long until the picture moved
/// again (mpv's `playback-restart`), how many requests mpv made to the
/// proxy, and how many requests and megabytes the proxy took from the line
/// — until the restart and in the five seconds after it.
///
///   flutter test test_bench/mpv_seek_bench.dart
///   BENCH_LINE_KBPS=8000 BENCH_RTT_MS=80 BENCH_FILM_S=600 BENCH_FILM_KBPS=1700
///
/// Needs mpv and ffmpeg on the machine; skipped where either is missing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final haveTools = Process.runSync('which', ['mpv']).exitCode == 0 &&
      Process.runSync('which', ['ffmpeg']).exitCode == 0;

  test('mpv through the proxy: what a seek costs', () async {
    HttpOverrides.global = null;
    final lineKbps = int.tryParse(env['BENCH_LINE_KBPS'] ?? '') ?? 8000;
    final rttMs = int.tryParse(env['BENCH_RTT_MS'] ?? '') ?? 80;
    final filmS = int.tryParse(env['BENCH_FILM_S'] ?? '') ?? 600;
    final filmKbps = int.tryParse(env['BENCH_FILM_KBPS'] ?? '') ?? 1700;
    final temp = await Directory.systemTemp.createTemp('mpvseek');
    PathProviderPlatform.instance = _FakePaths(temp.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('mx_clone/media_scan'),
            (call) async => call.method == 'freeBytes' ? 64 * 1024 * 1024 * 1024 : null);
    final proxyLog = <String>[];
    PlaybackLog.sink = proxyLog.add;

    // The film, in the ladder's layout: tool/transcode.sh's flags.
    final film = env['BENCH_FILM'] ?? '${temp.path}/film.mp4';
    if (env['BENCH_FILM'] == null) {
      final made = await Process.run('ffmpeg', [
        '-nostdin', '-v', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
        '-t', '$filmS', '-map', '0:v:0', '-map', '1:a:0',
        '-c:v', 'libx264', '-preset', 'ultrafast',
        '-b:v', '${filmKbps - 128}k', '-minrate', '${filmKbps - 128}k',
        '-maxrate', '${filmKbps - 128}k', '-bufsize', '${filmKbps}k',
        '-x264-params', 'nal-hrd=cbr', '-g', '48', '-keyint_min', '48',
        '-sc_threshold', '0', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '128k', '-ac', '2', '-ar', '48000',
        '-movflags', '+frag_keyframe+empty_moov+default_base_moof+global_sidx+cmaf+skip_trailer',
        film,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
    }
    final bytes = await File(film).readAsBytes();
    final line = _Line(lineKbps * 1000 ~/ 8, Duration(milliseconds: rttMs));
    final worker = await _Worker.start(bytes, line,
        port: int.tryParse(env['BENCH_PORT'] ?? '') ?? 0);
    final upstream = 'http://127.0.0.1:${worker.port}/film.mp4';

    // `shipped` is what the app does; `+nohand` and `+norounds` turn off
    // the proxy's hand-over and post-seek growth (the before), `sbN` sets
    // mpv's stream buffer to N MiB, `key=value;…` any mpv option.
    final variants = (env['BENCH_VARIANTS'] ?? 'shipped,shipped+nohand+norounds').split(',');
    final out = <String>[
      'line $lineKbps kbps, rtt $rttMs ms; film ${filmS}s at $filmKbps kbps '
          '(${(bytes.length / 1048576).toStringAsFixed(1)} MB); lanes ${StreamCacheServer.lanes}',
    ];
    print(out.first);
    // PATHS: `proxyN` is the app's way, through StreamCacheServer with N
    // lanes; `direct` is mpv on the line itself, the floor to measure the
    // proxy against.
    for (final path in (env['BENCH_PATHS'] ?? 'proxy6').split(',')) {
      for (final name in variants) {
        // Set per run: the variant's proxy switches are statics.
        final e = MapEntry(name, _variant(name));
        final direct = path == 'direct';
        if (!direct) StreamCacheServer.lanes = int.tryParse(path.substring(5)) ?? 6;
        final id = 'seek-$path-${e.key}-${DateTime.now().microsecondsSinceEpoch}';
        final local = direct
            ? upstream
            : await StreamCacheServer.instance
                .localUrlFor(cacheId: id, upstream: upstream, refresh: () async => upstream);
        final counter = await _Counter.start(Uri.parse(local!));
        worker.reset();
        proxyLog.clear();
        final rows = await _drive(e.value, counter.url(local), worker, counter,
            filmS: filmS, dir: temp.path);
        if (!direct) StreamCacheServer.instance.release(id);
        await counter.close();
        for (final r in rows) {
          final s = '${'$path ${e.key}'.padRight(16)} $r';
          out.add(s);
          print(s);
        }
        // A fresh cache for the next variant, or it would read the first's.
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    final o = env['BENCH_OUT'];
    if (o != null) File(o).writeAsStringSync('${out.join('\n')}\n');
    await worker.close();
    PlaybackLog.sink = null;
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  },
      skip: haveTools ? false : 'needs mpv and ffmpeg',
      timeout: const Timeout(Duration(minutes: 20)));
}

/// The app's network-stream options ([MediaKitPlayerService.streamProfile],
/// what setStreamBufferProfile writes for a film through the proxy), and
/// what a variant changes in them.
Map<String, String> _variant(String name) {
  final o = Map<String, String>.of(
      MediaKitPlayerService.streamProfile(viaLocalCache: true));
  StreamCacheServer.handOver = !name.contains('nohand');
  StreamCacheServer.seekSettledBytes =
      name.contains('norounds') ? 0 : 2 * 1024 * 1024;
  switch (name.split('+').first) {
    case 'shipped':
      break;
    case 'sb1':
      o['stream-buffer-size'] = '${1024 * 1024}';
    case 'sb2':
      o['stream-buffer-size'] = '${2 * 1024 * 1024}';
    case 'sb3':
      o['stream-buffer-size'] = '${3 * 1024 * 1024}';
    case 'sb4':
      o['stream-buffer-size'] = '${4 * 1024 * 1024}';
    case 'sb8':
      o['stream-buffer-size'] = '${8 * 1024 * 1024}';
    default:
      // key=value[;key=value…]
      for (final kv in name.split(';')) {
        final i = kv.indexOf('=');
        if (i > 0) o[kv.substring(0, i)] = kv.substring(i + 1);
      }
  }
  return o;
}

Future<List<String>> _drive(Map<String, String> opts, String url, _Worker w,
    _Counter c, {required int filmS, required String dir}) async {
  final ipc = '$dir/mpv-${DateTime.now().microsecondsSinceEpoch}.sock';
  final p = await Process.start('mpv', [
    '--no-config', '--vo=null', '--ao=null', '--idle=no', '--input-ipc-server=$ipc',
    for (final e in opts.entries) '--${e.key}=${e.value}',
    url,
  ]);
  unawaited(p.stdout.drain<void>());
  unawaited(p.stderr.drain<void>());
  Socket? s;
  for (var i = 0; i < 100 && s == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      s = await Socket.connect(InternetAddress(ipc, type: InternetAddressType.unix), 0);
    } catch (_) {}
  }
  if (s == null) {
    p.kill();
    return ['mpv did not start'];
  }
  final restarts = <DateTime>[];
  final pos = <double>[];
  s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
    try {
      final m = jsonDecode(l) as Map<String, dynamic>;
      if (m['event'] == 'playback-restart') restarts.add(DateTime.now());
      if (m['event'] == 'property-change' && m['name'] == 'time-pos' && m['data'] is num) {
        pos.add((m['data'] as num).toDouble());
      }
    } catch (_) {}
  });
  void send(List<Object> cmd) => s!.write('${jsonEncode({'command': cmd})}\n');
  send(['observe_property', 1, 'time-pos']);

  Future<int?> restartAfter(DateTime t) async {
    final end = t.add(const Duration(seconds: 40));
    while (DateTime.now().isBefore(end)) {
      final r = restarts.where((x) => x.isAfter(t));
      if (r.isNotEmpty) return r.first.difference(t).inMilliseconds;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return null;
  }

  final rows = <String>[];
  Future<void> phase(String what, void Function()? act, {int settle = 5}) async {
    final t = DateTime.now();
    final r0 = w.requests, b0 = w.bytes, m0 = c.requests;
    act?.call();
    final ms = await restartAfter(t);
    final r1 = w.requests, b1 = w.bytes, m1 = c.requests;
    await Future<void>.delayed(Duration(seconds: settle));
    rows.add('${what.padRight(12)} picture ${ms == null ? 'NEVER' : '$ms ms'.padLeft(7)}  '
        'mpv→proxy ${m1 - m0} req  line ${r1 - r0} req ${_mb(b1 - b0)} MB  '
        '| +${settle}s: mpv ${c.requests - m0} req, line ${w.requests - r0} req ${_mb(w.bytes - b0)} MB'
        '  at ${pos.isEmpty ? '-' : pos.last.toStringAsFixed(0)} s');
  }

  await phase('open', null, settle: 8);
  // Playing on, untouched: how many requests a stretch of film costs once
  // the player has settled — what every minute of every viewing costs the
  // Worker.
  final steady = int.tryParse(Platform.environment['BENCH_STEADY_S'] ?? '') ?? 20;
  {
    final r0 = w.requests, b0 = w.bytes, m0 = c.requests;
    await Future<void>.delayed(Duration(seconds: steady));
    final mb = (w.bytes - b0) / 1048576;
    rows.add('${''.padRight(12)} proxy: steps ${StreamCacheServer.stepsSeen} '
        'handed over ${StreamCacheServer.handedOver} carried on ${StreamCacheServer.carriedOn}');
    rows.add('${'steady ${steady}s'.padRight(12)} mpv→proxy ${c.requests - m0} req  '
        'line ${w.requests - r0} req ${mb.toStringAsFixed(2)} MB  '
        '(${mb == 0 ? '-' : ((w.requests - r0) / mb).toStringAsFixed(2)} req/MB)'
        '  at ${pos.isEmpty ? '-' : pos.last.toStringAsFixed(0)} s');
  }
  await phase('seek 40%', () => send(['seek', '${(filmS * 0.4).round()}', 'absolute']));
  await phase('skip +30', () => send(['seek', '30', 'relative']));
  await phase('back -120', () => send(['seek', '-120', 'relative']));
  await phase('seek 75%', () => send(['seek', '${(filmS * 0.75).round()}', 'absolute']));
  send(['quit']);
  await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
    p.kill();
    return -1;
  });
  await s.close();
  return rows;
}

String _mb(int b) => (b / 1048576).toStringAsFixed(2);

/// One line for every connection together: a rate and a round trip.
class _Line {
  _Line(this.bytesPerSecond, this.rtt);
  final int bytesPerSecond;
  final Duration rtt;
  var _next = DateTime.now();

  /// Wait for [n] bytes' turn on the line. A rate of 0 is no cap (the
  /// workflow's netem sets the pace).
  Future<void> take(int n) async {
    if (bytesPerSecond <= 0) return;
    final now = DateTime.now();
    if (_next.isBefore(now)) _next = now;
    _next = _next.add(Duration(microseconds: n * 1000000 ~/ bytesPerSecond));
    final wait = _next.difference(DateTime.now());
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }
}

/// The Worker: ranges over raw sockets with a small send buffer, so a byte
/// counted is a byte that crossed the line.
class _Worker {
  _Worker._(this._server, this._body, this._line);
  final ServerSocket _server;
  final List<int> _body;
  final _Line _line;
  int requests = 0;
  int bytes = 0;
  int get port => _server.port;

  void reset() {
    requests = 0;
    bytes = 0;
  }

  static Future<_Worker> start(List<int> body, _Line line, {int port = 0}) async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    final w = _Worker._(s, body, line);
    s.listen(w._serve);
    return w;
  }

  Future<void> _serve(Socket sock) async {
    try {
      // Linux SO_SNDBUF: a small send buffer, so nothing piles up unseen.
      sock.setRawOption(RawSocketOption.fromInt(RawSocketOption.levelSocket, 7, 64 * 1024));
    } catch (_) {}
    var buf = <int>[];
    var busy = false;
    var closed = false;
    final queue = <String>[];
    Future<void> pump() async {
      if (busy) return;
      busy = true;
      while (queue.isNotEmpty && !closed) {
        final head = queue.removeAt(0);
        await _answer(sock, head, () => closed);
      }
      busy = false;
    }

    unawaited(sock.done.then<void>((_) {}, onError: (Object _) {}));
    // The handshake: a round trip or two before the first request is heard.
    await Future<void>.delayed(_line.rtt * 2);
    sock.listen((data) {
      buf.addAll(data);
      while (true) {
        final s = String.fromCharCodes(buf);
        final i = s.indexOf('\r\n\r\n');
        if (i < 0) break;
        queue.add(s.substring(0, i));
        buf = buf.sublist(i + 4);
      }
      unawaited(pump());
    }, onDone: () => closed = true, onError: (_) => closed = true, cancelOnError: true);
  }

  Future<void> _answer(Socket sock, String head, bool Function() closed) async {
    requests++;
    final range = RegExp(r'^range:\s*bytes=(\d*)-(\d*)', caseSensitive: false, multiLine: true)
        .firstMatch(head);
    var a = 0, b = _body.length - 1;
    if (range != null) {
      a = int.tryParse(range.group(1)!) ?? 0;
      final e = int.tryParse(range.group(2)!);
      if (e != null) b = min(e, _body.length - 1);
    }
    await Future<void>.delayed(_line.rtt);
    sock.write('HTTP/1.1 ${range == null ? 200 : 206} OK\r\n'
        'Accept-Ranges: bytes\r\nContent-Type: video/mp4\r\n'
        'Content-Length: ${b - a + 1}\r\n'
        '${range == null ? '' : 'Content-Range: bytes $a-$b/${_body.length}\r\n'}'
        '\r\n');
    var at = a;
    try {
      while (at <= b && !closed()) {
        final n = min(16 * 1024, b - at + 1);
        await _line.take(n);
        sock.add(_body.sublist(at, at + n));
        await sock.flush();
        bytes += n;
        at += n;
      }
    } catch (_) {}
  }

  Future<void> close() => _server.close();
}

/// Between mpv and the proxy: counts the requests mpv makes.
class _Counter {
  _Counter._(this._server, this._to);
  final ServerSocket _server;
  final Uri _to;
  int requests = 0;
  final _open = <Socket>[];

  static Future<_Counter> start(Uri to) async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final c = _Counter._(s, to);
    s.listen(c._pipe);
    return c;
  }

  String url(String local) =>
      Uri.parse(local).replace(port: _server.port).toString();

  Future<void> _pipe(Socket a) async {
    final Socket b;
    try {
      b = await Socket.connect(InternetAddress.loopbackIPv4, _to.port);
    } catch (_) {
      a.destroy();
      return;
    }
    _open..add(a)..add(b);
    unawaited(a.done.then<void>((_) {}, onError: (Object _) {}));
    unawaited(b.done.then<void>((_) {}, onError: (Object _) {}));
    a.listen((d) {
      requests += RegExp('GET ').allMatches(String.fromCharCodes(d)).length;
      try {
        b.add(d);
      } catch (_) {}
    }, onDone: b.destroy, onError: (Object _) => b.destroy());
    b.listen((d) {
      try {
        a.add(d);
      } catch (_) {}
    }, onDone: a.destroy, onError: (Object _) => a.destroy());
  }

  Future<void> close() async {
    for (final s in _open) {
      s.destroy();
    }
    await _server.close();
  }
}
