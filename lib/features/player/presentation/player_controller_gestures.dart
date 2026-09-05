part of 'player_provider.dart';

extension PlayerGestures on PlayerController {
  Future<void> onBrightnessDelta(double delta) async {
    if (state.isLocked && state.lockScope != 'rotation') return;
    // Honour "Auto brightness": if the user asked the player to leave screen
    // brightness to the system, a swipe must not silently override it.
    if (_ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.screenAutoBrightness)) {
      return;
    }
    final newBrightness = (state.brightness + delta).clamp(0.0, 1.0);
    state = state.copyWith(
      brightness: newBrightness,
      activeIndicator: GestureIndicator.brightness(newBrightness),
      // Audit fix (C2): if a zoom indicator was lingering from a
      // recent pinch, kill it now — only one indicator should be
      // on screen at once.
      zoomIndicatorValue: null,
    );
    _zoomIndicatorTimer?.cancel();
    await _ref.read(brightnessServiceProvider).setBrightness(newBrightness);
    // Audit fix (B5): debounced per-URI brightness persistence. Many
    // delta events fire per swipe so we MUST debounce — otherwise
    // shared_preferences gets hammered. 500 ms of inactivity counts
    // as "the user has settled on this value".
    _persistBrightnessDebounced(newBrightness);
    _scheduleIndicatorClear();
  }

  Future<void> onVolumeDelta(double delta) async {
    if (state.isLocked && state.lockScope != 'rotation') return;
    final newVolume = (state.volume + delta).clamp(0.0, 1.0);
    // Raising the volume while muted has to lift libmpv's mute flag too,
    // otherwise the slider climbs and nothing is heard.
    if (state.isMuted && newVolume > 0.0) {
      final svc = _ref.read(videoPlayerServiceProvider);
      if (svc is MediaKitPlayerService) {
        // ignore: unawaited_futures
        svc.setMuted(false);
      }
    }
    state = state.copyWith(
      volume: newVolume,
      isMuted: newVolume <= 0.0,
      activeIndicator: GestureIndicator.volume(newVolume),
      // Audit fix (C2): clear any lingering zoom indicator.
      zoomIndicatorValue: null,
    );
    _zoomIndicatorTimer?.cancel();
    // Settings → Audio → "System volume: synchronize sound volume with the
    // system media volume." On, the swipe moves the phone's media volume (the
    // behaviour so far, and the default). Off, it moves only this player's
    // own output, leaving the device volume where the user left it — which is
    // the point of the setting, and it had no reader at all.
    final syncSystem = _ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.audioSystemVolume);
    if (syncSystem) {
      await _ref.read(volumeServiceProvider).setVolume(newVolume);
    } else {
      await _ref.read(videoPlayerServiceProvider).setVolume(newVolume);
    }
    _persistVolumeDebounced(newVolume);
    _scheduleIndicatorClear();
  }

  // Audit fix (B5): debounced per-URI persistence helpers + restore.
  // (_brightnessPersistTimer / _volumePersistTimer are declared on the
  // PlayerController class — extensions can't hold instance fields.)

  void _persistBrightnessDebounced(double v) {
    final uri = _currentUri;
    if (uri == null) return;
    _brightnessPersistTimer?.cancel();
    _brightnessPersistTimer = Timer(const Duration(milliseconds: 500), () {
      try {
        _ref.read(userDataServiceProvider).setVideoBrightness(uri, v);
      } catch (e) { if (kDebugMode) debugPrint('PlayerGestures: $e'); }
    });
  }

  void _persistVolumeDebounced(double v) {
    final uri = _currentUri;
    if (uri == null) return;
    _volumePersistTimer?.cancel();
    _volumePersistTimer = Timer(const Duration(milliseconds: 500), () {
      try {
        _ref.read(userDataServiceProvider).setVideoVolume(uri, v);
      } catch (e) { if (kDebugMode) debugPrint('PlayerGestures: $e'); }
    });
  }

  /// Read any saved per-URI brightness/volume for [uri] and apply
  /// them. Called from `_doOpenVideo` after the player is initialized
  /// so the values land on the actual playback session.
  Future<void> _restorePerVideoBrightnessVolume(String uri) async {
    try {
      // Settings → Player → Screen → "Auto brightness (use system brightness
      // setting)". When on, the player must not touch screen brightness at
      // all — no per-video restore, no default override. The switch existed
      // and nothing read it, so the player overrode the system regardless.
      final autoBrightness = _ref
          .read(playerSettingsProvider)
          .get(PlayerSetting.screenAutoBrightness);
      final uds = _ref.read(userDataServiceProvider);
      final savedB = await uds.getVideoBrightness(uri);
      final savedV = await uds.getVideoVolume(uri);
      // Audit fix (B5 cont.): also restore per-URI aspect + zoom.
      final savedAspectName = await uds.getVideoAspectName(uri);
      final savedZoom = await uds.getVideoZoom(uri);
      // Sanity: do nothing if the user has navigated away.
      if (!mounted || _currentUri != uri) return;
      if (savedB != null && !autoBrightness) {
        state = state.copyWith(brightness: savedB);
        await _ref.read(brightnessServiceProvider).setBrightness(savedB);
      }
      if (savedV != null) {
        state =
            state.copyWith(volume: savedV, isMuted: savedV <= 0.0);
        final syncSystem = _ref
            .read(playerSettingsProvider)
            .get(PlayerSetting.audioSystemVolume);
        // Restore into whichever volume the swipe actually moves — exactly
        // one of them. Writing both is what used to multiply them together:
        // a video last watched at 20 % reopened at 20 % of 20 %, i.e. 4 %,
        // and got quieter every time it was reopened.
        if (syncSystem) {
          await _ref.read(volumeServiceProvider).setVolume(savedV);
        } else {
          await _ref.read(videoPlayerServiceProvider).setVolume(savedV);
        }
      }
      // The volume/brightness restores above each awaited a platform call, so
      // re-check before the remaining writes rather than relying on the guard
      // at the top of the method.
      if (!mounted || _currentUri != uri) return;
      if (savedAspectName != null) {
        try {
          final mode = AspectRatioMode.values
              .firstWhere((m) => m.name == savedAspectName);
          state = state.copyWith(aspectRatioMode: mode);
        } catch (_) {
          // Saved name no longer corresponds to a valid enum value
          // (could happen if AspectRatioMode is refactored). Ignore.
        }
      }
      if (savedZoom != null) {
        state = state.copyWith(videoScale: savedZoom);
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerGestures: $e'); }
  }

  void onSeekStart() {
    if (state.isLocked && state.lockScope != 'rotation') return;
    // Anchor on the ENGINE position, not the whole-second-quantised state
    // copy, so a swipe-seek starts from where the video actually is.
    final svc = _ref.read(videoPlayerServiceProvider);
    _seekStartPosition =
        svc.position > Duration.zero ? svc.position : state.position;
    _lastSeekTargetMs = null;
    // Snappy scrubbing: keyframe-seek for the whole drag so every
    // throttled preview jump is instant (no decode-to-exact-frame).
    // onSeekEnd restores precise seeking for the exact final landing.
    beginScrub();
  }

  /// Phase 15: Throttle real-time seeks during drag.
  /// Without throttling we'd flood media_kit with seek calls causing the
  /// "buffering spinner" instead of smooth scrubbing. 60ms ≈ 16fps for the
  /// real video frame, which is enough for "MX Player feel".
  // _lastSeekAt / _lastSeekTargetMs are declared on the PlayerController
  // class (extensions can't hold instance fields). _seekThrottle is a
  // library-level const (declared in player_provider.dart) so it resolves
  // unqualified from here.

  void onSeekUpdate(int seconds) {
    if (state.isLocked || _seekStartPosition == null) return;
    final delta = Duration(seconds: seconds);
    var target = _seekStartPosition! + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (state.duration > Duration.zero && target > state.duration) {
      target = state.duration;
    }
    // Update the on-screen indicator + position immediately (responsive UI)
    state = state.copyWith(
      position: target,
      activeIndicator: GestureIndicator.seek(delta: delta, target: target),
    );

    // Phase 15: Real-time seek with throttling so user sees the video update.
    // Skip if same target (within 200ms) or too soon after last seek.
    final now = DateTime.now();
    final targetMs = target.inMilliseconds;
    if (_lastSeekTargetMs != null &&
        (targetMs - _lastSeekTargetMs!).abs() < 200) {
      return;
    }
    if (now.difference(_lastSeekAt) < _seekThrottle) return;
    _lastSeekAt = now;
    _lastSeekTargetMs = targetMs;
    // Fire and forget — media_kit handles the actual seek
    _ref.read(videoPlayerServiceProvider).seek(target);
  }

  Future<void> onSeekEnd() async {
    if (state.isLocked || _seekStartPosition == null) return;
    final indicator = state.activeIndicator;
    // Restore precise (absolute) seeking before the final landing so the
    // scrub bar drops the user exactly where they released it.
    await endScrub();
    if (indicator != null && indicator.target != null) {
      // Final precise seek to ensure target alignment
      await seek(indicator.target!);
    }
    _seekStartPosition = null;
    _lastSeekTargetMs = null;
    _clearIndicator();
  }

  void onDoubleTapRewind() {
    if (state.isLocked && state.lockScope != 'rotation') return;
    // Phase 45: respect the "Double-tap seek" setting AND the master
    // "Double-tap to seek" gate. When the gate is off the gesture
    // shouldn't reach here, but in case it does, no-op safely.
    final ps = _ref.read(playerSettingsProvider);
    if (!ps.get(PlayerSetting.ctlDoubleTapSeek)) return;
    final seconds = _ref.read(preferencesProvider).doubleTapSeekSeconds;
    // Audit fix (B6): haptic so the double-tap registers tactilely.
    HapticService.light();
    seekRelative(-seconds);
    showControls();
  }

  void onDoubleTapForward() {
    if (state.isLocked && state.lockScope != 'rotation') return;
    final ps = _ref.read(playerSettingsProvider);
    if (!ps.get(PlayerSetting.ctlDoubleTapSeek)) return;
    final seconds = _ref.read(preferencesProvider).doubleTapSeekSeconds;
    HapticService.light();
    seekRelative(seconds);
    showControls();
  }

  void onDoubleTapCenter() {
    if (state.isLocked && state.lockScope != 'rotation') return;
    playOrPause();
  }

  /// Long-press now shows speed slider (PDF page 9 spec)
  Future<void> onLongPressStart() async {
    if (state.isLocked && state.lockScope != 'rotation') return;
    HapticService.medium();
    _wasLongPressActive = true;
    // Re-anchor on the first drag move so speed starts from the current
    // value (×1 in the normal case) instead of jumping to the touch point.
    _speedDragAnchorX = null;
    state = state.copyWith(speedSliderVisible: true);
  }

  Future<void> onLongPressEnd() async {
    if (!_wasLongPressActive) return;
    _wasLongPressActive = false;
    _speedDragAnchorX = null;
    // Slider stays visible briefly so user can confirm; auto-hide after 2s
    Timer(const Duration(seconds: 2), () {
      if (mounted) state = state.copyWith(speedSliderVisible: false);
    });
  }

  void hideSpeedSlider() {
    state = state.copyWith(speedSliderVisible: false);
  }

  /// Phase 15: Speed slider geometry - set by SpeedSlider widget when rendered.
  /// Used so that long-press drag maps to absolute touch position over the slider.
  /// (_speedSliderBounds is declared on the PlayerController class.)
  void setSpeedSliderBounds(Rect bounds) {
    _speedSliderBounds = bounds;
  }

  /// PDF page 9: While long-press active, drag finger left/right to pick speed
  /// without releasing.
  /// MX Player behaviour: the point where the long-press begins is the anchor
  /// and maps to the CURRENT speed (×1 in the normal case). Speed changes only
  /// as the finger is dragged left/right from that anchor — it must NOT jump to
  /// an absolute position under the finger. Drag right → faster, left → slower.
  /// (_speedSteps is a library-level const — see player_provider.dart.)
  void onLongPressDragSpeed(Offset globalPosition) {
    if (!state.speedSliderVisible) return;

    // Distance (in px) the finger must travel to move one speed step.
    const pixelsPerStep = 48.0;

    // First move only sets the anchor at the current speed; no jump.
    if (_speedDragAnchorX == null) {
      _speedDragAnchorX = globalPosition.dx;
      _speedDragBaseIdx = _nearestSpeedIndex(state.playbackSpeed);
      return;
    }

    final delta = globalPosition.dx - _speedDragAnchorX!;
    final idxOffset = (delta / pixelsPerStep).round();
    var idx = _speedDragBaseIdx + idxOffset;
    if (idx < 0) idx = 0;
    if (idx >= _speedSteps.length) idx = _speedSteps.length - 1;

    final newSpeed = _speedSteps[idx];
    if ((newSpeed - state.playbackSpeed).abs() > 0.01) {
      _ref.read(videoPlayerServiceProvider).setRate(newSpeed);
      state = state.copyWith(playbackSpeed: newSpeed);
      HapticService.selection();
    }
  }

  /// Phase 12: Auto-detect subtitle file alongside the video.
  ///
  /// v1.63: the list moved to [SubtitleFormats.sidecarExtensions] and grew
  /// from four formats to twelve. It looked for `srt ass ssa vtt` only, so a
  /// `.smi` or a VobSub pair sitting right next to the video was never found
  /// even though libmpv reads both.
  Future<void> _autoLoadSidecarSubtitle(String uri) async {
    try {
      String? videoPath;
      if (uri.startsWith('file://')) {
        videoPath = Uri.parse(uri).toFilePath();
      } else if (uri.startsWith('/')) {
        videoPath = uri;
      }
      if (videoPath == null) return;
      final baseName = p.basenameWithoutExtension(videoPath);
      const candidates = SubtitleFormats.sidecarExtensions;
      // Settings → Subtitle → "Subtitle folder": an extra directory to search
      // besides the video's own. People who keep subtitles in one place had a
      // text field for it that nothing read, so only same-folder sidecars were
      // ever found. The video's own folder is still searched first — a
      // subtitle sitting next to the file is almost always the right one.
      final extraDir = _ref
          .read(extraSettingsProvider)
          .getStr(StringSetting.subtitleFolder)
          .trim();
      final dirs = <String>[
        p.dirname(videoPath),
        if (extraDir.isNotEmpty) extraDir,
      ];
      for (final dir in dirs) {
        for (final ext in candidates) {
          final candidate = p.join(dir, '$baseName.$ext');
          if (await File(candidate).exists()) {
            await _ref
                .read(videoPlayerServiceProvider)
                .loadExternalSubtitle(candidate);
            return;
          }
        }
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerGestures: $e'); }
  }

  int _nearestSpeedIndex(double speed) {
    int best = 0;
    double bestDiff = (speed - _speedSteps[0]).abs();
    for (int i = 1; i < _speedSteps.length; i++) {
      final d = (speed - _speedSteps[i]).abs();
      if (d < bestDiff) {
        best = i;
        bestDiff = d;
      }
    }
    return best;
  }

  void toggleShortcutsExpanded() {
    state = state.copyWith(shortcutsExpanded: !state.shortcutsExpanded);
    // Expanding/collapsing is deliberate user activity: reset the auto-hide
    // countdown so the (now longer) icon list stays put while the user
    // looks through it, instead of inheriting whatever time was left.
    _scheduleHideControls();
  }

  // Phase 7: Pinch-to-zoom — _zoomIndicatorTimer declared on the class.
  // Phase 14: Skip marker state (_introSkipped / _outroSkipped) is also
  // declared on the PlayerController class (extensions can't hold instance
  // fields).

  /// Called by ScaleGestureRecognizer during pinch
  /// [scaleDelta] is the multiplicative change (1.0 = no change)
  void onPinchUpdate(double scaleDelta) {
    if (state.isLocked && state.lockScope != 'rotation') return;
    var newScale = state.videoScale * scaleDelta;
    // Settings → Player → "Limit Video Resizing". 2x is the point past which a
    // 1080p source is being magnified more than the panel can repay — beyond
    // it you are enlarging compression artefacts, not seeing more detail. The
    // switch had no reader, so zoom always went to 10x.
    final maxScale = _ref
            .read(playerSettingsProvider)
            .get(PlayerSetting.limitResize)
        ? 2.0
        : 10.0;
    // Clamp 0.25x - max (PDF says 25% to 1000% unlimited)
    if (newScale < 0.25) newScale = 0.25;
    if (newScale > maxScale) newScale = maxScale;
    state = state.copyWith(
      videoScale: newScale,
      zoomIndicatorValue: newScale,
    );
  }

  void onPinchEnd() {
    if (state.isLocked && state.lockScope != 'rotation') return;
    // Schedule auto-hide of indicator after 1.5s
    _zoomIndicatorTimer?.cancel();
    _zoomIndicatorTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        state = state.copyWith(zoomIndicatorValue: null);
      }
    });
    // Audit fix (B5 cont.): persist per-URI zoom on gesture end (not
    // during, to avoid hammering shared_prefs across the pinch).
    final uri = _currentUri;
    if (uri != null) {
      // ignore: unawaited_futures
      _ref.read(userDataServiceProvider).setVideoZoom(uri, state.videoScale);
    }
  }

  void resetZoom() {
    _zoomIndicatorTimer?.cancel();
    state = state.copyWith(videoScale: 1.0, zoomIndicatorValue: null);
  }

  void _scheduleIndicatorClear() {
    _indicatorTimer?.cancel();
    _indicatorTimer = Timer(const Duration(milliseconds: 800), _clearIndicator);
  }

  void _clearIndicator() {
    if (mounted) state = state.copyWith(activeIndicator: null);
  }

}
