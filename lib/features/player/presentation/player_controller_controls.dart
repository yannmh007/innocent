// PlayerController is split into `part` extensions, and an extension is not
// an instance member of the class, so every `state` access trips these two.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'player_provider.dart';

extension PlayerControls on PlayerController {
  void toggleControls() {
    if (state.isLocked && state.lockScope != 'rotation') return;
    // Settings → Controls → "Tap to show/hide controls". Off means a single
    // tap on the video does nothing, which is what people who watch with the
    // bars pinned (or who keep brushing the screen) are asking for. The
    // switch had no reader, so a tap always toggled.
    //
    // The one exception is a tap that would REVEAL hidden controls: if the
    // bars are hidden and this is off, there would be no way back to them
    // short of the system back button. Hiding is what gets suppressed.
    if (state.controlsVisible &&
        !_ref.read(playerSettingsProvider).get(PlayerSetting.ctlTapToggle)) {
      // Treat it as activity instead, so the bars stay up rather than
      // vanishing under a stray touch.
      _scheduleHideControls();
      return;
    }
    final willShow = !state.controlsVisible;
    // Bringing the controls back on screen is the moment the position starts
    // being displayed again, so refresh it before the frame is built.
    if (willShow) syncPositionToState();
    state = state.copyWith(
      controlsVisible: willShow,
      // Whenever the controls hide (including a manual tap-to-hide while
      // paused), collapse the expanded shortcut row so the next tap-to-show
      // always starts from the default 4 icons — never the full list.
      shortcutsExpanded: willShow ? state.shortcutsExpanded : false,
    );
    if (willShow) _scheduleHideControls();
  }

  void showControls() {
    syncPositionToState();
    state = state.copyWith(controlsVisible: true);
    _scheduleHideControls();
  }

  /// Phase 45: forcibly hide the controls. Used by the PiP integration so
  /// the system's PiP overlay isn't competing with our own bars.
  void hideControls() {
    _hideControlsTimer?.cancel();
    // Collapse the shortcut row too, so it shows the default 4 icons when
    // controls reappear — not the previously-expanded full list.
    state = state.copyWith(controlsVisible: false, shortcutsExpanded: false);
  }

  /// MX Player parity: keep the controls on screen while the user is
  /// actively touching them — scrolling the shortcut row, dragging, or
  /// hunting for an icon among the expanded set. This ONLY resets the
  /// auto-hide countdown; it deliberately writes no state, so it can fire
  /// on every pointer move during a scroll without triggering rebuilds or
  /// interrupting the gesture. The fixed-time hide resumes the moment the
  /// finger lifts and the user stops interacting.
  void bumpControlsTimer() {
    if (!state.controlsVisible) return;
    _scheduleHideControls();
  }

  /// Phase 45: track whether we're in real Android Picture-in-Picture
  /// mode. Drives the lifecycle decision in `didChangeAppLifecycleState`.
  void setInSystemPip(bool inPip) {
    state = state.copyWith(inSystemPip: inPip);
  }

  void toggleLock() {
    HapticService.medium();
    // The lock overlay shows the elapsed time, so it is another surface that
    // brings the position back into view.
    syncPositionToState();
    final newLocked = !state.isLocked;
    // Audit fix (standard high-quality): read the user-chosen lock
    // scope from StringSetting.lockMode and apply it. 'rotation'
    // keeps controls + gestures usable (only freezes orientation).
    // 'touch' is the strictest — hides controls + blocks gestures.
    // 'all' (default) hides controls + blocks gestures but allows
    // tap-to-show for unlock.
    final scope = _ref
        .read(extraSettingsProvider)
        .getStr(StringSetting.lockMode);
    state = state.copyWith(
      isLocked: newLocked,
      lockScope: scope,
      // Rotation-only keeps controls visible; the other modes hide.
      controlsVisible: newLocked && scope == 'rotation' ? true : !newLocked,
    );
    if (!newLocked) _scheduleHideControls();
  }

  /// Kids Lock (MX parity, v0.49). Unlike [toggleLock] this absorbs
  /// EVERY touch (no tap-to-show), closes any open panel, and blocks
  /// the system back button; exit is only via the 2-second hold on the
  /// on-screen chip — deliberate enough that a toddler mashing the
  /// screen can't trigger it by accident.
  void toggleKidsLock() {
    HapticService.medium();
    final on = !state.isKidsLocked;
    state = state.copyWith(
      isKidsLocked: on,
      controlsVisible: !on,
      openPanel: SidePanel.none,
    );
    if (!on) _scheduleHideControls();
  }

  /// The screen's size and density, from the player's layout. Kept on the
  /// controller (not in the state: nothing redraws for it) so a mode
  /// change or a pinch can turn a mode into a zoom factor.
  void setViewport(Size view, double devicePixelRatio) {
    _viewport = view;
    _devicePixelRatio = devicePixelRatio;
  }

  /// The film's shape on screen: its pixel size with the user's aspect
  /// ratio override (Display → Aspect ratio) applied, or null before the
  /// first frame.
  Size? get displayVideoSize {
    final svc = _ref.read(videoPlayerServiceProvider);
    if (svc is! MediaKitPlayerService) return null;
    final v = svc.videoSize;
    if (v == null) return null;
    final ar = AspectRatioOverride.fromString(_ref
            .read(extraSettingsProvider)
            .getStr(StringSetting.aspectRatioOverride))
        .value;
    return ar == null ? v : Size(v.height * ar, v.height);
  }

  /// How much the contained picture is enlarged right now.
  double get effectiveVideoScale => screenModeScale(
        mode: state.aspectRatioMode,
        view: _viewport,
        video: displayVideoSize,
        devicePixelRatio: _devicePixelRatio,
        customScale: state.videoScale,
      );

  /// The picture's size on screen right now.
  Size get _pictureSize => pictureSize(
        mode: state.aspectRatioMode,
        view: _viewport,
        video: displayVideoSize,
        scale: effectiveVideoScale,
      );

  /// MX's fill toggle (Fit ↔ Crop), kept for the shortcut that calls it.
  void toggleFullscreenFill() {
    _setScreenMode(state.aspectRatioMode == AspectRatioMode.crop
        ? AspectRatioMode.fit
        : AspectRatioMode.crop);
    _scheduleHideControls();
  }

  /// MX Player's screen button: Fit to screen → Stretch → Crop → 100% →
  /// Custom → … (docs/player_playback_modes.md).
  void cycleAspectRatio() {
    // Settings → Player → "Quick zoom": skip Stretch, the one mode that
    // changes the film's shape.
    final quickZoom =
        _ref.read(playerSettingsProvider).get(PlayerSetting.quickZoom);
    var nextMode = state.aspectRatioMode.next;
    if (quickZoom && nextMode == AspectRatioMode.stretch) {
      nextMode = nextMode.next;
    }
    HapticService.selection();
    _setScreenMode(nextMode);
    // Kept per file, so the same film reopens the way it was watched.
    final uri = _currentUri;
    if (uri != null) {
      // ignore: unawaited_futures
      _ref.read(userDataServiceProvider).setVideoAspectName(uri, nextMode.name);
    }
    _scheduleHideControls();
  }

  /// Switch to [mode]: a preset mode starts centred; Custom comes back to
  /// the zoom and pan the user last pinched to.
  void _setScreenMode(AspectRatioMode mode) {
    final offset =
        mode == AspectRatioMode.custom ? _customOffset : Offset.zero;
    state = state.copyWith(
      aspectRatioMode: mode,
      videoOffset: offset,
      screenModeToast: mode,
      zoomIndicatorValue: null,
    );
    if (mode == AspectRatioMode.custom) {
      state = state.copyWith(
          videoOffset: clampPan(offset, _pictureSize, _viewport));
    }
    PlaybackLog.add('screen ${mode.name} '
        'x${effectiveVideoScale.toStringAsFixed(2)}');
    _modeToastTimer?.cancel();
    _modeToastTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) state = state.copyWith(screenModeToast: null);
    });
  }

  /// Phase 45 (audit refined): set the EXPLICIT aspect ratio override.
  /// Different from [cycleAspectRatio] (which toggles fit/crop/stretch
  /// behavior). This forces libmpv to render at the given ratio (1:1,
  /// 4:3, 16:9, etc.) regardless of the file's embedded SAR/DAR. The
  /// value is persisted via ExtraSettings so it applies on every play.
  Future<void> setExplicitAspectRatio(AspectRatioOverride r) async {
    await _ref
        .read(extraSettingsProvider.notifier)
        .setStr(StringSetting.aspectRatioOverride, r.name);
    try {
      await _ref
          .read(videoPlayerServiceProvider)
          .setAspectRatioOverride(r.value);
    } catch (e) { if (kDebugMode) debugPrint('PlayerControls: $e'); }
    _scheduleHideControls();
  }

  void openMoreMenu() {
    syncPositionToState();
    _hideControlsTimer?.cancel();
    state = state.copyWith(openPanel: SidePanel.more, controlsVisible: true);
  }

  void openSubtitleMenu() {
    _hideControlsTimer?.cancel();
    state =
        state.copyWith(openPanel: SidePanel.subtitle, controlsVisible: true);
  }

  void closePanel() {
    state = state.copyWith(openPanel: SidePanel.none);
    _scheduleHideControls();
  }

  void openDecoderDialog() {
    _hideControlsTimer?.cancel();
    state = state.copyWith(decoderDialogOpen: true, controlsVisible: true);
  }

  void closeDecoderDialog() {
    state = state.copyWith(decoderDialogOpen: false);
    _scheduleHideControls();
  }

  void selectDecoder(DecoderType type) async {
    state = state.copyWith(decoder: type, decoderDialogOpen: false);
    _scheduleHideControls();
    // BUG FIX — the decoder switch used to reopen the file, and the video
    // came back at 00:00 every time.
    //
    // Writing libmpv's `hwdec` property IS the switch. mpv's own command
    // handler reinitialises the decoder in place and then seeks back to the
    // frame you were on:
    //
    //     mp_decoder_wrapper_control(dec, VDCTRL_REINIT, NULL);
    //     double last_pts = mpctx->video_pts;
    //     if (last_pts != MP_NOPTS_VALUE)
    //         queue_seek(mpctx, MPSEEK_ABSOLUTE, last_pts, MPSEEK_EXACT, 0);
    //                                                -- mpv player/command.c
    //
    // It is a designed runtime toggle — mpv's own Ctrl+h binding flips hwdec
    // during playback — and it is how MX Player behaves. Reopening on top of
    // it did the job a second time and worse: Player.open() issues `loadfile`
    // and returns before the demuxer is ready, so the seek fired immediately
    // afterwards had nothing to seek in, threw, was swallowed by the catch,
    // and playback continued from the start of the newly loaded file.
    //
    // The reopen also meant that choosing a decoder which maps to the SAME
    // hwdec mode — on a local file "Default" and "HW" both resolve to
    // `auto-safe` — restarted the video to change nothing at all.
    try {
      final svc = _ref.read(videoPlayerServiceProvider);
      final uri = _currentUri;
      if (uri == null) return;
      state = state.copyWith(errorMessage: null);
      final isNetwork = _isNetworkUri(uri);
      // Map our DecoderType to the libmpv hwdec mode used in openVideo.
      // Phase 45 (audit refined, build 63): MX Player V3's
      // `omxdecoder.2` overall policy gates the per-stream choice.
      // If the user has set "Never use HW", force SW regardless of
      // the requested decoder type. If "Local files only", force SW
      // for network. If "Always try HW first", upgrade defaultMode
      // and sw to auto.
      final extras = _ref.read(extraSettingsProvider);
      final omxPolicy = extras.getStr(StringSetting.omxDecoderMode);
      String hwdec;
      switch (type) {
        case DecoderType.defaultMode:
          // Phase 45 (audit): MX Player's "Default" decoder lets the
          // engine make the best choice. Our equivalent: auto-safe for
          // local files (most stable), auto for network (where HW+
          // helps with bandwidth limits).
          hwdec = isNetwork ? 'auto' : 'auto-safe';
          break;
        case DecoderType.hw:
          hwdec = 'auto-safe';
          break;
        case DecoderType.hwPlus:
          hwdec = 'auto';
          break;
        case DecoderType.sw:
          hwdec = 'no';
          break;
      }
      // Apply the overall policy override.
      if (omxPolicy == 'never') {
        hwdec = 'no';
      } else if (omxPolicy == 'localOnly' && isNetwork) {
        hwdec = 'no';
      } else if (omxPolicy == 'everywhere' &&
          (type == DecoderType.defaultMode || type == DecoderType.sw)) {
        hwdec = 'auto';
      }
      // The whole switch, in one property write. mpv reinitialises the
      // decoder and restores the exact frame itself.
      await svc.setHardwareDecoder(hwdec);
      // What the switch actually achieved — the decoder mpv settled on can
      // differ from the one asked for — once it has settled.
      if (svc is MediaKitPlayerService) {
        Timer(const Duration(seconds: 5), () async {
          try {
            PlaybackLog.add('decoder ${type.name}: ${await svc.describePipeline()}');
          } catch (_) {}
        });
      }
      // The buffering profile is a set of runtime properties too, so it can be
      // refreshed without reloading anything. Kept in step with the open path
      // so a decoder switch never silently reinstates desktop-sized buffers.
      //
      // THROUGH [_applyStreamProfileFor], which carries the one thing the
      // call here used to drop: whether the address is this app's own caching
      // proxy. Without it, changing decoder mid-film while watching through
      // the proxy turned `cache-on-disk` back on, and mpv began spilling a
      // second copy of every byte the proxy was already writing to the same
      // phone — a duplicate of the film, invisible, charged to the viewer's
      // storage, for the sake of a decoder switch.
      if (svc is MediaKitPlayerService) {
        await _applyStreamProfileFor(uri);
      } else {
        await svc.setDemuxerCacheMb(isNetwork ? 96 : 32);
      }
    } catch (_) {
      // libmpv verifies option changes at runtime and rejects ones it cannot
      // apply, keeping the previous value — so a failed switch leaves the file
      // playing on the decoder it already had. That is the right outcome:
      // the user's selection shows in the UI, playback is undisturbed, and any
      // genuine codec failure still arrives through errorStream.
    }
  }

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    // Audit fix (A4): when the "pin controls" toggle is on, never
    // schedule the hide — just leave them visible.
    final prefs = _ref.read(playerSettingsProvider);
    if (prefs.get(PlayerSetting.alwaysShowControls)) return;
    // Audit fix (A2): delay is user-tunable, clamped 2-15s.
    final extra = _ref.read(extraSettingsProvider);
    final secs = extra.getInt(IntSetting.controlsHideDelay);
    _hideControlsTimer = Timer(Duration(seconds: secs), () {
      // Phase 42: MX Player parity — controls stay visible while paused, so
      // the user can see exactly where they stopped (timestamp, seek bar,
      // play button). Only auto-hide when playback is actually progressing.
      if (mounted &&
          state.isPlaying &&
          !state.isLocked &&
          state.openPanel == SidePanel.none &&
          !state.decoderDialogOpen &&
          !state.sleepTimerDialogOpen &&
          !state.resumeDialogOpen) {
        // Also collapse the shortcut row so it returns to the default 4.
        state =
            state.copyWith(controlsVisible: false, shortcutsExpanded: false);
      }
    });
  }

  // ============ SHORTCUT ACTIONS ============

}
