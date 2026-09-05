part of 'player_provider.dart';

extension PlayerModes on PlayerController {
  Future<void> toggleMute() async {
    final svc = _ref.read(videoPlayerServiceProvider);
    final volSvc = _ref.read(volumeServiceProvider);
    // Audit fix (B6): haptic on mute toggle. Audio-state changes are
    // exactly the kind of binary action a tactile click should
    // confirm — sound goes away, click happens, user knows.
    HapticService.medium();
    // AUDIT FIX — mute used to write 0 to the DEVICE's media volume as well as
    // to libmpv's. Two things went wrong with that. The phone's global media
    // volume stayed at zero after leaving the app (users reported "my ringer
    // media volume keeps getting turned down"), and unmuting restored a plain
    // 0..1 value, which silently discarded any audio boost — a 200 % boost
    // came back at 100 %. libmpv's own `mute` property is scoped to this
    // player, is instant, and leaves the volume level (boost included)
    // completely untouched.
    if (state.isMuted) {
      final restore = _volumeBeforeMute > 0 ? _volumeBeforeMute : 0.5;
      if (svc is MediaKitPlayerService) {
        await svc.setMuted(false);
      } else {
        await svc.setVolume(restore);
      }
      if (state.volume <= 0.0) {
        await volSvc.setVolume(restore);
        if (!mounted) return;
        state = state.copyWith(isMuted: false, volume: restore);
      } else {
        if (!mounted) return;
        state = state.copyWith(isMuted: false);
      }
    } else {
      _volumeBeforeMute = state.volume;
      if (svc is MediaKitPlayerService) {
        await svc.setMuted(true);
      } else {
        await svc.setVolume(0);
      }
      if (!mounted) return;
      state = state.copyWith(isMuted: true);
    }
  }

  void toggleLoop() => state = state.copyWith(isLoopEnabled: !state.isLoopEnabled);

  /// Phase 15: Set tri-state loop mode (Off / One / All).
  /// Mutually exclusive with Shuffle when set to non-off.
  void setLoopMode(LoopMode mode) {
    state = state.copyWith(
      loopMode: mode,
      isLoopEnabled: mode != LoopMode.off,
      // Turn off shuffle when enabling loop
      isShuffleEnabled: mode != LoopMode.off ? false : state.isShuffleEnabled,
    );
  }

  /// Phase 15: Enable shuffle (disables loop)
  void setShuffleEnabled(bool enabled) {
    state = state.copyWith(
      isShuffleEnabled: enabled,
      loopMode: enabled ? LoopMode.off : state.loopMode,
      isLoopEnabled: enabled ? false : state.isLoopEnabled,
    );
  }

  void toggleShuffle() => state = state.copyWith(isShuffleEnabled: !state.isShuffleEnabled);
  void toggleMirrorMode() => state = state.copyWith(isMirrorMode: !state.isMirrorMode);
  void toggleVerticalFlip() => state = state.copyWith(isVerticalFlip: !state.isVerticalFlip);
  void toggleNightMode() => state = state.copyWith(isNightMode: !state.isNightMode);
  void toggleBackgroundPlay() {
    final newValue = !state.isBackgroundPlay;
    state = state.copyWith(isBackgroundPlay: newValue);
    // CERTAINTY FIX (v1.55.1) — ask for POST_NOTIFICATIONS the moment the user
    // opts in, not never.
    //
    // On Android 13+ this permission is what decides whether a foreground
    // service's notification is SHOWN. Without it the service still runs and
    // the audio still plays, so nothing looks broken from the inside — but the
    // ongoing notification is silently suppressed, and with it go the Play,
    // Pause and Stop buttons AND the MediaStyle media card on the lock screen.
    // Every visible part of background play would simply be absent, with no
    // error anywhere to explain it.
    //
    // The app already asks for this for the ADB pairing flow, so the plumbing
    // exists; it was just never wired to the feature that needs it most.
    // Turning background play on is exactly the right moment to ask, and
    // permission_handler only surfaces a dialog when there is a decision left
    // to make.
    if (newValue && !_isPrivate) {
      // ignore: discarded_futures
      _ensureNotificationPermission();
    }
    // (Private videos never reach the background-play service — the
    //  player screen suppresses backgrounding for them entirely.)
    // Phase 45: also start/stop the Android foreground service so audio
    // continues when the app is backgrounded or the screen is off.
    // Without this, libmpv's audio thread can be throttled under
    // aggressive battery savers (Xiaomi MIUI, Oppo ColorOS, etc).
    try {
      final svc = _ref.read(backgroundPlaybackServiceProvider);
      if (newValue) {
        final title = _currentVideoTitle ?? 'Innocent';
        svc.start(title: title);
        // Turning the toggle on while PAUSED used to take the service's
        // partial WakeLock and hold it with nothing decoding. Hand straight
        // over to the playback-driven owner, which arms the release timer when
        // paused and does nothing when already playing.
        _updateBackgroundWakeLock(state.isPlaying);
      } else {
        svc.stop();
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerModes: $e'); }
    // Pre-arm the harmless part now, so libmpv is already configured by the
    // time the screen goes off.
    //
    // BUG FIX — this used to call setBackgroundAudioMode(true) here, which now
    // deselects the video track. Doing that at TOGGLE time would make the
    // picture vanish the instant someone flipped the switch mid-film. The
    // detach belongs to the lifecycle transition, not to the toggle; only the
    // surface-independent properties are set here.
    try {
      if (newValue) {
        // ignore: discarded_futures
        prepareBackgroundAudio();
      } else {
        // Turning background play OFF while backgrounded should put the
        // picture back rather than leave the track deselected.
        // ignore: discarded_futures
        setBackgroundAudioMode(false);
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerModes: $e'); }
  }

  /// Stop the audio-only foreground service unconditionally. Called when the
  /// player is torn down without background-play/PiP so no service (and thus
  /// no lingering audio/notification) is left running in the background.
  /// Best-effort POST_NOTIFICATIONS request; see [toggleBackgroundPlay].
  ///
  /// Deliberately silent on refusal: audio still works without it, and a
  /// second nag on every toggle would be worse than the missing buttons.
  Future<void> _ensureNotificationPermission() async {
    try {
      final perms = _ref.read(permissionServiceProvider);
      if (await perms.hasNotificationPermission()) return;
      if (await perms.isNotificationPermanentlyDenied()) return;
      await perms.requestNotificationPermission();
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerModes.notifPerm: $e');
    }
  }

  void stopBackgroundPlaybackService() {
    try {
      _ref.read(backgroundPlaybackServiceProvider).stop();
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerModes.stopBg: $e');
    }
  }

  Future<void> cycleSpeed() async {
    const cycle = [0.5, 1.0, 1.25, 1.5, 2.0];
    final current = state.playbackSpeed;
    final idx = cycle.indexWhere((s) => (s - current).abs() < 0.01);
    final next = cycle[(idx + 1) % cycle.length];
    // Audit fix (B6): haptic on every speed-cycle step so the user
    // feels the click even when they aren't looking at the screen.
    HapticService.selection();
    await setSpeed(next);
  }

  /// A-B Repeat tap progression:
  /// 1st tap → set A at current position
  /// 2nd tap → set B at current position (must be > A)
  /// 3rd tap → clear both
  void cycleABRepeat() {
    final a = state.abPointA;
    final b = state.abPointB;
    // Engine position: A and B must land where the video actually is, not on
    // the whole-second UI copy (which is also only refreshed while the
    // controls are on screen).
    final now = _livePosition();
    if (a == null) {
      // Set A
      state = state.copyWith(abPointA: now);
    } else if (b == null) {
      // Set B (only if > A)
      if (now > a) {
        state = state.copyWith(abPointB: now);
      } else {
        // Position is before A; reset A to current instead
        state = state.copyWith(abPointA: now);
      }
    } else {
      // Clear both
      state = state.copyWith(abPointA: null, abPointB: null);
    }
  }

  void updateVisibleShortcuts(Set<ShortcutItem> shortcuts) {
    state = state.copyWith(visibleShortcuts: shortcuts);
    // Persist it. Without this the Customise Items screen was write-only:
    // the checkboxes moved, the row updated, and closing the player threw the
    // whole thing away because the controller is autoDispose.
    try {
      // Serialise in enum order rather than set order, so the row is laid out
      // the same way every time instead of following whatever order the set
      // happened to iterate in.
      final ordered = ShortcutItem.values
          .where(shortcuts.contains)
          .map((e) => e.name)
          .join('|');
      // ignore: unawaited_futures
      _ref
          .read(extraSettingsProvider.notifier)
          .setStr(StringSetting.playerShortcuts,
              ordered.isEmpty ? '-' : ordered);
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerModes.shortcuts: $e');
    }
  }

  /// Read the saved shortcut row back, or null when the user has never
  /// customised it (in which case [PlayerState]'s built-in default stands).
  Set<ShortcutItem>? loadSavedShortcuts() {
    try {
      final raw = _ref
          .read(extraSettingsProvider)
          .getStr(StringSetting.playerShortcuts)
          .trim();
      if (raw.isEmpty) return null;
      if (raw == '-') return <ShortcutItem>{};
      final byName = {for (final e in ShortcutItem.values) e.name: e};
      final out = <ShortcutItem>{};
      for (final n in raw.split('|')) {
        final item = byName[n.trim()];
        // Unknown names are skipped rather than throwing, so a saved row
        // written by an older build survives an enum rename intact apart
        // from the renamed entry.
        if (item != null) out.add(item);
      }
      return out;
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerModes.shortcuts: $e');
      return null;
    }
  }

  // ============ GESTURES ============

}
