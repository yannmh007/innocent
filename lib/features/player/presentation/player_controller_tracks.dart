part of 'player_provider.dart';

extension PlayerTracks on PlayerController {
  Future<void> selectAudioTrack(AudioTrackInfo? track) async {
    if (track == null) return;
    await _ref.read(videoPlayerServiceProvider).setAudioTrack(track);
    // The engine call is a platform round-trip; the player can be gone by the
    // time it returns if the user pressed Back straight after choosing.
    if (!mounted) return;
    state = state.copyWith(currentAudioTrack: track);
    // Phase 41: persist the choice when "Remember selections" is on.
    final remember = _ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.rememberSelections);
    if (remember && _currentUri != null) {
      try {
        await _ref
            .read(userDataServiceProvider)
            .setVideoAudioTrackId(_currentUri!, track.id);
      } catch (e) { if (kDebugMode) debugPrint('PlayerTracks: $e'); }
    }
  }

  Future<void> selectSubtitleTrack(SubtitleTrackInfo? track) async {
    await _ref.read(videoPlayerServiceProvider).setSubtitleTrack(track);
    if (!mounted) return;
    state = state.copyWith(currentSubtitleTrack: track);
    // Phase 41: persist the choice when "Remember selections" is on.
    // A null track means "subtitles off" — store that as an empty string so
    // we can distinguish it from "never selected" on the next open.
    final remember = _ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.rememberSelections);
    if (remember && _currentUri != null) {
      try {
        await _ref
            .read(userDataServiceProvider)
            .setVideoSubtitleTrackId(_currentUri!, track?.id ?? '');
      } catch (e) { if (kDebugMode) debugPrint('PlayerTracks: $e'); }
    }
  }

  Future<void> loadExternalSubtitle(String path) async {
    await _ref.read(videoPlayerServiceProvider).loadExternalSubtitle(path);
  }

  // ============ SLEEP TIMER ============

  void openSleepTimerDialog() {
    _hideControlsTimer?.cancel();
    state = state.copyWith(
      sleepTimerDialogOpen: true,
      controlsVisible: true,
    );
  }

  void closeSleepTimerDialog() {
    state = state.copyWith(sleepTimerDialogOpen: false);
    _scheduleHideControls();
  }

  void selectSleepTimer(SleepTimerOption option, {bool playToEnd = false}) {
    _sleepTimerTicker?.cancel();
    if (option.mode == SleepTimerMode.off) {
      _clearSleepTimer();
      state = state.copyWith(sleepTimerDialogOpen: false);
      _scheduleHideControls();
      return;
    }

    if (option.mode == SleepTimerMode.endOfVideo) {
      state = state.copyWith(
        sleepTimer:
            const SleepTimerState(mode: SleepTimerMode.endOfVideo),
        sleepTimerDialogOpen: false,
      );
      _scheduleHideControls();
      return;
    }

    // Custom duration
    final duration = option.duration!;
    // Anchor to a wall-clock deadline so the timer is immune to Dart-timer
    // throttling while the screen is off: each tick recomputes remaining from
    // the real clock, and the moment a tick sees the deadline has passed it
    // fires — even if many 1-second ticks were skipped during deep sleep.
    final deadline = DateTime.now().add(duration);
    state = state.copyWith(
      sleepTimer: SleepTimerState(
        remaining: duration,
        mode: SleepTimerMode.custom,
        playToEnd: playToEnd,
        deadline: deadline,
      ),
      sleepTimerDialogOpen: false,
    );
    _scheduleHideControls();

    _sleepTimerTicker =
        Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final dl = state.sleepTimer.deadline;
      if (dl == null) {
        timer.cancel();
        return;
      }
      // Real elapsed time drives everything — not a decrementing counter.
      final remaining = dl.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        timer.cancel();
        if (playToEnd) {
          // UX-2 (audit): don't cut off mid-scene — switch to the
          // end-of-video stop mode so the current item finishes first.
          if (mounted) {
            state = state.copyWith(
              sleepTimer:
                  const SleepTimerState(mode: SleepTimerMode.endOfVideo),
            );
          }
        } else {
          _ref.read(videoPlayerServiceProvider).pause();
          // The whole point of a sleep timer is to save power overnight — so
          // once it fires and pauses, tear down the background foreground
          // service + its partial WakeLock too. Leaving them up would keep the
          // CPU awake all night with nothing playing, draining the battery.
          // Also flip the state flag off so the UI reflects it.
          try {
            stopBackgroundPlaybackService();
            if (mounted && state.isBackgroundPlay) {
              state = state.copyWith(isBackgroundPlay: false);
            }
          } catch (e) {
            if (kDebugMode) debugPrint('PlayerTracks: $e');
          }
          _clearSleepTimer();
        }
      } else {
        // BATTERY/HEAT FIX — this wrote a fresh PlayerState every second for
        // the whole life of the timer, rebuilding the entire player screen
        // each time. A 90-minute sleep timer therefore rebuilt ~5,400 times to
        // animate a countdown that is only drawn while the controls are on
        // screen — and the controls are hidden for almost all of it. The
        // deadline is wall-clock, so skipping these writes cannot make the
        // timer drift or miss; when the controls reappear the countdown is
        // recomputed from the deadline on the next tick.
        if (!state.controlsVisible && !state.sleepTimerDialogOpen) return;
        // Round up so the visible countdown shows e.g. "1:00" not "0:59" at
        // the first tick, and never displays a stale sub-second value.
        final shown = Duration(seconds: remaining.inSeconds + 1);
        if (state.sleepTimer.remaining?.inSeconds == shown.inSeconds) return;
        state = state.copyWith(
          sleepTimer: SleepTimerState(
            remaining: shown,
            mode: SleepTimerMode.custom,
            playToEnd: playToEnd,
            deadline: dl,
          ),
        );
      }
    });
  }

  void _clearSleepTimer() {
    _sleepTimerTicker?.cancel();
    _sleepTimerTicker = null;
    if (mounted) {
      state = state.copyWith(sleepTimer: const SleepTimerState());
    }
  }

  // ============ UI STATE ============

}
