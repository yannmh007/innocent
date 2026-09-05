import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/brightness/brightness_service.dart';
import '../services/audio_extraction/audio_extraction_service.dart';
import '../services/permission/permission_service.dart';
import '../services/pip/pip_service.dart';
import '../services/playback/background_playback_service.dart';
import '../services/audio_focus/audio_focus_service.dart';
import '../services/resume/resume_storage.dart';
import '../services/video_player/media_kit_player_service.dart';
import '../services/video_player/video_player_service.dart';
import '../services/volume/volume_service.dart';

/// VideoPlayerService — THE swap point for engine changes
final videoPlayerServiceProvider = Provider<VideoPlayerService>((ref) {
  final service = MediaKitPlayerService();
  service.initialize();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Scoped playback-position stream. The player screen used to rebuild
/// its whole 2300-line tree on every position tick; the controller now
/// quantises position-into-state to 1/sec, and the seek bar reads this
/// provider directly so ONLY the bottom bar (slider + elapsed label)
/// rebuilds at the engine's native cadence — smooth scrubbing without
/// the rest of the UI churning. media_kit's position stream is a
/// broadcast stream, so this extra listener coexists with the
/// controller's own subscription.
final videoPositionProvider = StreamProvider.autoDispose<Duration>((ref) {
  final svc = ref.watch(videoPlayerServiceProvider);
  return svc.positionStream;
});

/// How far ahead the demuxer has read. Backs the Debug overlay's buffer line.
///
/// autoDispose, like the position stream beside it: nothing subscribes unless
/// the overlay is actually on screen, so leaving the switch off costs nothing.
final videoBufferedProvider = StreamProvider.autoDispose<Duration>((ref) {
  final svc = ref.watch(videoPlayerServiceProvider);
  return svc.bufferedStream;
});

final permissionServiceProvider = Provider<PermissionService>((ref) {
  return PermissionServiceImpl();
});

final brightnessServiceProvider = Provider<BrightnessService>((ref) {
  return BrightnessServiceImpl();
});

final volumeServiceProvider = Provider<VolumeService>((ref) {
  return VolumeServiceImpl();
});

/// Audio extraction ("Convert to Audio"): a single instance so its progress
/// notifier is shared across any UI observing the current extraction.
final audioExtractionServiceProvider =
    Provider<AudioExtractionService>((ref) {
  return AudioExtractionService();
});

/// Phase 3: Resume storage
final resumeStorageProvider = Provider<ResumeStorage>((ref) {
  return ResumeStorage();
});

/// Phase 45: Android system Picture-in-Picture. Singleton because the
/// `mx_clone/pip` MethodChannel is per-FlutterEngine and we want the
/// same instance to handle both `enterPip` calls and the inbound
/// `onUserLeaveHint` / `onPipModeChanged` events.
final pipServiceProvider = Provider<PipService>((ref) {
  return PipService();
});

/// Phase 45: lightweight wrapper around the Android foreground service
/// that keeps audio playback alive when the app is backgrounded or the
/// screen is off. The Activity is the one keeping libmpv running; the
/// service just stops Android from killing our process under Doze.
final backgroundPlaybackServiceProvider = Provider<BackgroundPlaybackService>(
  (ref) => BackgroundPlaybackService(),
);

/// Phase 45: Android audio focus management. Singleton because the
/// `mx_clone/audio_focus` MethodChannel is per-FlutterEngine. The
/// service forwards focus-loss / focus-gain events to whoever sets
/// `onFocusEvent` — typically the player controller.
final audioFocusServiceProvider = Provider<AudioFocusService>(
  (ref) => AudioFocusService(),
);
