// PlayerController is split into `part` extensions, and an extension is not
// an instance member of the class, so every `state` access trips these two.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'player_provider.dart';

extension PlayerNavigation on PlayerController {
  void _scheduleAutoSave() {
    // Throttle, NOT debounce: keep a save firing on a steady ~5 s cadence
    // during continuous playback. The previous version cancelled and reset
    // the timer on every position tick, so while a video played without
    // pausing the timer never actually elapsed and nothing was persisted —
    // a force-kill mid-playback then lost the resume point entirely. Now the
    // first tick arms the timer and later ticks leave it running, so progress
    // is saved every few seconds and a crash loses at most ~5 s.
    if (_autoSaveTimer?.isActive ?? false) return;
    _autoSaveTimer =
        Timer(const Duration(seconds: 5), () => _autoSavePosition());
  }

  /// Phase 14: Find and play the next video in the same folder
  Future<void> _playNextInFolder() async {
    await playNextInFolder();
  }

  /// Phase 15: Public — play next video in current folder
  Future<void> playNextInFolder() async {
    final key = _libraryUri ?? _currentUri;
    if (key == null) return;
    try {
      final videos = await _ref.read(allVideosProvider.future);
      final currentIdx = videos.indexWhere((v) => v.uri == key);
      if (currentIdx < 0) return;
      final currentFolder = videos[currentIdx].folderPath;
      // AUDIT FIX — Shuffle was a toggle with a lit-up icon and no behaviour
      // behind it: nothing in the next-video path ever read it, so it played
      // the folder in order regardless. Now it picks a random OTHER file in
      // the same folder.
      if (state.isShuffleEnabled) {
        final pool = <int>[];
        for (int i = 0; i < videos.length; i++) {
          if (i != currentIdx && videos[i].folderPath == currentFolder) {
            pool.add(i);
          }
        }
        if (pool.isNotEmpty) {
          final pick = pool[_shuffleRandom.nextInt(pool.length)];
          await openVideo(videos[pick].uri, title: videos[pick].title);
          return;
        }
      }
      for (int i = currentIdx + 1; i < videos.length; i++) {
        if (videos[i].folderPath == currentFolder) {
          await openVideo(videos[i].uri, title: videos[i].title);
          return;
        }
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerNav: $e'); }
  }

  /// Audit fix (standard high-quality): forward-button handler that
  /// respects [StringSetting.forwardBackButtonAction]. nextPrev maps
  /// to playNextInFolder; seek10/30/60 map to relative seek by that
  /// many seconds.
  Future<void> onForwardButton() async {
    final action = _ref
        .read(extraSettingsProvider)
        .getStr(StringSetting.forwardBackButtonAction);
    switch (action) {
      case 'seek10':
        await seekRelative(10);
        return;
      case 'seek30':
        await seekRelative(30);
        return;
      case 'seek60':
        await seekRelative(60);
        return;
      case 'nextPrev':
      default:
        await playNextInFolder();
    }
  }

  /// Mirror of [onForwardButton] for the backward direction.
  Future<void> onBackwardButton() async {
    final action = _ref
        .read(extraSettingsProvider)
        .getStr(StringSetting.forwardBackButtonAction);
    switch (action) {
      case 'seek10':
        await seekRelative(-10);
        return;
      case 'seek30':
        await seekRelative(-30);
        return;
      case 'seek60':
        await seekRelative(-60);
        return;
      case 'nextPrev':
      default:
        await smartPrevious();
    }
  }

  /// Settings → Player → "Smart Previous Button".
  ///
  /// The behaviour every music app and most video players share: pressing
  /// Previous part-way into something restarts IT, and only takes you to the
  /// actual previous item if you are still near the beginning. Without it,
  /// one press forty minutes into an episode throws away your place and jumps
  /// to the one before — which is exactly when people press it by reflex.
  ///
  /// The switch existed and nothing read it, so Previous always jumped.
  Future<void> smartPrevious() async {
    final enabled = _ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.smartPrevious);
    if (enabled) {
      final svc = _ref.read(videoPlayerServiceProvider);
      final pos = svc.position > Duration.zero ? svc.position : state.position;
      if (pos > _smartPreviousThreshold) {
        await seek(Duration.zero);
        _introSkipped = false;
        _outroSkipped = false;
        return;
      }
    }
    await playPreviousInFolder();
  }

  /// Phase 15: Public — play previous video in current folder
  Future<void> playPreviousInFolder() async {
    final key = _libraryUri ?? _currentUri;
    if (key == null) return;
    try {
      final videos = await _ref.read(allVideosProvider.future);
      final currentIdx = videos.indexWhere((v) => v.uri == key);
      if (currentIdx < 0) return;
      final currentFolder = videos[currentIdx].folderPath;
      for (int i = currentIdx - 1; i >= 0; i--) {
        if (videos[i].folderPath == currentFolder) {
          await openVideo(videos[i].uri, title: videos[i].title);
          return;
        }
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerNav: $e'); }
  }

  /// Phase 15: Loop All mode — next in folder, wrap to first if at end.
  /// Returns true if a video was started, false otherwise.
  Future<bool> _playNextInFolderOrWrap() async {
    final key = _libraryUri ?? _currentUri;
    if (key == null) return false;
    try {
      final videos = await _ref.read(allVideosProvider.future);
      final currentIdx = videos.indexWhere((v) => v.uri == key);
      if (currentIdx < 0) return false;
      final currentFolder = videos[currentIdx].folderPath;
      // Try forward
      for (int i = currentIdx + 1; i < videos.length; i++) {
        if (videos[i].folderPath == currentFolder) {
          await openVideo(videos[i].uri, title: videos[i].title);
          return true;
        }
      }
      // Wrap to first in folder
      for (int i = 0; i < videos.length; i++) {
        if (videos[i].folderPath == currentFolder) {
          await openVideo(videos[i].uri, title: videos[i].title);
          return true;
        }
      }
    } catch (e) { if (kDebugMode) debugPrint('PlayerNav: $e'); }
    return false;
  }

  Future<void> _autoSavePosition({bool force = false}) async {
    // Capture the URI locally to avoid a TOCTOU race: the async awaits
    // below yield to the event loop, and a concurrent openVideo() call
    // could null out _currentUri between the guard and the writes,
    // crashing on `_currentUri!`. Capturing also eliminates the
    // unnecessary force-unwraps.
    final uri = _currentUri;
    if (uri == null) return;
    // Privacy mode: when the user has incognito watching turned on,
    // do not touch resume storage or history at all. Existing entries
    // stay where they are; we simply stop adding to them.
    final prefs = _ref.read(playerSettingsProvider);
    if (prefs.get(PlayerSetting.privacyMode)) return;
    // Vault privacy: a Private Folder video must leave NO trace in shared
    // storage — no resume point, no history record. Otherwise it would
    // appear in the public Local tab's Continue Watching row. This is a
    // hard privacy guarantee, independent of the user's incognito toggle.
    if (_isPrivate) return;
    // A URI that is not a stable identity must not be written down at all.
    // Keying resume and history on a signed, expiring URL means the key never
    // matches twice (so resume silently never works and Continue Watching
    // fills with duplicates), and it puts Video Hub titles on the Local tab —
    // in front of the age gate rather than behind it. See [_isEphemeral].
    if (_isEphemeral) return;
    // Use the player's LIVE position, not state.position. The UI state is
    // intentionally updated only on whole-second boundaries (a rebuild
    // optimisation), so reading it here would round the saved point down by
    // up to a second. svc.position is the exact libmpv position, so resume
    // lands precisely where the user actually stopped — including on the
    // final save fired from dispose() when the player closes.
    final svc = _ref.read(videoPlayerServiceProvider);
    final live = svc.position;
    final pos = live > Duration.zero ? live : state.position;
    // Never persist a zero.
    //
    // There is a window during a reload — the network auto-retry reopens the
    // file after a dropped connection — where libmpv reports position 0 for a
    // moment. If the five-second save landed inside that window it wrote 0
    // over a real resume point, and a crash right afterwards would have sent
    // the user back to the start of a film they were an hour into. Nothing is
    // lost by skipping it: a genuine 0:00 is below the 30-second resume
    // threshold anyway, so saving it would never have produced an offer to
    // resume.
    if (pos <= Duration.zero) return;
    await _ref.read(resumeStorageProvider).savePosition(
          uri: uri,
          position: pos,
          duration: state.duration,
        );
    // Phase 8: also record into history.
    //
    // AUDIT FIX — this ran on the same 5-second cadence as the resume marker,
    // but a history record rewrites a whole JSON list rather than one key, so
    // a two-hour film performed roughly 1,400 full-list rewrites. That is real
    // jank on entry-level phones and needless flash wear. The resume marker
    // (which is what a crash actually needs) keeps its 5-second cadence; the
    // history entry now settles every 30 seconds, and always on the final save
    // when the player closes.
    final nowHist = DateTime.now();
    if (!force &&
        nowHist.difference(_lastHistoryAt) < const Duration(seconds: 30)) {
      return;
    }
    _lastHistoryAt = nowHist;
    try {
      final firstForThisPlay = !_countedThisPlay;
      _countedThisPlay = true;
      await _ref.read(historyProvider.notifier).record(
            videoUri: uri,
            videoTitle: _currentVideoTitle ?? uri.split('/').last,
            position: pos,
            duration: state.duration,
            countAsNewPlay: firstForThisPlay,
          );
    } catch (e) { if (kDebugMode) debugPrint('PlayerNav: $e'); }
  }

  /// Phase 45: returns true when the URI looks like a network stream
  /// (HTTP/HTTPS/RTMP/RTSP/etc.) so we can apply different buffer and
  /// timeout settings vs local files.
  bool _isNetworkUri(String uri) {
    final lower = uri.toLowerCase();
    return lower.startsWith('http:') ||
        lower.startsWith('https:') ||
        lower.startsWith('rtmp:') ||
        lower.startsWith('rtsp:') ||
        lower.startsWith('mms:') ||
        lower.startsWith('udp:') ||
        lower.startsWith('rtp:');
  }

  // ============ TRACK SELECTION ============

}
