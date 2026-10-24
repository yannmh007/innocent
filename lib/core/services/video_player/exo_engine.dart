import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../diagnostics/playback_log.dart';

/// The Dart side of ExoStreamEngine (android/.../ExoStreamEngine.kt): Media3's
/// ExoPlayer, for catalogue films that have a ladder, played as HLS from the
/// local proxy.
///
/// Used only through MediaKitPlayerService, which hands it the films whose
/// address is a ladder's master playlist and keeps libmpv for everything
/// else — so the player screen, its gestures, the account code, PiP and the
/// resume point see one service whichever engine is drawing.
class ExoEngine {
  ExoEngine._(this.id, this.textureId);

  static const MethodChannel _m = MethodChannel('innocent/exo');
  static const EventChannel _ev = EventChannel('innocent/exo/events');
  static Stream<Map<Object?, Object?>>? _events;

  final int id;
  final int textureId;

  Duration position = Duration.zero;
  Duration buffered = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  bool buffering = false;
  bool ended = false;
  Size? size;

  /// The rung on screen, by height, as the player last reported it.
  int? rung;

  /// The heights the master offers, once the player has read it.
  List<int> heights = const <int>[];

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _buffered = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String?>.broadcast();
  final _size = StreamController<Size?>.broadcast();
  final _first = StreamController<void>.broadcast();
  StreamSubscription<Map<Object?, Object?>>? _sub;

  Stream<Duration> get positionStream => _position.stream;
  Stream<Duration> get durationStream => _duration.stream;
  Stream<Duration> get bufferedStream => _buffered.stream;
  Stream<bool> get playingStream => _playing.stream;
  Stream<bool> get bufferingStream => _buffering.stream;
  Stream<bool> get completedStream => _completed.stream;
  Stream<String?> get errorStream => _error.stream;
  Stream<Size?> get sizeStream => _size.stream;
  Stream<void> get firstFrameStream => _first.stream;

  /// A new engine and its texture, or null where there is none (anything but
  /// Android, an app built without it, a test).
  static Future<ExoEngine?> create() async {
    try {
      final r = await _m.invokeMapMethod<String, Object?>('create');
      final id = (r?['id'] as num?)?.toInt();
      final tex = (r?['texture'] as num?)?.toInt();
      if (id == null || tex == null) return null;
      final e = ExoEngine._(id, tex);
      e._listen();
      return e;
    } catch (e) {
      if (kDebugMode) debugPrint('ExoEngine.create: $e');
      return null;
    }
  }

  void _listen() {
    _events ??= _ev.receiveBroadcastStream().map((e) => e as Map<Object?, Object?>).asBroadcastStream();
    _sub = _events!.where((e) => (e['id'] as num?)?.toInt() == id).listen(_on);
  }

  void _on(Map<Object?, Object?> e) {
    switch (e['e']) {
      case 'pos':
        position = Duration(milliseconds: (e['pos'] as num?)?.toInt() ?? 0);
        buffered = Duration(milliseconds: (e['buf'] as num?)?.toInt() ?? 0);
        final d = Duration(milliseconds: (e['dur'] as num?)?.toInt() ?? 0);
        if (d != duration) {
          duration = d;
          _duration.add(d);
        }
        _position.add(position);
        _buffered.add(buffered);
      case 'state':
        final p = e['playing'] == true;
        final b = e['buffering'] == true;
        final end = e['ended'] == true;
        if (p != playing) _playing.add(playing = p);
        if (b != buffering) _buffering.add(buffering = b);
        if (end != ended) _completed.add(ended = end);
      case 'size':
        final w = (e['w'] as num?)?.toDouble() ?? 0;
        final h = (e['h'] as num?)?.toDouble() ?? 0;
        size = w > 0 && h > 0 ? Size(w, h) : null;
        _size.add(size);
      case 'first':
        final clock = _seekClock;
        if (clock != null) {
          PlaybackLog.add('exo picture after seek ${clock.elapsedMilliseconds} ms');
          _seekClock = null;
        }
        final back = _surfaceClock;
        if (back != null) {
          PlaybackLog.add('exo picture back ${back.elapsedMilliseconds} ms after its surface');
          _surfaceClock = null;
        }
        _first.add(null);
      case 'surface':
        final on = e['on'] == true;
        PlaybackLog.add('exo surface ${on ? 'back' : 'gone'} at ${position.inSeconds}s');
        _surfaceClock = on ? (Stopwatch()..start()) : null;
      case 'rung':
        final h = (e['h'] as num?)?.toInt();
        if (h != null && h > 0 && h != rung) {
          rung = h;
          PlaybackLog.add('exo rung ${h}p ${(e['kbps'] as num?)?.toInt() ?? 0} kbps');
        }
      case 'tracks':
        heights = [
          for (final h in (e['heights'] as List<Object?>? ?? const <Object?>[]))
            if (h is num) h.toInt(),
        ];
        PlaybackLog.add('exo tracks ${heights.join(',')} selected=${e['selected']} '
            'adaptive=${e['adaptive']}');
      case 'steer':
        PlaybackLog.add('exo steer ${e['why']} target=${e['target'] ?? 'auto'} '
            'made=${e['made']} rungs=${e['heights']} picks=${e['picks']}');
      case 'loaderr':
        PlaybackLog.add('exo load error ${e['what']} type=${e['type']} ${e['err']}');
      case 'dropped':
        // In the trail only when it matters: a decoder falling behind.
        final n = (e['n'] as num?)?.toInt() ?? 0;
        if (n >= 10) PlaybackLog.add('exo dropped $n frames');
      case 'error':
        final msg = '${e['code'] ?? 'error'}: ${e['msg'] ?? ''}';
        PlaybackLog.add('exo error $msg');
        _error.add(msg);
    }
  }

  Future<bool> _call(String method, [Map<String, Object?> args = const {}]) async {
    try {
      return await _m.invokeMethod<bool>(method, <String, Object?>{'id': id, ...args}) ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('ExoEngine.$method: $e');
      return false;
    }
  }

  /// [target] a rung by height (null: Auto), [maxHeight] the data saver's
  /// ceiling for Auto, [kbps] what the line was last measured at, [start]
  /// Auto's first rung (the one warmed while the viewer looked at the film),
  /// [rungs] each rung's average rate by height — how the player tells the
  /// rungs apart when the master could not yet say their sizes.
  Future<bool> open(String url,
      {Duration? startAt,
      bool autoplay = true,
      int? target,
      int? maxHeight,
      int? kbps,
      int? start,
      Map<int, int> rungs = const <int, int>{}}) {
    position = startAt ?? Duration.zero;
    ended = false;
    rung = null;
    return _call('open', <String, Object?>{
      'url': url,
      'startMs': startAt?.inMilliseconds ?? 0,
      'autoplay': autoplay,
      'target': target,
      'maxHeight': maxHeight,
      'bps': kbps == null ? null : kbps * 1000,
      'start': start,
      // As the master writes AVERAGE-BANDWIDTH (HlsLadder.master).
      'rungs': [
        for (final e in rungs.entries) <int>[e.key, (e.value < 1 ? 1 : e.value) * 1000],
      ],
    });
  }

  Future<bool> play() => _call('play');
  Future<bool> pause() => _call('pause');
  /// [fast]: the keyframe nearest [to] (at most a second off), for a far
  /// jump; otherwise the exact frame.
  Future<bool> seek(Duration to, {bool fast = false}) {
    position = to;
    _seekClock = Stopwatch()..start();
    return _call('seek', <String, Object?>{'ms': to.inMilliseconds, 'fast': fast});
  }

  /// Since the last seek, until its first picture: in the trail.
  Stopwatch? _seekClock;

  /// Since the picture's surface came back (the app back in front), until
  /// its first frame.
  Stopwatch? _surfaceClock;

  Future<bool> scrubbing(bool on) => _call('scrubbing', <String, Object?>{'on': on});
  Future<bool> rate(double r) => _call('rate', <String, Object?>{'rate': r});
  /// 0.0 to 4.0: above 1.0 the sound is lifted (LoudnessEnhancer).
  Future<bool> volume(double v) => _call('volume', <String, Object?>{'volume': v});

  /// A rung by height, or Auto (null): the picture keeps moving, and the
  /// new rung shows within a couple of seconds.
  Future<bool> quality(int? height) => _call('quality', <String, Object?>{'height': height});
  Future<bool> maxHeight(int? height) => _call('maxHeight', <String, Object?>{'height': height});

  /// The line's speed as the proxy measured it, for Auto's choices.
  Future<bool> bandwidth(int kbps) => _call('bandwidth', <String, Object?>{'bps': kbps * 1000});

  Future<bool> stop() => _call('stop');

  Future<void> release() async {
    await _call('release');
    await _sub?.cancel();
    for (final c in [_position, _duration, _buffered, _playing, _buffering, _completed, _error, _size, _first]) {
      await c.close();
    }
  }

  static const MethodChannel _preview = MethodChannel('innocent/preview');

  /// The keyframe of [film] — an init segment and one fragment, as
  /// StreamCacheServer.previewClip makes them — as a JPEG [maxWidth] wide,
  /// or null. For the seek bar's preview.
  static Future<Uint8List?> frame(Uint8List film, Duration at, {int maxWidth = 320}) async {
    try {
      return await _preview.invokeMethod<Uint8List>('frame', <String, Object?>{
        'film': film,
        'timeUs': at.inMicroseconds,
        'maxWidth': maxWidth,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('ExoEngine.frame: $e');
      return null;
    }
  }

  /// Whether [uri] is a ladder's master playlist on the local proxy — the
  /// one kind of address this engine plays.
  static bool isLadder(String uri) {
    final u = Uri.tryParse(uri);
    if (u == null || u.host != '127.0.0.1') return false;
    final p = u.pathSegments;
    return p.length == 4 && p.first == 'h' && p.last == 'master.m3u8';
  }
}

/// The picture of an [ExoEngine], fitted like libmpv's.
class ExoVideo extends StatelessWidget {
  const ExoVideo({super.key, required this.engine, this.fit = BoxFit.contain});

  final ExoEngine engine;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Size?>(
      stream: engine.sizeStream,
      initialData: engine.size,
      builder: (context, snap) {
        final s = snap.data;
        if (s == null) return const ColoredBox(color: Color(0xFF000000));
        return ColoredBox(
          color: const Color(0xFF000000),
          child: FittedBox(
            fit: fit,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: s.width,
              height: s.height,
              child: Texture(textureId: engine.textureId),
            ),
          ),
        );
      },
    );
  }
}
