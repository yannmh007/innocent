import 'dart:async';

import 'package:flutter/material.dart';
import 'package:innocent/core/services/video_player/models/audio_track_info.dart';
import 'package:innocent/core/services/video_player/models/subtitle_track_info.dart';
import 'package:innocent/core/services/video_player/models/video_track_info.dart';
import 'package:innocent/core/services/video_player/video_player_service.dart';

/// A player engine for widget tests of the player screen: no libmpv, no
/// ExoPlayer, no platform channel. It "opens" anything at once, reports a
/// film of [filmLength] paused or playing at [startPosition], and draws a
/// still frame in place of the picture, so the screen's controls can be
/// laid out, tapped and photographed (test/player_layout_test.dart).
class FakePlayerService implements VideoPlayerService {
  FakePlayerService({
    this.filmLength = const Duration(hours: 1, minutes: 29, seconds: 22),
    this.startPosition = const Duration(minutes: 12, seconds: 34),
    this.audioTracks = const <AudioTrackInfo>[],
    this.subtitleTracks = const <SubtitleTrackInfo>[],
    this.videoSize = const Size(1920, 1080),
  }) : _position = startPosition;

  final Duration filmLength;
  final Duration startPosition;
  final List<AudioTrackInfo> audioTracks;
  final List<SubtitleTrackInfo> subtitleTracks;
  final Size videoSize;

  /// Every call the screen made, by name, for tests that check a button
  /// reached the engine.
  final List<String> calls = <String>[];

  Duration _position;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _initialized = false;
  double _rate = 1.0;

  final _positionC = StreamController<Duration>.broadcast();
  final _durationC = StreamController<Duration>.broadcast();
  final _playingC = StreamController<bool>.broadcast();
  final _bufferingC = StreamController<bool>.broadcast();
  final _bufferedC = StreamController<Duration>.broadcast();
  final _audioC = StreamController<List<AudioTrackInfo>>.broadcast();
  final _subsC = StreamController<List<SubtitleTrackInfo>>.broadcast();
  final _videoC = StreamController<List<VideoTrackInfo>>.broadcast();
  final _volumeC = StreamController<double>.broadcast();
  final _rateC = StreamController<double>.broadcast();
  final _errorC = StreamController<String?>.broadcast();
  final _completedC = StreamController<bool>.broadcast();

  @override
  Stream<Duration> get positionStream => _positionC.stream;
  @override
  Stream<Duration> get durationStream => _durationC.stream;
  @override
  Stream<bool> get playingStream => _playingC.stream;
  @override
  Stream<bool> get bufferingStream => _bufferingC.stream;
  @override
  Stream<Duration> get bufferedStream => _bufferedC.stream;
  @override
  Stream<List<AudioTrackInfo>> get audioTracksStream => _audioC.stream;
  @override
  Stream<List<SubtitleTrackInfo>> get subtitleTracksStream => _subsC.stream;
  @override
  Stream<List<VideoTrackInfo>> get videoTracksStream => _videoC.stream;
  @override
  Stream<double> get volumeStream => _volumeC.stream;
  @override
  Stream<double> get rateStream => _rateC.stream;
  @override
  Stream<String?> get errorStream => _errorC.stream;
  @override
  Stream<bool> get completedStream => _completedC.stream;

  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  bool get isPlaying => _playing;
  @override
  bool get isInitialized => _initialized;

  /// Puts a playback error on the engine's error stream, as libmpv would.
  void failWith(String message) => _errorC.add(message);

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    _initialized = true;
  }

  @override
  Future<void> open(String uri, {Duration? startAt, bool autoplay = true}) async {
    calls.add('open');
    _initialized = true;
    _duration = filmLength;
    _position = startAt ?? startPosition;
    _playing = autoplay;
    _durationC.add(_duration);
    _positionC.add(_position);
    _bufferingC.add(false);
    _playingC.add(_playing);
    // As media_kit sends them: its two pseudo-tracks first.
    _audioC.add(<AudioTrackInfo>[
      const AudioTrackInfo(id: 'auto'),
      const AudioTrackInfo(id: 'no'),
      ...audioTracks,
    ]);
    _subsC.add(<SubtitleTrackInfo>[
      const SubtitleTrackInfo(id: 'auto'),
      const SubtitleTrackInfo(id: 'no'),
      ...subtitleTracks,
    ]);
    _videoC.add(<VideoTrackInfo>[
      VideoTrackInfo(
        id: '1',
        width: videoSize.width.round(),
        height: videoSize.height.round(),
      ),
    ]);
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }

  /// Closes every stream; the test's own teardown, once the screen is gone.
  Future<void> close() async {
    await _positionC.close();
    await _durationC.close();
    await _playingC.close();
    await _bufferingC.close();
    await _bufferedC.close();
    await _audioC.close();
    await _subsC.close();
    await _videoC.close();
    await _volumeC.close();
    await _rateC.close();
    await _errorC.close();
    await _completedC.close();
  }

  @override
  Future<void> play() async {
    calls.add('play');
    _playing = true;
    _playingC.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playing = false;
    _playingC.add(false);
  }

  @override
  Future<void> playOrPause() => _playing ? pause() : play();

  @override
  Future<void> stop() async {
    calls.add('stop');
    _playing = false;
    _playingC.add(false);
  }

  @override
  Future<void> seek(Duration to) async {
    calls.add('seek');
    _position = to;
    _positionC.add(to);
  }

  @override
  Future<void> seekRelative(Duration delta) => seek(_position + delta);

  @override
  Future<void> setRate(double rate) async {
    calls.add('setRate');
    _rate = rate;
    _rateC.add(_rate);
  }

  @override
  Widget buildVideoWidget({BoxFit fit = BoxFit.contain}) => Center(
        child: AspectRatio(
          aspectRatio: videoSize.width / videoSize.height,
          child: const _StillFrame(),
        ),
      );

  /// Everything else the screen may ask of an engine: accepted, recorded,
  /// and done at once.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName.toString());
    if (invocation.isMethod) return Future<void>.value();
    return super.noSuchMethod(invocation);
  }
}

/// A frame of "film": sky, sun, hills, so a screenshot shows where the
/// picture is and what the controls cover.
class _StillFrame extends StatelessWidget {
  const _StillFrame();

  @override
  Widget build(BuildContext context) => const CustomPaint(painter: _Scene());
}

class _Scene extends CustomPainter {
  const _Scene();

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(
      r,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF2B5876), Color(0xFFE9A16B)],
        ).createShader(r),
    );
    canvas.drawCircle(Offset(size.width * 0.72, size.height * 0.38),
        size.height * 0.11, Paint()..color = const Color(0xFFFFE08A));
    final hills = Path()
      ..moveTo(0, size.height * 0.78)
      ..quadraticBezierTo(size.width * 0.25, size.height * 0.55,
          size.width * 0.5, size.height * 0.74)
      ..quadraticBezierTo(
          size.width * 0.78, size.height * 0.9, size.width, size.height * 0.66)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(hills, Paint()..color = const Color(0xFF1E3B2F));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
