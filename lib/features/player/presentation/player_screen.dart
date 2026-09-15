import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/adb/adb_service.dart';
import '../../../core/services/hardware_keys/hardware_keys_service.dart';
import '../../../core/services/haptic/haptic_service.dart';
// v1.61: PipService is named directly by the teardown snapshot field.
// core_providers.dart imports it, but Dart imports are not transitive —
// naming the type here requires its own import.
import '../../../core/services/pip/pip_service.dart';
import '../../../core/services/subtitles/subtitle_formats.dart';
import '../../../core/services/thumbnail/thumbnail_cache.dart';
import 'floating_pip_provider.dart';
import '../../../core/di/preferences_provider.dart';
import '../../network_stream/presentation/network_stream_screen.dart';
import '../../music/presentation/music_providers.dart';
import '../../user_data/user_data_providers.dart';
import '../../local_browser/domain/video.dart';
import '../../local_browser/presentation/widgets/video_option_menu.dart'
    show VideoInfoDialog;

import '../../../core/di/core_providers.dart';
import '../../../core/services/diagnostics/playback_log.dart';
import '../../../core/services/file_transfer/file_transfer_service.dart';
import '../../../core/router/routes.dart';
import '../../shell/shell_screen.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/services/preferences/extra_settings_service.dart';
// v1.63: the subtitle tune panel calls setSubtitleScale /
// setSubtitleVerticalPos, which live on the concrete service rather than
// on the VideoPlayerService interface.
import '../../../core/services/video_player/media_kit_player_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/app_snackbar.dart';
import '../../../core/utils/system_insets.dart';
import '../../equalizer/presentation/audio_effect_sheet.dart';
import '../../settings/presentation/subtitle_text_screen.dart';
import '../../settings/presentation/subtitle_layout_screen.dart';
import 'aspect_ratio_mode.dart';
import 'player_provider.dart';
import 'player_stats_overlay.dart';
import 'shortcut_item.dart';
import 'widgets/brightness_indicator.dart';
import 'widgets/bookmarks_sheet.dart';
import 'widgets/custom_speed_dialog.dart';
import 'widgets/customise_items_screen.dart';
import 'widgets/cut_sheet.dart';
import 'widgets/decoder_dialog.dart';
import 'widgets/display_settings_sheet.dart';
import 'widgets/gesture_overlay.dart';
import 'widgets/gestures_help_overlay.dart';
import 'widgets/kids_lock_overlay.dart';
import 'widgets/lock_overlay.dart';
import 'widgets/more_menu_panel.dart';
import 'widgets/playing_queue_sheet.dart';
import 'widgets/resume_dialog.dart';
import 'widgets/seek_indicator.dart';
import 'widgets/shortcut_row.dart';
import 'widgets/sleep_timer_dialog.dart';
import 'widgets/speed_indicator.dart';
import 'widgets/speed_slider.dart';
import 'widgets/zoom_indicator.dart';
import 'widgets/skip_markers_sheet.dart';
import 'widgets/subtitle_tune_panel.dart';
import 'widgets/loop_menu_sheet.dart';
import 'widgets/subtitle_panel.dart';
import 'widgets/track_selection_sheet.dart';
import 'widgets/volume_indicator.dart';
import '../../../core/services/secure_screen/secure_screen_service.dart';
import '../../../core/services/video_player/stream_renewal.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  final String videoUri;
  final String title;

  /// True when this video is playing FROM the Private Folder vault.
  /// Privacy rule: a private video must never keep playing once the app
  /// leaves the foreground — background play, system PiP and floating PiP
  /// are all suppressed, and any lifecycle change that isn't `resumed`
  /// hard-pauses immediately. So even if the OS keeps the media session
  /// alive, a locked/backgrounded private video is silent and hidden.
  final bool isPrivate;

  /// Block screenshots and screen recording for this playback, WITHOUT the
  /// rest of the vault's behaviour.
  ///
  /// Separate from [isPrivate] on purpose: that flag also suppresses
  /// background play, system PiP and floating PiP, which paid catalogue
  /// content should still get. Only the capture protection is shared.
  final bool secureScreen;

  /// The URI is a one-off address, not a stable identity for this video.
  ///
  /// True for a signed, expiring stream URL. Nothing about this playback may
  /// be written down: no resume point, no crash marker, no history entry.
  /// Keying any of those on a string that changes every time would mean resume
  /// never works AND that catalogue titles surface on the Local tab, in front
  /// of the age gate instead of behind it.
  final bool ephemeral;

  const PlayerScreen({
    super.key,
    required this.videoUri,
    required this.title,
    this.isPrivate = false,
    this.secureScreen = false,
    this.ephemeral = false,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  bool _videoDisplayEnabled = true;
  final GlobalKey _videoBoundaryKey = GlobalKey();
  final HardwareKeysService _hwKeys = HardwareKeysService();
  /// Subtitle timing currently in force, in ms.
  ///
  /// v1.63.1 — this used to be hard-initialised to 0 and never read the saved
  /// value, so the panel opened showing "+0.0s" even when
  /// `IntSetting.subtitleDefaultSync` was applying a real offset to libmpv on
  /// every file. The number on screen and the number in the engine disagreed,
  /// and the first tap of "+" jumped the subtitle by the whole hidden offset.
  /// It is seeded from the setting in initState now.
  int _subtitleDelayMs = 0;

  /// Shortcut tap feedback: briefly show a small dark label inside the
  /// player instead of a SnackBar (MX Player style).
  final ValueNotifier<String?> _overlayMsg = ValueNotifier(null);
  Timer? _overlayTimer;

  /// Phase 41: timestamp of the last back-button press. Used by the
  /// "Double-tap the back button" setting (Settings → Player → Interface)
  /// to require two presses within 2 seconds before actually closing.
  DateTime? _lastBackPressAt;

  /// Whether the user's settings permit holding the screen awake at all.
  bool _keepScreenOnAllowed = true;

  /// Whether we are currently holding it. Tracked so we only cross the
  /// platform channel when the answer actually changes — calling
  /// enable()/disable() on every frame would be its own small drain.
  bool _wakelockHeld = false;

  // v1.61 — TEARDOWN STATE. See [dispose] for the crash this comes from.
  //
  // `State.mounted` cannot be trusted here. It is `_element != null`, and the
  // element is only nulled AFTER dispose() returns — so a dispose() that threw
  // part-way leaves `mounted` reporting true forever, on a State that is
  // finished. The device log showed exactly that: three lifecycle callbacks
  // arriving on a dead screen, each logging `mounted=true`. This flag is set
  // on the first line of dispose() and cannot lie.
  bool _disposed = false;

  // Snapshot taken in [deactivate], while `ref` is still usable, because
  // dispose() must not touch `ref` at all.
  bool _floatingPipActiveAtTeardown = false;
  PlayerController? _controllerAtTeardown;
  PipService? _pipServiceAtTeardown;

  /// Hide or show the status and navigation bars, per Settings → Screen.
  ///
  /// `edgeToEdge` for the "off" case rather than `manual`: the video keeps
  /// drawing full-bleed and the bars simply sit on top, which is what "don't
  /// hide them" should look like in a player.
  void _applySystemUiMode() {
    final full = ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.screenFullScreen);
    SystemChrome.setEnabledSystemUIMode(
      full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  /// Rotation mode for the on-screen rotate button: 0 follows the device,
  /// 1 pins portrait, 2 pins landscape.
  ///
  /// Seeded from the user's default-orientation setting so the first tap moves
  /// to the next mode rather than to whatever the code assumed.
  int _rotationMode = 0;

  void _applyRotationMode({bool announce = false}) {
    switch (_rotationMode) {
      case 1:
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        if (announce) _showOverlay('Portrait');
        break;
      case 2:
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        if (announce) _showOverlay('Landscape');
        break;
      default:
        // Hand control back to the device. This is the state the old button
        // could never reach.
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        if (announce) _showOverlay('Auto rotate');
    }
  }

  /// Armed when the app goes `inactive` with background play on; fires only
  /// if we have not come back. See didChangeAppLifecycleState.
  Timer? _bgDetachTimer;

  /// Settings → Player → Controls → "Lock screen on rotation". Remembers the
  /// last orientation so a change can be detected; another switch that had a
  /// description and no reader.
  Orientation? _lastOrientation;

  /// Hold the screen awake only while there is something to watch.
  ///
  /// "Something to watch" deliberately includes buffering and the initial
  /// load: a video copying over ADB can take a while, and the screen going
  /// dark mid-copy would look like a hang. It excludes plain pause, which is
  /// the case that used to cost a whole battery.
  void _applyKeepScreenOn(PlayerState state) {
    final shouldHold = _keepScreenOnAllowed &&
        (state.isPlaying ||
            state.isBuffering ||
            state.loadingMessage != null ||
            state.resumeDialogOpen);
    if (shouldHold == _wakelockHeld) return;
    _wakelockHeld = shouldHold;
    if (shouldHold) {
      // ignore: discarded_futures
      WakelockPlus.enable();
    } else {
      // ignore: discarded_futures
      WakelockPlus.disable();
    }
  }
  @override
  void initState() {
    super.initState();
    // v1.63.1: seed the subtitle timing from the saved value, so the tune
    // panel opens showing what libmpv is actually doing. See the field's note.
    try {
      _subtitleDelayMs =
          ref.read(extraSettingsProvider).getInt(IntSetting.subtitleDefaultSync);
    } catch (_) {
      // A settings read must never be the reason a video will not open.
    }
    // immersiveSticky (not plain immersive): the nav/status bars stay hidden
    // for a fullscreen video, a swipe reveals them only transiently, and —
    // crucially — this mode reasserts itself after a screen-off/on cycle.
    // Plain `immersive` is cleared by that cycle, which briefly brings the
    // nav bar back while the player's controls are still laid out for a
    // full-bleed screen, so Prev/Play/Next overlapped the Home/Back keys.
    // Settings → Player → Screen → "Full screen: hide system status bar and
    // navigation bar during playback." The switch had a description and no
    // reader, so the bars were always hidden. Some people genuinely want the
    // clock and battery visible while watching; that is the option.
    _applySystemUiMode();
    // Phase 12: Apply orientation preference.
    // Phase 42: respect the Phase 41 Settings → Player → Screen toggles too.
    // The Phase 41 [PlayerSetting.screenAutoRotation] and [screenKeepOn]
    // toggles are what the user actually sees in Settings; the legacy
    // [preferencesProvider] flags are the older mechanism. We honour the
    // Phase 41 setting (defaults to on) AND require the legacy one to also
    // be on, so neither surface alone can silently disable rotation/wakelock.
    final prefs = ref.read(preferencesProvider);
    final playerSettings = ref.read(playerSettingsProvider);
    final autoRotate = prefs.autoRotate &&
        playerSettings.get(PlayerSetting.screenAutoRotation);
    final keepScreenOn =
        prefs.keepScreenOn && playerSettings.get(PlayerSetting.screenKeepOn);
    // Audit fix (standard high-quality): apply user's preferred
    // default orientation if explicitly set. 'system' falls through
    // to the existing autoRotate logic. The string values map to
    // single-orientation `setPreferredOrientations` calls so the
    // device respects the choice regardless of physical rotation.
    final orientationPref = ref
        .read(extraSettingsProvider)
        .getStr(StringSetting.defaultPlayerOrientation);
    if (orientationPref == 'landscape') {
      SystemChrome.setPreferredOrientations(
          const [DeviceOrientation.landscapeLeft]);
    } else if (orientationPref == 'landscapeReverse') {
      SystemChrome.setPreferredOrientations(
          const [DeviceOrientation.landscapeRight]);
    } else if (orientationPref == 'portrait') {
      SystemChrome.setPreferredOrientations(
          const [DeviceOrientation.portraitUp]);
    } else if (autoRotate) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitUp,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    // Seed the rotate button's cycle to match what we just applied, so the
    // first tap advances from where the user actually is instead of jumping.
    if (orientationPref == 'portrait') {
      _rotationMode = 1;
    } else if (orientationPref == 'landscape' ||
        orientationPref == 'landscapeReverse') {
      _rotationMode = 2;
    } else {
      _rotationMode = autoRotate ? 0 : 2;
    }
    // Phase 12: Apply keepScreenOn preference
    // Phase 42: use the combined flag (Phase 41 setting + legacy pref).
    //
    // BATTERY FIX — this used to turn the screen wake lock on here and off
    // only in dispose(), so the display was pinned awake for the entire time
    // the player was open whether or not anything was playing. Pausing a film
    // and setting the phone down left the screen lit until the battery went,
    // which on a phone is the most expensive mistake in this whole audit —
    // the display draws more than the decoder does. The lock now follows
    // playback: see [_applyKeepScreenOn], driven from build().
    _keepScreenOnAllowed = keepScreenOn;
    if (keepScreenOn) {
      // The file is still loading at this point (an Android/data copy can take
      // a while), so hold it until the first playback state arrives.
      WakelockPlus.enable();
      _wakelockHeld = true;
    }
    // Phase 15: Media keys only (volume keys removed - they should control system volume)
    // Phase 45: respect Settings → Audio → "Media buttons" — when off,
    // the headset / Bluetooth media keys do nothing in our player so
    // they fall back to whatever the system thinks should handle them.
    _hwKeys.enable(
      onMediaKey: (action) {
        // Re-read at call time so a settings change mid-playback takes
        // effect immediately.
        final mediaButtonsOn = ref
            .read(playerSettingsProvider)
            .get(PlayerSetting.mediaButtons);
        if (!mediaButtonsOn) return;
        final controller = ref.read(playerControllerProvider.notifier);
        switch (action) {
          case MediaKeyAction.playPause:
            controller.playOrPause();
            break;
          case MediaKeyAction.play:
            controller.play();
            break;
          case MediaKeyAction.pause:
            controller.pause();
            break;
          case MediaKeyAction.forward:
            controller.seekRelative(10);
            break;
          case MediaKeyAction.rewind:
            controller.seekRelative(-10);
            break;
          case MediaKeyAction.next:
            controller.playNextInFolder();
            break;
          case MediaKeyAction.previous:
            controller.playPreviousInFolder();
            break;
          case MediaKeyAction.headphonesDisconnected:
            // Settings → Audio → "Pause on headset disconnected". The switch
            // had no reader, so this pause was unconditional. It is the right
            // default — nobody wants a video blasting out of the loudspeaker
            // on a bus — but it is a choice, and the setting exists to make it.
            if (!ref
                .read(playerSettingsProvider)
                .get(PlayerSetting.audioPauseOnHeadsetDisconnect)) {
              break;
            }
            controller.pause();
            // Also stop any music in the queue — same reason.
            try {
              ref.read(musicAudioServiceProvider).pause();
            } catch (e) { if (kDebugMode) debugPrint('player_screen.best-effort: $e'); }
            break;
        }
      },
    );
    WidgetsBinding.instance.addObserver(this);
    // Vault playback must not be screenshot-able or appear in the recents
    // preview. The vault SCREEN already holds a claim while it is mounted and
    // the player is pushed on top of it, so this is strictly belt-and-braces
    // — but the player can also be reached from a resume shortcut, and the
    // ref-counted service makes an extra claim free.
    if (widget.isPrivate || widget.secureScreen) {
      // ignore: discarded_futures
      SecureScreenService.instance.acquire();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Opening a video in the fullscreen player supersedes any floating PiP
      // window — e.g. the user picked a NEW video while one was still floating.
      // Clear it here so the player and the floating overlay never render the
      // same libmpv output as two windows at once. hideForExpand (not close)
      // leaves the libmpv instance running; openVideo below retargets it.
      // (The expand-to-player path already clears it, so this is a no-op there.)
      final notifier = ref.read(playerControllerProvider.notifier);
      // Expanding back out of the in-app floating window? Then this is the
      // SAME playback session, still running in the same libmpv instance, and
      // reopening the file would throw away the very thing that made the
      // little window worth having. Two independent locks have to agree before
      // we skip the open: the floating window must have handed this exact uri
      // over moments ago, AND the controller must still have that file live.
      // Compare against what is ACTUALLY playing, not the address this screen
      // was constructed with: after a stream renewal they are different
      // strings for the same video, and requiring the original would refuse
      // the adopt and reopen a dead url.
      final live = notifier.activeUri;
      final handoff = ref
          .read(floatingPipProvider.notifier)
          .consumeHandoff(live ?? widget.videoUri);
      final adopt = handoff &&
          !widget.isPrivate &&
          live != null &&
          (live == widget.videoUri || widget.ephemeral);
      if (adopt) {
        // The picture may be detached (screen was off while floating), so put
        // it back; everything else — position, tracks, subtitles, history —
        // is already exactly where the user left it.
        // ignore: discarded_futures
        notifier.setBackgroundAudioMode(false);
        return;
      }
      ref.read(floatingPipProvider.notifier).hideForExpand();
      notifier.openVideo(widget.videoUri,
          title: widget.title,
          isPrivate: widget.isPrivate,
          ephemeral: widget.ephemeral);
    });

    // Phase 45: Android system Picture-in-Picture.
    //
    // When the user presses Home / swipes-up AND the "Background/PIP
    // mode" setting is on AND the video is currently playing, Android
    // gives us `onUserLeaveHint` BEFORE the activity actually pauses.
    // We use that window to enter PiP, so playback continues in a
    // small floating window — the experience MX Player users expect.
    //
    // Settings → Player → PiP → "Use custom PiP" lets the user pick
    // the in-app floating overlay instead. We honor both: when custom
    // PiP is on we activate the FloatingPipProvider, otherwise we ask
    // Android for real system PiP.
    //
    // `onPipModeChanged` fires after the system PiP entered/exited so
    // we can hide our top/bottom bars (PiP shows its own controls).
    final pipSvc = ref.read(pipServiceProvider);
    pipSvc.onUserLeaveHint = () {
      // Phase 45 (audit): MX Player V3 `sticky_video` is a 3-mode
      // setting:
      //   'stop'       — pause and exit (no background activity)
      //   'background' — keep audio + screen-off playback running
      //   'pip'        — enter Picture-in-Picture (default)
      // Re-read at call time so flicking the setting takes effect
      // immediately even mid-session.
      final st = ref.read(playerControllerProvider);
      final ps = ref.read(playerSettingsProvider);
      final mode = ref
          .read(extraSettingsProvider)
          .getStr(StringSetting.stickyVideo);
      if (mode == 'stop' || !st.isPlaying) return;
      if (mode == 'background') {
        // Keep audio playing via the foreground service; no PiP.
        // The BackgroundPlaybackService is already wired and starts
        // automatically when bgPlayAudio is true.
        return;
      }
      // mode == 'pip' (default).
      // Also honour the legacy bgPipMode toggle so users who never
      // visited the new dropdown but had bgPipMode off still get the
      // old "do nothing on home" behaviour.
      final bgPip = ps.get(PlayerSetting.bgPipMode);
      if (!bgPip) return;
      // Leaving the app → System Picture-in-Picture, so the video keeps
      // playing in a small window OVER other apps / the launcher. (The
      // in-app floating overlay is deliberately NOT used here: it can only
      // draw inside Innocent, so it would vanish the instant the app goes to
      // background — pointless when the user's whole intent is to watch while
      // using another app. The in-app overlay remains the behaviour of the
      // on-screen PiP *button*, for floating within the app.)
      // Set the transition flag BEFORE asking Android to enter PiP so the
      // upcoming `paused` lifecycle callback skips the auto-pause. Safety
      // timeout clears it in case Android never sends onPipModeChanged.
      _pipTransitionInFlight = true;
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) _pipTransitionInFlight = false;
      });
      // Aspect from the first video track (native clamps illegal ratios).
      int w = 16;
      int h = 9;
      if (st.videoTracks.isNotEmpty) {
        final v = st.videoTracks.first;
        final vw = v.width ?? 0;
        final vh = v.height ?? 0;
        if (vw > 0 && vh > 0) {
          w = vw;
          h = vh;
        }
      }
      // Source rect = the on-screen video bounds, for a smooth morph into
      // the PiP window instead of a hard cut.
      Rect? srcRect;
      final ro = _videoBoundaryKey.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.hasSize) {
        srcRect = ro.localToGlobal(Offset.zero) & ro.size;
      }
      pipSvc.enterPip(
        width: w,
        height: h,
        isPlaying: st.isPlaying,
        sourceRect: srcRect,
      );
    };
    pipSvc.onPipModeChanged = (inPip) {
      // Toggle controls visibility through the controller so timers
      // and other state are kept consistent. Also write the state
      // flag so the lifecycle handler knows we're in real PiP and
      // must NOT pause the player when the activity backgrounds.
      final controller = ref.read(playerControllerProvider.notifier);
      controller.setInSystemPip(inPip);
      // Phase 45: PiP confirmed (or exited) — clear the transition flag.
      _pipTransitionInFlight = false;
      if (inPip) {
        // System PiP shows the picture, so whatever the background path may
        // have released on the way in has to come back. Cheap and idempotent
        // when nothing was detached — and the safety net for any ordering
        // where the detach still wins the race into PiP.
        // ignore: discarded_futures
        controller.setBackgroundAudioMode(false);
        // Hide top/bottom bars while in PiP — the system shows its
        // own minimal controls there.
        controller.hideControls();
      } else {
        // Restore controls when the user expands back out of PiP.
        controller.showControls();
      }
    };
    // The play/pause button inside the PiP window taps this. Toggle
    // playback, then push the new state back so the PiP icon flips.
    pipSvc.onPipPlayPause = () {
      final controller = ref.read(playerControllerProvider.notifier);
      final playing = ref.read(playerControllerProvider).isPlaying;
      if (playing) {
        controller.pause();
      } else {
        controller.play();
      }
      // ignore: discarded_futures
      pipSvc.setPipPlaying(!playing);
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    super.didChangeAppLifecycleState(appState);
    // Recorded before every early return below, because "which gate turned it
    // away" is exactly the question four rounds of guessing could not answer.
    PlaybackLog.add('lifecycle ${appState.name} mounted=$mounted');
    // v1.61: the real guard. `mounted` below is kept as a second check but it
    // is NOT sufficient on its own — see [_disposed].
    if (_disposed) return;
    // If this player is already being torn down, do nothing — otherwise a
    // late resume callback could re-assert immersiveSticky just as the user
    // lands back on the main shell, hiding the nav bar there. (The shell
    // separately re-asserts edge-to-edge on resume as a backstop.)
    if (!mounted) return;
    // Phase 13: Background play handling.
    // Phase 45 refinements:
    // 1. ALSO keep playing if we're in real Android Picture-in-Picture
    //    (the system pauses our Activity but PiP keeps the surface
    //    visible, so audio + video should continue).
    // 2. RACE WINDOW: when the user presses Home with bgPipMode on,
    //    Android sends `inactive` → `paused` → onPictureInPictureModeChanged.
    //    Our `inSystemPip` flag only flips on the third callback, so a
    //    naive paused-check would pause the player just before PiP
    //    starts and the user would see a black PiP window. To avoid
    //    that we honor the `_pipTransitionInFlight` flag set by the
    //    onUserLeaveHint handler — it's true ONLY for a short window
    //    after a Home press, never for phone-sleep / incoming-call /
    //    app-switch events which should still pause.
    // 3. AppLifecycleState.inactive is the transient state between
    //    foreground and PiP / phone-sleep; never pause on this one.
    final playerState = ref.read(playerControllerProvider);
    final isBackgroundPlay = playerState.isBackgroundPlay;
    final inSystemPip = playerState.inSystemPip;
    final controller = ref.read(playerControllerProvider.notifier);

    // Privacy override: a Private Folder video is ALWAYS paused the moment
    // we lose the foreground — no background play, no PiP exemption.
    if (widget.isPrivate) {
      if (appState != AppLifecycleState.resumed) {
        controller.pause();
      }
      return;
    }

    if (appState == AppLifecycleState.paused ||
        appState == AppLifecycleState.hidden) {
      _bgDetachTimer?.cancel();
      if (!isBackgroundPlay && !inSystemPip && !_pipTransitionInFlight) {
        controller.pause();
      } else if (isBackgroundPlay &&
          !inSystemPip &&
          !_pipTransitionInFlight) {
        // A real background transition, and the surface is about to go.
        // Detach the video output now so the audio thread has nothing left to
        // wait on. Not done in system PiP: there the surface stays alive and
        // the whole point is that the picture keeps showing.
        //
        // BUG FIX (v1.54) — `_pipTransitionInFlight` was honoured by the pause
        // branch above but not by this one, and the two need it for the same
        // reason. Pressing Home with PiP enabled sends `paused` BEFORE
        // onPictureInPictureModeChanged, so `inSystemPip` is still false here
        // and the detach fired on its way into PiP: audio playing over a black
        // PiP window, with nothing to put the picture back afterwards.
        // ignore: discarded_futures
        controller.setBackgroundAudioMode(true);
      }
      // Otherwise the player keeps running (BG play / system PiP /
      // PiP-imminent after a Home press with bgPipMode on).
    } else if (appState == AppLifecycleState.inactive) {
      // `inactive` is ambiguous. It covers a PiP transition and a screen-off
      // (which on some devices never goes on to `paused`), but ALSO a pulled
      // notification shade or a permission dialog — moments when the video is
      // still partly on screen and detaching it would black the picture out
      // for no reason.
      //
      // So `inactive` only ARMS the detach. If we are still not resumed a
      // moment later this really was a background transition and the detach
      // runs; if the user let the shade go and we are back, the timer is
      // cancelled and nothing ever flickered.
      if (isBackgroundPlay && !widget.isPrivate && !inSystemPip) {
        _bgDetachTimer?.cancel();
        // v1.51 — ask Android instead of guessing.
        //
        // The 1.2 s timer below is still the right answer for a notification
        // shade (come back within a second and the picture never flickers),
        // but it is the wrong answer for a screen-off, where every millisecond
        // spent waiting is a millisecond libmpv spends filling a buffer queue
        // nothing is draining. PowerManager.isInteractive() separates the two
        // cases in a single, cheap round trip, so the shade keeps its grace
        // period and the screen-off gets none.
        //
        // (The native ACTION_SCREEN_OFF broadcast normally beats this to it
        // and the detach is already done by the time we get here — this is
        // the belt to that pair of braces, for OEM builds that delay or
        // suppress the broadcast.)
        // ignore: discarded_futures
        _detachNowIfScreenOff();
        _bgDetachTimer = Timer(const Duration(milliseconds: 1200), () {
          if (!mounted) return;
          final st = ref.read(playerControllerProvider);
          if (!st.isBackgroundPlay || st.inSystemPip) return;
          // ignore: discarded_futures
          ref
              .read(playerControllerProvider.notifier)
              .setBackgroundAudioMode(true);
        });
      }
    } else if (appState == AppLifecycleState.resumed) {
      _bgDetachTimer?.cancel();
      // Back in foreground → restore normal audio/video coupling so the
      // picture is in sync again.
      // ignore: discarded_futures
      controller.setBackgroundAudioMode(false);
      // Re-apply immersive mode — but ONLY if this player is still the
      // top-most route. If the user backed out to the shell while the app
      // was in the background, re-asserting immersive here would hide the
      // main screen's nav bar (the bug being fixed). Guarding on
      // ModalRoute.isCurrent keeps immersive scoped to the player, while the
      // shell restores edge-to-edge for itself.
      final playerIsTop = ModalRoute.of(context)?.isCurrent ?? true;
      if (playerIsTop) {
        _applySystemUiMode();
      }
      // No automatic resume; user controls playback explicitly. Also
      // clear the PiP-imminent flag if we ended up back in foreground
      // without entering PiP (e.g. user cancelled the gesture).
      _pipTransitionInFlight = false;
    }
  }

  /// Resolve an ambiguous `inactive` by asking the platform whether the
  /// display is actually off, and detach immediately when it is.
  Future<void> _detachNowIfScreenOff() async {
    final bg = ref.read(backgroundPlaybackServiceProvider);
    final on = await bg.isInteractive();
    if (on) return; // shade / dialog — let the grace timer decide.
    if (!mounted) return;
    final st = ref.read(playerControllerProvider);
    if (!st.isBackgroundPlay || st.inSystemPip || widget.isPrivate) return;
    _bgDetachTimer?.cancel();
    await ref
        .read(playerControllerProvider.notifier)
        .setBackgroundAudioMode(true);
  }

  /// Phase 45: true between an `onUserLeaveHint` (Home press with
  /// bgPipMode on) and the subsequent `onPictureInPictureModeChanged`
  /// — the few hundred ms where Android has paused our Activity but
  /// PiP hasn't formally entered yet. Without this flag we'd pause
  /// playback on the intermediate `paused` callback and the user
  /// would see a black PiP window. Cleared automatically on
  /// `resumed` (cancelled PiP) or in `onPipModeChanged` (PiP entered).
  bool _pipTransitionInFlight = false;

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Settings → Player → Controls → "Lock screen on rotation: automatically
    // lock screen when device rotates."
    //
    // Rotating is the moment a phone is most likely to be in a hand, a bag or
    // a lap, so it is also the moment a stray touch is most likely — which is
    // the whole reason MX Player offers this. The switch had no reader.
    if (!mounted) return;
    final size = WidgetsBinding.instance.platformDispatcher.views.isEmpty
        ? null
        : MediaQuery.maybeOf(context)?.size;
    if (size == null) return;
    final now =
        size.width >= size.height ? Orientation.landscape : Orientation.portrait;
    final was = _lastOrientation;
    _lastOrientation = now;
    if (was == null || was == now) return;
    if (!ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.ctlLockOnRotation)) {
      return;
    }
    final controller = ref.read(playerControllerProvider.notifier);
    if (!ref.read(playerControllerProvider).isLocked) {
      controller.toggleLock();
    }
  }

  /// Show the "enable Picture-in-picture permission" guidance at most once per
  /// app session (static → survives player re-opens) so we nudge the user
  /// toward the fix without nagging on every PiP tap.
  static bool _pipPermPromptedThisSession = false;

  /// v1.61 — the last moment `ref` is legal.
  ///
  /// Riverpod's ConsumerStatefulElement marks itself disposed inside
  /// `unmount()`, and `unmount()` is what calls `State.dispose()`. So EVERY
  /// `ref.read` in dispose() throws, always — it is not a race. `deactivate()`
  /// runs before unmount, so the values dispose() needs are taken here and
  /// dispose() never touches `ref` again.
  @override
  void deactivate() {
    try {
      _floatingPipActiveAtTeardown = ref.read(floatingPipProvider).isActive;
      _controllerAtTeardown = ref.read(playerControllerProvider.notifier);
      _pipServiceAtTeardown = ref.read(pipServiceProvider);
    } catch (e) {
      // Never let a snapshot failure stop the teardown that follows it.
      PlaybackLog.add('deactivate snapshot failed: $e');
    }
    super.deactivate();
  }

  /// WHAT THIS IS RECOVERING FROM (v1.61, from a device crash log).
  ///
  /// dispose() used to call `ref.read(floatingPipProvider)` on its 34th line.
  /// That throws — see [deactivate] — so everything after it never ran:
  /// playback was never stopped, libmpv was never destroyed, the PiP callbacks
  /// kept pointing into a dead widget, the wakelock stayed held, the
  /// orientation lock was never lifted, `super.dispose()` never happened, and
  /// `WidgetsBinding.instance.removeObserver(this)` never happened either — so
  /// the finished screen stayed subscribed to lifecycle events and kept
  /// throwing on each one. The log showed three of those, then a second video
  /// being opened on top of a libmpv nobody owned, then the process aborting
  /// in native code.
  ///
  /// Two rules follow, and they are the point of this method:
  ///   1. NO `ref` HERE. Use the [deactivate] snapshot.
  ///   2. EVERY STEP IS INDEPENDENT. Each is wrapped, so one failure can cost
  ///      at most its own line — never the rest of the teardown.
  @override
  void dispose() {
    // FIRST, before anything that could throw. A leaked observer is the one
    // failure that outlives the screen and keeps firing forever.
    _disposed = true;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _step('overlayTimer', () => _overlayTimer?.cancel());
    _step('overlayMsg', () => _overlayMsg.dispose());
    // Release the screen-capture claim taken in initState. Paired exactly:
    // the service counts holders, so a missed release here would leave the
    // whole app capture-blocked until it restarted.
    if (widget.isPrivate || widget.secureScreen) {
      // ignore: discarded_futures
      SecureScreenService.instance.release();
    }
    // Decide whether playback should survive leaving this screen.
    // It should ONLY survive when the floating PiP window is taking over —
    // that window is a live widget that renders this playback and can stop it.
    //
    // THE PILE-UP FIX (v1.55). This used to keep playing for background-play
    // too, and that is where every voice in the pile came from.
    //
    // libmpv's threads belong to the PROCESS, not to the Dart isolate. Nothing
    // in Flutter tears them down: `mpv_destroy` only runs if someone calls
    // dispose. So playback that outlives the player screen is playback that
    // nobody owns — and when the engine is destroyed (swipe the app away) the
    // isolate goes with it while those native threads keep running. Relaunching
    // builds a NEW engine, a NEW isolate and a NEW libmpv, which cannot even
    // see the orphan: statics do not survive an isolate. So it plays alongside
    // it. Do that a few times and every video you have opened is singing at
    // once, and only Force Stop — killing the process — clears them, exactly as
    // reported.
    //
    // MX Player draws this line in the same place: background play means the
    // audio keeps going while the APP is in the background — screen off, Home,
    // another app — not that it keeps going after you have closed the video.
    // Backing out of the player closes the video. So it stops here, and libmpv
    // is once again owned by something that can stop it for its whole life.
    final keepPlaying = _floatingPipActiveAtTeardown;
    if (!keepPlaying) {
      _step('stopPlayback', () {
        final notifier = _controllerAtTeardown;
        if (notifier == null) {
          // Nothing else can stop libmpv once this screen is gone, so a lost
          // snapshot is worth a line in the log rather than silence.
          PlaybackLog.add('TEARDOWN: no controller snapshot — playback NOT stopped');
          return;
        }
        // Stop the audio-only foreground service if it was started, then
        // hard-stop the player so no audio lingers in the background.
        notifier.stopBackgroundPlaybackService();
        // ignore: discarded_futures
        notifier.stopPlayback();
      });
    }
    // Phase 45: unregister the PiP listeners we set in initState — the
    // PipService is a singleton kept alive by Riverpod, so leaving the
    // callbacks pointing into a disposed State would invoke methods on
    // a dead widget tree.
    _step('pipCallbacks', () {
      final pipSvc = _pipServiceAtTeardown;
      // Only drop the PiP callbacks if we're NOT handing off to the floating
      // window. When the user pops the player into the in-app floating window,
      // the floating overlay installs its OWN handlers (so leaving the app
      // from there enters system PiP); clearing here would wipe them.
      if (pipSvc != null && !_floatingPipActiveAtTeardown) {
        pipSvc.onUserLeaveHint = null;
        pipSvc.onPipModeChanged = null;
        pipSvc.onPipPlayPause = null;
      }
    });
    // (removeObserver has already run, on the first line.)
    _step('systemUi', () {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // The app is portrait-locked; only the player may rotate to landscape.
      // So leaving the player must restore portrait — otherwise the whole app
      // stays stuck in landscape after backing out of a rotated video.
      SystemChrome.setPreferredOrientations(
          const [DeviceOrientation.portraitUp]);
    });
    // AUDIT FIX — this used to run unconditionally, including when the user
    // had just popped the video into the in-app floating window. That window
    // keeps rendering VIDEO inside the app, so releasing the screen wakelock
    // let the display time out and sleep on top of a playing picture. Keep it
    // held while the floating player is alive; its own teardown releases it.
    _step('bgDetachTimer', () => _bgDetachTimer?.cancel());
    _step('wakelock', () {
      if (!_floatingPipActiveAtTeardown && _wakelockHeld) {
        _wakelockHeld = false;
        // ignore: discarded_futures
        WakelockPlus.disable();
      }
    });
    _step('hwKeys', () => _hwKeys.disable());
    // Recorded so the NEXT crash log can say whether teardown finished. A
    // missing line here is the signal that something threw in a place still
    // not covered.
    PlaybackLog.add('player teardown done keepPlaying=$keepPlaying');
    super.dispose();
  }

  /// Run one teardown step in isolation.
  ///
  /// The whole failure this release fixes was one throwing line taking the
  /// other thirty with it, so each step gets its own guard and its own name in
  /// the log. The name is what makes the next log readable: "teardown step
  /// stopPlayback failed" says immediately which resource leaked.
  void _step(String name, void Function() body) {
    try {
      body();
    } catch (e) {
      PlaybackLog.add('TEARDOWN step $name failed: $e');
      if (kDebugMode) debugPrint('player_screen teardown $name: $e');
    }
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _fmtTimerBadge(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Set<ShortcutItem> _activeSet(PlayerState state) {
    final s = <ShortcutItem>{};
    if (state.loopMode != LoopMode.off || state.isLoopEnabled) s.add(ShortcutItem.loop);
    if (state.isMuted) s.add(ShortcutItem.mute);
    if (state.isShuffleEnabled) s.add(ShortcutItem.shuffle);
    if (state.isMirrorMode) s.add(ShortcutItem.mirrorMode);
    if (state.isVerticalFlip) s.add(ShortcutItem.verticalFlip);
    if (state.isNightMode) s.add(ShortcutItem.nightMode);
    if (state.isBackgroundPlay) s.add(ShortcutItem.backgroundPlay);
    if (state.playbackSpeed != 1.0) s.add(ShortcutItem.playbackSpeed);
    if (state.sleepTimer.isActive) s.add(ShortcutItem.sleepTimer);
    if (state.abPointA != null) s.add(ShortcutItem.abRepeat);
    return s;
  }

  Future<void> _captureScreenshot(BuildContext context) async {
    try {
      final boundary = _videoBoundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        _showSnack(context, 'Screenshot failed: no boundary');
        return;
      }
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        // `toImage` / `toByteData` above are both awaits, so match the
        // `context.mounted` guard this method already uses on its success and
        // error paths. The screenshot has failed either way; the only question
        // is whether there is still a Scaffold to say so in.
        if (context.mounted) {
          _showSnack(context, 'Screenshot failed: encoding error');
        }
        return;
      }
      final bytes = byteData.buffer.asUint8List();

      // Save to app documents directory (no extra permission needed)
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/screenshot_$ts.png');
      await file.writeAsBytes(bytes);

      if (!context.mounted) return;
      _showOverlay('Saved: ${p.basename(file.path)}');
    } catch (e) {
      if (!context.mounted) return;
      _showSnack(context, 'Screenshot error: $e');
    }
  }

  Future<void> _enterPip(BuildContext context) async {
    // The on-screen PiP button. Its behaviour follows the "Use custom PiP"
    // setting:
    //   • ON  (default) → in-app floating overlay: the video shrinks into a
    //     draggable window and we drop back to the screen the user came from
    //     (e.g. the Movies folder), staying INSIDE Innocent.
    //   • OFF           → Android system PiP: the video floats over other
    //     apps / the launcher.
    // (Leaving the app entirely always uses system PiP — see onUserLeaveHint
    //  — because the in-app overlay can't draw outside Innocent.)
    final useCustom =
        ref.read(playerSettingsProvider).get(PlayerSetting.useCustomPip);
    if (useCustom) {
      // Continuing over OTHER apps (once the user leaves Innocent from the
      // floating window) relies on the system Picture-in-picture permission.
      // It's ON by default on stock Android but some OEMs ship it OFF / the
      // user can revoke it — in which case the hand-off silently fails. The
      // first time in a session we notice it's off, point the user at the
      // Settings toggle instead of failing quietly.
      if (!_pipPermPromptedThisSession) {
        final allowed = await ref.read(pipServiceProvider).isPipAllowed();
        if (!allowed && context.mounted) {
          _pipPermPromptedThisSession = true;
          final goToSettings = await _showPipPermissionDialog(context);
          if (goToSettings == true) {
            await ref.read(pipServiceProvider).openPipSettings();
            return;
          }
        }
      }
      // The permission check and its dialog above are awaits, so the player
      // screen can be gone by now. Do NOT open the floating window in that
      // case: it would leave a video hovering over a screen the user has
      // already left, with no player behind it to expand back into. Bailing
      // out entirely is the decided behaviour — a PiP the user asked for is
      // worth less than one they cannot get rid of.
      if (!context.mounted) return;
      ref.read(floatingPipProvider.notifier).activate(
            // THE LIVE ADDRESS, NOT THE ONE WE WERE BORN WITH.
            //
            // `widget.videoUri` is immutable, but a renewed stream is playing
            // from a DIFFERENT url than the one this screen was pushed with.
            // Handing the little window the original means it carries a dead
            // address, and expanding back fails the adopt check below — so the
            // player reopens a url that expired, and playback restarts from
            // zero on a link that cannot work.
            ref.read(playerControllerProvider.notifier).activeUri ??
                widget.videoUri,
            widget.title,
            secure: widget.isPrivate || widget.secureScreen,
            ephemeral: widget.ephemeral,
          );
      if (context.canPop()) {
        _lockPortraitOnExit();
        context.pop();
      }
      return;
    }
    // System PiP path.
    final st = ref.read(playerControllerProvider);
    int w = 16;
    int h = 9;
    if (st.videoTracks.isNotEmpty) {
      final v = st.videoTracks.first;
      final vw = v.width ?? 0;
      final vh = v.height ?? 0;
      if (vw > 0 && vh > 0) {
        w = vw;
        h = vh;
      }
    }
    Rect? srcRect;
    final ro = _videoBoundaryKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      srcRect = ro.localToGlobal(Offset.zero) & ro.size;
    }
    final pipSvc = ref.read(pipServiceProvider);
    final entered = await pipSvc.enterPip(
      width: w,
      height: h,
      isPlaying: st.isPlaying,
      sourceRect: srcRect,
    );
    // If the device can't do system PiP, fall back to the in-app overlay so
    // the button always does *something* useful.
    if (!entered && context.mounted) {
      ref.read(floatingPipProvider.notifier).activate(
            // THE LIVE ADDRESS, NOT THE ONE WE WERE BORN WITH.
            //
            // `widget.videoUri` is immutable, but a renewed stream is playing
            // from a DIFFERENT url than the one this screen was pushed with.
            // Handing the little window the original means it carries a dead
            // address, and expanding back fails the adopt check below — so the
            // player reopens a url that expired, and playback restarts from
            // zero on a link that cannot work.
            ref.read(playerControllerProvider.notifier).activeUri ??
                widget.videoUri,
            widget.title,
            secure: widget.isPrivate || widget.secureScreen,
            ephemeral: widget.ephemeral,
          );
      if (context.canPop()) {
        _lockPortraitOnExit();
        context.pop();
      }
    }
  }

  /// One-time-per-session prompt explaining that over-apps playback needs the
  /// system Picture-in-picture permission, with a shortcut into Settings.
  /// Returns true if the user chose to open Settings.
  Future<bool?> _showPipPermissionDialog(BuildContext context) {
    final s = AppStrings.of(context);
    return showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(
          s.pipOverAppsTitle,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: Text(
          s.pipOverAppsBody,
          style: const TextStyle(
            color: AppColors.darkOnSurfaceMuted,
            fontSize: 14,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(
              s.openSettings,
              style: const TextStyle(color: AppColors.accentBlue),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickExternalSubtitle(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: SubtitleFormats.pickerExtensions,
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) return;

      final controller = ref.read(playerControllerProvider.notifier);
      await controller.loadExternalSubtitle(path);

      if (!context.mounted) return;
      _showSnack(context, 'Loaded: ${p.basename(path)}');
    } catch (e) {
      if (!context.mounted) return;
      _showSnack(context, 'Subtitle pick error: $e');
    }
  }

  Future<void> _addBookmark(BuildContext context) async {
    // Quick-add bookmark at current position, then show sheet
    final state = ref.read(playerControllerProvider);
    // Engine position: the UI copy is rounded to whole seconds and is only
    // refreshed while something on screen is showing it.
    final live = ref.read(videoPlayerServiceProvider).position;
    final position = live > Duration.zero ? live : state.position;
    await ref.read(bookmarksProvider.notifier).add(
          videoUri: widget.videoUri,
          videoTitle: widget.title,
          position: position,
        );
    if (!context.mounted) return;
    final h = position.inHours;
    final m = position.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = position.inSeconds.remainder(60).toString().padLeft(2, '0');
    final timeStr = h > 0 ? '$h:$m:$s' : '$m:$s';
    _showSnack(context, '⭐ Bookmark added at $timeStr');
  }

  Future<void> _showBookmarks(BuildContext context) async {
    final controller = ref.read(playerControllerProvider.notifier);
    await BookmarksSheet.show(
      context,
      ref,
      videoUri: widget.videoUri,
      onSeek: (pos) => controller.seek(pos),
    );
  }

  Future<void> _toggleFavourite(BuildContext context) async {
    // EPHEMERAL PLAYBACK CANNOT BE SAVED OR SENT.
    //
    // The address is a signed, short-lived credential, not a location. Writing
    // it into a favourite or a playlist stores a key that stops working, and
    // sharing it hands a stranger the paid stream for as long as the signature
    // lasts — which defeats the entire reason the URL is signed. The +289
    // audit closed the resume and history paths and MISSED these four, which
    // is the same bug wearing four more hats.
    if (widget.ephemeral) {
      _showSnack(context, 'This title can only be opened from its own page.');
      return;
    }
    // Audit: haptic on a binary toggle gives the user immediate
    // tactile confirmation the action registered, even before the
    // snackbar slides in.
    HapticService.medium();
    final added = await ref
        .read(favouritesProvider.notifier)
        .toggle(widget.videoUri);
    if (!context.mounted) return;
    _showSnack(context, added ? '★ Added to favourites' : '☆ Removed');
  }

  Future<void> _addToPlaylist(BuildContext context) async {
    // EPHEMERAL PLAYBACK CANNOT BE SAVED OR SENT.
    //
    // The address is a signed, short-lived credential, not a location. Writing
    // it into a favourite or a playlist stores a key that stops working, and
    // sharing it hands a stranger the paid stream for as long as the signature
    // lasts — which defeats the entire reason the URL is signed. The +289
    // audit closed the resume and history paths and MISSED these four, which
    // is the same bug wearing four more hats.
    if (widget.ephemeral) {
      _showSnack(context, 'This title can only be opened from its own page.');
      return;
    }
    final playlists = ref.read(playlistsProvider);
    if (playlists.isEmpty) {
      _showSnack(context, 'No playlists yet. Create one from Me → Video Playlists');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      // Named, not `_`: the tile below pops THIS sheet to return the chosen
      // playlist id. Under Dart 3.7 semantics `_` stops binding, so the name
      // has to be real — see the note in docs/upgrade_plan.md §4a.
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(AppStrings.of(context).addToPlaylist,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            ...playlists.map(
              (pl) => ListTile(
                leading: const Icon(Icons.playlist_play, color: Colors.white),
                title: Text(pl.name, style: const TextStyle(color: Colors.white)),
                subtitle: Text(
                  '${pl.videoUris.length} videos',
                  style: const TextStyle(
                    color: AppColors.darkOnSurfaceMuted,
                    fontSize: 12,
                  ),
                ),
                onTap: () => Navigator.of(sheetCtx).pop(pl.id),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    await ref
        .read(playlistsProvider.notifier)
        .addVideo(picked, widget.videoUri);
    if (!context.mounted) return;
    // `firstWhere` with no `orElse` THROWS. The sheet above is async, so a
    // playlist deleted from another screen while it was open would have taken
    // the player down on an otherwise successful add. Same defect as the one
    // fixed in the multi-select bar; this copy was missed.
    final matches = playlists.where((p) => p.id == picked);
    final name = matches.isEmpty ? '' : matches.first.name;
    _showSnack(context, AppStrings.of(context).addedToPlaylist(1, name));
  }

  Future<void> _shareVideo(BuildContext context) async {
    // EPHEMERAL PLAYBACK CANNOT BE SAVED OR SENT.
    //
    // The address is a signed, short-lived credential, not a location. Writing
    // it into a favourite or a playlist stores a key that stops working, and
    // sharing it hands a stranger the paid stream for as long as the signature
    // lasts — which defeats the entire reason the URL is signed. The +289
    // audit closed the resume and history paths and MISSED these four, which
    // is the same bug wearing four more hats.
    if (widget.ephemeral) {
      _showSnack(context, 'This title can only be opened from its own page.');
      return;
    }
    try {
      await Share.share(widget.videoUri, subject: widget.title);
    } catch (e) {
      if (!context.mounted) return;
      _showSnack(context, 'Share failed: $e');
    }
  }

  /// Add the currently-playing video to the in-app Transfer queue and jump to
  /// the Transfer tab, so the user can send the exact file they're watching.
  Future<void> _transferVideo(BuildContext context) async {
    // EPHEMERAL PLAYBACK CANNOT BE SAVED OR SENT.
    //
    // The address is a signed, short-lived credential, not a location. Writing
    // it into a favourite or a playlist stores a key that stops working, and
    // sharing it hands a stranger the paid stream for as long as the signature
    // lasts — which defeats the entire reason the URL is signed. The +289
    // audit closed the resume and history paths and MISSED these four, which
    // is the same bug wearing four more hats.
    if (widget.ephemeral) {
      _showSnack(context, 'This title can only be opened from its own page.');
      return;
    }
    try {
      final uri = widget.videoUri;
      String path;
      // Android/data (adb://) videos can't be read by the LAN server — pull a
      // local copy first, exactly like the Transfer picker does. Everything
      // else uses its real filesystem path.
      if (uri.startsWith('adb://')) {
        final src = uri.substring('adb://'.length);
        final pulled = await AdbService.instance.pullForPlayback(src);
        if (pulled.startsWith('ERROR')) {
          if (!context.mounted) return;
          _showSnack(context,
              'Connect iADB to send this Android/data video.');
          return;
        }
        path = pulled;
      } else {
        path = uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri;
      }
      int size = 0;
      try {
        size = await File(path).length();
      } catch (e) { if (kDebugMode) debugPrint('player_screen.best-effort: $e'); }
      if (!context.mounted) return;
      final file = SharedFile(
        id: '${path.hashCode}',
        path: path,
        displayName:
            widget.title.isNotEmpty ? widget.title : p.basename(path),
        sizeBytes: size,
      );
      ref.read(transferProvider.notifier).addFiles([file]);
      // Land on the Transfer tab (index 2 → Send mode) with the file queued.
      ref.read(shellTabIndexProvider.notifier).state = 2;
      context.go(Routes.transfer);
    } catch (e) {
      if (!context.mounted) return;
      _showSnack(context, 'Could not add to Transfer: $e');
    }
  }

  void _showInfo(BuildContext context) {
    // Show the SAME rich dialog as the library's "Properties" action, so the
    // in-player Information button surfaces file / media / playback details
    // instead of just the URI. We assemble a Video from what the player knows
    // (uri, title, duration, and the active video track's dimensions); the
    // dialog itself fills in exact size, on-disk path, date and resume
    // position by reading the file. `overPlayer` uses a translucent scrim so
    // the video stays faintly visible behind the dialog.
    final state = ref.read(playerControllerProvider);
    final vt = state.videoTracks.isNotEmpty ? state.videoTracks.first : null;
    final path = widget.videoUri.startsWith('file://')
        ? Uri.parse(widget.videoUri).toFilePath()
        : widget.videoUri;
    final folder = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '';
    final video = Video(
      id: widget.videoUri,
      uri: widget.videoUri,
      title: widget.title,
      folderPath: folder,
      duration: state.duration,
      sizeBytes: 0, // dialog resolves exact bytes from disk
      width: vt?.width ?? 0,
      height: vt?.height ?? 0,
      mimeType: null,
      dateAdded: null,
    );
    VideoInfoDialog.show(context, video, overPlayer: true);
  }

  /// v1.63: timing, size and position, adjusted against the running picture.
  ///
  /// This replaced a sheet that offered timing alone. Size and position were
  /// reachable only from Settings — three screens from the one moment anybody
  /// notices they are wrong. Each change is written straight to libmpv AND
  /// persisted, so it survives the next video rather than being a temporary
  /// nudge the user has to make again.
  void _showSubtitleDelay(BuildContext context) {
    final extras = ref.read(extraSettingsProvider);
    final svc = ref.read(videoPlayerServiceProvider);
    // The panel is a modal route, so the system bars come back while it is up
    // and the player is no longer the top route. Immersive is re-applied when
    // it closes — the lifecycle path at `playerIsTop` only fires on an app
    // resume, which does not happen for an in-app sheet.
    // ignore: discarded_futures
    SubtitleTunePanel.show(
      context,
      initialDelayMs: _subtitleDelayMs,
      initialScale: extras.getInt(IntSetting.subtitleScale) / 100.0,
      initialVerticalPos: extras.getInt(IntSetting.subtitleVerticalPos),
      onDelayChanged: (ms) {
        if (mounted) setState(() => _subtitleDelayMs = ms);
        // Persist, like size and position do. A timing fix that evaporates
        // when the file closes is a fix the user has to make again for the
        // next episode of the same badly-synced series.
        // ignore: discarded_futures
        extras.setInt(IntSetting.subtitleDefaultSync, ms);
        // Best-effort by design: libmpv refuses unknown properties on some
        // builds, and a subtitle nudge must never be able to interrupt
        // playback.
        try {
          svc.setSubtitleDelay(Duration(milliseconds: ms));
        } catch (_) {}
      },
      onScaleChanged: (scale) {
        try {
          if (svc is MediaKitPlayerService) svc.setSubtitleScale(scale);
        } catch (_) {}
        // ignore: discarded_futures
        extras.setInt(IntSetting.subtitleScale, (scale * 100).round());
      },
      onVerticalPosChanged: (pos) {
        try {
          if (svc is MediaKitPlayerService) svc.setSubtitleVerticalPos(pos);
        } catch (_) {}
        // ignore: discarded_futures
        extras.setInt(IntSetting.subtitleVerticalPos, pos);
      },
    ).whenComplete(() {
      if (mounted) _applySystemUiMode();
    });
  }

  void _showCustomSpeed(BuildContext context) {
    final state = ref.read(playerControllerProvider);
    CustomSpeedDialog.show(
      context,
      currentSpeed: state.playbackSpeed,
      onSpeedSet: (speed) {
        ref.read(playerControllerProvider.notifier).setSpeed(speed);
      },
    );
  }

  /// Phase 15: Loop menu (long-press Next button)
  void _showLoopMenu(BuildContext context) {
    LoopMenuSheet.show(context);
  }

  void _onShortcutTap(BuildContext context, ShortcutItem item) {
    final controller = ref.read(playerControllerProvider.notifier);
    controller.showControls();
    switch (item) {
      case ShortcutItem.mute:
        // Phase 45: compute the toast based on the current state BEFORE
        // calling toggleMute — that function awaits libmpv/system volume
        // before updating the isMuted flag, so reading it immediately
        // after would show the old value.
        {
          final wasMuted = ref.read(playerControllerProvider).isMuted;
          controller.toggleMute();
          _showOverlay(wasMuted ? 'Unmuted' : 'Muted');
        }
        break;
      case ShortcutItem.loop:
        // Phase 15: cycle Off → One → All → Off
        // Phase 45: toast the new mode so the user sees what mode is
        // active. Without this it's not obvious which of 3 modes the
        // single icon represents.
        {
          final cur = ref.read(playerControllerProvider).loopMode;
          final next = cur == LoopMode.off
              ? LoopMode.one
              : cur == LoopMode.one
                  ? LoopMode.all
                  : LoopMode.off;
          controller.setLoopMode(next);
          final label = next == LoopMode.off
              ? 'Loop off'
              : next == LoopMode.one
                  ? 'Loop one'
                  : 'Loop all';
          _showOverlay(label);
        }
        break;
      case ShortcutItem.shuffle:
        controller.toggleShuffle();
        // Phase 45: toast feedback.
        {
          final on = ref.read(playerControllerProvider).isShuffleEnabled;
          _showOverlay(on ? 'Shuffle on' : 'Shuffle off');
        }
        break;
      case ShortcutItem.mirrorMode:
        controller.toggleMirrorMode();
        // Phase 45: toast feedback.
        {
          final on = ref.read(playerControllerProvider).isMirrorMode;
          _showOverlay(on ? 'Mirror mode on' : 'Mirror mode off');
        }
        break;
      case ShortcutItem.verticalFlip:
        controller.toggleVerticalFlip();
        // Phase 45: toast feedback.
        {
          final on = ref.read(playerControllerProvider).isVerticalFlip;
          _showOverlay(on ? 'Vertical flip on' : 'Vertical flip off');
        }
        break;
      case ShortcutItem.nightMode:
        controller.toggleNightMode();
        // Phase 45: toast feedback.
        {
          final on = ref.read(playerControllerProvider).isNightMode;
          _showOverlay(on ? 'Night mode on' : 'Night mode off');
        }
        break;
      case ShortcutItem.backgroundPlay:
        // Phase 45: toggle + toast so the user knows what changed. The
        // headphone icon is "audio continues playing when the app is in
        // background or the screen is off". The actual continuation is
        // handled by `didChangeAppLifecycleState` reading
        // `state.isBackgroundPlay` and skipping the auto-pause.
        controller.toggleBackgroundPlay();
        {
          final on = ref.read(playerControllerProvider).isBackgroundPlay;
          _showOverlay(on ? 'Background play on' : 'Background play off');
        }
        break;
      case ShortcutItem.playbackSpeed:
        // Phase 45: compute the next speed value here instead of reading
        // state after `cycleSpeed()` returns — `setSpeed` awaits libmpv's
        // setRate before updating state, so a read-immediately-after
        // would show the OLD speed in the toast.
        {
          const cycle = [0.5, 1.0, 1.25, 1.5, 2.0];
          final current = ref.read(playerControllerProvider).playbackSpeed;
          final idx =
              cycle.indexWhere((s) => (s - current).abs() < 0.01);
          final next = cycle[(idx + 1) % cycle.length];
          controller.setSpeed(next);
          _showOverlay('Speed ${next.toStringAsFixed(2)}x');
        }
        break;
      case ShortcutItem.screenRotation:
        // Auto → Portrait → Landscape → Auto, the way MX Player's does.
        //
        // The previous version read the current orientation and flipped to the
        // other one, which meant it could only ever PIN the device: the first
        // tap overrode the phone's own auto-rotate and nothing in the player
        // could hand it back. Anyone who straightened out one awkward clip was
        // then stuck with a fixed orientation for every video that session.
        _rotationMode = (_rotationMode + 1) % 3;
        _applyRotationMode(announce: true);
        break;
      case ShortcutItem.customiseItems:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const CustomiseItemsScreen(),
          ),
        );
        break;
      case ShortcutItem.screenshot:
        _captureScreenshot(context);
        break;
      case ShortcutItem.sleepTimer:
        controller.openSleepTimerDialog();
        break;
      case ShortcutItem.equalizer:
        // MX Player–style audio effects panel as a bottom sheet that slides
        // up over the video. Equalizer opens on the Equalizer tab.
        showAudioEffectSheet(context, initialTab: 1);
        break;
      case ShortcutItem.audioEffect:
        // Same panel, opened on the Audio Effect tab (Bass Boost /
        // Virtualizer dials).
        showAudioEffectSheet(context, initialTab: 0);
        break;
      case ShortcutItem.abRepeat:
        controller.cycleABRepeat();
        final st = ref.read(playerControllerProvider);
        if (st.abPointA != null && st.abPointB == null) {
          _showOverlay('A point set');
        } else if (st.abPointA != null && st.abPointB != null) {
          _showOverlay('A-B loop active');
        } else {
          _showOverlay('A-B repeat cleared');
        }
        break;
    }
  }

  void _showSnack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// Show a brief dark text badge in the player (MX Player style shortcut feedback).
  /// Replaces SnackBar for shortcut actions so the feedback stays inside the player.
  void _showOverlay(String msg) {
    _overlayMsg.value = msg;
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) _overlayMsg.value = null;
    });
  }

  // The app is portrait-only; only the player may rotate to landscape.
  // dispose() also restores portrait, but it runs AFTER the route
  // transition, so the destination screen can briefly build in landscape
  // (and on some devices the post-dispose call is unreliable). Calling
  // this synchronously at every exit point flips orientation BEFORE
  // navigation, so the previous screen rebuilds already in portrait.
  void _lockPortraitOnExit() {
    SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.portraitUp]);
  }

  /// Retry, and REPLACE the address first if it can be replaced.
  ///
  /// The button used to reopen `widget.videoUri` verbatim, which is correct
  /// for a file and useless for a short-lived signed stream URL: once the
  /// signature has expired every retry fails identically, and the user is left
  /// pressing a button that cannot work. Asking for a fresh URL is a new
  /// server request, so entitlement is re-decided rather than extended.
  Future<void> _retryPlayback(PlayerController controller) async {
    final current = controller.activeUri ?? widget.videoUri;
    if (StreamRenewal.canRenew(current)) {
      final fresh = await StreamRenewal.renew(current);
      if (!mounted) return;
      if (fresh != null) {
        await controller.openVideo(fresh,
            title: widget.title,
            isPrivate: widget.isPrivate,
            ephemeral: true);
        return;
      }
    }
    if (!mounted) return;
    await controller.openVideo(widget.videoUri,
        title: widget.title,
        isPrivate: widget.isPrivate,
        ephemeral: widget.ephemeral);
  }

  /// Single source of truth for "the user wants to leave the player" — used by
  /// BOTH the on-screen back arrow and the phone's hardware/gesture back
  /// button, so they behave identically. Handles Kids Lock and the optional
  /// double-tap-to-exit setting, and — crucially — pops the route ITSELF
  /// Immediately silence playback when leaving the player, using the SAME
  /// keep-playing rule as dispose() (PiP taking over, or background-play on for
  /// a non-private video). Called at the moment we commit to popping so audio
  /// stops on the same frame as the back press — not after the route animation.
  void _stopAudioIfLeaving() {
    if (!mounted) return;
    // Same rule as dispose() — see the long note there. Only the floating
    // window may carry playback out of this screen.
    final pipActive = ref.read(floatingPipProvider).isActive;
    final keepPlaying = pipActive;
    if (keepPlaying) return;
    try {
      ref.read(playerControllerProvider.notifier).stopPlaybackImmediate();
    } catch (e) {
      if (kDebugMode) debugPrint('player_screen.best-effort: $e');
    }
  }

  /// rather than relying on PopScope's `canPop` flipping (which never happened
  /// because the flag was set without a rebuild, so the phone back button
  /// used to just re-show the toast forever and never actually exit).
  void _handleBackRequest() {
    if (!mounted) return;
    final state = ref.read(playerControllerProvider);
    // Kids Lock: swallow the back entirely and nudge how to unlock.
    if (state.isKidsLocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).kidsLockHoldHint),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    final requireDouble =
        ref.read(playerSettingsProvider).get(PlayerSetting.doubleTapBack);
    final now = DateTime.now();
    final withinWindow = _lastBackPressAt != null &&
        now.difference(_lastBackPressAt!) < const Duration(seconds: 2);
    if (!requireDouble || withinWindow) {
      _lockPortraitOnExit();
      // Silence audio the INSTANT we commit to leaving (unless PiP is taking
      // over or background-play is on) — waiting for dispose() let audio bleed
      // through behind the previous screen for a moment. dispose() still does
      // the authoritative async teardown.
      _stopAudioIfLeaving();
      if (context.canPop()) context.pop();
      return;
    }
    // First press of a double-tap exit → arm the window + hint.
    _lastBackPressAt = now;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppStrings.of(context).pressBackAgain),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showAudioTracks(BuildContext context) {
    final state = ref.read(playerControllerProvider);
    final controller = ref.read(playerControllerProvider.notifier);
    if (state.audioTracks.isEmpty) {
      _showSnack(context, 'No audio tracks available');
      return;
    }
    TrackSelectionSheet.showAudio(
      context,
      tracks: state.audioTracks,
      current: state.currentAudioTrack,
      // Phase 45 (audit): wrap the selection callback so the user sees a
      // brief toast confirming what they just switched to — MX Player
      // shows this as "Audio: <track name>" in the same position as
      // the gesture indicator. Without it the user has no idea whether
      // the tap registered.
      onSelect: (track) async {
        await controller.selectAudioTrack(track);
        if (track != null && context.mounted) {
          AppSnackbar.show(context, 'Audio: ${track.displayName}');
        }
      },
    );
  }

  void _showSubtitleTracks(BuildContext context) {
    final state = ref.read(playerControllerProvider);
    final controller = ref.read(playerControllerProvider.notifier);
    TrackSelectionSheet.showSubtitle(
      context,
      tracks: state.subtitleTracks,
      current: state.currentSubtitleTrack,
      // Phase 45 (audit): same feedback toast as the audio picker, plus
      // an explicit "Subtitle off" message when the user picks no
      // subtitle (otherwise nothing changes visibly).
      onSelect: (track) async {
        await controller.selectSubtitleTrack(track);
        if (context.mounted) {
          AppSnackbar.show(
            context,
            track == null
                ? 'Subtitle off'
                : 'Subtitle: ${track.displayName}',
          );
        }
      },
      onLoadExternal: () => _pickExternalSubtitle(context),
    );
  }

  /// Phase 45 (audit refined): show the MX Player V3 explicit aspect
  /// ratio picker. 12 options matching the decompiled
  /// `aspect_ratios_landscape` array — Default / 1:1 / 4:3 / 16:9 /
  /// 16:10 / 21:9 / 64:27 / 2.21:1 / 2.35:1 / 2.39:1 / 5:4 / Custom.
  /// Picking persists via [StringSetting.aspectRatioOverride] so it
  /// applies on every subsequent play.
  Future<void> _showAspectRatioPicker(BuildContext context) async {
    final extras = ref.read(extraSettingsProvider);
    final current = AspectRatioOverride.fromString(
        extras.getStr(StringSetting.aspectRatioOverride));
    final controller = ref.read(playerControllerProvider.notifier);
    final picked = await showDialog<AspectRatioOverride>(
      context: context,
      builder: (dctx) => SimpleDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).aspectRatioTitle,
            style: const TextStyle(color: Colors.white)),
        children: AspectRatioOverride.values.map((r) {
          final isSelected = r == current;
          return SimpleDialogOption(
            onPressed: () => Navigator.of(dctx).pop(r),
            child: Row(
              children: [
                Icon(
                  isSelected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: isSelected
                      ? AppColors.accentBlue
                      : Colors.white54,
                ),
                const SizedBox(width: 12),
                Text(
                  r.label,
                  style: TextStyle(
                    color: isSelected
                        ? AppColors.accentBlue
                        : Colors.white,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
    if (picked != null && context.mounted) {
      await controller.setExplicitAspectRatio(picked);
      if (context.mounted) {
        AppSnackbar.show(context, 'Aspect: ${picked.label}');
      }
    }
  }

  List<MoreMenuItemData> _buildMoreMenuItems(BuildContext context) {
    final controller = ref.read(playerControllerProvider.notifier);
    final s = AppStrings.of(context);

    // Phase 18: Order and selection match real MX Player More panel
    // (Function PDF page 5 reference).
    return [
      MoreMenuItemData(
        label: s.playingQueue,
        category: MoreMenuCategory.playback,
        icon: Icons.queue_music,
        onTap: () {
          controller.closePanel();
          PlayingQueueSheet.show(
            context,
            currentTitle: widget.title,
          );
        },
      ),
      // Kids Lock (v0.49, MX parity): child-proof shield. Lives in the
      // Action section next to the other "change how the screen reacts"
      // switches.
      MoreMenuItemData(
        label: s.kidsLock,
        category: MoreMenuCategory.action,
        icon: Icons.child_care,
        onTap: () {
          controller.closePanel();
          controller.toggleKidsLock();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppStrings.of(context).kidsLockOnMsg),
              duration: const Duration(seconds: 2),
            ),
          );
        },
      ),
      MoreMenuItemData(
        label: s.aspectRatioMenu,
        category: MoreMenuCategory.playback,
        icon: Icons.aspect_ratio,
        onTap: () {
          controller.closePanel();
          // Phase 45 (audit refined): open the 12-ratio explicit
          // picker dialog (matches MX Player V3). The previous
          // behavior (cycle 4 modes) is still available via the
          // dedicated bottom-bar button.
          _showAspectRatioPicker(context);
        },
      ),
      MoreMenuItemData(
        label: s.displaySettings,
        category: MoreMenuCategory.playback,
        icon: Icons.tune,
        onTap: () {
          controller.closePanel();
          DisplaySettingsSheet.show(context);
        },
      ),
      MoreMenuItemData(
        label: s.bookmark,
        category: MoreMenuCategory.edit,
        icon: Icons.bookmark_outline,
        onTap: () async {
          controller.closePanel();
          await _addBookmark(context);
          if (!context.mounted) return;
          await _showBookmarks(context);
        },
      ),
      MoreMenuItemData(
        label: s.cut,
        category: MoreMenuCategory.edit,
        icon: Icons.content_cut,
        onTap: () {
          controller.closePanel();
          CutSheet.show(context, ref);
        },
      ),
      MoreMenuItemData(
        label: s.favourite,
        category: MoreMenuCategory.library,
        icon: Icons.favorite_outline,
        onTap: () {
          controller.closePanel();
          _toggleFavourite(context);
        },
      ),
      MoreMenuItemData(
        label: s.addToPlaylistMenu,
        category: MoreMenuCategory.library,
        icon: Icons.playlist_add,
        onTap: () {
          controller.closePanel();
          _addToPlaylist(context);
        },
      ),
      MoreMenuItemData(
        label: s.information,
        category: MoreMenuCategory.info,
        icon: Icons.info_outline,
        onTap: () {
          controller.closePanel();
          _showInfo(context);
        },
      ),
      MoreMenuItemData(
        label: s.share,
        category: MoreMenuCategory.action,
        icon: Icons.share,
        onTap: () {
          controller.closePanel();
          _shareVideo(context);
        },
      ),
      MoreMenuItemData(
        label: s.tabTransfer,
        category: MoreMenuCategory.action,
        icon: Icons.send_to_mobile,
        onTap: () {
          controller.closePanel();
          _transferVideo(context);
        },
      ),
      MoreMenuItemData(
        label: s.networkStream,
        category: MoreMenuCategory.action,
        icon: Icons.public,
        onTap: () {
          controller.closePanel();
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const NetworkStreamScreen()),
          );
        },
      ),
      MoreMenuItemData(
        label: s.tutorial,
        category: MoreMenuCategory.info,
        icon: Icons.help_outline,
        onTap: () {
          controller.closePanel();
          GesturesHelpOverlay.show(context);
        },
      ),
      MoreMenuItemData(
        label: s.subtitleDelayMenu,
        category: MoreMenuCategory.playback,
        icon: Icons.subtitles_outlined,
        onTap: () {
          controller.closePanel();
          _showSubtitleDelay(context);
        },
      ),
      MoreMenuItemData(
        label: s.skipMarkers,
        category: MoreMenuCategory.edit,
        icon: Icons.skip_next_outlined,
        onTap: () {
          controller.closePanel();
          SkipMarkersSheet.show(context);
        },
      ),
      MoreMenuItemData(
        label: s.customSpeed,
        category: MoreMenuCategory.playback,
        icon: Icons.speed,
        onTap: () {
          controller.closePanel();
          _showCustomSpeed(context);
        },
      ),
    ];
  }

  Widget _wrapVideoTransforms(Widget child, PlayerState state) {
    Widget result = child;
    if (state.isMirrorMode || state.isVerticalFlip) {
      result = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(
          state.isMirrorMode ? -1.0 : 1.0,
          state.isVerticalFlip ? -1.0 : 1.0,
          1.0,
        ),
        child: result,
      );
    }
    if (state.isNightMode) {
      result = ColorFiltered(
        colorFilter: const ColorFilter.matrix([
          1, 0, 0, 0, 0,
          0, 0.4, 0, 0, 0,
          0, 0, 0.2, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: result,
      );
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final svc = ref.watch(videoPlayerServiceProvider);
    final state = ref.watch(playerControllerProvider);
    final controller = ref.read(playerControllerProvider.notifier);

    // Screen wake lock follows playback rather than the player's lifetime.
    _applyKeepScreenOn(state);

    // Phase 41: when "Back to list" is on, completing a video flips
    // [playbackCompleted] in state. Pop back to the file list once that
    // happens.
    ref.listen<PlayerState>(playerControllerProvider, (prev, next) {
      if (prev?.playbackCompleted == next.playbackCompleted) return;
      if (next.playbackCompleted && context.mounted) {
        _lockPortraitOnExit();
        context.pop();
      }
    });

    // Phase 45: when Settings → Player → Screen toggles flip while a
    // video is playing, push the change to the system immediately.
    // Without this the user has to back out of the player and re-open
    // for "Auto-rotation" / "Keep screen on" to take effect.
    ref.listen<PlayerSettings>(playerSettingsProvider, (prev, next) {
      // Auto-rotation
      final prevAutoRot =
          prev?.get(PlayerSetting.screenAutoRotation) ?? true;
      final nextAutoRot = next.get(PlayerSetting.screenAutoRotation);
      if (prevAutoRot != nextAutoRot) {
        final legacyAutoRot = ref.read(preferencesProvider).autoRotate;
        if (legacyAutoRot && nextAutoRot) {
          SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
            DeviceOrientation.portraitUp,
          ]);
        } else {
          SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        }
      }
      // Keep screen on
      // Full screen applies live — flipping it should not need a re-open.
      if (prev == null ||
          prev.get(PlayerSetting.screenFullScreen) !=
              next.get(PlayerSetting.screenFullScreen)) {
        _applySystemUiMode();
      }
      final prevKeep = prev?.get(PlayerSetting.screenKeepOn) ?? true;
      final nextKeep = next.get(PlayerSetting.screenKeepOn);
      if (prevKeep != nextKeep) {
        final legacyKeep = ref.read(preferencesProvider).keepScreenOn;
        // Update the permission and let _applyKeepScreenOn decide; toggling
        // the lock directly here would fight the playback-driven logic.
        _keepScreenOnAllowed = legacyKeep && nextKeep;
        _applyKeepScreenOn(ref.read(playerControllerProvider));
      }
    });

    // PDF page 4: When collapsed only essentials show; when expanded ALL shortcuts available
    final visibleShortcutList = state.shortcutsExpanded
        ? ShortcutItem.values.toList()
        : ShortcutItem.values
            .where((i) => state.visibleShortcuts.contains(i))
            .toList();

    final blockGestures = state.isLocked ||
        state.isKidsLocked ||
        state.openPanel != SidePanel.none ||
        state.decoderDialogOpen ||
        state.sleepTimerDialogOpen ||
        state.resumeDialogOpen;

    // Phase 42: also enforce "Double-tap the back button" on the SYSTEM back
    // gesture/button, not only the on-screen back arrow. Daily users on
    // Android most often close videos with the system back, so without this
    // wrap they could skip the protection entirely.
    // (The double-tap / Kids Lock decision now lives in _handleBackRequest,
    //  shared by the phone back button and the on-screen arrow.)
    return PopScope(
      // Always intercept: we decide in the handler whether to actually leave
      // (single vs double-tap, Kids Lock) and pop the route ourselves. This
      // is what makes the phone's back button exit the player — the old code
      // gated on `canPop` flipping to true, which never happened.
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) {
          _lockPortraitOnExit();
          return;
        }
        _handleBackRequest();
      },
      child: Scaffold(
        backgroundColor: AppColors.playerBackground,
        body: Stack(
        children: [
          // === LAYER 1: Video (with screenshot boundary) ===
          Positioned.fill(
            child: RepaintBoundary(
              key: _videoBoundaryKey,
              child: Container(
                color: Colors.black,
                child: _videoDisplayEnabled && svc.isInitialized
                    // Only wrap in a Transform when the user has actually
                    // pinch-zoomed. At 1.0 the transform is the identity, but
                    // it still pushes a transform layer the compositor has to
                    // carry on every single frame for no visible effect.
                    ? (state.videoScale == 1.0
                        ? _wrapVideoTransforms(
                            svc.buildVideoWidget(
                                fit: state.aspectRatioMode.boxFit),
                            state,
                          )
                        : Transform.scale(
                            scale: state.videoScale,
                            child: _wrapVideoTransforms(
                              svc.buildVideoWidget(
                                  fit: state.aspectRatioMode.boxFit),
                              state,
                            ),
                          ))
                    : (svc.isInitialized
                        ? const Center(
                            child: Icon(
                              Icons.music_note,
                              color: Colors.white24,
                              size: 80,
                            ),
                          )
                        : const Center(child: CircularProgressIndicator())),
              ),
            ),
          ),

          // === LAYER 2: Buffering ===
          // Phase 41: gated by "Loading circle animation" (Settings →
          // Player → Misc). When off, the buffering UI is suppressed.
          if (state.isBuffering &&
              state.activeIndicator == null &&
              ref
                  .watch(playerSettingsProvider)
                  .get(PlayerSetting.loadingCircle))
            const Center(
              child: CircularProgressIndicator(color: AppColors.accentBlue),
            ),

          // Loading text for a long, non-network load (chiefly copying an
          // Android/data video out over ADB before playback). Sits under the
          // spinner so the wait reads as progress, not a frozen screen.
          if (state.loadingMessage != null && state.isBuffering)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).size.height * 0.18,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    state.loadingMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),

          // Audit fix (C4): tier-1 "slow connection" hint, shown
          // after 3 s of continuous network buffering. Positioned
          // just under the centred spinner; auto-disappears when
          // buffering recovers (controller clears the flag).
          if (state.slowNetworkHintVisible && state.isBuffering)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).size.height * 0.18,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_off,
                          size: 16, color: Colors.white70),
                      const SizedBox(width: 8),
                      Text(AppStrings.of(context).slowBuffering,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // === LAYER 3: Gestures ===
          if (!blockGestures)
            Positioned.fill(
              child: GestureOverlay(
                onTap: controller.toggleControls,
                onDoubleTapRewind: controller.onDoubleTapRewind,
                onDoubleTapForward: controller.onDoubleTapForward,
                onDoubleTapCenter: controller.onDoubleTapCenter,
                onBrightnessDelta: controller.onBrightnessDelta,
                onVolumeDelta: controller.onVolumeDelta,
                onSeekStart: controller.onSeekStart,
                onSeekUpdate: controller.onSeekUpdate,
                onSeekEnd: controller.onSeekEnd,
                onLongPressStart: controller.onLongPressStart,
                onLongPressEnd: controller.onLongPressEnd,
                onLongPressMoveGlobal: controller.onLongPressDragSpeed,
                onPinchUpdate: controller.onPinchUpdate,
                onPinchEnd: controller.onPinchEnd,
                // Phase 45: respect the user's per-gesture toggles from
                // Settings → Controls. Each gate is independent so the
                // user can, e.g., keep brightness swipe but disable
                // volume swipe.
                brightnessSwipeEnabled: ref
                    .watch(playerSettingsProvider)
                    .get(PlayerSetting.ctlSwipeBrightness),
                volumeSwipeEnabled: ref
                    .watch(playerSettingsProvider)
                    .get(PlayerSetting.ctlSwipeVolume),
                seekSwipeEnabled: ref
                    .watch(playerSettingsProvider)
                    .get(PlayerSetting.ctlSwipeSeek),
                pinchZoomEnabled: ref
                    .watch(playerSettingsProvider)
                    .get(PlayerSetting.ctlPinchZoom),
                longPressSpeedEnabled: ref
                    .watch(playerSettingsProvider)
                    .get(PlayerSetting.ctlLongPressSpeed),
              ),
            ),

          // === LAYER 4: Top bar ===
          // Audit fix (standard high-quality): toolbar position
          // toggleable. When set to 'bottom', the bar sits just
          // above the playback controls (~120 px from bottom edge)
          // so its buttons fall within the thumb-arc of a one-handed
          // grip. Default 'top' is the conventional position.
          if (state.controlsVisible &&
              !state.isLocked &&
              !state.sleepTimerDialogOpen)
            Builder(builder: (ctx) {
              final pos = ref
                  .read(extraSettingsProvider)
                  .getStr(StringSetting.toolbarPosition);
              return Positioned(
                top: pos == 'bottom' ? null : 0,
                bottom: pos == 'bottom' ? 120 : null,
                left: 0,
                right: 0,
                child: _TopBar(
                title: widget.title,
                decoderLabel: state.decoder.label,
                sleepTimerRemaining: state.sleepTimer.remaining,
                // Phase 41: respect "Double-tap the back button" (Settings →
                // Player → Interface). When enabled, the first press shows
                // a snackbar and only the second press within 2 seconds
                // actually closes the player.
                onBack: _handleBackRequest,
                onAudio: () => _showAudioTracks(context),
                onSubtitle: controller.openSubtitleMenu,
                onDecoder: controller.openDecoderDialog,
                onMore: controller.openMoreMenu,
                // Phase 45 (audit): PiP icon is in the TOP bar (MX V3 parity).
                onEnterPip: () => _enterPip(context),
                fmtTimer: _fmtTimerBadge,
                hasMultipleAudioTracks: state.audioTracks.length > 1,
                hasMultipleSubtitleTracks: state.subtitleTracks.length > 1,
                showTitle: ref
                    .watch(playerSettingsProvider)
                    .get(PlayerSetting.styleShowTitle),
                showClock: ref
                    .watch(playerSettingsProvider)
                    .get(PlayerSetting.styleShowClock),
                // NEVER for an ephemeral or capture-protected stream. The
                // whole string is the credential for a signed URL — drawing it
                // on screen puts the token in every screenshot, every screen
                // recording and every over-the-shoulder glance, which is the
                // one thing FLAG_SECURE was acquired to prevent.
                sourceLabel: ref
                            .watch(playerSettingsProvider)
                            .get(PlayerSetting.styleShowSourceUrl) &&
                        !widget.ephemeral &&
                        !widget.secureScreen &&
                        (widget.videoUri.startsWith('http') ||
                            widget.videoUri.startsWith('rtmp') ||
                            widget.videoUri.startsWith('rtsp'))
                    ? widget.videoUri
                    : null,
              ),
            );
          }),

          // === LAYER 5: Speed indicator ===
          if (!state.sleepTimerDialogOpen &&
              ((state.controlsVisible && !state.isLocked) ||
                  state.playbackSpeed != 1.0))
            Positioned(
              left: 16,
              top: MediaQuery.of(context).orientation == Orientation.portrait
                  ? 124
                  : 80,
              child: SpeedIndicator(speed: state.playbackSpeed),
            ),

          // === LAYER 6: Shortcut row ===
          if (state.controlsVisible &&
              !state.isLocked &&
              !state.sleepTimerDialogOpen &&
              visibleShortcutList.isNotEmpty)
            Positioned(
              left: 70,
              right: 0,
              top: MediaQuery.of(context).orientation == Orientation.portrait
                  ? 108
                  : 64,
              child: Listener(
                // MX Player parity: any touch on the shortcut strip —
                // scrolling through the icons to find one, or a slow
                // press while deciding — keeps the controls alive. These
                // are passive observers (deferToChild + no event consumed),
                // so the row's own taps and horizontal scroll still work;
                // they just bump the auto-hide timer on every pointer.
                behavior: HitTestBehavior.deferToChild,
                onPointerDown: (_) => controller.bumpControlsTimer(),
                onPointerMove: (_) => controller.bumpControlsTimer(),
                child: ShortcutRow(
                visibleItems: visibleShortcutList,
                activeItems: _activeSet(state),
                expanded: state.shortcutsExpanded,
                onItemTap: (item) => _onShortcutTap(context, item),
                onToggleExpand: controller.toggleShortcutsExpanded,
                // Phase 45 (audit): MX Player styling rules — portrait
                // uses plain white icons (no circle bg); the speed
                // shortcut shows a "1X"/"1.5X" text label; Audio Effect
                // shows a red dot when an effect is engaged.
                isPortrait: MediaQuery.of(context).orientation ==
                    Orientation.portrait,
                currentSpeed: state.playbackSpeed,
                // Audio Effect "active" indicator (red dot) — MX Player
                // shows it when an audio effect is engaged. We read the
                // persisted master toggle the EQ/Audio-Effect sheet writes
                // (PlayerSetting.audioEffectsEnabled); the shortcut row
                // rebuilds with player state, so toggling EQ and returning
                // reflects here.
                audioEffectActive: ref
                    .read(playerSettingsProvider)
                    .get(PlayerSetting.audioEffectsEnabled),
                loopMode: state.loopMode,
              ),
              ),
            ),

          // === LAYER 7: Bottom controls ===
          // Hide the player's play/pause + seek bar while the Sleep Timer
          // dialog is open — its own STOP/START row sits at the bottom and
          // would otherwise overlap (and block taps on) these controls.
          if (state.controlsVisible &&
              !state.isLocked &&
              !state.sleepTimerDialogOpen)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _BottomControls(
                position: state.position,
                duration: state.duration,
                isPlaying: state.isPlaying,
                aspectRatioMode: state.aspectRatioMode,
                showSeekBar: ref
                    .watch(playerSettingsProvider)
                    .get(PlayerSetting.navShowSeekBar),
                showPrevNext: ref
                    .watch(playerSettingsProvider)
                    .get(PlayerSetting.navShowPrevNext),
                // Master switch AND the per-surface one, matching how the two
                // settings are worded.
                previewEnabled: ref
                        .watch(playerSettingsProvider)
                        .get(PlayerSetting.previewSeek) &&
                    ref
                        .watch(playerSettingsProvider)
                        .get(PlayerSetting.navSeekBarPreview),
                previewOnNetwork: ref
                    .watch(playerSettingsProvider)
                    .get(PlayerSetting.previewSeekNetwork),
                onSeek: controller.seek,
                onScrubStart: controller.beginScrub,
                onScrubEnd: () {
                  // ignore: discarded_futures
                  controller.endScrub();
                },
                onPlayPause: controller.playOrPause,
                onSeekRelative: controller.seekRelative,
                onLock: controller.toggleLock,
                onCycleAspectRatio: () {
                  controller.cycleAspectRatio();
                  // Phase 42: MX Player parity — show the new mode name as a
                  // brief toast so the user knows which mode is active even
                  // before the video visibly reflows.
                  final mode =
                      ref.read(playerControllerProvider).aspectRatioMode;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(mode.label),
                      duration: const Duration(milliseconds: 1200),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                // Phase 45 (audit): bottom row toggles fit↔crop, NOT PiP.
                // PiP icon moved to top bar (MX Player V3 parity).
                onToggleFullscreenFill: () {
                  controller.toggleFullscreenFill();
                  final mode =
                      ref.read(playerControllerProvider).aspectRatioMode;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(mode == AspectRatioMode.crop
                          ? 'Fill screen'
                          : 'Original aspect'),
                      duration: const Duration(milliseconds: 1200),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                formatDuration: _fmt,
                onPrevious: controller.onBackwardButton,
                onNext: controller.onForwardButton,
                onShowLoopMenu: () => _showLoopMenu(context),
                onFrameStep: (forward) =>
                    controller.frameStep(forward: forward),
                // Phase 45: video URI for scrub preview thumbnails.
                videoUri: widget.videoUri,
                // Audit fix (A1): forward slider drag activity to the
                // controller so the auto-hide timer resets on each
                // touch — controls don't vanish mid-scrub.
                onUserActivity: controller.showControls,
              ),
            ),

          // === LAYER 7b: Shortcut feedback overlay (dark text badge) ===
          // Suppressed while the Sleep Timer dialog owns the screen, so a
          // shortcut toast fired moments earlier can't linger over it.
          if (!state.sleepTimerDialogOpen)
            Positioned(
            top: 0, left: 0, right: 0, bottom: 0,
            child: IgnorePointer(
              child: ValueListenableBuilder<String?>(
                valueListenable: _overlayMsg,
                builder: (_, msg, __) {
                  if (msg == null) return const SizedBox.shrink();
                  return Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                      decoration: BoxDecoration(
                        color: const Color(0x9E000000), // black ~62%
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        msg,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // === LAYER 8: Lock overlay ===
          if (state.isLocked) LockOverlay(onUnlock: controller.toggleLock),

          // === LAYER 8b: Kids Lock overlay (v0.49) — sits above the
          // gesture layer and controls so it swallows every touch. ===
          if (state.isKidsLocked)
            KidsLockOverlay(
              onUnlock: () {
                controller.toggleKidsLock();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(AppStrings.of(context).kidsLockOffMsg),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),

          // === LAYER 9: Gesture indicator ===
          if (state.activeIndicator != null)
            _buildIndicator(state.activeIndicator!),

          // === LAYER 10: Side panels ===
          if (state.openPanel == SidePanel.more)
            MoreMenuPanel(
              items: _buildMoreMenuItems(context),
              videoDisplayEnabled: _videoDisplayEnabled,
              visibleShortcuts: state.visibleShortcuts,
              onVideoDisplayToggle: (v) =>
                  setState(() => _videoDisplayEnabled = v),
              onShortcutsToggle: (v) {
                if (v) {
                  controller
                      .updateVisibleShortcuts(ShortcutItem.values.toSet());
                } else {
                  controller.updateVisibleShortcuts({});
                }
              },
              onShortcutToggle: (item) {
                final next =
                    Set<ShortcutItem>.from(state.visibleShortcuts);
                if (next.contains(item)) {
                  next.remove(item);
                } else {
                  next.add(item);
                }
                controller.updateVisibleShortcuts(next);
              },
              onDismiss: controller.closePanel,
            ),

          if (state.openPanel == SidePanel.subtitle)
            SubtitlePanel(
              onOpen: () {
                controller.closePanel();
                _pickExternalSubtitle(context);
              },
              onSettings: () => _showSubtitleTracks(context),
              onTextStyle: () {
                controller.closePanel();
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const SubtitleTextScreen()),
                );
              },
              onLayout: () {
                controller.closePanel();
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const SubtitleLayoutScreen()),
                );
              },
              onOnlineSubtitles: () {
                controller.closePanel();
                // Phase 40: share a constructed OpenSubtitles search URL so the
                // user can open it in their browser. A real OpenSubtitles API
                // integration would need an account + REST client; this is
                // the most useful thing we can do without adding url_launcher.
                final fileName = widget.title.replaceAll(' ', '+');
                final url =
                    'https://www.opensubtitles.org/en/search/sublanguageid-all/moviename-$fileName';
                Share.share(
                  url,
                  subject: 'Search subtitles for ${widget.title}',
                );
              },
              onDismiss: controller.closePanel,
            ),

          // === LAYER 11: Decoder dialog ===
          if (state.decoderDialogOpen)
            DecoderDialog(
              current: state.decoder,
              // Phase 45 (audit): toast the new decoder so the user
              // sees confirmation. Switching decoder is non-instant
              // (libmpv re-opens the file) so the visible confirmation
              // helps the user understand why the screen briefly went
              // black.
              onSelect: (type) {
                controller.selectDecoder(type);
                final label = type == DecoderType.defaultMode
                    ? 'Decoder: Default'
                    : type == DecoderType.hwPlus
                        ? 'Decoder: HW+'
                        : type == DecoderType.hw
                            ? 'Decoder: HW'
                            : 'Decoder: SW';
                AppSnackbar.show(context, label);
              },
              onDismiss: controller.closeDecoderDialog,
            ),

          // === LAYER 12: Sleep timer dialog ===
          if (state.sleepTimerDialogOpen)
            SleepTimerDialog(
              currentRemaining: state.sleepTimer.remaining,
              onSelect: (opt, playToEnd) =>
                  controller.selectSleepTimer(opt, playToEnd: playToEnd),
              onDismiss: controller.closeSleepTimerDialog,
            ),

          // === LAYER 13: Resume banner / dialog ===
          // Phase 45 (audit): 'ask' mode shows a centered modal; 'resume'
          // mode shows a transient bottom toast (legacy behaviour).
          if (state.resumeDialogOpen && state.pendingResumePosition != null)
            ResumeDialog(
              savedPosition: state.pendingResumePosition!,
              isAskMode: state.resumeIsAskMode,
              onResume: ({required bool useByDefault}) {
                controller.resumeFromSaved();
                if (useByDefault) {
                  // Phase 45 (audit): "Use by default" → persist the
                  // resume_last setting so this becomes the new behaviour.
                  ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.resumeLast, 'resume');
                }
              },
              onStartOver: ({required bool useByDefault}) {
                controller.startOverFromBeginning();
                if (useByDefault) {
                  ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.resumeLast, 'startover');
                }
              },
            ),

          // === LAYER 12b: Debug stats (Settings → Player → Debug) ===
          // Three switches that had descriptions and no overlay to control.
          //
          // A collection-if rather than a Builder. Either works — Builder
          // creates no render object, so a Positioned inside one still finds
          // the Stack as its parent — but the collection-if skips an element
          // entirely when the switches are off, which is the usual case.
          if (ref.watch(playerSettingsProvider)
                  .get(PlayerSetting.devShowBufferInfo) ||
              ref.watch(playerSettingsProvider)
                  .get(PlayerSetting.devShowDecoderInfo) ||
              ref.watch(playerSettingsProvider).get(PlayerSetting.devShowFps))
            PlayerStatsOverlay(
              showBuffer: ref
                  .watch(playerSettingsProvider)
                  .get(PlayerSetting.devShowBufferInfo),
              showDecoder: ref
                  .watch(playerSettingsProvider)
                  .get(PlayerSetting.devShowDecoderInfo),
              showFps: ref
                  .watch(playerSettingsProvider)
                  .get(PlayerSetting.devShowFps),
            ),

          // === LAYER 13a: Zoom indicator (pinch-to-zoom) ===
          if (state.zoomIndicatorValue != null)
            ZoomIndicator(value: state.zoomIndicatorValue!),

          // === LAYER 13aa: AB Repeat badge ===
          // Phase 45 (audit): when AB-repeat is engaged, show a small
          // pill near the bottom-left that displays the loop range.
          // Users sometimes forget they set A-B and wonder why the
          // video is looping — this badge makes the state visible.
          if (state.abPointA != null)
            Positioned(
              left: 16,
              bottom: MediaQuery.of(context).padding.bottom + 110,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.accentBlue,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    state.abPointB == null
                        ? 'A · ${_fmt(state.abPointA!)}'
                        : 'A → B · ${_fmt(state.abPointA!)} - ${_fmt(state.abPointB!)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),

          // === LAYER 13b: Speed slider (long-press) ===
          if (state.speedSliderVisible)
            Positioned(
              top: 30,
              left: 0,
              right: 0,
              child: SpeedSlider(
                currentSpeed: state.playbackSpeed,
                onSpeedChanged: (speed) {
                  controller.setSpeed(speed);
                },
                onBoundsUpdate: controller.setSpeedSliderBounds,
              ),
            ),

          // === LAYER 14: Error banner (Phase 13: with retry) ===
          // Phase 41: if "Suppress error message" is on (Settings → Player),
          // hide the banner entirely so the user isn't blocked. We still
          // keep the error in state so Decoder dialog / logs can see it.
          if (state.errorMessage != null &&
              !ref
                  .watch(playerSettingsProvider)
                  .get(PlayerSetting.suppressError))
            Positioned(
              top: 80,
              left: 16,
              right: 16,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.error.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.error_outline,
                              color: Colors.white, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppStrings.of(context).playbackFailed,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => controller.dismissError(),
                            borderRadius: BorderRadius.circular(12),
                            child: const Icon(Icons.close,
                                color: Colors.white, size: 20),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        state.errorMessage!,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: () {
                              controller.dismissError();
                              // ignore: discarded_futures
                              _retryPlayback(controller);
                            },
                            icon: const Icon(Icons.refresh,
                                color: Colors.white, size: 16),
                            label: Text(AppStrings.of(context).retry,
                              style: const TextStyle(color: Colors.white),
                            ),
                            style: TextButton.styleFrom(
                              backgroundColor: Colors.white24,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton.icon(
                            onPressed: () {
                              _lockPortraitOnExit();
                              _stopAudioIfLeaving();
                              Navigator.of(context).pop();
                            },
                            icon: const Icon(Icons.arrow_back,
                                color: Colors.white, size: 16),
                            label: Text(AppStrings.of(context).goBack,
                              style: const TextStyle(color: Colors.white),
                            ),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }

  Widget _buildIndicator(GestureIndicator indicator) {
    switch (indicator.type) {
      case IndicatorType.brightness:
        return BrightnessIndicator(value: indicator.value!);
      case IndicatorType.volume:
        return VolumeIndicator(value: indicator.value!);
      case IndicatorType.seek:
        return SeekIndicator(
          delta: indicator.delta!,
          targetPosition: indicator.target!,
        );
    }
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  final String decoderLabel;
  final Duration? sleepTimerRemaining;
  final VoidCallback onBack;
  final VoidCallback onAudio;
  final VoidCallback onSubtitle;
  final VoidCallback onDecoder;
  final VoidCallback onMore;
  /// Phase 45 (audit): MX Player V3 puts the PiP-enter icon in the TOP
  /// bar alongside HW/HW+ and ⋮, not in the bottom row. We now match.
  final VoidCallback onEnterPip;
  final String Function(Duration) fmtTimer;
  /// Phase 44: MX Player V3 parity — small dot on the audio/subtitle
  /// icons when the file actually has multiple of that kind of track, so
  /// the user knows there's something to switch to.
  final bool hasMultipleAudioTracks;
  final bool hasMultipleSubtitleTracks;

  /// Settings → Player → Style → "Show title" and "Show system clock".
  /// Both had a label, a description and a saved value that nothing read.
  final bool showTitle;
  final bool showClock;

  /// Settings → Player → Style → "Show source URL": display the path or URL
  /// under the title for network playback. Useful when several streams look
  /// alike, and another switch that had a description and no reader.
  final String? sourceLabel;

  const _TopBar({
    required this.title,
    required this.decoderLabel,
    required this.sleepTimerRemaining,
    required this.onBack,
    required this.onAudio,
    required this.onSubtitle,
    required this.onDecoder,
    required this.onMore,
    required this.onEnterPip,
    required this.fmtTimer,
    this.hasMultipleAudioTracks = false,
    this.hasMultipleSubtitleTracks = false,
    this.showTitle = true,
    this.showClock = false,
    this.sourceLabel,
  });

  /// 24-hour HH:MM. No timer behind it: the top bar only exists while the
  /// controls are on screen, and while they are the player rebuilds about once
  /// a second anyway, so the clock stays current without anything ticking in
  /// the background — which is exactly what a clock in a video player should
  /// cost.
  static String _clockNow() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:'
        '${n.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // Phase 45 (audit): MX Player shows audio + subtitle icons ONLY in
    // LANDSCAPE. In portrait the top bar is compact: back, title, PiP,
    // HW+, ⋮. The audio/subtitle pickers are still reachable via the
    // More menu, but the icons themselves are hidden to keep the
    // portrait top bar uncluttered.
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    return Container(
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.playerOverlayDark, Colors.transparent],
        ),
      ),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: onBack,
            ),
            Expanded(
              child: showTitle
                  ? Text(
                // Phase 18: Strip common video file extensions for cleaner display
                // (MX Player parity — Picsart 06-50-457 reference).
                _stripExtension(title),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
                // Phase 17: 2-line wrap (MX Player parity, V1 t=20)
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              )
                  // Title hidden: keep the Expanded so the icons on the right
                  // stay where they are instead of sliding across the bar.
                  : const SizedBox.shrink(),
            ),
            // Settings → Style → "Show source URL". Only rendered when there
            // is a source worth showing, so a local file does not get a second
            // line repeating the path already in the title.
            if (sourceLabel != null && sourceLabel!.isNotEmpty)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    sourceLabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            // Settings → Style → "Show system clock".
            if (showClock)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  _clockNow(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            // Sleep timer remaining badge
            if (sleepTimerRemaining != null)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accentBlue.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.timer_outlined,
                        color: AppColors.accentBlue, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      fmtTimer(sleepTimerRemaining!),
                      style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            // Phase 28: Audio + subtitle icons ALWAYS in title bar (was landscape-only).
            // Phase 44: small accent dot when there's more than one track,
            // so the user can tell a file has selectable audio/subtitle.
            // Phase 45 (audit): PiP icon BEFORE audio/subtitle to match
            // MX Player V3 layout. The PiP icon is always visible
            // (both orientations), unlike audio/subtitle which are
            // landscape-only.
            IconButton(
              icon: const Icon(
                Icons.picture_in_picture_alt_outlined,
                color: Colors.white,
                size: 20,
              ),
              tooltip: 'Picture-in-Picture',
              onPressed: onEnterPip,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            ),
            // Phase 45 (audit): Audio + subtitle icons LANDSCAPE ONLY.
            // MX Player hides them in portrait — they're reachable via
            // the More menu instead. This matches frame 20 (180939) which
            // shows only ←, title, PiP, HW+, ⋮ in portrait top bar.
            if (isLandscape) ...[
              _IconWithDot(
                icon: Icons.music_note,
                tooltip: 'Audio track',
                showDot: hasMultipleAudioTracks,
                onPressed: onAudio,
              ),
              _IconWithDot(
                icon: Icons.subtitles_outlined,
                tooltip: 'Subtitle',
                showDot: hasMultipleSubtitleTracks,
                onPressed: onSubtitle,
              ),
            ],
            TextButton(
              onPressed: onDecoder,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(40, 40),
              ),
              child: Text(
                decoderLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              onPressed: onMore,
              tooltip: 'More',
            ),
          ],
        ),
      ),
    );
  }
}

/// Phase 18: Strip common video file extensions from displayed title
/// (MX Player parity — they hide .mp4/.mkv/.avi etc.).
String _stripExtension(String title) {
  const exts = [
    '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm',
    '.m4v', '.3gp', '.ts', '.mpg', '.mpeg', '.f4v',
  ];
  final lower = title.toLowerCase();
  for (final ext in exts) {
    if (lower.endsWith(ext)) {
      return title.substring(0, title.length - ext.length);
    }
  }
  return title;
}

/// v1.63.2: frame-step buttons OFF by default — owner's decision, 31 Aug 2026.
///
/// The feature works (verified on device: the buttons appear while paused and
/// step correctly). It is hidden because two extra icons sitting either side
/// of play/pause crowd the one control everybody reaches for, and stepping
/// frames is a rare need in a phone media player.
///
/// TO BRING IT BACK: change `false` to `true` on the line below. Nothing else.
/// Every layer underneath is untouched and still wired — `onFrameStep` here,
/// `frameStep()` in player_controller_playback.dart, and `frameStep()` in
/// media_kit_player_service.dart. There is no other entry point to remove.
///
/// Deliberately `final`, not `const`: a `const false` lets the analyzer fold
/// the condition and report the button code as dead, which would add noise to
/// the Analyzer tab that analysis_options.yaml works hard to keep readable.
const bool _kShowFrameStepButtons = false;

class _BottomControls extends ConsumerStatefulWidget {
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final AspectRatioMode aspectRatioMode;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onPlayPause;
  final ValueChanged<int> onSeekRelative;
  final VoidCallback onLock;
  final VoidCallback onCycleAspectRatio;
  /// Phase 45 (audit): MX Player V3 bottom row has a "fullscreen-fill"
  /// toggle (NOT PiP — PiP is in the top bar now). Tapping flips
  /// between fit (letterbox) and crop (fill screen).
  final VoidCallback onToggleFullscreenFill;
  final String Function(Duration) formatDuration;
  // Phase 15: Prev/Next instead of ±10s; long-press next → loop menu
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onShowLoopMenu;

  /// v1.63: step exactly one frame. `true` = forward.
  ///
  /// The buttons only appear while PAUSED. Stepping a playing video is
  /// meaningless, and two extra icons in the transport row at all times
  /// would crowd the control everyone actually reaches for.
  final ValueChanged<bool> onFrameStep;
  /// Phase 45: video URI for scrub preview thumbnails. When null
  /// (e.g. network streams where we can't generate previews via
  /// MediaMetadataRetriever) the preview is hidden but seek still works.
  final String? videoUri;

  /// Audit fix (A1): called on every user touch of the slider so the
  /// parent can reset its auto-hide-controls timer. Without this, a
  /// long scrub past the 4-second hide threshold would let the
  /// controls disappear mid-drag — frustrating.
  final VoidCallback? onUserActivity;

  /// Settings → Player → Navigation → "Show seek bar" and "Show
  /// previous/next buttons", and Settings → Player → "Preview while seeking" /
  /// "Seek bar preview". All four had descriptions and no reader.
  final bool showSeekBar;
  final bool showPrevNext;
  final bool previewEnabled;
  final bool previewOnNetwork;

  /// Start / end of a seek-bar drag.
  ///
  /// AUDIT FIX — the controller already had a keyframe-seek "snappy scrub"
  /// mode, but it was reachable only from the swipe-to-seek gesture. Dragging
  /// the bar itself — the way most people seek — still asked libmpv for a
  /// frame-exact landing on every throttled step, which is what made long
  /// drags stutter and flash the buffering spinner instead of previewing.
  final VoidCallback? onScrubStart;
  final VoidCallback? onScrubEnd;

  const _BottomControls({
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.aspectRatioMode,
    required this.onSeek,
    required this.onPlayPause,
    required this.onSeekRelative,
    required this.onLock,
    required this.onCycleAspectRatio,
    required this.onToggleFullscreenFill,
    required this.formatDuration,
    required this.onPrevious,
    required this.onNext,
    required this.onShowLoopMenu,
    required this.onFrameStep,
    this.videoUri,
    this.onUserActivity,
    this.onScrubStart,
    this.onScrubEnd,
    this.showSeekBar = true,
    this.showPrevNext = true,
    this.previewEnabled = true,
    this.previewOnNetwork = false,
  });

  @override
  ConsumerState<_BottomControls> createState() => _BottomControlsState();
}

class _BottomControlsState extends ConsumerState<_BottomControls> {
  /// Local drag position — overrides widget.position while user is scrubbing.
  /// PDF page 10: real-time scrub preview.
  double? _dragValue;

  /// Phase 15: Throttle real-time seeks during slider drag.
  /// Without throttling we flood media_kit and the spinner shows instead of
  /// smooth scrubbing. 60ms ≈ 16fps which feels MX-Player smooth.
  DateTime _lastSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _seekThrottle = Duration(milliseconds: 60);

  /// Phase 45: scrub-preview state — the small video frame shown above
  /// the seek bar while the user drags. We throttle loads to 5-second
  /// granularity (matches ThumbnailCache.getAtTime's bucket size) so
  /// dragging back and forth doesn't spam the native side.
  Uint8List? _previewBytes;
  int _previewLoadedBucket = -1;
  int _previewRequestSeq = 0;
  DateTime _lastPreviewLoadAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _previewThrottle = Duration(milliseconds: 150);

  void _loadPreview(int seconds) {
    final uri = widget.videoUri;
    if (uri == null) return;
    // "Preview while seeking" is the master switch; "Seek bar preview" is the
    // per-surface one. Neither was read, so the bubble appeared for everyone
    // regardless of what Settings said.
    if (!widget.previewEnabled) return;
    // Network streams get their own switch, because pulling frames out of a
    // remote file costs bandwidth that the person watching over mobile data is
    // paying for. Off by default for that reason.
    if (uri.startsWith('http') ||
        uri.startsWith('rtmp') ||
        uri.startsWith('rtsp')) {
      if (!widget.previewOnNetwork) return;
    }
    final bucket = (seconds ~/ 5) * 5;
    if (bucket == _previewLoadedBucket) return;
    final now = DateTime.now();
    if (now.difference(_lastPreviewLoadAt) < _previewThrottle) return;
    _lastPreviewLoadAt = now;
    final seq = ++_previewRequestSeq;
    final path = uri.startsWith('file://')
        ? Uri.parse(uri).toFilePath()
        : uri;
    ThumbnailCache.instance.getAtTime(path, bucket).then((bytes) {
      // Ignore stale results — user may have moved on.
      if (!mounted || seq != _previewRequestSeq) return;
      setState(() {
        _previewBytes = bytes;
        _previewLoadedBucket = bucket;
      });
    }, onError: (e) {
      // Code-quality audit: was a silent .then() without onError.
      // Thumbnail extraction can fail (file deleted, codec error,
      // corrupt frame) — log so we can diagnose missing preview
      // bubbles in debug builds.
      if (kDebugMode) debugPrint('Preview thumbnail fetch failed for $path @ ${bucket}ms: $e');
    });
  }

  void _onChanged(double v) {
    setState(() => _dragValue = v);
    // Audit fix (A1): keep the controls visible while the user is
    // actively scrubbing. Without this every drag past the 4-second
    // auto-hide threshold lost the seek handle mid-drag.
    widget.onUserActivity?.call();
    if (widget.duration.inMilliseconds <= 0) return;
    // Phase 45: kick off a scrub preview load at the drag position.
    final seconds = (widget.duration.inSeconds * v).round();
    _loadPreview(seconds);
    final now = DateTime.now();
    if (now.difference(_lastSeekAt) < _seekThrottle) return;
    _lastSeekAt = now;
    final to = Duration(
      milliseconds: (widget.duration.inMilliseconds * v).round(),
    );
    widget.onSeek(to);
  }

  void _onChangeEnd(double v) {
    final to = Duration(
      milliseconds: (widget.duration.inMilliseconds * v).round(),
    );
    // Close the scrub session BEFORE the final seek so that last landing is
    // the frame-exact one the user released on (and gets its fade-in, if the
    // setting is on) while every throttled step during the drag stayed on the
    // fast keyframe path.
    widget.onScrubEnd?.call();
    widget.onSeek(to);
    setState(() {
      _dragValue = null;
      // Phase 45: clear preview when scrub ends.
      _previewBytes = null;
      _previewLoadedBucket = -1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasDuration = widget.duration.inMilliseconds > 0;
    final isLandscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    // Spacing between Prev/Play/Next: portrait is already comfortable; landscape
    // gets much wider so the three buttons aren't cramped together (MX parity).
    final transportSpacing = isLandscape ? 56.0 : 8.0;
    // Smooth scoped position: the controller only writes position into
    // its state once per second (to keep whole-screen rebuilds low), so
    // for a fluid seek bar we read the engine's position stream directly
    // here. Falls back to the passed-in position before the first emit.
    final livePosition =
        ref.watch(videoPositionProvider).value ?? widget.position;
    final actualProgress = hasDuration
        ? livePosition.inMilliseconds / widget.duration.inMilliseconds
        : 0.0;
    // Use drag value while scrubbing, actual position otherwise
    final progress = _dragValue ?? actualProgress;
    final displayPosition = _dragValue != null && hasDuration
        ? Duration(
            milliseconds:
                (widget.duration.inMilliseconds * _dragValue!).round())
        : livePosition;

    return Container(
      // Reserve the real nav-bar height even in immersive mode (where
      // MediaQuery.padding.bottom collapses to 0), so the Prev/Play/Next row
      // never ends up under the system Back/Home/Recent bar when it slides in.
      padding: EdgeInsets.only(
        bottom: math.max(
          MediaQuery.of(context).padding.bottom,
          SystemInsets.bottomBar,
        ),
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, AppColors.playerOverlayDark],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Phase 45: scrub-preview frame, MX Player parity. Shows a
          // small video thumbnail of the position the user is currently
          // dragging to, anchored above the seek bar. Hidden when not
          // scrubbing or when preview bytes haven't arrived yet
          // (network streams, first 150ms of drag, etc.).
          if (_dragValue != null && _previewBytes != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: Alignment(
                  // Map slider position (0..1) → alignment (-1..1).
                  (_dragValue!.clamp(0.0, 1.0) * 2) - 1,
                  0,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    border: Border.all(color: Colors.white24, width: 1),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black54,
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Image.memory(
                      _previewBytes!,
                      width: 144,
                      height: 81,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      // Phase 45: errors should NEVER throw out of the
                      // build. Bytes can be malformed if libmpv hasn't
                      // finished probing the file. Silently hide on err.
                      errorBuilder: (_, __, ___) => const SizedBox(
                        width: 144,
                        height: 81,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Settings → Player → Navigation → "Show seek bar". Hiding it takes
          // the elapsed and remaining labels with it: they are the seek bar's
          // readout, and leaving two bare timestamps floating above the
          // transport row is not what "hide the seek bar" means.
          if (widget.showSeekBar)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 50,
                  child: Text(
                    widget.formatDuration(displayPosition),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: AppColors.specPrimary,
                      inactiveTrackColor: AppColors.specSeekRail,
                      thumbColor: AppColors.specCheckbox,
                      trackHeight: 2.5,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 5.5,
                      ),
                      // Drop the invisible touch-overlay padding so the track
                      // extends right up to the time labels — they sit snug
                      // against the seek bar like MX Player.
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: progress.clamp(0.0, 1.0),
                      onChangeStart: hasDuration
                          ? (v) {
                              widget.onScrubStart?.call();
                              setState(() => _dragValue = v);
                            }
                          : null,
                      onChanged: hasDuration ? _onChanged : null,
                      onChangeEnd: hasDuration ? _onChangeEnd : null,
                      // Audit fix (Phase B): TalkBack support.
                      // semanticFormatterCallback turns the 0.0..1.0
                      // value into a human position the screen-reader
                      // announces (e.g. "12 minutes 34 seconds of
                      // 1 hour 29 minutes"). Without this, TalkBack
                      // just reads "50 %".
                      semanticFormatterCallback: hasDuration
                          ? (v) {
                              final pos = Duration(
                                  milliseconds:
                                      (widget.duration.inMilliseconds * v)
                                          .round());
                              return 'Playback position '
                                  '${widget.formatDuration(pos)} '
                                  'of ${widget.formatDuration(widget.duration)}';
                            }
                          : null,
                    ),
                  ),
                ),
                SizedBox(
                  width: 50,
                  child: Text(
                    // MX Player parity: right side shows negative remaining time
                    // e.g. "-1:29:22" rather than total duration
                    hasDuration
                        ? '-${widget.formatDuration(widget.duration - displayPosition)}'
                        : widget.formatDuration(widget.duration),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Primary transport — prev / play / next — pinned to the
                // centre of the screen as the main (major) controls.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.showPrevNext) ...[
                      IconButton(
                        icon: const Icon(Icons.skip_previous,
                            color: Colors.white),
                        iconSize: 32,
                        onPressed: widget.onPrevious,
                        tooltip: 'Previous video',
                      ),
                      SizedBox(width: transportSpacing),
                    ],
                    // v1.63: frame-step, paused only. See [onFrameStep].
                    // v1.63.2: hidden — see [_kShowFrameStepButtons].
                    if (_kShowFrameStepButtons && !widget.isPlaying) ...[
                      IconButton(
                        icon: const Icon(Icons.first_page, color: Colors.white),
                        iconSize: 26,
                        onPressed: () => widget.onFrameStep(false),
                        tooltip: 'Previous frame',
                      ),
                      const SizedBox(width: 4),
                    ],
                    // Phase 16: Plain play/pause icons (NO white filled circle).
                    IconButton(
                      tooltip: widget.isPlaying ? 'Pause' : 'Play',
                      icon: Icon(
                        widget.isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                      ),
                      iconSize: 38,
                      onPressed: widget.onPlayPause,
                    ),
                    // v1.63.2: hidden — see [_kShowFrameStepButtons].
                    if (_kShowFrameStepButtons && !widget.isPlaying) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.last_page, color: Colors.white),
                        iconSize: 26,
                        onPressed: () => widget.onFrameStep(true),
                        tooltip: 'Next frame',
                      ),
                    ],
                    if (widget.showPrevNext) ...[
                      SizedBox(width: transportSpacing),
                      GestureDetector(
                        onLongPress: widget.onShowLoopMenu,
                        child: IconButton(
                          icon:
                              const Icon(Icons.skip_next, color: Colors.white),
                          iconSize: 32,
                          onPressed: widget.onNext,
                          tooltip: 'Next (long-press for Loop menu)',
                        ),
                      ),
                    ],
                  ],
                ),
                // Lock — far left.
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.lock_open, color: Colors.white),
                    onPressed: widget.onLock,
                    tooltip: 'Lock controls',
                  ),
                ),
                // Aspect ratio + fill-screen — far right.
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.crop_landscape_outlined,
                            color: Colors.white),
                        onPressed: widget.onCycleAspectRatio,
                        tooltip: widget.aspectRatioMode.label,
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.fit_screen_outlined,
                          color: Colors.white,
                        ),
                        tooltip: 'Fill screen',
                        onPressed: widget.onToggleFullscreenFill,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Phase 44: Top-bar icon button with optional accent-blue dot overlay.
/// Used on the Audio and Subtitle icons to signal "this file has multiple
/// tracks you can switch between" — MX Player V3 parity.
class _IconWithDot extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool showDot;
  final VoidCallback onPressed;

  const _IconWithDot({
    required this.icon,
    required this.tooltip,
    required this.showDot,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          icon: Icon(icon, color: Colors.white, size: 20),
          onPressed: onPressed,
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        ),
        if (showDot)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: AppColors.accentBlue,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}
