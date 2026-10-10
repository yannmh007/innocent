// PlayerController is split into `part` extensions, and an extension is not
// an instance member of the class, so every `state` access trips these two.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
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
    // ABOVE 100 %: with the audio booster on, swiping up past the top keeps
    // going into gain, as MX does (docs/player_gestures.md); swiping down
    // takes the gain back to 100 % before the volume itself moves.
    if (await _volumeBoostDelta(delta)) return;
    final newVolume = (state.volume + delta).clamp(0.0, 1.0);
    if (newVolume >= 1.0 && state.volume < 1.0) unawaited(HapticService.light());
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

  /// The booster's ceiling for a swipe: 200 % (MX), or the user's own
  /// booster level if that is set higher.
  double get _swipeBoostMax {
    final mult = _ref.read(preferencesProvider).audioVolumeBoost;
    return math.max(2.0, mult.clamp(1.0, 4.0).toDouble());
  }

  /// Handles the part of a volume swipe above 100 %. Returns true when it
  /// used [delta] (the gain moved), false when the ordinary volume should.
  Future<bool> _volumeBoostDelta(double delta) async {
    final boostOn =
        _ref.read(playerSettingsProvider).get(PlayerSetting.audioVolumeBoost);
    if (!boostOn) return false;
    final svc = _ref.read(videoPlayerServiceProvider);
    if (svc is! MediaKitPlayerService) return false;
    final gain = svc.outputVolumePct / 100.0;
    // Only from the top of the ordinary range: below 100 % a swipe moves
    // the volume as it always has, whatever gain the booster was opened at.
    if (state.volume < 1.0) return false;
    if (!(delta > 0) && !(gain > 1.0 && delta < 0)) return false;
    final next = (gain + delta).clamp(1.0, _swipeBoostMax).toDouble();
    if ((next - _swipeBoostMax).abs() < 1e-6 && gain < _swipeBoostMax) {
      unawaited(HapticService.light());
    }
    if (next <= 1.0 && gain > 1.0) unawaited(HapticService.light());
    await svc.setAudioGain(next);
    state = state.copyWith(
      activeIndicator: GestureIndicator.volume(next),
      zoomIndicatorValue: null,
    );
    _zoomIndicatorTimer?.cancel();
    _scheduleIndicatorClear();
    return true;
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
    final target = clampSeekTarget(
      current: _seekStartPosition!,
      delta: delta,
      duration: state.duration,
    );
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

  /// A double tap on a side, and each further tap of the same run (the
  /// engine counts them): one more step each, with the run's total shown
  /// on that side — YouTube's and VLC's stacked seek.
  void onDoubleTapStacked({required bool forward, required int count}) {
    if (state.isLocked && state.lockScope != 'rotation') return;
    final ps = _ref.read(playerSettingsProvider);
    if (!ps.get(PlayerSetting.ctlDoubleTapSeek)) return;
    final seconds = _ref.read(preferencesProvider).doubleTapSeekSeconds;
    HapticService.light();
    seekRelative(forward ? seconds : -seconds);
    _rippleSerial++;
    state = state.copyWith(
      doubleTapRipple: DoubleTapRipple(
        forward: forward,
        seconds: seconds * count,
        serial: _rippleSerial,
      ),
    );
    _rippleTimer?.cancel();
    _rippleTimer = Timer(const Duration(milliseconds: 750), () {
      if (mounted) state = state.copyWith(doubleTapRipple: null);
    });
  }

  // ── two-finger speed (MX) ────────────────────────────────────────

  void onSpeedGestureStart() {
    if (state.isLocked && state.lockScope != 'rotation') return;
    _speedGestureBase = state.playbackSpeed;
    HapticService.light();
    state = state.copyWith(
        activeIndicator: GestureIndicator.speed(state.playbackSpeed));
  }

  /// [steps] whole 0.1x steps from where the swipe began, 0.25x to 4x.
  void onSpeedGestureSteps(int steps) {
    if (state.isLocked && state.lockScope != 'rotation') return;
    final base = _speedGestureBase ?? state.playbackSpeed;
    final raw = (base + steps * 0.1).clamp(0.25, 4.0);
    final speed = (raw * 20).round() / 20; // to the nearest 0.05
    if ((speed - state.playbackSpeed).abs() > 0.001) {
      _ref.read(videoPlayerServiceProvider).setRate(speed);
      HapticService.selection();
    }
    state = state.copyWith(
      playbackSpeed: speed,
      activeIndicator: GestureIndicator.speed(speed),
    );
  }

  void onSpeedGestureEnd() {
    _speedGestureBase = null;
    _scheduleIndicatorClear();
  }

  // ── pan while zoomed (MX "zoom and pan") ─────────────────────────

  /// Moves a picture larger than the screen (Crop, 100 %, a pinch zoom)
  /// with two fingers, never so far that a black edge is pulled into
  /// view. [view] is the player's size in dp.
  void onPanDelta(Offset delta, Size view) {
    if (state.isLocked && state.lockScope != 'rotation') return;
    if (_viewport.isEmpty) _viewport = view;
    final next = clampPan(state.videoOffset + delta, _pictureSize, _viewport);
    if (next == state.videoOffset) return;
    state = state.copyWith(videoOffset: next);
    if (state.aspectRatioMode == AspectRatioMode.custom) _customOffset = next;
  }

  // ── subtitle gestures (MX) ───────────────────────────────────────

  /// A vertical drag that started on the subtitle: move it.
  /// [delta] is a fraction of the player's height (+ = down).
  Future<void> onSubtitleMoveDelta(double delta) async {
    if (state.isLocked && state.lockScope != 'rotation') return;
    final svc = _ref.read(videoPlayerServiceProvider);
    if (svc is! MediaKitPlayerService) return;
    final ex = _ref.read(extraSettingsProvider);
    final from = _subtitlePosDrag ??
        ex.getInt(IntSetting.subtitleVerticalPos).toDouble();
    final pos = (from + delta * 100).clamp(0.0, 100.0).toDouble();
    _subtitlePosDrag = pos;
    await svc.setSubtitleVerticalPos(pos.round());
    state = state.copyWith(
        activeIndicator: GestureIndicator.subtitlePosition(pos));
  }

  /// A pinch that started on the subtitle: size it.
  Future<void> onSubtitleScaleDelta(double scaleDelta) async {
    if (state.isLocked && state.lockScope != 'rotation') return;
    final svc = _ref.read(videoPlayerServiceProvider);
    if (svc is! MediaKitPlayerService) return;
    final ex = _ref.read(extraSettingsProvider);
    final from =
        _subtitleScaleDrag ?? ex.getInt(IntSetting.subtitleScale) / 100.0;
    final scale = (from * scaleDelta).clamp(0.3, 2.0).toDouble();
    _subtitleScaleDrag = scale;
    await svc.setSubtitleScale(scale);
    state =
        state.copyWith(activeIndicator: GestureIndicator.subtitleSize(scale));
  }

  /// A horizontal swipe on the subtitle: the next / previous line.
  Future<void> onSubtitleStep(int direction) async {
    if (state.isLocked && state.lockScope != 'rotation') return;
    final svc = _ref.read(videoPlayerServiceProvider);
    if (svc is! MediaKitPlayerService) return;
    unawaited(HapticService.selection());
    await svc.subSeek(direction);
  }

  /// Keeps what the subtitle gestures set, as the Subtitle settings would.
  Future<void> onSubtitleGestureEnd() async {
    final n = _ref.read(extraSettingsProvider.notifier);
    final pos = _subtitlePosDrag;
    final scale = _subtitleScaleDrag;
    _subtitlePosDrag = null;
    _subtitleScaleDrag = null;
    _scheduleIndicatorClear();
    try {
      if (pos != null) {
        await n.setInt(IntSetting.subtitleVerticalPos, pos.round());
      }
      if (scale != null) {
        await n.setInt(IntSetting.subtitleScale, (scale * 100).round());
      }
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerGestures: $e');
    }
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
  /// A pinch zooms from whatever is on screen and makes the mode Custom,
  /// as in MX: the zoom the user pinched to is what Custom then means.
  void onPinchUpdate(double scaleDelta) {
    if (state.isLocked && state.lockScope != 'rotation') return;
    final from = state.aspectRatioMode == AspectRatioMode.custom
        ? state.videoScale
        : effectiveVideoScale;
    // Settings → Player → "Limit Video Resizing". 2x is the point past which a
    // 1080p source is being magnified more than the panel can repay — beyond
    // it you are enlarging compression artefacts, not seeing more detail.
    final maxScale = _ref
            .read(playerSettingsProvider)
            .get(PlayerSetting.limitResize)
        ? 2.0
        : 10.0;
    final newScale = (from * scaleDelta).clamp(0.25, maxScale).toDouble();
    state = state.copyWith(
      aspectRatioMode: AspectRatioMode.custom,
      videoScale: newScale,
      zoomIndicatorValue: newScale,
      screenModeToast: null,
    );
    // Zooming out pulls a panned picture back with it.
    final offset = clampPan(state.videoOffset, _pictureSize, _viewport);
    if (offset != state.videoOffset) state = state.copyWith(videoOffset: offset);
    _customOffset = state.videoOffset;
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
      final uds = _ref.read(userDataServiceProvider);
      // ignore: unawaited_futures
      uds.setVideoZoom(uri, state.videoScale);
      // ignore: unawaited_futures
      uds.setVideoAspectName(uri, state.aspectRatioMode.name);
    }
  }

  void resetZoom() {
    _zoomIndicatorTimer?.cancel();
    _customOffset = Offset.zero;
    state = state.copyWith(
      aspectRatioMode: AspectRatioMode.fit,
      videoScale: 1.0,
      zoomIndicatorValue: null,
      videoOffset: Offset.zero,
    );
  }

  void _scheduleIndicatorClear() {
    _indicatorTimer?.cancel();
    _indicatorTimer = Timer(const Duration(milliseconds: 800), _clearIndicator);
  }

  void _clearIndicator() {
    if (mounted) state = state.copyWith(activeIndicator: null);
  }

}
