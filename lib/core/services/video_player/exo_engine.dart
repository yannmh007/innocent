import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../diagnostics/playback_log.dart';
import 'models/audio_track_info.dart';

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

  /// An engine with no player behind it, fed its events by [debugEvent].
  @visibleForTesting
  ExoEngine.forTest() : this._(0, 0);

  @visibleForTesting
  void debugEvent(Map<Object?, Object?> e) => _on(e);

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

  /// [rung], for whoever draws it (the top bar's "Auto · 480p").
  final ValueNotifier<int?> rungOnScreen = ValueNotifier<int?>(null);

  /// The bitrate of the copy on screen (kbps), as the file declares it.
  int? rungKbps;

  /// The heights the master offers, once the player has read it.
  List<int> heights = const <int>[];

  /// THE PICTURE WHERE A FAR JUMP LANDS, drawn over the old frame until the
  /// new one is: the seek bar's picture of that moment, so a jump shows
  /// where it went at once rather than a still of where it left (YouTube
  /// holds its storyboard frame the same way). Null the rest of the time.
  final ValueNotifier<Uint8List?> landing = ValueNotifier<Uint8List?>(null);
  Timer? _landingUp;
  Timer? _landingCap;
  Stopwatch? _landingClock;

  /// Why the player is ready, asked to play, and not playing ('scrubbing',
  /// 'audio focus'…), and since when; null while it is not held.
  String? _heldWhy;
  Stopwatch? _heldClock;

  /// A hold this long is said in the trail as it ends (or as the film
  /// leaves): a drag's own is a few seconds; one nobody ended is the
  /// "playing and not moving" film of 14 Nov 2026.
  static const Duration heldWorthSaying = Duration(seconds: 1);

  void _noteHeld(String why) {
    final was = _heldWhy;
    if (why == (was ?? '')) return;
    final clock = _heldClock;
    if (was != null && clock != null && clock.elapsed >= heldWorthSaying) {
      PlaybackLog.add('exo held ${clock.elapsedMilliseconds} ms ($was) '
          'at ${position.inSeconds}s');
    }
    _heldWhy = why.isEmpty ? null : why;
    _heldClock = why.isEmpty ? null : (Stopwatch()..start());
  }

  /// A jump answered from memory draws its frame in a few tens of ms:
  /// holding the picture that briefly would only flash a softer copy.
  static const Duration landingAfter = Duration(milliseconds: 120);

  /// However long the jump takes, the picture goes by then: past it, the
  /// spinner tells the truth better than a still.
  static const Duration landingAtMost = Duration(seconds: 4);

  /// How the last far jump's picture went, for the lab: "held N ms, first
  /// frame", "not needed" (the jump drew its frame first), "no picture"
  /// (none had been taken there), or null while it is up.
  String? lastLanding;

  void _hold(Uint8List picture) {
    _landingUp = Timer(landingAfter, () {
      _landingUp = null;
      landing.value = picture;
      _landingClock = Stopwatch()..start();
    });
    _landingCap = Timer(landingAtMost, () => _letGo('timed out'));
  }

  void _letGo(String why) {
    final early = _landingUp != null;
    _landingUp?.cancel();
    _landingUp = null;
    _landingCap?.cancel();
    _landingCap = null;
    final clock = _landingClock;
    _landingClock = null;
    if (landing.value == null) {
      if (early) lastLanding = 'not needed';
      return;
    }
    landing.value = null;
    lastLanding = 'held ${clock?.elapsedMilliseconds ?? 0} ms, $why';
    PlaybackLog.add('exo landing picture $lastLanding');
  }

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _buffered = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String?>.broadcast();
  final _size = StreamController<Size?>.broadcast();
  final _first = StreamController<void>.broadcast();
  final _audio = StreamController<List<AudioTrackInfo>>.broadcast();
  StreamSubscription<Map<Object?, Object?>>? _sub;

  /// ♪ on a catalogue film (P4, 27 Nov 2026): the audio tracks the ladder
  /// offers (an HLS rendition each, or the one muxed in), as ExoPlayer
  /// reads them; [audioTrackOn] the one playing, [audioOff] when ♪'s
  /// Disable is on. Ids are "group:track" in the player's own Tracks.
  List<AudioTrackInfo> audioTracks = const <AudioTrackInfo>[];
  String? audioTrackOn;
  bool audioOff = false;
  Stream<List<AudioTrackInfo>> get audioTracksStream => _audio.stream;

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
      if (const bool.fromEnvironment('INNOCENT_LAB')) labLatest = e;
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
        // PLAYING MEANS THE VIEWER HAS IT PLAYING, as libmpv says it: a film
        // waiting for its bytes is still a playing film. ExoPlayer's own
        // isPlaying is false while it buffers, and read as "paused" it made
        // a change of quality during a stall reopen the film paused, and put
        // the play button up under the spinner (device lab run 40190583932).
        final p = e['ready'] == true && e['ended'] != true;
        final b = e['buffering'] == true;
        final pos = (e['pos'] as num?)?.toInt();
        final buf = (e['buf'] as num?)?.toInt();
        if (pos != null) position = Duration(milliseconds: pos);
        if (buf != null) buffered = Duration(milliseconds: buf);
        final end = e['ended'] == true;
        if (p != playing) _playing.add(playing = p);
        if (b != buffering) _buffering.add(buffering = b);
        if (end != ended) _completed.add(ended = end);
        _noteHeld(e['held'] as String? ?? '');
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
        _letGo('first frame');
        _first.add(null);
      case 'film':
        final note = e['note'] as String?;
        if (note != null) {
          PlaybackLog.add('exo film: $note');
          return;
        }
        final on = e['on'] == true;
        final clock = _filmClock;
        _filmClock = null;
        PlaybackLog.add('exo film on ${on ? 'its own surface' : 'the texture'}'
            '${clock == null ? '' : ' after ${clock.elapsedMilliseconds} ms'}');
        if (!on && surfaceAsked) {
          // The phone took it back (a new Activity, the window's secure flag
          // changed): asked again by the player when it wants it.
          surfaceAsked = false;
          _filmWait?.cancel();
        }
        if (on) _filmWait?.cancel();
        onSurface.value = on;
      case 'surface':
        final on = e['on'] == true;
        PlaybackLog.add('exo surface ${on ? 'back' : 'gone'} at ${position.inSeconds}s');
        _surfaceClock = on ? (Stopwatch()..start()) : null;
      case 'rung':
        final h = (e['h'] as num?)?.toInt();
        if (h != null && h > 0 && h != rung) {
          rung = h;
          rungOnScreen.value = h;
          rungKbps = (e['kbps'] as num?)?.toInt();
          PlaybackLog.add('exo rung ${h}p ${(e['kbps'] as num?)?.toInt() ?? 0} kbps');
        }
      case 'audio':
        final list = <AudioTrackInfo>[];
        String? on;
        for (final t in (e['tracks'] as List<Object?>? ?? const <Object?>[])) {
          if (t is! Map) continue;
          final tid = t['id'] as String?;
          if (tid == null) continue;
          list.add(AudioTrackInfo(
            id: tid,
            title: t['title'] as String?,
            language: t['lang'] as String?,
            codec: t['codec'] as String?,
            channels: (t['ch'] as num?)?.toInt(),
          ));
          if (t['on'] == true) on = tid;
        }
        audioTracks = list;
        audioTrackOn = on;
        audioOff = e['off'] == true;
        _audio.add(list);
      case 'tracks':
        heights = [
          for (final h in (e['heights'] as List<Object?>? ?? const <Object?>[]))
            if (h is num) h.toInt(),
        ];
        final peaks = (e['peaks'] as List<Object?>?)?.whereType<num>().map((p) => p.toInt()).toList();
        PlaybackLog.add('exo tracks ${heights.join(',')} selected=${e['selected']} '
            'adaptive=${e['adaptive']}'
            '${peaks == null || peaks.isEmpty ? '' : ' peaks=${peaks.join(',')} kbps'}');
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
        _letGo('error');
        _error.add(msg);
    }
  }

  Future<bool> _call(String method, [Map<String, Object?> args = const {}]) async {
    try {
      final ok =
          await _m.invokeMethod<bool>(method, <String, Object?>{'id': id, ...args}) ?? false;
      // ExoStreamEngine answers false for one reason only: it holds no
      // engine by this id (released, or never made in this process).
      if (!ok) _refused(method, 'no engine $id');
      return ok;
    } on PlatformException catch (e) {
      _refused(method, e.message ?? e.code);
      return false;
    } catch (e) {
      _refused(method, '$e');
      return false;
    }
  }

  /// WHY IT REFUSED, IN THE TRAIL (14 Nov 2026). After the double open the
  /// next film's open answered false within a tenth of a second and fell
  /// back to libmpv, and the trail could not say why: a missing engine and a
  /// Kotlin exception both read as false. Each method's reason once per
  /// engine; any address in a message is left out.
  final Set<String> _saidRefusals = <String>{};

  void _refused(String method, String why) {
    final plain = why
        .replaceAll(RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://\S+'), '<address>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final line = plain.length > 160 ? '${plain.substring(0, 160)}…' : plain;
    if (_saidRefusals.add('$method $line')) {
      PlaybackLog.add('exo $method refused: $line');
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
      Map<int, int> rungs = const <int, int>{},
      bool progressive = false}) {
    position = startAt ?? Duration.zero;
    ended = false;
    rung = null;
    rungOnScreen.value = null;
    _letGo('a new film');
    if (const bool.fromEnvironment('INNOCENT_LAB')) labUrl = url;
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
      // One MP4 file (a film's Original) rather than the ladder's HLS.
      'progressive': progressive,
    });
  }

  Future<bool> play() => _call('play');
  Future<bool> pause() => _call('pause');
  /// [fast]: the keyframe nearest [to] (at most a second off), for a far
  /// jump; otherwise the exact frame. [picture]: that moment's seek-bar
  /// picture, shown until the jump draws its own ([landing]).
  Future<bool> seek(Duration to, {bool fast = false, Uint8List? picture}) {
    position = to;
    _seekClock = Stopwatch()..start();
    _letGo('another jump');
    if (picture != null) {
      lastLanding = null;
      _hold(picture);
    } else {
      lastLanding = 'no picture';
    }
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

  Future<bool> stop() {
    _letGo('stopped');
    return _call('stop');
  }

  /// ♪: plays the audio track [trackId] (one of [audioTracks]).
  Future<bool> audioTrack(String trackId) =>
      _call('audioTrack', <String, Object?>{'track': trackId});

  /// ♪'s Disable: no sound at all, or back.
  Future<bool> setAudioOff(bool off) => _call('audioOff', <String, Object?>{'off': off});

  /// Synchronization: the sound [ms] later than the picture (negative:
  /// sooner) — ExoPlayer's audio clock moved (ExoAudio.kt).
  Future<bool> audioDelay(int ms) => _call('audioDelay', <String, Object?>{'ms': ms});

  /// Stereo mode: 0 stereo, 1 mono, 2 left and right swapped.
  Future<bool> stereo(int mode) => _call('stereo', <String, Object?>{'mode': mode});

  /// Night mode: loud moments down, quiet ones up.
  Future<bool> night(bool on) => _call('night', <String, Object?>{'on': on});

  /// Frames drawn and dropped so far, whether it plays, where it is.
  Future<Map<String, Object?>> stats() async {
    try {
      final r = await _m.invokeMapMethod<String, Object?>('stats', <String, Object?>{'id': id});
      return r ?? const <String, Object?>{};
    } catch (_) {
      return const <String, Object?>{};
    }
  }

  // ── THE FILM ON ITS OWN SURFACE (P1 in production, 28 Nov 2026) ─────
  // ExoStreamEngine's film surface: the film on Android's own SurfaceView
  // under Flutter's see-through surface (PlayerWindow.kt), which the
  // display composes without Flutter drawing a frame for it (Test Lab
  // 46124628533: app CPU realme 61 → 39 %, OPPO 52 → ~42 % of a core).
  // The player screen asks for it ([useSurface]) and places it
  // ([placeFilm]); [ExoVideo] in the player draws nothing while
  // [onSurface] is true, so the film shows through.

  /// The film's frame is on its own SurfaceView (Kotlin said so after the
  /// first frame landed there), not on [textureId].
  final ValueNotifier<bool> onSurface = ValueNotifier<bool>(false);

  /// What was asked last ([useSurface]); the move may still be on its way.
  bool surfaceAsked = false;

  /// The phone said no once ([useSurface]: Flutter's surface opaque, no
  /// Activity): not asked again for this engine.
  bool surfaceRefused = false;

  Stopwatch? _filmClock;
  List<int>? _placed;
  Timer? _filmWait;

  /// How long a playing film may take to show its first frame on its own
  /// surface before the texture is kept for good (this engine): a phone
  /// whose SurfaceView never draws would otherwise leave the texture's last
  /// frame standing over a film that plays on.
  static const Duration filmLandLimit = Duration(seconds: 5);

  /// The film on its own SurfaceView ([on]) or back on the texture. The
  /// move lands with the first frame on the new surface ([onSurface]).
  Future<bool> useSurface(bool on) async {
    if (on == surfaceAsked) return true;
    if (on && surfaceRefused) return false;
    surfaceAsked = on;
    _filmClock = Stopwatch()..start();
    // Not [_call]: a false here is "this phone cannot", not a lost engine.
    var ok = false;
    try {
      ok = await _m.invokeMethod<bool>(
              'filmSurface', <String, Object?>{'id': id, 'on': on}) ??
          false;
    } catch (e) {
      PlaybackLog.add('exo film: ${e.runtimeType}');
    }
    if (on && !ok) {
      surfaceAsked = false;
      surfaceRefused = true;
      _filmClock = null;
      PlaybackLog.add('exo film: no surface of its own here (the texture stays)');
    }
    _filmWait?.cancel();
    if (on && ok) _filmWait = Timer(filmLandLimit, _filmLate);
    return ok;
  }

  void _filmLate() {
    if (!surfaceAsked || onSurface.value) return;
    if (!playing || buffering) {
      // Paused or waiting for bytes: no frame is due yet.
      _filmWait = Timer(filmLandLimit, _filmLate);
      return;
    }
    PlaybackLog.add('exo film: no frame on its own surface in '
        '${filmLandLimit.inSeconds} s while playing (the texture kept)');
    surfaceRefused = true;
    // ignore: discarded_futures
    useSurface(false);
  }

  /// Where the film's SurfaceView goes: [rect] in physical pixels of
  /// Flutter's view, which is [view] pixels large. Sent when it changes.
  Future<void> placeFilm(Rect rect, Size view) async {
    final p = <int>[
      rect.left.round(),
      rect.top.round(),
      rect.width.round(),
      rect.height.round(),
      view.width.round(),
      view.height.round(),
    ];
    final last = _placed;
    if (last != null && listEquals(last, p)) return;
    _placed = p;
    await _call('filmPlace', <String, Object?>{
      'l': p[0],
      't': p[1],
      'w': p[2],
      'h': p[3],
      'vw': p[4],
      'vh': p[5],
    });
  }

  /// The frame on the film's SurfaceView, the part on screen, as a PNG
  /// (PixelCopy); null when the film is not there or the copy failed.
  Future<Uint8List?> filmShot() async {
    if (!onSurface.value) return null;
    try {
      return await _m.invokeMethod<Uint8List>('filmShot', <String, Object?>{'id': id});
    } catch (e) {
      PlaybackLog.add('exo film shot: ${e.runtimeType}');
      return null;
    }
  }

  // ── LAB ONLY (SmoothLab's `tex` and `sched` looks; PlayerLab.kt) ─────
  /// The engine made last, for a lab that has no player in hand.
  static ExoEngine? labLatest;

  /// The address this engine opened last (the local proxy's master
  /// playlist): SmoothLab copies a minute of it into a local file.
  String? labUrl;

  /// SmoothLab's `tex`: the film kept on the texture, as 1.64.90 drew it,
  /// for an A/B beside the build's own SurfaceView.
  static final ValueNotifier<bool> labTexture = ValueNotifier<bool>(false);

  /// True while libmpv draws on a SurfaceView of the lab's (`mpvsv`,
  /// `mpvembed`): the player's background is then left see-through.
  static final ValueNotifier<bool> labNative = ValueNotifier<bool>(false);

  /// ExoPlayer's dynamic scheduling, by opening the film again where it is.
  Future<bool> labSched(bool on) async {
    if (!const bool.fromEnvironment('INNOCENT_LAB')) return false;
    return _call('labSched', <String, Object?>{'on': on});
  }

  Future<void> release() async {
    _letGo('released');
    // A hold still on as the film leaves is said too: the stuck film of
    // 14 Nov ended in Back, not in a drag.
    _noteHeld('');
    _filmWait?.cancel();
    await _call('release');
    onSurface.value = false;
    surfaceAsked = false;
    await _sub?.cancel();
    await _audio.close();
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
///
/// While the film is on its own SurfaceView ([ExoEngine.onSurface]), the
/// player's own picture ([filmHost]) draws nothing but the landing picture
/// of a far jump, so the film under Flutter shows through; any other
/// (the in-app picture-in-picture window) is black until the film is back
/// on the texture — the texture then holds an old frame.
class ExoVideo extends StatelessWidget {
  const ExoVideo({
    super.key,
    required this.engine,
    this.fit = BoxFit.contain,
    this.filmHost = false,
  });

  final ExoEngine engine;
  final BoxFit fit;

  /// The player screen's picture, which the film's SurfaceView lies under.
  final bool filmHost;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: engine.onSurface,
      builder: (context, onSurface, _) {
        if (!onSurface) return _picture(film: true);
        if (!filmHost) return const ColoredBox(color: Color(0xFF000000));
        return _picture(film: false);
      },
    );
  }

  /// The texture ([film]) or nothing in its place, the landing picture over it.
  Widget _picture({required bool film}) {
    return StreamBuilder<Size?>(
      stream: engine.sizeStream,
      initialData: engine.size,
      builder: (context, snap) {
        final s = snap.data;
        if (s == null) {
          return film
              ? const ColoredBox(color: Color(0xFF000000))
              : const SizedBox.expand();
        }
        final picture = FittedBox(
          fit: fit,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: s.width,
            height: s.height,
            // The landing picture inside the same box as the texture, so
            // it takes the same fit, zoom and crop as the film.
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (film) Texture(textureId: engine.textureId),
                ValueListenableBuilder<Uint8List?>(
                  valueListenable: engine.landing,
                  builder: (context, picture, _) => picture == null
                      ? const SizedBox.shrink()
                      : Image.memory(
                          picture,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                ),
              ],
            ),
          ),
        );
        return film
            ? ColoredBox(color: const Color(0xFF000000), child: picture)
            : SizedBox.expand(child: picture);
      },
    );
  }
}
