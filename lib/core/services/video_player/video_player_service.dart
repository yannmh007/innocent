import 'package:flutter/widgets.dart';
import 'models/audio_track_info.dart';
import 'models/subtitle_track_info.dart';
import 'models/video_track_info.dart';

/// Abstract video player service.
///
/// Key abstraction: UI never imports media_kit directly.
/// This allows swapping to better_player or any other engine
/// without touching UI code.
abstract class VideoPlayerService {
  // === Streams ===
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get bufferingStream;
  Stream<Duration> get bufferedStream;
  Stream<List<AudioTrackInfo>> get audioTracksStream;
  Stream<List<SubtitleTrackInfo>> get subtitleTracksStream;
  Stream<List<VideoTrackInfo>> get videoTracksStream;
  Stream<double> get volumeStream;
  Stream<double> get rateStream;
  Stream<String?> get errorStream;
  Stream<bool> get completedStream;

  // === Synchronous getters ===
  Duration get position;
  Duration get duration;
  bool get isPlaying;
  bool get isInitialized;

  // === Lifecycle ===
  Future<void> initialize();
  Future<void> open(String uri, {Duration? startAt, bool autoplay = true});
  Future<void> dispose();

  // === Playback control ===
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> stop();
  Future<void> seek(Duration to);
  Future<void> seekRelative(Duration delta);

  /// Advance or rewind exactly one frame, pausing first.
  ///
  /// v1.63 — one of the few things MX Player does that this player could not.
  /// It is not a very small seek: at 24 fps a frame is 41.7 ms and seeking by
  /// a fixed duration lands wherever the nearest decodable point happens to
  /// be, which on a long-GOP file can be seconds away. libmpv has real
  /// frame-stepping commands that decode exactly one frame, so this asks for
  /// those and falls back to nothing rather than to a bad approximation.
  ///
  /// [forward] false steps back, which mpv itself documents as less exact —
  /// it works by seeking behind and re-decoding forward.
  Future<void> frameStep({bool forward = true});

  // === Audio ===
  Future<void> setVolume(double volume); // 0.0 - 1.0
  Future<void> setAudioTrack(AudioTrackInfo track);

  // === Speed ===
  Future<void> setRate(double rate); // 0.25 - 4.0

  // === Subtitle ===
  Future<void> setSubtitleTrack(SubtitleTrackInfo? track);
  Future<void> loadExternalSubtitle(String path);
  Future<void> setSubtitleDelay(Duration delay);
  Future<void> setSubtitleSize(double size);

  // === Phase 45: powerful-player extensions ===
  /// Switch the hardware-decoder strategy. See implementation doc for
  /// the supported values.
  Future<void> setHardwareDecoder(String mode);

  /// Update the subtitle styling baseline (color, border, shadow, font).
  Future<void> setSubtitleStyle({
    String? color,
    String? borderColor,
    double? borderSize,
    String? shadowColor,
    double? shadowOffset,
    String? font,
  });

  /// Network read timeout in seconds.
  Future<void> setNetworkTimeout(int seconds);

  /// Demuxer-cache ceiling in megabytes.
  Future<void> setDemuxerCacheMb(int mb);

  /// Apply an audio gain multiplier (1.0 = unity, 2.0 = +6 dB, …).
  Future<void> setAudioGain(double multiplier);

  /// Phase 45 (audit): global audio delay in milliseconds (-2000..+2000).
  Future<void> setAudioDelayMs(int ms);

  /// Phase 45 (audit): global subtitle delay in milliseconds (-10000..+10000).
  Future<void> setSubtitleDelayMs(int ms);

  /// Phase 45 (audit): subtitle encoding override. Empty = auto-detect.
  Future<void> setSubtitleCharset(String charset);

  /// Phase 45 (audit): preferred audio language ISO code. Empty = no
  /// preference (libmpv picks the default track).
  Future<void> setPreferredAudioLanguage(String code);

  /// Phase 45 (audit): preferred subtitle language ISO code.
  Future<void> setPreferredSubtitleLanguage(String code);

  /// Phase 45 (audit): custom HTTP User-Agent for network streams.
  Future<void> setHttpUserAgent(String userAgent);

  /// Phase 45 (audit refined): explicit aspect ratio override. Pass
  /// `null` to use the file's intrinsic aspect. Maps to libmpv's
  /// `video-aspect-override` property.
  Future<void> setAspectRatioOverride(double? aspect);

  /// Zoom the video to fill the window while keeping aspect ratio.
  /// 0.0 = letterbox (fit), 1.0 = fill (zoom). Maps to libmpv `panscan`.
  Future<void> setPanscan(double value);

  /// Phase 45 (audit refined, build 63): MX Player V3 `audio_device`.
  /// Pass 'auto' (or empty) to let libmpv pick the system route.
  Future<void> setAudioDevice(String device);

  /// Phase 45 (audit refined, build 63): MX Player V3
  /// `prefer_audio_passthrough_mode`. When ON, pass Dolby/DTS
  /// bitstream untouched to the receiver.
  Future<void> setAudioPassthrough(bool enabled);

  /// Keep audio decoding alive when the app is backgrounded / screen is off.
  /// When [enabled], libmpv is told not to depend on its video surface so
  /// the audio thread keeps running with the display gone; when disabled,
  /// normal foreground playback resumes. Fixes intermittent "playback stops
  /// on sleep" for background-play video.
  Future<void> setBackgroundAudioMode(bool enabled);

  // === UI rendering ===
  Widget buildVideoWidget({BoxFit fit = BoxFit.contain});
}
