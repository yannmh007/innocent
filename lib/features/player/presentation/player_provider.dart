import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as p;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/haptic/haptic_service.dart';
import '../../../core/services/connectivity/connectivity_service.dart';
import '../../../core/services/adb/adb_service.dart';
import '../../../core/di/core_providers.dart';
import '../../../core/services/diagnostics/playback_log.dart';
import '../../../core/di/preferences_provider.dart';
import '../../../core/services/video_player/media_kit_player_service.dart';
import '../../../core/services/video_player/stall_diagnosis.dart';
import '../../../core/services/video_player/stream_renewal.dart';
import '../../user_data/domain/user_data_models.dart';
import '../../user_data/user_data_providers.dart';
import '../../local_browser/presentation/library_provider.dart';
import '../../music/presentation/music_providers.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/video_player/models/audio_track_info.dart';
import '../../../core/services/video_player/models/subtitle_track_info.dart';
import '../../../core/services/audio_focus/audio_focus_service.dart';
import '../../../core/services/subtitles/subtitle_download_service.dart';
import '../../../core/services/video_player/models/video_track_info.dart';
import '../../equalizer/presentation/equalizer_screen.dart'
    show equalizerServiceProvider;
import 'aspect_ratio_mode.dart';
import 'shortcut_item.dart';
import 'widgets/sleep_timer_dialog.dart';
// v1.63: the canonical subtitle-format list, used by the sidecar scan in
// player_controller_gestures.dart (a `part of` this library).
import '../../../core/services/subtitles/subtitle_formats.dart';

part 'player_state.dart';
part 'player_controller_playback.dart';
part 'player_controller_navigation.dart';
part 'player_controller_tracks.dart';
part 'player_controller_controls.dart';
part 'player_controller_modes.dart';
part 'player_controller_gestures.dart';

// Library-level constants shared by the controller extensions. Declared
// top-level (not as extension statics) so every part file references them
// unqualified without an extension-name prefix.
const Duration _seekThrottle = Duration(milliseconds: 60);

/// How far into a video Previous stops meaning "the previous file" and starts
/// meaning "restart this one". Top-level rather than an extension static for
/// the same reason as the constants around it: extension members are awkward
/// to reference unqualified from sibling part files.
const Duration _smartPreviousThreshold = Duration(seconds: 5);
const List<double> _speedSteps = [0.25, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0];

// ── how long the player waits before it says anything ────────────────────
//
// FOUR NUMBERS, NOT TWO, because opening a stream and running dry during one
// are different events. The pairs are deliberately far apart:
//
//   * opening is expected to take a moment, so the caption is late and the
//     give-up is very late — abandoning a start is strictly worse than a
//     slow one, since the retry pays the entire cost again;
//   * a refill mid-film is not expected at all, so it is called out quickly
//     and abandoned sooner: at that point the stream has already proved it
//     can be read, and twenty seconds of nothing means it stopped being
//     readable.
const Duration _openHintAfter = Duration(seconds: 6);
const Duration _openGiveUpAfter = Duration(seconds: 40);
const Duration _stallHintAfter = Duration(seconds: 3);
const Duration _stallGiveUpAfter = Duration(seconds: 20);

class PlayerController extends StateNotifier<PlayerState> {
  final Ref _ref;
  final List<StreamSubscription> _subs = [];
  Timer? _hideControlsTimer;
  Timer? _indicatorTimer;
  Timer? _autoSaveTimer;
  Timer? _sleepTimerTicker;
  /// Audit + industry pattern: fires after 10s of continuous network
  /// buffering, surfacing a clear "playback stalled" message so the
  /// user doesn't sit watching a spinner with no explanation.
  Timer? _bufferStallTimer;
  /// Audit fix (C4): tier-1 timer at 3 s of continuous network
  /// buffering — soft "slow connection" hint, supersedes by the
  /// 10 s hard "stalled" error if buffering doesn't recover.
  Timer? _bufferSlowTimer;
  /// Debounce timer for the buffering SPINNER. A brief buffer refill
  /// after a seek/skip should not flash a loading circle, so the spinner
  /// only appears if buffering is still active after this delay.
  Timer? _bufferSpinnerTimer;
  /// True once the current file has produced a frame.
  ///
  /// The whole of the buffering watchdog hangs off this one bool. Before the
  /// first frame the player is OPENING, and a wait means the stream is being
  /// set up; after it, a wait means the stream fell behind. Those are
  /// different events with different honest sentences and very different
  /// patience, and merging them is what produced "Slow connection" on a
  /// 13 MB/s link.
  bool _firstFrameSeen = false;

  /// When the current file was handed to libmpv. Used only to measure the
  /// black screen, never to decide anything.
  DateTime? _openStartedAt;

  /// Called once per file with the measured time to first frame, so the
  /// feature that knows what a title is can report it. Null for local
  /// playback, which has nobody to report to.
  void Function(Duration openTook)? onFirstFrame;

  /// Called when playback stops mid-film for long enough to matter, with the
  /// measured reason. Null for local playback, which has nobody to report to.
  ///
  /// THE CALLBACK, AND NOT A REPORT FROM HERE, for the same reason
  /// [onFirstFrame] is: this controller plays local files, music and vault
  /// content as well as catalogue titles, and none of those has a title id or
  /// belongs in the event log.
  void Function(StallDiagnosis reason)? onStall;

  /// The decoder's cumulative drop count at the last reading. The property is
  /// a running total for the whole file, so without this every stall after
  /// the first would inherit the first one's drops and be filed as a decode
  /// problem for the rest of the film.
  int _droppedAtLastStall = 0;

  /// How many stalls have been reported for this playback.
  ///
  /// CAPPED, because the failure this diagnoses is one that repeats every two
  /// seconds. Six samples say what is happening; six hundred would be the app
  /// answering a bad connection by making more requests on it.
  int _stallsReported = 0;
  static const int _maxStallReports = 6;

  Duration? _seekStartPosition;
  bool _wasLongPressActive = false;
  double _volumeBeforeMute = 0.5;
  String? _currentUri;

  /// Privacy flag: true when the current video is a Private Folder item.
  /// While set, the player MUST NOT persist any trace of it to shared
  /// storage — no resume position, no "last playing" crash marker, no
  /// watch-history record. Otherwise a vault video would surface in the
  /// public Local tab (Continue Watching / "Resume X?" prompt), which
  /// defeats the whole point of the vault.
  bool _isPrivate = false;

  /// True when the current URI is NOT A STABLE IDENTITY.
  ///
  /// A signed, expiring stream URL is a different string every time the same
  /// title is opened, so writing it to resume storage or history does three
  /// wrong things at once:
  ///
  ///   * resume never works, because the key never matches twice — every film
  ///     restarts at 00:00 and Continue Watching fills with duplicates of the
  ///     same title;
  ///   * the title leaks OUT of the feature it belongs to. Video Hub entries
  ///     would appear in the Local tab's Continue Watching row, the Resume
  ///     FAB and the cold-start "Resume X?" prompt — all of which sit in front
  ///     of the age gate rather than behind it;
  ///   * tapping one of those entries opens a URL that expired hours ago and
  ///     reads as a broken app.
  ///
  /// Deliberately separate from [_isPrivate]: that flag also forces a pause on
  /// every background transition and holds FLAG_SECURE, which is right for a
  /// vault item and wrong for a streamed one. This flag says only "do not
  /// write this string down".
  bool _isEphemeral = false;

  /// Phase 45: guards against piling up retries when libmpv emits the
  /// same error multiple times in quick succession during a network
  /// glitch. Cleared when the retry attempt completes (success or fail).
  bool _networkRetryInFlight = false;

  /// Phase 41: tracks whether we've already opened a file in this player
  /// session. Used by the "Resume only the first file" setting
  /// (Settings → Player → Playback): when on, only the first file's
  /// saved position is restored — subsequent files in a multi-file
  /// playback session start from the beginning.
  bool _hasOpenedFirstFile = false;

  PlayerController(this._ref) : super(const PlayerState()) {
    _attachListeners();
    _initializeSystemValues();
    // Phase 45: react to settings changes while a file is playing.
    // Without this, the user has to re-open the video for Settings →
    // Subtitle / Audio toggles to take effect, which a powerful video
    // player should never require.
    _ref.listen<PlayerSettings>(playerSettingsProvider, (prev, next) {
      _applyLiveSettingChanges(prev, next);
    });
    // Audit fix (B3): also react to ExtraSettings (Int/String values)
    // changes mid-playback. Previously the user had to exit and
    // re-open the player to see subtitle-scale changes take effect.
    _ref.listen<ExtraSettings>(extraSettingsProvider, (prev, next) {
      _applyLiveExtraSettingChanges(prev, next);
    });
    // Phase 45: hook up Android audio focus events. Phone calls,
    // navigation prompts, other media apps starting playback — all
    // route through OnAudioFocusChangeListener. We pause on losses
    // and (optionally) resume on regain. Using the broadcast stream
    // means Music can subscribe to the same events independently.
    final focusSvc = _ref.read(audioFocusServiceProvider);
    _focusSub = focusSvc.events.listen(_handleAudioFocusEvent);
    // Claim focus once on construction. Reference-counted so Music
    // can also claim/release without us stepping on each other.
    //
    // Settings → Player → "Play alone" decides whether we claim it at all. On,
    // we take focus and other apps stop; off, we leave their audio alone and
    // mix with it. The switch had no reader, so focus was always claimed. We
    // still SUBSCRIBE to focus events either way — a phone call must duck the
    // video whether or not we asked for exclusivity.
    if (_ref.read(playerSettingsProvider).get(PlayerSetting.playAlone)) {
      focusSvc.request();
    }
    _attachScreenStateHandlers();
  }

  /// v1.51 — THE background-play-on-screen-off fix.
  ///
  /// Owned by the CONTROLLER and not by the player screen on purpose. The
  /// screen is popped when the user sends the video to the in-app floating
  /// window, but the controller (and libmpv) live on — so a handler that
  /// belonged to the screen would go missing in exactly the case where the
  /// user is most likely to lock the phone next.
  void _attachScreenStateHandlers() {
    try {
      final bg = _ref.read(backgroundPlaybackServiceProvider);
      bg.onScreenOff = _handleScreenOff;
      bg.onScreenOn = _handleScreenOn;
      bg.onPlaybackAction = _handleNotificationAction;
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerProvider.screenState: $e');
    }
  }

  /// The display just went off — Android's own ACTION_SCREEN_OFF, forwarded
  /// natively, which is both earlier and less ambiguous than any Flutter
  /// lifecycle callback.
  ///
  /// Why the hurry: media_kit hands libmpv a SurfaceTexture whose consumer is
  /// Flutter's raster thread. The moment the display goes off that thread
  /// stops, nothing calls updateTexImage any more, and the producer blocks
  /// inside dequeueBuffer as soon as the queue is full — which at 30 fps is
  /// about a tenth of a second. A blocked core cannot process the property
  /// write that would have released it, so anything that arrives late is not
  /// a late fix, it is no fix at all. Releasing the video track here, before
  /// the first undrained frame, is what keeps the audio thread running.
  void _handleScreenOff() {
    PlaybackLog.add('SCREEN_OFF mounted=$mounted '
        'bg=${mounted ? state.isBackgroundPlay : null} '
        'priv=$_isPrivate '
        'sysPip=${mounted ? state.inSystemPip : null} '
        'playing=${mounted ? state.isPlaying : null}');
    if (!mounted) return;
    if (!state.isBackgroundPlay || _isPrivate) return;
    // System PiP keeps a live, system-owned surface and the picture is the
    // entire point there — leave it attached.
    if (state.inSystemPip) return;
    // ignore: discarded_futures
    setBackgroundAudioMode(true);
    // The screen going off is precisely the moment before the lock screen is
    // shown, so this is the one place worth pushing session state unprompted:
    // it is the last chance to make the media card truthful, and it is a
    // single channel call rather than a ticker.
    try {
      // ignore: discarded_futures
      _ref.read(backgroundPlaybackServiceProvider).update(
            title: _currentVideoTitle ?? 'Innocent',
            isPlaying: state.isPlaying,
            position: _livePosition(),
            duration: _liveDuration(),
          );
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerProvider.screenOff: $e');
    }
    // The foreground service is what stops Android freezing the process once
    // the screen is off, and its partial WakeLock is what stops the CPU
    // suspending libmpv's audio thread. start() is idempotent, so asserting
    // it here costs nothing and closes the window where playback had just
    // started and the service had not caught up.
    if (state.isPlaying) {
      _updateBackgroundWakeLock(true);
    }
  }

  /// The display came back on.
  ///
  /// Normally the picture is restored by the player screen's `resumed`
  /// callback, and that is the right place for it: the screen can be on while
  /// the app is still behind the keyguard, and reattaching there would put
  /// libmpv straight back into the surface it cannot draw to.
  ///
  /// This is the safety net for the OEM builds this codebase has already been
  /// bitten by, where screen-off arrives as `inactive` and the activity is
  /// never actually paused — so there is no `paused`, and therefore no
  /// `resumed` to come back on. The lifecycle state is the guard: we only
  /// reattach when Flutter itself already considers us foreground.
  void _handleScreenOn() {
    if (!mounted) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    // ignore: discarded_futures
    setBackgroundAudioMode(false);
  }

  /// A transport command arrived — from the notification's own buttons, or
  /// (v1.55) from the MediaSession: the lock screen, the shade's media panel,
  /// a headset button, a car head unit, a watch.
  ///
  /// `play` and `pause` are separate from `play_pause` on purpose. A button
  /// press is a toggle and genuinely means "whatever the opposite is", but a
  /// session command is a statement about the state the system wants — and
  /// answering it with a toggle inverts playback whenever the two disagree,
  /// which is exactly what happens when a command is delivered twice or
  /// arrives while our own state is a frame behind.
  void _handleNotificationAction(String action, int positionMs) {
    if (!mounted) return;
    switch (action) {
      case 'play_pause':
        if (state.isPlaying) {
          // ignore: discarded_futures
          pause();
        } else {
          // ignore: discarded_futures
          play();
        }
        break;
      case 'play':
        if (!state.isPlaying) {
          // ignore: discarded_futures
          play();
        }
        break;
      case 'pause':
        if (state.isPlaying) {
          // ignore: discarded_futures
          pause();
        }
        break;
      case 'next':
        // ignore: discarded_futures
        playNextInFolder();
        break;
      case 'previous':
        // ignore: discarded_futures
        playPreviousInFolder();
        break;
      case 'seek':
        if (positionMs >= 0) {
          // ignore: discarded_futures
          seek(Duration(milliseconds: positionMs));
        }
        break;
      case 'stop':
        // ignore: discarded_futures
        stopPlayback();
        stopBackgroundPlaybackService();
        break;
    }
  }

  /// Drop our claim on the shared background-playback callbacks.
  ///
  /// v1.51 tried to be clever here and hand these OVER to closures bound to
  /// the app-scoped player service, so that playback surviving a Back press
  /// would still have working notification buttons. v1.55 removed the thing
  /// that made that necessary: playback no longer survives a Back press at
  /// all, because playback nobody owns is exactly what produced the pile-up
  /// (see the long note in PlayerScreen.dispose). With the controller once
  /// again outliving every note libmpv plays, clearing is not only correct,
  /// it is the only thing that can be correct — the alternative left live
  /// callbacks pointing into a notifier that no longer exists.
  void _detachScreenStateHandlers() {
    try {
      final bg = _ref.read(backgroundPlaybackServiceProvider);
      bg.onScreenOff = null;
      bg.onScreenOn = null;
      bg.onPlaybackAction = null;
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerProvider.screenState: $e');
    }
  }

  /// Phase 45: audio focus event subscription. Cancelled in dispose.
  StreamSubscription<AudioFocusEvent>? _focusSub;

  /// Phase 45: tracks whether we paused due to an audio-focus loss so
  /// we know whether to auto-resume on focus regain. Manual pauses
  /// (user tapped the button) leave this false.
  bool _pausedByFocusLoss = false;

  /// Keep the background-play foreground service (and its partial WakeLock)
  /// alive only while audio is genuinely being produced.
  ///
  /// BATTERY/HEAT FIX — the service used to be tied to the background-play
  /// TOGGLE, not to playback. Leaving a video paused with the toggle on held a
  /// partial WakeLock for as long as the player existed, keeping the CPU from
  /// sleeping with nothing to decode. It now stops after a short paused grace
  /// period and restarts the instant playback resumes. The user's toggle state
  /// is untouched, so nothing about the feature changes from their side.
  void _updateBackgroundWakeLock(bool playing) {
    PlaybackLog.add('wakelock playing=$playing bg=${state.isBackgroundPlay} '
        'priv=$_isPrivate');
    if (!state.isBackgroundPlay || _isPrivate) return;
    _bgPauseTimer?.cancel();
    _bgPauseTimer = null;
    if (playing) {
      try {
        // Progress goes with it: the MediaSession extrapolates elapsed time
        // from position + speed + the moment we last told it, so pushing on
        // real state changes is enough and pushing on every tick is waste.
        // ignore: discarded_futures
        _ref.read(backgroundPlaybackServiceProvider).start(
              title: _currentVideoTitle ?? 'Innocent',
              position: _livePosition(),
              duration: _liveDuration(),
            );
      } catch (e) {
        if (kDebugMode) debugPrint('PlayerProvider.bg-wakelock: $e');
      }
      return;
    }
    // Paused: reflect it on the notification straight away, so the button the
    // user is looking at matches what the player is doing. (The service
    // itself is torn down later, by the grace timer below.)
    try {
      // ignore: discarded_futures
      _ref.read(backgroundPlaybackServiceProvider).update(
            title: _currentVideoTitle ?? 'Innocent',
            isPlaying: false,
            position: _livePosition(),
            duration: _liveDuration(),
          );
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerProvider.bg-wakelock: $e');
    }
    // Paused: give a normal pause-and-resume a moment before tearing the
    // service down, so the notification does not flicker on every tap.
    _bgPauseTimer = Timer(const Duration(seconds: 45), () {
      if (!mounted || state.isPlaying) return;
      try {
        _ref.read(backgroundPlaybackServiceProvider).stop();
      } catch (e) {
        if (kDebugMode) debugPrint('PlayerProvider.bg-wakelock: $e');
      }
    });
  }

  /// Phase 45: handle Android audio-focus events.
  void _handleAudioFocusEvent(AudioFocusEvent event) {
    if (!mounted) return;
    final svc = _ref.read(videoPlayerServiceProvider);
    switch (event) {
      case AudioFocusEvent.loss:
        // Permanent loss — user switched to another media app. Pause
        // and forget so we don't auto-resume later.
        if (state.isPlaying) {
          svc.pause();
          _pausedByFocusLoss = false; // permanent
        }
        break;
      case AudioFocusEvent.lossTransient:
      case AudioFocusEvent.lossTransientCanDuck:
        // Phone call, notification reading, navigation voice — pause
        // and remember so we can resume when focus returns. We treat
        // ducking the same as transient because powerful video players
        // pause cleanly rather than play under a voice prompt.
        if (state.isPlaying) {
          svc.pause();
          _pausedByFocusLoss = true;
        }
        break;
      case AudioFocusEvent.gain:
        // The interruption ended. Auto-resume iff WE were the ones
        // who paused for the interruption. If the user paused
        // manually mid-call, respect that and don't fight them.
        if (_pausedByFocusLoss && !state.isPlaying) {
          svc.play();
        }
        _pausedByFocusLoss = false;
        break;
    }
  }

  /// Phase 45: when a single setting that we can apply mid-playback
  /// changes, push it into libmpv directly. Settings that require a
  /// file re-open (decoder strategy) are still applied via openVideo.
  Future<void> _applyLiveSettingChanges(
      PlayerSettings? prev, PlayerSettings next) async {
    if (_currentUri == null) return;
    final svc = _ref.read(videoPlayerServiceProvider);
    try {
      // Subtitle bold / background visual style.
      if (prev == null ||
          prev.get(PlayerSetting.subTextBold) !=
              next.get(PlayerSetting.subTextBold) ||
          prev.get(PlayerSetting.subLayoutShowBackground) !=
              next.get(PlayerSetting.subLayoutShowBackground)) {
        final bold = next.get(PlayerSetting.subTextBold);
        final background = next.get(PlayerSetting.subLayoutShowBackground);
        // AUDIT FIX — bold used to be faked with sub-border-size (the same
        // property the border-style picker owns, so the two cancelled each
        // other out) and "show background" was routed into the SHADOW colour,
        // so it never drew the panel the setting promises. Bold now uses
        // libmpv's own `sub-bold`, and the background re-composes the user's
        // chosen colour + opacity with the toggle acting as the master gate.
        if (svc is MediaKitPlayerService) {
          await svc.setSubtitleBold(bold);
          final ex = _ref.read(extraSettingsProvider);
          await svc.setSubtitleBackgroundColor(
            ex.getInt(IntSetting.subtitleBackgroundColor),
            background ? ex.getInt(IntSetting.subtitleBackgroundOpacity) : 0,
          );
        }
      }
      // Audio booster on/off — re-apply the multiplier.
      if (prev == null ||
          prev.get(PlayerSetting.audioVolumeBoost) !=
              next.get(PlayerSetting.audioVolumeBoost)) {
        final boostOn = next.get(PlayerSetting.audioVolumeBoost);
        final mult = _ref.read(preferencesProvider).audioVolumeBoost;
        if (boostOn && mult > 1.0) {
          await svc.setAudioGain(mult.clamp(1.0, 4.0));
        } else {
          await svc.setAudioGain(1.0);
        }
      }
      // The four libmpv-backed switches, applied live. Every one of them is
      // a single property write, so making the user leave the player and come
      // back would have been pure friction.
      if (svc is MediaKitPlayerService) {
        if (prev == null ||
            prev.get(PlayerSetting.fastSeeking) !=
                next.get(PlayerSetting.fastSeeking)) {
          await svc.setFastSeeking(next.get(PlayerSetting.fastSeeking));
        }
        if (prev == null ||
            prev.get(PlayerSetting.decDeinterlace) !=
                next.get(PlayerSetting.decDeinterlace)) {
          await svc.setDeinterlace(next.get(PlayerSetting.decDeinterlace));
        }
        if (prev == null ||
            prev.get(PlayerSetting.decSpeedupTricks) !=
                next.get(PlayerSetting.decSpeedupTricks)) {
          await svc
              .setSpeedupTricks(next.get(PlayerSetting.decSpeedupTricks));
        }
        if (prev == null ||
            prev.get(PlayerSetting.subtitleItalicEffect) !=
                next.get(PlayerSetting.subtitleItalicEffect)) {
          await svc.setSubtitleItalic(
              next.get(PlayerSetting.subtitleItalicEffect));
        }
      }
      // Audit fix (Phase 4 #15): loudness normalization toggle. The
      // libmpv property mutates the active filter chain at runtime —
      // no re-open needed.
      if (prev == null ||
          prev.get(PlayerSetting.loudnessNormalization) !=
              next.get(PlayerSetting.loudnessNormalization)) {
        if (svc is MediaKitPlayerService) {
          await svc.setLoudnessNormalization(
              next.get(PlayerSetting.loudnessNormalization));
        }
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
    // Note: screenAutoRotation + screenKeepOn are handled in
    // player_screen because they need access to SystemChrome + Wakelock
    // which aren't directly part of the player service. The player
    // screen also listens via ref.watch so changes there propagate
    // through its own build cycle.
  }

  /// Audit fix (B3): mid-playback live application of the user's
  /// Int/String settings changes. Without this the player only
  /// noticed Bool toggles on `playerSettingsProvider`, and every
  /// numeric/text tweak (subtitle size, audio delay, ...) required
  /// a player exit + reopen — surprising friction.
  ///
  /// We diff what actually changed and dispatch only the affected
  /// setter — `setSubtitleScale` and friends are cheap (libmpv
  /// property writes) but still skip the no-op case.
  Future<void> _applyLiveExtraSettingChanges(
      ExtraSettings? prev, ExtraSettings next) async {
    if (_currentUri == null) return;
    final svc = _ref.read(videoPlayerServiceProvider);
    try {
      final prevScale = prev?.getInt(IntSetting.subtitleScale);
      final nextScale = next.getInt(IntSetting.subtitleScale);
      if (prevScale != nextScale) {
        // IntSetting stores 100 = 100% (range 10..200). libmpv's
        // sub-scale property is a multiplier where 1.0 = 100%.
        // setSubtitleScale is MediaKit-specific; cast to use it.
        if (svc is MediaKitPlayerService) {
          await svc.setSubtitleScale(nextScale / 100.0);
        }
      }
      final prevDelay = prev?.getInt(IntSetting.audioDelay);
      final nextDelay = next.getInt(IntSetting.audioDelay);
      if (prevDelay != nextDelay) {
        await svc.setAudioDelayMs(nextDelay);
      }
      final prevSubSync = prev?.getInt(IntSetting.subtitleDefaultSync);
      final nextSubSync = next.getInt(IntSetting.subtitleDefaultSync);
      if (prevSubSync != nextSubSync) {
        // Subtitle delay is exposed by VideoPlayerService directly
        // (`setSubtitleDelayMs`) and maps to libmpv's `sub-delay`
        // property under the hood.
        try {
          await svc.setSubtitleDelayMs(nextSubSync);
        } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
      }
      // Audit fix (standard high-quality): live-apply subtitle layout
      // settings. All three are libmpv properties accessible via
      // _setMpvProperty, so changes take effect without re-opening
      // the file.
      if (svc is MediaKitPlayerService) {
        final prevVPos = prev?.getInt(IntSetting.subtitleVerticalPos);
        final nextVPos = next.getInt(IntSetting.subtitleVerticalPos);
        if (prevVPos != nextVPos) {
          // libmpv `sub-pos` is 0..100, top to bottom
          try {
            await (svc as dynamic).setMpvProperty('sub-pos', '$nextVPos');
          } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
        }
        final prevMX = prev?.getInt(IntSetting.subtitleMarginX);
        final nextMX = next.getInt(IntSetting.subtitleMarginX);
        if (prevMX != nextMX) {
          try {
            await (svc as dynamic).setMpvProperty('sub-margin-x', '$nextMX');
          } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
        }
        final prevMY = prev?.getInt(IntSetting.subtitleMarginY);
        final nextMY = next.getInt(IntSetting.subtitleMarginY);
        if (prevMY != nextMY) {
          try {
            await (svc as dynamic).setMpvProperty('sub-margin-y', '$nextMY');
          } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
        }
        final prevAlign =
            prev?.getInt(IntSetting.subtitleHorizontalAlign);
        final nextAlign =
            next.getInt(IntSetting.subtitleHorizontalAlign);
        if (prevAlign != nextAlign) {
          const alignNames = ['left', 'center', 'right'];
          if (nextAlign >= 0 && nextAlign < alignNames.length) {
            try {
              await (svc as dynamic)
                  .setMpvProperty('sub-align-x', alignNames[nextAlign]);
            } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
          }
        }
      }
      // Live-apply subtitle background colour (StringSetting).
      // Empty string ('') clears the libmpv `sub-back-color` (no bg).
      if (svc is MediaKitPlayerService) {
        final prevBg = prev?.getStr(StringSetting.subtitleBackgroundColor);
        final nextBg = next.getStr(StringSetting.subtitleBackgroundColor);
        if (prevBg != nextBg) {
          try {
            await (svc as dynamic)
                .setMpvProperty('sub-back-color', nextBg);
          } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
        }
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
  }

  Future<void> _initializeSystemValues() async {
    // Restore the user's customised shortcut row before anything else, so the
    // first frame of the controls already shows their icons rather than the
    // stock four swapping out a moment later.
    try {
      final saved = loadSavedShortcuts();
      if (saved != null && mounted) {
        state = state.copyWith(visibleShortcuts: saved);
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
    try {
      final brightness =
          await _ref.read(brightnessServiceProvider).getBrightness();
      final volume = await _ref.read(volumeServiceProvider).getVolume();
      if (mounted) {
        state = state.copyWith(brightness: brightness, volume: volume);
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
  }

  void _attachListeners() {
    final svc = _ref.read(videoPlayerServiceProvider);
    _subs.add(svc.positionStream.listen((p) {
      if (!mounted) return;
      _scheduleAutoSave();
      // A-B Repeat: jump back to A if we passed B
      final a = state.abPointA;
      final b = state.abPointB;
      if (a != null && b != null && b > a && p >= b) {
        // Only one jump per wrap: libmpv goes on reporting positions past B
        // for a few ticks after a seek is queued, and re-seeking on each of
        // them produced a burst of seeks (and, with fade-on-seek enabled, a
        // burst of volume ramps) every time the loop came round.
        final nowAb = DateTime.now();
        if (nowAb.difference(_lastAbJumpAt) >
            const Duration(milliseconds: 700)) {
          _lastAbJumpAt = nowAb;
          seek(a);
        }
      }
      // Phase 14: Auto-skip intro - jump from 0 to introEnd ONCE per playback
      // Only triggers when we're in first 5 seconds, to avoid re-skipping after seeking back.
      final introEnd = state.introEndMs;
      if (introEnd != null &&
          !_introSkipped &&
          p.inMilliseconds < 5000 &&
          p.inMilliseconds < introEnd) {
        _introSkipped = true;
        seek(Duration(milliseconds: introEnd));
      }
      // Phase 14: Auto-skip outro - if we hit the outro start mark
      final outroStart = state.outroStartMs;
      if (outroStart != null &&
          !_outroSkipped &&
          p.inMilliseconds >= outroStart) {
        _outroSkipped = true;
        // Jump close to end so next-video logic triggers
        if (state.duration.inMilliseconds > 0) {
          seek(state.duration - const Duration(milliseconds: 200));
        }
      }
      // Perf (budget-phone jank/battery): the seek-sensitive logic above
      // runs on every libmpv tick, but pushing position into `state`
      // rebuilds the whole ~2800-line player screen (build() watches the
      // full PlayerState). Two gates keep that under control.
      //
      // The first, already here, collapses sub-second updates: the seekbar
      // and the time label only show whole seconds.
      //
      // BATTERY/HEAT FIX — the second gate is new, and it is the one that
      // matters for a long film. Watching fullscreen with the controls hidden
      // is the normal case, and in that state NOTHING on screen displays the
      // position — yet the old code still rebuilt and re-diffed the entire
      // widget tree once a second, about 7,000 times over a two-hour film,
      // purely to update a number nobody could see. The position is now
      // written into state only while something is actually showing it; the
      // moment the controls (or the lock overlay, or a panel) appear,
      // `syncPositionToState` pushes the live value in so the first frame is
      // already correct. The exact position is always available from
      // `svc.position` for anything that needs it on demand.
      // Backstop for the first-frame flag. `bufferingStream` going false is
      // the primary signal, but a file that never reports buffering at all
      // (a local file, or a stream mpv had cached) would otherwise stay
      // "opening" forever and never be measured.
      if (!_firstFrameSeen && p > Duration.zero) _markFirstFrame();
      if (_positionIsVisible() && p.inSeconds != state.position.inSeconds) {
        state = state.copyWith(position: p);
      }
    }));
    _subs.add(svc.durationStream.listen((d) {
      if (mounted) state = state.copyWith(duration: d);
    }));
    _subs.add(svc.playingStream.listen((p) {
      if (!mounted) return;
      state = state.copyWith(isPlaying: p);
      _updateBackgroundWakeLock(p);
    }));
    _subs.add(svc.bufferingStream.listen((b) {
      if (!mounted) return;
      // Buffering going FALSE is the first-frame signal: libmpv only stops
      // reporting a starved demuxer once it has enough to render, so this is
      // the moment the black screen ends.
      if (!b) _markFirstFrame();
      // Debounce the SPINNER: a brief buffer refill right after a
      // seek/skip (typically well under 350 ms) should never flash a
      // "loading" circle — only a sustained stall surfaces it. Clearing
      // is immediate so playback resuming instantly hides the spinner.
      _bufferSpinnerTimer?.cancel();
      _bufferSpinnerTimer = null;
      if (b) {
        _bufferSpinnerTimer =
            Timer(const Duration(milliseconds: 350), () {
          if (!mounted) return;
          state = state.copyWith(isBuffering: true);
        });
      } else if (state.isBuffering) {
        state = state.copyWith(isBuffering: false);
      }

      // TWO WATCHDOGS THAT USED TO BE ONE, and the merge was the bug.
      //
      // ExoPlayer and VLC both expose a buffer-underrun signal, and the
      // pattern of escalating a sustained one into a message is right. What
      // was wrong here was applying it to START-UP. Opening a signed R2
      // stream means a DNS lookup, a TLS handshake, an HTTP GET, finding and
      // parsing the moov atom — which on a file that was not written
      // faststart costs a second round trip to the tail of a multi-gigabyte
      // object — and only then a decode. Every one of those seconds was
      // reported to the user as "Slow connection — buffering…", on a link
      // doing 13 MB/s. The sentence was false, and it pointed the user at
      // their router instead of at us.
      //
      // So: before the first frame this is OPENING. It gets a neutral
      // caption, a much longer rope, and a failure message that says the
      // video would not start rather than blaming the network. After the
      // first frame a refill genuinely does mean the stream cannot keep up,
      // and only there does the old wording apply.
      _bufferStallTimer?.cancel();
      _bufferStallTimer = null;
      _bufferSlowTimer?.cancel();
      _bufferSlowTimer = null;
      if (b) {
        final uri = _currentUri;
        if (uri != null && _isNetworkUri(uri)) {
          final opening = !_firstFrameSeen;
          // Tier 1 — soft caption. While opening it is a statement of fact
          // ("still opening"); mid-playback it is a diagnosis ("slow
          // connection"), and the screen picks the wording off `isOpening`.
          _bufferSlowTimer = Timer(
            opening ? _openHintAfter : _stallHintAfter,
            () {
              if (!mounted) return;
              if (!state.isBuffering) return;
              state = state.copyWith(slowNetworkHintVisible: true);
              // A stall that has lasted this long is worth measuring. Not an
              // open — before the first frame there is no bitrate, no cache
              // duration and no decoder to be behind, so the numbers would be
              // nulls dressed up as a diagnosis.
              if (!opening) unawaited(_measureStall());
            },
          );
          // Tier 2 — hard error + clear the soft hint. Giving up on an open
          // at ten seconds is what turned a slow first play into a red error
          // screen the user then retried, paying the whole cost again. A
          // start that takes twenty seconds is bad; a start abandoned at ten
          // is worse, because it never happens at all.
          _bufferStallTimer = Timer(
            opening ? _openGiveUpAfter : _stallGiveUpAfter,
            () {
              if (!mounted) return;
              if (!state.isBuffering) return;
              state = state.copyWith(
                slowNetworkHintVisible: false,
                errorMessage: opening
                    ? 'This video would not start. Tap Retry — if it keeps '
                        'failing, the file may be unavailable.'
                    : 'Playback stalled — the network is too slow to keep '
                        'up. Tap Retry or check your connection.',
              );
            },
          );
        }
      } else {
        // Buffer recovered — clear any visible hint, and the diagnosis with
        // it. A cause that outlives the stall it explained would sit under a
        // stream that is now perfectly healthy.
        if (state.slowNetworkHintVisible || state.stallCause != null) {
          state = state.copyWith(
            slowNetworkHintVisible: false,
            clearStallCause: true,
          );
        }
      }
    }));
    _subs.add(svc.errorStream.listen((e) {
      if (e == null || !mounted) return;
      // Phase 45: for network streams, libmpv sometimes drops the
      // connection on transient errors (Wi-Fi switching, ISP routing
      // blips). Try a single silent retry from the last known position
      // before showing the failure to the user. Local files don't get
      // retries — they either work or they're broken.
      final uri = _currentUri;
      final isNetwork = uri != null && _isNetworkUri(uri);
      if (!isNetwork) {
        state = state.copyWith(errorMessage: e);
        return;
      }
      // Audit: connectivity-aware error message. Before showing the
      // raw libmpv error and queuing a retry, probe whether the
      // device is actually online. If not, surface that clearly so
      // the user knows to reconnect rather than wonder why retry
      // keeps failing.
      () async {
        final online = await const ConnectivityService().isOnline();
        if (!mounted) return;
        if (!online) {
          state = state.copyWith(
              errorMessage:
                  'No internet connection. Reconnect and tap Retry.');
          // Skip the auto-retry — it would just fail again.
          return;
        }
        state = state.copyWith(errorMessage: e);
        if (_networkRetryInFlight) return;
        _networkRetryInFlight = true;
        Future.delayed(const Duration(seconds: 2), () async {
          // Re-check: did the user navigate to a different video while
          // we were waiting? If so, abort the retry — don't yank the
          // current playback back to a stale URI.
          if (!mounted || _currentUri != uri) {
            _networkRetryInFlight = false;
            return;
          }
          try {
            final s = _ref.read(videoPlayerServiceProvider);
            // Exact engine position, not the whole-second UI copy — a silent
            // reconnect that rewinds up to a second every time is noticeable
            // on a flaky connection that retries repeatedly.
            final lastPos =
                s.position > Duration.zero ? s.position : state.position;
            // A SIGNED URL CANNOT BE RETRIED, ONLY REPLACED.
            //
            // This path was written for a Wi-Fi blip, where reopening the same
            // address is exactly right. For a short-lived signed stream it is
            // exactly wrong: once the signature expires, every retry fails the
            // same way, and libmpv re-requests on any seek outside the buffer,
            // so a film longer than the URL's lifetime became unplayable
            // part-way through with the message blaming the network.
            //
            // Ask for a fresh URL first when one is obtainable. The renewal is
            // a new server request, so entitlement and the concurrency cap are
            // re-decided — a lapsed subscription gets a refusal here, not an
            // extension.
            var target = uri;
            if (StreamRenewal.canRenew(uri)) {
              final fresh = await StreamRenewal.renew(uri);
              if (!mounted || _currentUri != uri) {
                _networkRetryInFlight = false;
                return;
              }
              if (fresh == null) {
                // Matches the other messages emitted from this file: plain
                // English, set on state and rendered by the error card. The
                // provider has no BuildContext, and inventing one to reach
                // AppStrings here would be a bigger change than the message
                // is worth.
                state = state.copyWith(
                    errorMessage: 'This stream link has expired. '
                        'Open the title again to keep watching.');
                _networkRetryInFlight = false;
                return;
              }
              target = fresh;
              _currentUri = fresh;
            }
            await s.open(target, startAt: lastPos);
            await s.play();
            // Clear the error message — playback resumed.
            if (mounted && _currentUri == target) {
              state = state.copyWith(errorMessage: null);
            }
          } catch (_) {
            // Genuine failure — keep the error message for the UI.
          } finally {
            _networkRetryInFlight = false;
          }
        });
      }();
    }));
    _subs.add(svc.rateStream.listen((rate) {
      if (mounted) state = state.copyWith(playbackSpeed: rate);
    }));
    _subs.add(svc.completedStream.listen((completed) async {
      if (completed && mounted) {
        // Audit fix: capture the COMPLETED video's URI before any
        // await below changes `_currentUri`. The old code cleared
        // `_currentUri` post-await, but auto-play-next swaps that
        // out, so the next episode's saved resume position was
        // being wiped before the user ever watched it.
        final completedUri = _currentUri;
        // Phase 15: LoopMode handling (MX Player parity)
        // - LoopMode.one  → replay same video
        // - LoopMode.all  → next in folder; wrap to first when reach end
        // - LoopMode.off  → next if autoPlayNext pref enabled
        final mode = state.loopMode;
        // A sleep timer set to "end of video" must win over Loop: the user
        // asked for playback to STOP when this finishes. Checking loop first
        // meant a looping video simply never let the sleep timer fire, so the
        // phone played all night.
        if (state.sleepTimer.mode == SleepTimerMode.endOfVideo) {
          _ref.read(videoPlayerServiceProvider).pause();
          stopBackgroundPlaybackService();
          if (state.isBackgroundPlay) {
            state = state.copyWith(isBackgroundPlay: false);
          }
          _clearSleepTimer();
        } else if (mode == LoopMode.one || state.isLoopEnabled) {
          // Replaying is a fresh pass through the file, so the once-per-play
          // intro/outro auto-skips must be re-armed. Without this reset they
          // fired on the first play only and every later loop played the
          // intro the user had explicitly marked to skip.
          _introSkipped = false;
          _outroSkipped = false;
          seek(Duration.zero);
          _ref.read(videoPlayerServiceProvider).play();
        } else if (mode == LoopMode.all) {
          // Always play next in folder; if at end, wrap to first
          final played = await _playNextInFolderOrWrap();
          if (!played) {
            // Couldn't determine folder context — replay current
            seek(Duration.zero);
            _ref.read(videoPlayerServiceProvider).play();
          }
        } else {
          // Phase 14: Auto-play next in folder
          // Phase 41: respect "Back to list" (Settings → Player → Playback).
          // When on, completing a video sets [playbackCompleted=true] so the
          // screen can pop back to the file list instead of auto-advancing.
          final prefs = _ref.read(preferencesProvider);
          final backToList = _ref
              .read(playerSettingsProvider)
              .get(PlayerSetting.backToList);
          if (backToList) {
            state = state.copyWith(playbackCompleted: true);
          } else if (prefs.autoPlayNext && _currentUri != null) {
            await _playNextInFolder();
          }
        }
        // Clear resume position for the COMPLETED video — using the
        // captured URI, NOT `_currentUri` which may now be a freshly
        // opened next-episode whose resume marker we must not touch.
        if (completedUri != null) {
          _ref.read(resumeStorageProvider).clearPosition(completedUri);
        }
      }
    }));
    _subs.add(svc.audioTracksStream.listen((tracks) async {
      if (!mounted) return;
      state = state.copyWith(audioTracks: tracks);
      // Phase 41: when "Remember selections" is on, reapply the previously
      // chosen track for this video once the engine reports its track list.
      //
      // Audit fix: capture `_currentUri` BEFORE the await. Otherwise a
      // mid-flight openVideo would change `_currentUri` and we would
      // apply the previous video's saved audio track to the new one.
      try {
        final remember = _ref
            .read(playerSettingsProvider)
            .get(PlayerSetting.rememberSelections);
        final uriAtEntry = _currentUri;
        if (remember && uriAtEntry != null) {
          final savedId = await _ref
              .read(userDataServiceProvider)
              .getVideoAudioTrackId(uriAtEntry);
          // Re-check: did the user open a different video while we
          // were fetching the saved id? If so the `tracks` list we
          // captured belongs to the previous video — abort.
          if (!mounted || _currentUri != uriAtEntry) return;
          if (savedId != null) {
            final match = tracks.where((t) => t.id == savedId).toList();
            if (match.isNotEmpty) {
              await _ref
                  .read(videoPlayerServiceProvider)
                  .setAudioTrack(match.first);
              if (mounted && _currentUri == uriAtEntry) {
                state = state.copyWith(currentAudioTrack: match.first);
              }
            }
          }
        }
      } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
    }));
    _subs.add(svc.subtitleTracksStream.listen((tracks) async {
      if (!mounted) return;
      state = state.copyWith(subtitleTracks: tracks);
      // Phase 41: same restore behaviour for subtitles. Empty string means
      // "subtitles were explicitly off last time".
      //
      // Audit fix: same URI-capture-and-recheck pattern as audio above.
      try {
        final remember = _ref
            .read(playerSettingsProvider)
            .get(PlayerSetting.rememberSelections);
        final uriAtEntry = _currentUri;
        if (remember && uriAtEntry != null) {
          final savedId = await _ref
              .read(userDataServiceProvider)
              .getVideoSubtitleTrackId(uriAtEntry);
          if (!mounted || _currentUri != uriAtEntry) return;
          if (savedId != null) {
            if (savedId.isEmpty) {
              await _ref
                  .read(videoPlayerServiceProvider)
                  .setSubtitleTrack(null);
              if (mounted && _currentUri == uriAtEntry) {
                state = state.copyWith(currentSubtitleTrack: null);
              }
            } else {
              final match = tracks.where((t) => t.id == savedId).toList();
              if (match.isNotEmpty) {
                await _ref
                    .read(videoPlayerServiceProvider)
                    .setSubtitleTrack(match.first);
                if (mounted && _currentUri == uriAtEntry) {
                  state = state.copyWith(currentSubtitleTrack: match.first);
                }
              }
            }
          }
        }
      } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
    }));

    // Phase 45: video tracks stream — used by the PiP integration to
    // compute aspect ratio. Most files have just one video track but
    // multi-stream MKVs can have several; we store the whole list.
    _subs.add(svc.videoTracksStream.listen((tracks) {
      if (!mounted) return;
      state = state.copyWith(videoTracks: tracks);
    }));
  }

  // ============ PLAYBACK ============

  /// Phase 45: reentrancy guard for [openVideo]. Spam-tapping Next or
  /// the resume banner can fire multiple opens before libmpv finishes
  /// probing the previous one — that races inside libmpv and sometimes
  /// leaves the player on a frozen frame. We track the most-recently-
  /// requested URI; whenever an in-flight open completes we check if
  /// the user asked for something newer in the meantime and chain to
  /// it. This gives the user-visible behaviour of always landing on
  /// the LAST requested file, never an intermediate one.
  bool _openInProgress = false;
  String? _pendingOpenUri;
  String? _pendingOpenTitle;

  // Relocated during the file split: these instance fields previously sat
  // interspersed among controller methods that now live in extension part
  // files (player_controller_gestures.dart / player_controller_navigation
  // .dart). Dart extensions cannot declare instance fields, so they must
  // live on the class itself — the extension methods (same library) still
  // reference them directly.
  Timer? _brightnessPersistTimer;
  Timer? _volumePersistTimer;
  DateTime _lastSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
  int? _lastSeekTargetMs;
  Rect? _speedSliderBounds;
  // Long-press speed control (MX-style relative drag): the finger position
  // where the long-press begins is the anchor and maps to the current speed;
  // speed changes only as the finger is dragged from that anchor, never
  // jumping to an absolute position.
  double? _speedDragAnchorX;
  int _speedDragBaseIdx = 2; // index of 1.0x in _speedSteps
  Timer? _zoomIndicatorTimer;
  bool _introSkipped = false;
  bool _outroSkipped = false;
  String? _currentVideoTitle;

  /// The uri libmpv currently has open, or null when nothing is loaded.
  ///
  /// Exposed because the player screen lives in another library and needs to
  /// answer one question before it decides whether to reopen a file: "is this
  /// already the video that is playing?"
  String? get activeUri => _currentUri;

  /// The URI as the LIBRARY knows it, which is not always the URI libmpv is
  /// playing.
  ///
  /// AUDIT FIX — an `adb://…` video is copied to a local cache file first and
  /// `_currentUri` is then overwritten with that cache path. Next / Previous /
  /// Loop-all all locate the current file by `videos.indexWhere((v) => v.uri
  /// == _currentUri)`, which could never match a cache path, so every one of
  /// those controls did nothing at all on Android/data videos — silently, with
  /// no error. Keeping the original URI alongside restores them.
  String? _libraryUri;

  /// True while the user is dragging the seek bar.
  ///
  /// AUDIT FIX — "fade in on seek" fires a 300 ms volume ramp per seek, and a
  /// scrub emits a throttled seek every 60 ms. That is up to five overlapping
  /// ramps at any moment, each writing libmpv's volume, which is audible as
  /// pumping rather than a fade. Scrub seeks are also keyframe seeks now, so
  /// the drag stays instant.
  bool _isScrubbing = false;

  /// Debounce for the A-B repeat jump. libmpv keeps emitting positions past
  /// point B for a beat after a seek is requested, and the old code issued a
  /// fresh seek on every one of them — a small seek storm each time the loop
  /// wrapped.
  DateTime _lastAbJumpAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Watch-history is far heavier to write than a resume marker (it rewrites
  /// a JSON list), so it gets its own, slower cadence.
  DateTime _lastHistoryAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// False until this file's first history write, so the play counter is
  /// incremented once per viewing rather than once per progress save.
  bool _countedThisPlay = false;

  /// Whether the "Background play (audio)" default has been applied yet. Once
  /// per player session, so tapping the in-player toggle off is not undone by
  /// the next file in the folder.
  bool _appliedBgPlayDefault = false;

  /// Shuffle picker for next-in-folder.
  final math.Random _shuffleRandom = math.Random();

  /// Armed when playback pauses while background-play is on.
  ///
  /// BATTERY/HEAT FIX — the background-play foreground service holds a partial
  /// WakeLock, which is exactly right while audio is decoding and exactly
  /// wrong the moment it is not. Pausing with background-play left on used to
  /// keep that WakeLock held indefinitely: the CPU was pinned awake with
  /// nothing playing, which is the "I paused it and put the phone down and the
  /// battery was gone" case. A short grace period rather than an immediate
  /// stop, so a normal pause-then-resume does not flap the notification.
  Timer? _bgPauseTimer;

  /// The black screen just ended.
  ///
  /// Idempotent by design: three separate signals can arrive first (buffering
  /// clearing, the position advancing, a seek completing) and whichever wins
  /// is the right one. Everything after the first call is ignored, so a
  /// mid-film refill can never be mistaken for another start.
  /// Ask libmpv why it stopped, and say so out loud.
  ///
  /// This is the method that ends a three-week argument. "It stutters" has
  /// been explained here as the moov atom, then as the probe size, then as
  /// the connection, each from the symptom rather than from a measurement,
  /// and two of those were wrong. The player knows at the moment it stops
  /// whether its buffer is empty or full, and those two facts have opposite
  /// causes and opposite fixes.
  ///
  /// BEST EFFORT, ALWAYS. Every read can come back empty and the result is
  /// then `unknown`, which is reported as `unknown` rather than rounded to
  /// whichever cause was last suspected. A failure to measure must never
  /// touch playback, so the whole thing is wrapped and discarded on error.
  Future<void> _measureStall() async {
    if (_stallsReported >= _maxStallReports) return;
    _stallsReported++;
    try {
      final svc = _ref.read(videoPlayerServiceProvider);
      final reading =
          await svc.readStallNumbers(previousDropped: _droppedAtLastStall);
      _droppedAtLastStall = await svc.readDroppedFrames();
      final diagnosis = diagnoseStall(reading);
      PlaybackLog.add(
        'stall #$_stallsReported ${diagnosis.cause.name} '
        '${diagnosis.toMeta()}',
      );
      if (!mounted) return;
      // THE CAPTION STOPS LYING HERE TOO. "Slow connection" printed over a
      // video the chip cannot decode sends the viewer to restart their
      // router, and sends us to look at the network. The player now says
      // which it is, because it now knows.
      state = state.copyWith(stallCause: diagnosis.cause);
      onStall?.call(diagnosis);
    } catch (e) {
      PlaybackLog.add('stall measurement failed: $e');
    }
  }

  void _markFirstFrame() {
    if (_firstFrameSeen) return;
    _firstFrameSeen = true;
    final started = _openStartedAt;
    _openStartedAt = null;
    if (mounted && state.isOpening) {
      state = state.copyWith(isOpening: false, slowNetworkHintVisible: false);
    }
    if (started != null) {
      // Reported, not logged. A number nobody collects is a number nobody
      // can act on, and "it feels slow" is not something you can tune
      // against — p50 and p95 time-to-first-frame is.
      onFirstFrame?.call(DateTime.now().difference(started));
    }
  }

  /// True when something currently on screen actually displays the playback
  /// position. Used to skip state writes (and therefore whole-screen rebuilds)
  /// during ordinary fullscreen playback with the controls hidden.
  bool _positionIsVisible() =>
      state.controlsVisible ||
      state.isLocked ||
      state.speedSliderVisible ||
      state.activeIndicator != null ||
      state.openPanel != SidePanel.none ||
      state.decoderDialogOpen ||
      state.sleepTimerDialogOpen ||
      state.resumeDialogOpen;

  @override
  void dispose() {
    // Final save before dispose — forced, so the history entry lands even if
    // the throttled window has not elapsed.
    _autoSavePosition(force: true);
    // Audit: clean exit. Wipe the crash-recovery marker — the user
    // closed the player intentionally, no need to nag them with
    // "Resume X?" next time the app opens.
    try {
      _ref.read(resumeStorageProvider).clearLastPlaying();
    } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
    _hideControlsTimer?.cancel();
    _indicatorTimer?.cancel();
    _autoSaveTimer?.cancel();
    _sleepTimerTicker?.cancel();
    _zoomIndicatorTimer?.cancel();
    _bufferStallTimer?.cancel();
    _bufferSlowTimer?.cancel();
    _bufferSpinnerTimer?.cancel();
    _brightnessPersistTimer?.cancel();
    _volumePersistTimer?.cancel();
    _bgPauseTimer?.cancel();
    // The background-playback service is an app-lifetime singleton, so our
    // callbacks must be cleared — never left pointing at a disposed notifier.
    _detachScreenStateHandlers();
    // Phase 45 (audit): restore system brightness when the player
    // closes. Without this, if the user dragged brightness down in the
    // player, their phone screen stays dim on the home screen — a
    // genuinely confusing daily-use bug. MX Player V3 resets too.
    try {
      _ref.read(brightnessServiceProvider).reset();
    } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
    // Tear down the foreground service when the player goes away.
    //
    // v1.55 restores this to unconditional. v1.51 made it conditional so that
    // playback surviving a Back press would keep its notification and its
    // WakeLock — and that WakeLock is what let the process outlive the task,
    // which is what let an orphaned libmpv keep playing after the app was
    // swiped away. Playback no longer survives a Back press, so there is
    // nothing left for the service to serve.
    try {
      _ref.read(backgroundPlaybackServiceProvider).stop();
    } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
    // Phase 45: release audio focus so other apps can take over.
    try {
      _focusSub?.cancel();
      _ref.read(audioFocusServiceProvider).abandon();
    } catch (e) { if (kDebugMode) debugPrint('PlayerProvider: $e'); }
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

final playerControllerProvider =
    StateNotifierProvider.autoDispose<PlayerController, PlayerState>((ref) {
  return PlayerController(ref);
});
