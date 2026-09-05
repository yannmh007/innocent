import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../features/music/data/music_audio_service.dart';

/// Audit fix (Music background play / lock-screen / Bluetooth):
/// audio_service handler that wires existing MusicAudioService to
/// the OS MediaSession. Without this music stops on background.
class MusicAudioHandler extends BaseAudioHandler {
  final MusicAudioService _audio;

  VoidCallback onPlayPressed = () {};
  VoidCallback onPausePressed = () {};
  VoidCallback onSkipNextPressed = () {};
  VoidCallback onSkipPreviousPressed = () {};
  VoidCallback onStopPressed = () {};
  void Function(Duration) onSeekRequested = (_) {};

  StreamSubscription? _posSub;
  StreamSubscription? _playSub;
  StreamSubscription? _durSub;

  MusicAudioHandler(this._audio) {
    _posSub = _audio.positionStream.listen((p) => _push(position: p));
    _playSub = _audio.playingStream.listen((p) => _push(playing: p));
    _durSub = _audio.durationStream.listen((d) => _push(duration: d));
  }

  /// Last written notification-art temp file, kept so we can clean up
  /// the previous one when the track changes.
  File? _lastArtFile;

  Future<void> setNowPlaying({
    required String id,
    required String title,
    required String artist,
    required String album,
    required Duration duration,
    Uint8List? artBytes,
  }) async {
    Uri? artUri;
    // Audit fix: previously the art was embedded as a
    // `data:image/png;base64,...` URI — but the bytes are often JPEG, so
    // the hard-coded image/png MIME could make Android fail to decode it,
    // and a large base64 blob bloats the MediaItem. Writing the raw bytes
    // to a temp file lets the OS decode by content (any format) and is
    // what audio_service handles most reliably for lock-screen art.
    if (artBytes != null &&
        artBytes.isNotEmpty &&
        artBytes.length < 5 * 1024 * 1024) {
      try {
        final dir = await getTemporaryDirectory();
        final f = File(
            '${dir.path}/np_art_${id.hashCode.toRadixString(16)}.img');
        await f.writeAsBytes(artBytes, flush: true);
        artUri = Uri.file(f.path);
        final prev = _lastArtFile;
        if (prev != null && prev.path != f.path) {
          try {
            if (await prev.exists()) await prev.delete();
          } catch (e) { if (kDebugMode) debugPrint('music_audio_handler.best-effort: $e'); }
        }
        _lastArtFile = f;
      } catch (e) { if (kDebugMode) debugPrint('music_audio_handler.best-effort: $e'); }
    }
    mediaItem.add(MediaItem(
      id: id,
      title: title,
      artist: artist.isEmpty ? null : artist,
      album: album.isEmpty ? null : album,
      duration: duration > Duration.zero ? duration : null,
      artUri: artUri,
    ));
  }

  void _push({Duration? position, bool? playing, Duration? duration}) {
    final p = position ?? _audio.position;
    final isP = playing ?? _audio.isPlaying;
    playbackState.add(playbackState.value.copyWith(
      // The middle control must follow the state. It was hard-coded to
      // `pause`, so a paused track still offered a pause button — tapping it
      // asked audio_service for a state it was already in and nothing
      // happened, which reads as a dead notification.
      controls: [
        MediaControl.skipToPrevious,
        if (isP) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: AudioProcessingState.ready,
      playing: isP,
      updatePosition: p,
      bufferedPosition: p,
      speed: 1.0,
      queueIndex: 0,
    ));
  }

  @override
  Future<void> play() async => onPlayPressed();

  @override
  Future<void> pause() async => onPausePressed();

  @override
  Future<void> skipToNext() async => onSkipNextPressed();

  @override
  Future<void> skipToPrevious() async => onSkipPreviousPressed();

  @override
  Future<void> stop() async {
    onStopPressed();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async => onSeekRequested(position);

  Future<void> disposeHandler() async {
    await _posSub?.cancel();
    await _playSub?.cancel();
    await _durSub?.cancel();
  }
}
