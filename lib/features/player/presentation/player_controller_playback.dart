part of 'player_provider.dart';

extension PlayerPlayback on PlayerController {
  /// Open video. Returns true if there's a saved position to resume from.
  Future<void> openVideo(
    String uri, {
    String? title,
    bool isPrivate = false,
    bool ephemeral = false,
  }) async {
    // Remember privacy state for THIS video so all the persistence paths
    // (resume, last-playing, history) can skip writing when it's a vault
    // item. Set before any await so early save paths see the right value.
    _isPrivate = isPrivate;
    // Same, for a URI that is not a stable identity (a signed, expiring stream
    // URL). See [_isEphemeral] for why writing one down is three bugs.
    _isEphemeral = ephemeral;
    if (!ephemeral) {
      // A plain file supersedes any stream renewal still registered from the
      // last one, so a renewer can never be applied to the wrong media.
      StreamRenewal.clear();
    }
    // If another open is running, record this request and let the
    // running one chain to it when it finishes. This ensures the user
    // always ends up on the last-tapped video, not on an intermediate.
    if (_openInProgress) {
      _pendingOpenUri = uri;
      _pendingOpenTitle = title;
      return;
    }
    _openInProgress = true;
    var nextUri = uri;
    var nextTitle = title;
    try {
      while (true) {
        await _doOpenVideo(nextUri, nextTitle);
        // If the user tapped another video while we were opening,
        // honor that and run again.
        if (_pendingOpenUri == null) break;
        nextUri = _pendingOpenUri!;
        nextTitle = _pendingOpenTitle;
        _pendingOpenUri = null;
        _pendingOpenTitle = null;
      }
    } finally {
      _openInProgress = false;
      _pendingOpenUri = null;
      _pendingOpenTitle = null;
    }
  }

  Future<void> _doOpenVideo(String uri, String? title) async {
    // Keep the caller's original uri: for adb:// sources the resolved target
    // (a per-session proxy URL) isn't stable across restarts, so the crash-
    // resume marker below should remember the adb:// uri and re-resolve it.
    final originalUri = uri;
    // Android/data videos (surfaced from the ADB scan) can't be read by this
    // app directly. An "adb://<path>" uri means: copy the file out over the ADB
    // connection into our own cache, then play that local copy. This full-read
    // path is the reliable one (the same approach Shizuku-based file managers
    // use); on-demand HTTP streaming was tried but is fragile per-request over
    // ADB and gave media_kit no way to fall back when a stream stalled, so
    // playback could fail outright. Reliability first.
    if (uri.startsWith('adb://')) {
      final src = uri.substring('adb://'.length);
      // Give immediate, honest feedback: a copy can take a few seconds (longer
      // for big files), and without this the player just shows a blank frame
      // and looks stuck.
      if (mounted) {
        state = state.copyWith(
          isBuffering: true,
          errorMessage: null,
          loadingMessage: 'Loading video over ADB…\nLarger files take a moment.',
        );
      }
      final local = await AdbService.instance.pullForPlayback(src);
      if (local.startsWith('ERROR:')) {
        if (mounted) {
          state = state.copyWith(
            // AUDIT FIX — isBuffering was left true on this path, so the
            // loading spinner kept turning on top of the error card forever
            // and the screen read as "still trying" when it had given up.
            isBuffering: false,
            loadingMessage: null,
            errorMessage: 'Could not load this video over ADB. Make sure the '
                'device is still connected on the ADB screen, then try again.',
          );
        }
        return;
      }
      if (mounted) state = state.copyWith(loadingMessage: null);
      uri = local;
    }
    _currentUri = uri;
    // Keep the library-facing identity separate from the URI libmpv plays,
    // so Next / Previous / Loop-all keep working for adb:// videos whose
    // playable URI is a local cache copy.
    _libraryUri = originalUri;
    _currentVideoTitle = title;
    // A new file (or a re-open of the same one) is a new viewing.
    _countedThisPlay = false;
    _introSkipped = false;
    _outroSkipped = false;
    // Audit: crash-recovery marker. Anything that survives in
    // resumeStorage from this call to the next clean exit means the
    // app died mid-playback. The home screen reads this on cold
    // start and offers a "Resume X?" snackbar.
    // Privacy: NEVER write this marker for a vault video — the cold-start
    // prompt lives on the public Local tab and would expose the title.
    // Same for an ephemeral URI: the prompt would name a Video Hub title on a
    // screen in front of the age gate, and open a URL that has since expired.
    if (!_isPrivate && !_isEphemeral) {
      try {
        await _ref.read(resumeStorageProvider).setLastPlaying(
              uri: originalUri.startsWith('adb://') ? originalUri : uri,
              title: title ?? uri.split('/').last,
            );
      } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
    }
    // Phase 45: cancel any in-flight network retry from the prior
    // session so it doesn't compete with the new file.
    _networkRetryInFlight = false;
    // Phase 45: stale state from the previous video must not leak into
    // the new one. Clear error + playbackCompleted now; tracks will be
    // overwritten by the streams as soon as libmpv probes the new file.
    state = state.copyWith(
      errorMessage: null,
      playbackCompleted: false,
      isBuffering: true,
      position: Duration.zero,
      // Audit fix (B2): auto-close any side panel / dialog left open
      // from the previous video. Without this a user who had the
      // tracks panel open could see audio tracks from the OLD file
      // briefly stick around until the new file's streams arrived,
      // then watch the list mutate beneath their finger. Same
      // applies to decoder dialog, sleep-timer dialog, resume
      // dialog (which is now stale by definition).
      openPanel: SidePanel.none,
      decoderDialogOpen: false,
      sleepTimerDialogOpen: false,
      resumeDialogOpen: false,
      pendingResumePosition: null,
      resumeIsAskMode: false,
    );
    // Phase 43: MX Player V3 parity — never let music and video play at the
    // same time. Pause music first if it's running.
    try {
      await _ref.read(musicAudioServiceProvider).pause();
    } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
    final svc = _ref.read(videoPlayerServiceProvider);
    if (!svc.isInitialized) await svc.initialize();

    // Phase 45: apply the user's decoder strategy BEFORE opening the
    // file so libmpv picks the right path on the first frame. The logic
    // mirrors MX Player's "decoder list" — try HW first when allowed,
    // fall back to SW when HW is disabled or the user asked for it
    // specifically. Local vs network is judged by URI scheme.
    final isNetwork = _isNetworkUri(uri);
    try {
      final ps = _ref.read(playerSettingsProvider);
      final tryHw = ps.get(PlayerSetting.decTryHw);
      final tryHwPlus = ps.get(PlayerSetting.decTryHwPlus);
      final swLocal = ps.get(PlayerSetting.decSwLocal);
      final swNetwork = ps.get(PlayerSetting.decSwNetwork);
      // The other half of the decoder matrix. Settings offers "Use HW decoder
      // for local files" and "...for network streams" as their own switches,
      // and neither was read: only the software side of the same grid was,
      // so turning HW off for network streams did nothing. Also
      // Debug → "Disable hardware acceleration", which is the blunt override
      // people reach for when a specific file will not play.
      final hwLocal = ps.get(PlayerSetting.decHwLocal);
      final hwNetwork = ps.get(PlayerSetting.decHwNetwork);
      final devNoHw = ps.get(PlayerSetting.devDisableHwAccel);
      final hwAllowedHere = isNetwork ? hwNetwork : hwLocal;

      final wantsSwOnly = devNoHw ||
          !hwAllowedHere ||
          (!isNetwork && swLocal) ||
          (isNetwork && swNetwork);

      String hwdec;
      if (wantsSwOnly || (!tryHw && !tryHwPlus)) {
        hwdec = 'no';
      } else if (tryHwPlus) {
        // HW+ allows aggressive HW with copy fallback for rare codecs.
        hwdec = 'auto';
      } else {
        // Plain HW — safe fallback to SW when a codec isn't HW-supported.
        hwdec = 'auto-safe';
      }
      await svc.setHardwareDecoder(hwdec);
    } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }

    // Size the whole buffering group for this source.
    //
    // BATTERY/HEAT FIX — this used to raise only the byte ceiling (150 MB
    // local / 250 MB network) and leave the seconds-based read-ahead at
    // desktop values, so a local film ran behind a cache thread holding well
    // over a hundred megabytes it never needed. Local storage is faster than
    // the decoder; read-ahead there is pure cost. Network keeps the generous
    // buffer, because absorbing a dead spot is the entire point of it.
    try {
      if (svc is MediaKitPlayerService) {
        await svc.setStreamBufferProfile(network: isNetwork);
      } else {
        await svc.setDemuxerCacheMb(isNetwork ? 96 : 32);
      }
      if (isNetwork) await svc.setNetworkTimeout(10);
    } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }

    // Phase 45 (audit): apply user-configured extra settings on every
    // file open. These come from the new ExtraSettings service and map
    // directly to MX Player V3's `frag_audio.xml` / `frag_subtitle.xml`
    // / `frag_general.xml` entries.
    try {
      final extras = _ref.read(extraSettingsProvider);
      // Audio delay (MX Player's `audio_delay` setting in ms).
      await svc.setAudioDelayMs(extras.getInt(IntSetting.audioDelay));
      // Global subtitle sync offset.
      await svc.setSubtitleDelayMs(
          extras.getInt(IntSetting.subtitleDefaultSync));
      // Phase 45 (audit refined, build 63): HW decoder subtitle sync
      // calibration. MX Player V3's `calibrate_hw_play_position`
      // (frag_subtitle.xml) — non-zero value compensates for HW
      // decoder presentation latency. Stored in SECONDS in MX
      // Player; we convert to milliseconds and ADD to the existing
      // sub-delay so both settings stack.
      final hwCalibSec =
          extras.getInt(IntSetting.calibrateHwPlayPosition);
      if (hwCalibSec != 0 &&
          state.decoder != DecoderType.sw) {
        // Read current sub-delay and adjust by the HW calibration.
        final baseSyncMs =
            extras.getInt(IntSetting.subtitleDefaultSync);
        await svc.setSubtitleDelayMs(baseSyncMs + hwCalibSec * 1000);
      }
      // Subtitle encoding override (empty = auto-detect).
      await svc
          .setSubtitleCharset(extras.getStr(StringSetting.subtitleCharset));
      // Preferred audio / subtitle language for multi-track files.
      await svc.setPreferredAudioLanguage(
          extras.getStr(StringSetting.audioLanguage));
      await svc.setPreferredSubtitleLanguage(
          extras.getStr(StringSetting.subtitleLanguage));
      // HTTP user-agent override (network streams only).
      if (isNetwork) {
        await svc.setHttpUserAgent(
            extras.getStr(StringSetting.httpUserAgent));
      }
      // Phase 45 (audit refined): explicit aspect ratio override.
      // MX Player V3's `video-aspect-override`. The user can pick
      // from 12 ratios (or "Default" to use the file's intrinsic).
      try {
        final ar = AspectRatioOverride.fromString(
            extras.getStr(StringSetting.aspectRatioOverride));
        await svc.setAspectRatioOverride(ar.value);
      } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
      // Apply the panscan (zoom-to-fill) that matches the current aspect
      // mode, so a fresh video starts consistent with the selected Fit/Zoom
      // state instead of libmpv's default. Fit/original/stretch → 0.0.
      try {
        await svc.setPanscan(state.aspectRatioMode.panscan);
      } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
      // Four switches that had a label, a description, a saved value — and
      // no reader anywhere, so flipping them did nothing at all. Each maps to
      // a single libmpv property; they were simply never connected.
      if (svc is MediaKitPlayerService) {
        final ps2 = _ref.read(playerSettingsProvider);
        await svc.setFastSeeking(ps2.get(PlayerSetting.fastSeeking));
        await svc.setDeinterlace(ps2.get(PlayerSetting.decDeinterlace));
        await svc.setSpeedupTricks(ps2.get(PlayerSetting.decSpeedupTricks));
        await svc.setSubtitleItalic(
            ps2.get(PlayerSetting.subtitleItalicEffect));
      }
      // Phase 45 (audit refined, build 63): audio device + Dolby/DTS
      // passthrough. MX Player V3 `audio_device` +
      // `prefer_audio_passthrough_mode`.
      try {
        await svc.setAudioDevice(
            extras.getStr(StringSetting.audioDevice));
      } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
      try {
        final passthrough = _ref
            .read(playerSettingsProvider)
            .get(PlayerSetting.preferAudioPassthrough);
        await svc.setAudioPassthrough(passthrough);
      } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
      // Phase 45 (audit refined, build 63): subtitle text appearance
      // (Scale / Shadow / Background / Bottom margin). MX Player V3
      // subtitle_text_screen sliders/pickers now ACTUALLY apply to
      // libmpv's `sub-*` properties instead of being visible-only.
      try {
        if (svc is MediaKitPlayerService) {
          final scale = extras.getInt(IntSetting.subtitleScale) / 100.0;
          // Phase 45 (audit refined, build 64): font size preset is
          // combined with user scale (preset * user = final scale).
          await svc.setSubtitleFontSize(
              extras.getInt(IntSetting.subtitleFontSize), scale);
          await svc.setSubtitleShadow(
              extras.getInt(IntSetting.subtitleShadow));
          // AUDIT FIX — "Show background" is the master gate. It used to be
          // written into the subtitle SHADOW colour, which is why toggling it
          // darkened the outline and never drew a panel. It now forces the
          // background fully transparent when off and lets the user's chosen
          // colour + opacity through when on, so the two controls compose
          // instead of overwriting each other.
          final showSubBg = _ref
              .read(playerSettingsProvider)
              .get(PlayerSetting.subLayoutShowBackground);
          final opacityLevel = showSubBg
              ? extras.getInt(IntSetting.subtitleBackgroundOpacity)
              : 0;
          await svc.setSubtitleBackgroundOpacity(opacityLevel);
          await svc.setSubtitleBottomMargin(
              extras.getInt(IntSetting.subtitleBottomMargin));
          // Phase 45 (audit refined, build 63): color + alignment.
          await svc.setSubtitleTextColor(
              extras.getInt(IntSetting.subtitleTextColor));
          await svc.setSubtitleBorderColor(
              extras.getInt(IntSetting.subtitleBorderColor));
          await svc.setSubtitleBackgroundColor(
              extras.getInt(IntSetting.subtitleBackgroundColor),
              opacityLevel);
          await svc.setSubtitleAlignment(
              extras.getInt(IntSetting.subtitleAlignment));
          // Phase 45 (audit refined, build 64): border style.
          await svc.setSubtitleBorderStyle(
              extras.getInt(IntSetting.subtitleBorderStyle));
          // Phase 45 (audit refined, build 64): improve stroke
          // rendering — ASS `force` (our styling wins) vs `no` (the
          // file's own ASS styling is left intact).
          final improveStroke = _ref
              .read(playerSettingsProvider)
              .get(PlayerSetting.subTextImproveStroke);
          await svc.setSubtitleImproveStroke(improveStroke);
        }
      } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
    } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }

    // Check for resume position before opening
    final savedPos =
        await _ref.read(resumeStorageProvider).getPosition(uri);

    // Decide UP-FRONT whether this file must open PAUSED. When the resume
    // mode is 'ask' and there's a real saved position, a Resume / Start over
    // dialog is about to appear (see the resume-decision block below) — and
    // the video must sit on its first frame BEHIND that dialog until the user
    // chooses, not play (with audio) from 0 while they decide. Opening with
    // autoplay:false avoids the brief play-then-pause audio blip that a
    // post-open pause would cause. These three inputs mirror the decision
    // block further down exactly, so the two stay in lock-step — nothing
    // mutates them in between.
    final resumeModeAtOpen =
        _ref.read(extraSettingsProvider).getStr(StringSetting.resumeLast);
    final resumeOnlyFirstAtOpen =
        _ref.read(playerSettingsProvider).get(PlayerSetting.resumeOnlyFirst);
    final willAskResume = savedPos != null &&
        savedPos > const Duration(seconds: 30) &&
        (!resumeOnlyFirstAtOpen || !_hasOpenedFirstFile) &&
        resumeModeAtOpen == 'ask';

    // Silent-resume ('resume' mode) hands the saved position to open() so
    // libmpv lands there as part of loading the file.
    //
    // AUDIT FIX — the seek used to happen much further down, after roughly a
    // dozen awaited setting writes. In between, the file played from 00:00
    // with sound, so resuming an episode began with a fraction of a second of
    // the wrong scene and audio before snapping forward. open(startAt:) also
    // uses keyframe seeking, so the first frame appears immediately instead of
    // libmpv decoding forward to an exact timestamp nobody can perceive.
    final bool willSilentResume = savedPos != null &&
        savedPos > const Duration(seconds: 30) &&
        (!resumeOnlyFirstAtOpen || !_hasOpenedFirstFile) &&
        resumeModeAtOpen == 'resume';
    await svc.open(
      uri,
      autoplay: !willAskResume,
      startAt: willSilentResume ? savedPos : null,
    );
    // Non-ask paths play immediately; the 'ask' path stays paused until the
    // user picks Resume/Start over (resumeFromSaved / startOverFromBeginning
    // each start playback then).
    if (!willAskResume) await svc.play();
    // The player screen may have been popped while the file was loading;
    // every state write from here on has to be guarded.
    if (!mounted || _currentUri != uri) return;

    // Re-apply the user's saved equalizer / audio-effect tuning to the
    // engine now that audio is flowing. Without this, a saved EQ curve
    // only takes effect while the EQ sheet is open — after an app restart
    // playback would start flat until the user reopened the panel. Guarded
    // by the audio-effects master switch and fired fire-and-forget so it
    // never delays the first frame. (Private videos are unaffected — EQ is
    // an audio-output effect, not a stored trace.)
    // ignore: unawaited_futures
    () async {
      try {
        final masterOn = _ref
            .read(playerSettingsProvider)
            .get(PlayerSetting.audioEffectsEnabled);
        await _ref
            .read(equalizerServiceProvider)
            .reapplyFromCache(masterEnabled: masterOn);
      } catch (e) {
        if (kDebugMode) debugPrint('PlayerPlayback.eq-reapply: $e');
      }
    }();
    // Audit fix (B5): restore the per-URI brightness + volume the
    // user landed on last time. Fired AFTER play() so the volume set
    // actually sticks (some libmpv builds reset volume on open).
    // Errors here are silent — failing to restore is annoying but
    // not playback-blocking.
    // ignore: unawaited_futures
    _restorePerVideoBrightnessVolume(uri);

    // Audit fix (standard high-quality): if the user previously
    // downloaded a subtitle via "Add Subtitle from URL", attach
    // it now. Fire-and-forget — failure means the user can still
    // manually attach via "Add subtitle file" in the player.
    () async {
      try {
        final subPath = await _ref
            .read(subtitleDownloadServiceProvider)
            .findExisting(uri);
        if (subPath != null && mounted && _currentUri == uri) {
          await svc.loadExternalSubtitle(subPath);
        }
      } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
    }();

    // Phase 12: Apply preferences on open
    try {
      final prefs = _ref.read(preferencesProvider);

      // Apply audio volume boost (from preferences). Phase 45: use the
      // dedicated setAudioGain() helper which can amplify beyond 100 %,
      // not the clamped setVolume(0..1). Gated by Settings → Audio →
      // "Volume boost" so a stray multiplier never amps audio silently.
      final boostEnabled = _ref
          .read(playerSettingsProvider)
          .get(PlayerSetting.audioVolumeBoost);
      if (boostEnabled && prefs.audioVolumeBoost > 1.0) {
        await svc.setAudioGain(prefs.audioVolumeBoost.clamp(1.0, 4.0));
      }
      // Audit fix (Phase 4 #15): apply loudness normalization toggle
      // for newly opened files.
      final loudnessOn = _ref
          .read(playerSettingsProvider)
          .get(PlayerSetting.loudnessNormalization);
      if (svc is MediaKitPlayerService) {
        await svc.setLoudnessNormalization(loudnessOn);
      }
      // Audit fix (standard high-quality): apply subtitle layout
      // settings on each open so a freshly loaded file picks up
      // the user's preferences. The live-apply listener handles
      // mid-playback tweaks; this is the cold-start path.
      if (svc is MediaKitPlayerService) {
        final extras = _ref.read(extraSettingsProvider);
        try {
          await svc.setMpvProperty(
              'sub-pos',
              '${extras.getInt(IntSetting.subtitleVerticalPos)}');
          await svc.setMpvProperty(
              'sub-margin-x',
              '${extras.getInt(IntSetting.subtitleMarginX)}');
          await svc.setMpvProperty(
              'sub-margin-y',
              '${extras.getInt(IntSetting.subtitleMarginY)}');
          // Horizontal alignment: libmpv `sub-align-x` accepts the
          // strings 'left' / 'center' / 'right'. We map our 0/1/2
          // int into those names.
          const alignNames = ['left', 'center', 'right'];
          final alignIdx =
              extras.getInt(IntSetting.subtitleHorizontalAlign);
          if (alignIdx >= 0 && alignIdx < alignNames.length) {
            await svc.setMpvProperty('sub-align-x', alignNames[alignIdx]);
          }
          // Only honour an explicit background colour string when the user
          // actually set one AND the background is switched on — otherwise
          // this blank write used to land on top of the composed value.
          final bg =
              extras.getStr(StringSetting.subtitleBackgroundColor).trim();
          final bgOn = _ref
              .read(playerSettingsProvider)
              .get(PlayerSetting.subLayoutShowBackground);
          if (bg.isNotEmpty && bgOn) {
            await svc.setMpvProperty('sub-back-color', bg);
          }
          // Audit fix: CPU core limit for SW decoding. 0 = libmpv auto.
          final threads = extras.getInt(IntSetting.videoDecoderThreads);
          if (threads > 0) {
            await svc.setMpvProperty('vd-lavc-threads', '$threads');
          }
          // Audit fix: default brightness on first open if no per-URI
          // value exists. -1 = follow system (we skip).
          final defaultB =
              extras.getInt(IntSetting.defaultBrightnessPct);
          final autoB = _ref
              .read(playerSettingsProvider)
              .get(PlayerSetting.screenAutoBrightness);
          if (defaultB >= 0 && !autoB) {
            final uds = _ref.read(userDataServiceProvider);
            final perUri = await uds.getVideoBrightness(uri);
            if (perUri == null && mounted) {
              final v = defaultB / 100.0;
              state = state.copyWith(brightness: v);
              try {
                await _ref
                    .read(brightnessServiceProvider)
                    .setBrightness(v);
              } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
            }
          }
        } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }

    // Phase 11: restore per-video playback speed
    // Per-video > preferences default > 1.0
    try {
      double? speedToApply;
      final savedSpeed =
          await _ref.read(userDataServiceProvider).getVideoSpeed(uri);
      if (savedSpeed != null) {
        speedToApply = savedSpeed;
      } else {
        // Phase 45 (audit): MX Player V3 stores default_playback_speed
        // as an integer percent (25..400, default 100 = 1.0x). Prefer
        // the new ExtraSettings value when it's been customised; fall
        // back to the legacy double preference for back-compat.
        final pct = _ref
            .read(extraSettingsProvider)
            .getInt(IntSetting.defaultPlaybackSpeed);
        if (pct != 100) {
          speedToApply = pct / 100.0;
        } else {
          final prefs = _ref.read(preferencesProvider);
          if (prefs.defaultPlaybackSpeed != 1.0) {
            speedToApply = prefs.defaultPlaybackSpeed;
          }
        }
      }
      if (speedToApply != null && speedToApply != 1.0) {
        await svc.setRate(speedToApply);
        if (mounted && _currentUri == uri) {
          state = state.copyWith(playbackSpeed: speedToApply);
        }
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }

    // Phase 12: Apply subtitle preferences
    try {
      final prefs = _ref.read(preferencesProvider);
      if (!prefs.subtitleEnabled) {
        await svc.setSubtitleTrack(null);
      }
      // Apply subtitle font size
      await svc.setSubtitleSize(prefs.subtitleSize.size);

      // Phase 45: apply subtitle style from PlayerSettings → Subtitle.
      // libmpv doesn't have a single "bold" property, but we can fake
      // it by switching the font family to the OS bold-sans + thicker
      // border. Background is implemented as a translucent box around
      // each line via `sub-back-color`.
      final ps = _ref.read(playerSettingsProvider);
      final bold = ps.get(PlayerSetting.subTextBold);
      // Bold now uses libmpv's own `sub-bold` instead of being faked with
      // border thickness, so it no longer cancels the border-style picker.
      // The background is composed above, where the colour and opacity the
      // user picked are in scope.
      if (svc is MediaKitPlayerService) {
        await svc.setSubtitleBold(bold);
      }
      // Phase 45 (audit refined, build 64): apply the user-selected
      // subtitle font from StringSetting.typefaceDir. Empty = libmpv
      // system default. Otherwise the value is either a font family
      // name (e.g. 'sans-serif') or a full .ttf path.
      final extras = _ref.read(extraSettingsProvider);
      final fontName =
          extras.getStr(StringSetting.typefaceDir).trim();
      // Only the font is set here now. Border size belongs to the border-style
      // picker and shadow colour to the shadow picker; writing them from here
      // as a bold/background approximation is what made those two settings
      // appear to do nothing.
      if (fontName.isNotEmpty) {
        await svc.setSubtitleStyle(font: fontName);
      }

      // Phase 12: Auto-detect sidecar subtitle (.srt/.ass with same name)
      if (prefs.subtitleEnabled) {
        await _autoLoadSidecarSubtitle(uri);
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }

    // Settings → Player → "Background play (audio)" is the DEFAULT for the
    // in-player headphones toggle, not a separate feature. It had no reader,
    // so a user who turned it on still had to press the toggle by hand every
    // single time — which is the one thing the setting exists to avoid.
    // Only applied on the first file of a session, so it never overrides a
    // choice the user made mid-session by tapping the toggle.
    try {
      if (!_appliedBgPlayDefault) {
        _appliedBgPlayDefault = true;
        final wantBg = _ref
            .read(playerSettingsProvider)
            .get(PlayerSetting.bgPlayAudio);
        if (wantBg && !state.isBackgroundPlay && !_isPrivate) {
          toggleBackgroundPlay();
        }
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }

    // Phase 14: Load skip markers
    try {
      final markers =
          await _ref.read(userDataServiceProvider).getSkipMarkers(uri);
      if (!mounted || _currentUri != uri) return;
      if (markers != null) {
        state = state.copyWith(
          introEndMs: markers.introEndMs,
          outroStartMs: markers.outroStartMs,
        );
      } else {
        state = state.copyWith(introEndMs: null, outroStartMs: null);
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }

    if (!mounted || _currentUri != uri) return;
    if (savedPos != null && savedPos > const Duration(seconds: 30)) {
      // Phase 41: respect "Resume only the first file" — when on, only the
      // first file opened in this session restores its saved position.
      // Subsequent files (next/prev) start from the beginning.
      final resumeOnlyFirst = _ref
          .read(playerSettingsProvider)
          .get(PlayerSetting.resumeOnlyFirst);
      final shouldConsiderRestore =
          !resumeOnlyFirst || !_hasOpenedFirstFile;
      _hasOpenedFirstFile = true;

      // Phase 45 (audit): MX Player V3 `resume_last` setting has THREE
      // values, not two: 'ask' (default), 'resume', 'startover'.
      //   - 'resume':   silently jump to saved position
      //   - 'startover': always start from 0
      //   - 'ask':      pop a dialog "Do you wish to resume from where
      //                 you stopped?" with [Resume] / [Start over] buttons
      // We previously hard-coded the 'resume' branch + auto-dismiss
      // banner. Now we honour the setting.
      final mode = _ref
          .read(extraSettingsProvider)
          .getStr(StringSetting.resumeLast);
      if (shouldConsiderRestore) {
        if (mode == 'startover') {
          // User explicitly opted out — start from 0, do nothing.
        } else if (mode == 'resume') {
          // The seek already happened as part of open(startAt:) above — doing
          // it a second time here would re-trigger buffering for no reason.
          state = state.copyWith(
            pendingResumePosition: savedPos,
            resumeDialogOpen: true,
          );
          Future.delayed(const Duration(seconds: 5), () {
            if (mounted && state.resumeDialogOpen) {
              state = state.copyWith(
                resumeDialogOpen: false,
                pendingResumePosition: null,
              );
            }
          });
        } else {
          // 'ask' (default): show the resume dialog WITHOUT auto-seeking.
          // Audit fix (A3): if the user doesn't interact within 12 s,
          // we auto-pick "Resume" (the friendlier default) instead of
          // leaving the dialog blocking the screen forever. This matches
          // Netflix / Plex / Jellyfin behaviour and avoids the "I tapped
          // the wrong file, walked away, came back to a dead dialog"
          // situation that real users hit.
          state = state.copyWith(
            pendingResumePosition: savedPos,
            resumeDialogOpen: true,
            resumeIsAskMode: true,
          );
          Future.delayed(const Duration(seconds: 12), () {
            if (!mounted) return;
            // Re-check both flags — user may have answered the dialog
            // already (which clears them) or closed the player entirely.
            if (state.resumeDialogOpen && state.resumeIsAskMode) {
              // Resume is the default action. Calling the public method
              // also handles the 3-second overshoot tolerance we added
              // earlier.
              resumeFromSaved();
            }
          });
        }
      }
    } else {
      _scheduleHideControls();
    }
  }

  /// Confirm the resume. Behaviour depends on which mode we're in:
  ///   - **Confirmation toast mode** (legacy): the video has already
  ///     auto-seeked; calling this just dismisses the toast.
  ///   - **Ask mode** (Phase 45 audit): the video has NOT yet been
  ///     seeked. We seek to the saved position here, then resume.
  Future<void> resumeFromSaved() async {
    if (state.resumeIsAskMode && state.pendingResumePosition != null) {
      try {
        // Industry pattern (Netflix, YouTube, Plex all do this):
        // rewind ~3 seconds before the saved position so the user
        // gets brief context for what's happening, not a dead-cold
        // mid-sentence resume. Helps especially when the saved
        // position is from an auto-save that triggered late.
        final saved = state.pendingResumePosition!;
        const overshootTolerance = Duration(seconds: 3);
        final target = saved > overshootTolerance
            ? saved - overshootTolerance
            : Duration.zero;
        await _ref
            .read(videoPlayerServiceProvider)
            .seek(target);
        // The file opened PAUSED behind the ask dialog — begin playback now
        // that the user has chosen Resume (or the 12 s timeout defaulted to
        // it). Without this the video would sit frozen on the saved frame.
        await _ref.read(videoPlayerServiceProvider).play();
      } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
    }
    // Seek + play are platform round-trips, and this write sits OUTSIDE the
    // try above — so if the user tapped Resume and then Back, writing state on
    // the disposed controller threw an uncaught StateError.
    if (!mounted) return;
    state = state.copyWith(
      resumeDialogOpen: false,
      pendingResumePosition: null,
      resumeIsAskMode: false,
    );
    _scheduleHideControls();
  }

  /// Phase 17: "START OVER" — seek to 0 and clear saved position.
  Future<void> startOverFromBeginning() async {
    final svc = _ref.read(videoPlayerServiceProvider);
    // Starting over is a fresh pass: re-arm the once-per-play auto-skips.
    _introSkipped = false;
    _outroSkipped = false;
    // Audit fix: capture URI BEFORE the seek-await so that a
    // concurrent openVideo can't change `_currentUri` between the
    // null-check and the clearPosition call. Same TOCTOU pattern
    // already fixed in `_autoSavePosition`.
    final uriAtEntry = _currentUri;
    try {
      await svc.seek(Duration.zero);
      // The file opened PAUSED behind the ask dialog — start playing from the
      // top now that the user picked Start over.
      await svc.play();
    } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
    if (uriAtEntry != null) {
      try {
        await _ref.read(resumeStorageProvider).clearPosition(uriAtEntry);
      } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
    }
    // Same exposure as resumeFromSaved: awaits above, write outside the try.
    if (!mounted) return;
    state = state.copyWith(
      resumeDialogOpen: false,
      pendingResumePosition: null,
      resumeIsAskMode: false,
    );
    _scheduleHideControls();
  }

  void dismissResumeDialog() {
    state = state.copyWith(
      resumeDialogOpen: false,
      pendingResumePosition: null,
    );
    _scheduleHideControls();
  }

  Future<void> playOrPause() async {
    // Settings → Player → "Toggle playback with play button". Off, the button
    // only ever starts playback and never pauses — for people who hand the
    // phone to a child, or who keep catching the button mid-film. The switch
    // had no reader, so it always toggled.
    if (state.isPlaying &&
        !_ref.read(playerSettingsProvider).get(PlayerSetting.togglePlayback)) {
      _scheduleHideControls();
      return;
    }
    await _ref.read(videoPlayerServiceProvider).playOrPause();
    _scheduleHideControls();
  }

  Future<void> pause() async {
    await _ref.read(videoPlayerServiceProvider).pause();
  }

  /// Hard-stop playback: pauses AND tells libmpv to stop, so no audio thread
  /// lingers after the player screen is gone. Used when leaving the player
  /// without background-play/PiP. Best-effort and never throws.
  Future<void> stopPlayback() async {
    final svc = _ref.read(videoPlayerServiceProvider);
    try {
      await svc.pause();
    } catch (_) {}
    try {
      await svc.stop();
    } catch (_) {}
  }

  /// Cut audio the INSTANT the user leaves the player (Back, arrow, gesture)
  /// when nothing is meant to keep playing — don't wait for dispose(), which
  /// runs only after the pop animation and left libmpv's audio thread audible
  /// behind the previous screen for a beat.
  ///
  /// IMPORTANT: this only PAUSES (which silences immediately) — it must NOT
  /// call stop(), because stop() resets libmpv's position to zero, and
  /// dispose() saves the resume point from the live position right after this.
  /// Stopping here would wipe the position before it's saved, losing the user's
  /// place. dispose()'s stopPlayback() does the authoritative pause+stop AFTER
  /// the final resume save. Idempotent.
  void stopPlaybackImmediate() {
    final svc = _ref.read(videoPlayerServiceProvider);
    // pause() is the fastest path to silence and keeps the position intact.
    // Fire-and-forget so this returns synchronously with no UI stall.
    try {
      // ignore: discarded_futures
      svc.pause();
    } catch (_) {}
    // Also tear down the audio-only foreground service if it was running, so a
    // background notification can't keep the audio session alive.
    try {
      stopBackgroundPlaybackService();
    } catch (_) {}
  }

  /// Toggle libmpv's background-audio mode (decode audio without a video
  /// surface). Called by the player screen on background/foreground so
  /// screen-off never intermittently stalls background playback.
  /// Harmless preparation that does NOT detach the video. Safe to call while
  /// the user is still watching.
  Future<void> prepareBackgroundAudio() async {
    final svc = _ref.read(videoPlayerServiceProvider);
    if (svc is MediaKitPlayerService) {
      await svc.prepareBackgroundAudio();
    }
  }

  Future<void> setBackgroundAudioMode(bool enabled) async {
    await _ref
        .read(videoPlayerServiceProvider)
        .setBackgroundAudioMode(enabled);
  }

  Future<void> play() async {
    final svc = _ref.read(videoPlayerServiceProvider);
    await svc.play();
    // Phase 45 (audit refined, build 63): apply MX Player V3's
    // `audio_fade_in_on_start`. The user can disable this in
    // Settings → Audio. We only fade when libmpv exposes the helper
    // (currently media_kit). Cast safely so non-supporting
    // implementations fail soft.
    final fadeOnStart = _ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.audioFadeOnStart);
    if (fadeOnStart && svc is MediaKitPlayerService) {
      // Don't await — the ramp runs in the background so play()
      // returns immediately and the UI stays responsive.
      // ignore: unawaited_futures
      svc.fadeInVolume();
    }
  }

  /// Begin / end a seek-bar drag.
  ///
  /// AUDIT FIX — the "snappy scrub" keyframe-seek optimisation existed but was
  /// wired only to the swipe-to-seek GESTURE, never to the seek bar itself, so
  /// dragging the bar (which is how most people seek) still asked libmpv for a
  /// frame-exact landing on every throttled step and showed a spinner instead
  /// of moving. Both paths now share one scrub session.
  void beginScrub() {
    _isScrubbing = true;
    final svc = _ref.read(videoPlayerServiceProvider);
    if (svc is MediaKitPlayerService) {
      // ignore: unawaited_futures
      svc.setPreciseSeek(false);
    }
  }

  Future<void> endScrub() async {
    if (!_isScrubbing) return;
    _isScrubbing = false;
    final svc = _ref.read(videoPlayerServiceProvider);
    if (svc is MediaKitPlayerService) {
      await svc.setPreciseSeek(true);
    }
  }

  /// Copy the engine's live position into state.
  ///
  /// Companion to the rebuild gate in the position listener: while nothing on
  /// screen shows the position we stop writing it, so whatever brings the
  /// position back into view calls this first and the very first frame is
  /// already correct rather than showing a stale second.
  /// The most accurate position available: libmpv's own, falling back to the
  /// UI copy only before the engine has reported anything.
  Duration _livePosition() {
    final live = _ref.read(videoPlayerServiceProvider).position;
    return live > Duration.zero ? live : state.position;
  }

  /// The duration twin of [_livePosition], and deliberately in the same
  /// extension rather than on the class.
  ///
  /// BUILD FIX (v1.55.2) — a getter named `_livePosition` was briefly added to
  /// the CLASS while this method already existed on an EXTENSION of it. Dart
  /// resolves a class member ahead of an extension member, so the class getter
  /// silently won and every existing `_livePosition()` call became "isn't a
  /// function and can't be invoked". Nothing was redeclared, so no duplicate
  /// check could see it — the two names simply lived in different scopes on
  /// the same type. Keeping helpers beside their siblings avoids the whole
  /// question.
  Duration _liveDuration() {
    final live = _ref.read(videoPlayerServiceProvider).duration;
    return live > Duration.zero ? live : state.duration;
  }

  void syncPositionToState() {
    if (!mounted) return;
    final live = _ref.read(videoPlayerServiceProvider).position;
    if (live > Duration.zero && live.inSeconds != state.position.inSeconds) {
      state = state.copyWith(position: live);
    }
  }

  /// Phase 13: Dismiss the error banner
  void dismissError() {
    state = state.copyWith(errorMessage: null);
  }

  // === Phase 14: Skip markers ===

  Future<void> setIntroMarker() async {
    if (_currentUri == null) return;
    // Engine position, not the UI copy: the UI copy is only refreshed while
    // something is showing it, and it is rounded to whole seconds either way.
    final pos = _livePosition().inMilliseconds;
    state = state.copyWith(introEndMs: pos);
    _introSkipped = true; // don't trigger on the very moment we set it
    await _ref.read(userDataServiceProvider).setSkipMarkers(
          _currentUri!,
          SkipMarkers(
            introEndMs: pos,
            outroStartMs: state.outroStartMs,
          ),
        );
  }

  Future<void> setOutroMarker() async {
    if (_currentUri == null) return;
    final pos = _livePosition().inMilliseconds;
    state = state.copyWith(outroStartMs: pos);
    await _ref.read(userDataServiceProvider).setSkipMarkers(
          _currentUri!,
          SkipMarkers(
            introEndMs: state.introEndMs,
            outroStartMs: pos,
          ),
        );
  }

  Future<void> clearSkipMarkers() async {
    if (_currentUri == null) return;
    state = state.copyWith(introEndMs: null, outroStartMs: null);
    _introSkipped = false;
    _outroSkipped = false;
    await _ref
        .read(userDataServiceProvider)
        .clearSkipMarkers(_currentUri!);
  }

  Future<void> seek(Duration to) async {
    final svc = _ref.read(videoPlayerServiceProvider);
    // Audit fix: clamp to valid bounds. libmpv tolerates out-of-range
    // values but the UI state would briefly show negative or
    // past-end positions until libmpv corrects them. Industry
    // pattern: clamp at the caller (Netflix / VLC / ExoPlayer's
    // standard `seekTo` is documented to clamp).
    final dur = state.duration;
    final clamped = to < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && to > dur ? dur : to);
    await svc.seek(clamped);
    // Phase 45 (audit refined, build 63): MX Player V3's
    // `audio_fade_in_on_seek`. Apply same volume ramp behaviour
    // post-seek so the audio doesn't slam in mid-scene.
    //
    // AUDIT FIX — skipped while the user is dragging the seek bar. A scrub
    // fires a throttled seek roughly every 60 ms and each one used to start
    // its own 300 ms ramp, so several ramps wrote the volume at once and the
    // result was pumping, not fading.
    final fadeOnSeek = _ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.audioFadeOnSeek);
    if (fadeOnSeek && !_isScrubbing && svc is MediaKitPlayerService) {
      // ignore: unawaited_futures
      svc.fadeInVolume(duration: const Duration(milliseconds: 300));
    }
  }

  Future<void> seekRelative(int seconds) async {
    final svc = _ref.read(videoPlayerServiceProvider);
    // Audit fix: same clamping as `seek`. Spam-tapping +10 at the end
    // of a 5-minute clip would otherwise let the internal position
    // run past duration before completion fires.
    //
    // AUDIT FIX — base the jump on the ENGINE's position, not `state.position`.
    // State position is deliberately quantised to whole seconds to keep the
    // 2800-line player screen from rebuilding on every tick, so a +10 s skip
    // taken from it actually moved somewhere between 9.0 and 10.0 seconds, and
    // repeated skips accumulated the error. libmpv's live position is exact.
    final dur = state.duration;
    final base = svc.position > Duration.zero ? svc.position : state.position;
    final target = base + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && target > dur ? dur : target);
    await svc.seek(clamped);
    // Keep the on-screen position in step immediately; the quantised stream
    // update can be up to a second behind and the label would lag the jump.
    if (mounted) state = state.copyWith(position: clamped);
    final fadeOnSeek = _ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.audioFadeOnSeek);
    if (fadeOnSeek && !_isScrubbing && svc is MediaKitPlayerService) {
      // ignore: unawaited_futures
      svc.fadeInVolume(duration: const Duration(milliseconds: 300));
    }
    _scheduleHideControls();
  }

  /// Step exactly one frame, and show it.
  ///
  /// v1.63. Deliberately NOT built out of [seekRelative] with a small
  /// duration: seeking lands on the nearest decodable point, which on a
  /// long-GOP file can be seconds from where the user asked. libmpv decodes
  /// exactly one frame instead.
  ///
  /// The state has to be corrected by hand afterwards because the engine's
  /// pause and its new position both arrive through streams that are
  /// quantised to whole seconds — a single frame is far below that, so
  /// waiting for them would leave the UI showing the old time on the new
  /// picture.
  Future<void> frameStep({bool forward = true}) async {
    if (state.isLocked) return;
    final svc = _ref.read(videoPlayerServiceProvider);
    await svc.frameStep(forward: forward);
    if (!mounted) return;
    state = state.copyWith(
      isPlaying: false,
      position: svc.position,
      // Controls must stay up: stepping is something a person does several
      // times in a row, and a fade-out between taps would make it unusable.
      controlsVisible: true,
    );
    _scheduleHideControls();
  }

  Future<void> setSpeed(double rate) async {
    await _ref.read(videoPlayerServiceProvider).setRate(rate);
    if (!mounted) return;
    state = state.copyWith(playbackSpeed: rate);
    // Phase 11: persist per-video speed (sticky)
    if (_currentUri != null) {
      try {
        await _ref
            .read(userDataServiceProvider)
            .setVideoSpeed(_currentUri!, rate);
      } catch (e) { if (kDebugMode) debugPrint('PlayerPlayback: $e'); }
    }
  }

  // ============ AUTO-SAVE ============

}
