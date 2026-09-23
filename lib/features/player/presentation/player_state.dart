part of 'player_provider.dart';

enum IndicatorType { brightness, volume, seek }
enum SidePanel { none, more, subtitle }

class GestureIndicator {
  final IndicatorType type;
  final double? value;
  final Duration? delta;
  final Duration? target;

  const GestureIndicator.brightness(double v)
      : type = IndicatorType.brightness,
        value = v,
        delta = null,
        target = null;

  const GestureIndicator.volume(double v)
      : type = IndicatorType.volume,
        value = v,
        delta = null,
        target = null;

  const GestureIndicator.seek({required this.delta, required this.target})
      : type = IndicatorType.seek,
        value = null;
}

/// Sleep timer state
class SleepTimerState {
  final Duration? remaining;
  final SleepTimerMode mode;
  // UX-2 (audit): when true, a fired custom timer finishes the current
  // media before stopping instead of pausing immediately.
  final bool playToEnd;
  // Wall-clock moment the custom timer should fire. The ticker compares the
  // real clock against this each tick and recomputes `remaining`, so if the
  // OS throttles or pauses Dart timers while the screen is off, the timer
  // still fires as soon as any tick runs past the deadline instead of drifting
  // by the amount of missed ticks. Null for off / end-of-video modes.
  final DateTime? deadline;
  const SleepTimerState({
    this.remaining,
    this.mode = SleepTimerMode.off,
    this.playToEnd = false,
    this.deadline,
  });
  bool get isActive => mode != SleepTimerMode.off;
}

/// Phase 15: Tri-state loop control (MX Player parity).
enum LoopMode {
  off,      // play once, then next-in-folder (if autoPlayNext)
  one,      // repeat current video forever
  all,      // play folder; when last video ends, restart from first
}

/// Player state — Phase 3
class PlayerState {
  // Playback
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool isBuffering;
  final String? errorMessage;

  /// A short overlay message shown during a long, non-network load — chiefly
  /// copying an Android/data video out over ADB before playback. null hides it.
  final String? loadingMessage;

  /// True from the moment a file is handed to libmpv until the first frame
  /// of it is actually decoded.
  ///
  /// THE FLAG THAT STOPS THE PLAYER LYING. Opening a network stream and
  /// running out of buffer halfway through a film both surface as "the
  /// demuxer is waiting", and the old code had no way to tell them apart, so
  /// it called both a slow connection. Start-up is not a slow connection: a
  /// signed URL has to be resolved, a TLS session negotiated and the moov
  /// atom found and parsed before a single frame exists, and on a 13 MB/s
  /// link that is still seconds of work during which the network is doing
  /// exactly what it should. Blaming the user's connection for it sent people
  /// to go and check their Wi-Fi over a delay Wi-Fi never caused.
  ///
  /// Only once a frame has been shown does a refill mean what the sentence
  /// says — the stream cannot keep up — and only then is that sentence used.
  final bool isOpening;

  /// Audit fix (C4): tier-1 soft hint shown after 3 s of continuous
  /// network buffering (before the 10 s hard "stalled" error fires).
  /// Lets the UI show a polite "Slow connection..." indicator that
  /// auto-disappears when buffering recovers — distinguishes a
  /// brief blip from a genuine stall.
  final bool slowNetworkHintVisible;

  /// Phase 41: set to true when the current video reaches its end AND the
  /// "Back to list" setting (Settings → Player → Playback) is on. The
  /// screen watches this flag and pops back to the file list.
  final bool playbackCompleted;

  // UI
  final bool controlsVisible;
  final bool isLocked;
  /// Audit fix (standard high-quality): scope of the active lock,
  /// matching [StringSetting.lockMode]: 'all' (default — controls
  /// hidden, gestures blocked), 'rotation' (controls visible,
  /// gestures usable, orientation pinned via SystemChrome),
  /// 'touch' (controls hidden + gestures blocked, no tap-to-show).
  /// Meaningful only while [isLocked] is true.
  final String lockScope;

  /// Kids Lock (MX parity, v0.49): child-proof screen lock. Stricter
  /// than [isLocked] — every touch is absorbed, the system back button
  /// is blocked, and the only way out is press-and-holding the on-screen
  /// lock chip for ~2 s. Independent of [lockScope].
  final bool isKidsLocked;
  final AspectRatioMode aspectRatioMode;
  final double playbackSpeed;
  final SidePanel openPanel;
  final bool decoderDialogOpen;
  final bool sleepTimerDialogOpen;
  final bool resumeDialogOpen;
  /// Phase 45 (audit): when true, the resume dialog is in 'ask' mode and
  /// shows Resume / Start over buttons WITHOUT auto-seek and WITHOUT
  /// auto-dismiss. When false (legacy behaviour) the dialog is a brief
  /// confirmation toast that auto-dismisses after 5s, and the video has
  /// already been seeked to the saved position.
  final bool resumeIsAskMode;

  // System
  final double brightness;
  final double volume;

  // Shortcut states
  final bool isLoopEnabled;
  final LoopMode loopMode;
  final bool isMuted;
  final bool isShuffleEnabled;
  final bool isMirrorMode;
  final bool isVerticalFlip;
  final bool isNightMode;
  final bool isBackgroundPlay;
  /// Phase 45: true while the Activity is in real Android Picture-in-
  /// Picture mode. Drives lifecycle decisions (don't pause when
  /// backgrounded), control visibility (PiP shows system controls),
  /// and a few other UI knobs.
  final bool inSystemPip;
  final DecoderType decoder;
  final Set<ShortcutItem> visibleShortcuts;

  // Phase 3: Tracks
  final List<AudioTrackInfo> audioTracks;
  final List<SubtitleTrackInfo> subtitleTracks;
  /// Phase 45: video tracks (typically just one, but multi-stream MKVs
  /// can have several). Used by the PiP integration to compute aspect
  /// ratio from the active video's width/height.
  final List<VideoTrackInfo> videoTracks;
  final AudioTrackInfo? currentAudioTrack;
  final SubtitleTrackInfo? currentSubtitleTrack;

  // Phase 3: Sleep timer
  final SleepTimerState sleepTimer;

  // Phase 4: A-B Repeat
  final Duration? abPointA;
  final Duration? abPointB;

  // Phase 6: Long-press speed slider
  final bool speedSliderVisible;

  // Phase 6: Shortcut row expanded grid
  final bool shortcutsExpanded;

  // Phase 14: Skip markers
  final int? introEndMs;
  final int? outroStartMs;

  // Phase 7: Pinch-to-zoom (1.0 = 100%, range 0.25 - 10.0)
  final double videoScale;
  /// Auto-hide zoom indicator. null = no indicator visible
  final double? zoomIndicatorValue;

  // Phase 3: Resume
  final Duration? pendingResumePosition;

  // Indicator
  final GestureIndicator? activeIndicator;

  const PlayerState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.isPlaying = false,
    this.isBuffering = false,
    this.errorMessage,
    this.loadingMessage,
    this.isOpening = false,
    this.slowNetworkHintVisible = false,
    this.playbackCompleted = false,
    this.controlsVisible = true,
    this.isLocked = false,
    this.lockScope = 'all',
    this.isKidsLocked = false,
    this.aspectRatioMode = AspectRatioMode.fit,
    this.playbackSpeed = 1.0,
    this.openPanel = SidePanel.none,
    this.decoderDialogOpen = false,
    this.sleepTimerDialogOpen = false,
    this.resumeDialogOpen = false,
    this.resumeIsAskMode = false,
    this.brightness = 0.5,
    this.volume = 0.5,
    this.isLoopEnabled = false,
    this.loopMode = LoopMode.off,
    this.isMuted = false,
    this.isShuffleEnabled = false,
    this.isMirrorMode = false,
    this.isVerticalFlip = false,
    this.isNightMode = false,
    this.isBackgroundPlay = false,
    this.inSystemPip = false,
    this.decoder = DecoderType.defaultMode,
    // PDF page 4 (verified from screenshot): the collapsed top row shows
    // Screenshot, Background Play (headphones), Screen Rotation, Loop. The
    // expand chevron reveals everything else.
    this.visibleShortcuts = const {
      ShortcutItem.screenshot,
      ShortcutItem.backgroundPlay,
      ShortcutItem.screenRotation,
      ShortcutItem.loop,
      // The remaining items are still in `allItems` and become visible when expanded.
    },
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.videoTracks = const [],
    this.currentAudioTrack,
    this.currentSubtitleTrack,
    this.sleepTimer = const SleepTimerState(),
    this.abPointA,
    this.abPointB,
    this.speedSliderVisible = false,
    this.shortcutsExpanded = false,
    this.videoScale = 1.0,
    this.zoomIndicatorValue,
    this.introEndMs,
    this.outroStartMs,
    this.pendingResumePosition,
    this.activeIndicator,
  });

  PlayerState copyWith({
    Duration? position,
    Duration? duration,
    bool? isPlaying,
    bool? isBuffering,
    Object? errorMessage = _sentinel,
    Object? loadingMessage = _sentinel,
    bool? isOpening,
    bool? slowNetworkHintVisible,
    bool? playbackCompleted,
    bool? controlsVisible,
    bool? isLocked,
    String? lockScope,
    bool? isKidsLocked,
    AspectRatioMode? aspectRatioMode,
    double? playbackSpeed,
    SidePanel? openPanel,
    bool? decoderDialogOpen,
    bool? sleepTimerDialogOpen,
    bool? resumeDialogOpen,
    bool? resumeIsAskMode,
    double? brightness,
    double? volume,
    bool? isLoopEnabled,
    LoopMode? loopMode,
    bool? isMuted,
    bool? isShuffleEnabled,
    bool? isMirrorMode,
    bool? isVerticalFlip,
    bool? isNightMode,
    bool? isBackgroundPlay,
    bool? inSystemPip,
    DecoderType? decoder,
    Set<ShortcutItem>? visibleShortcuts,
    List<AudioTrackInfo>? audioTracks,
    List<SubtitleTrackInfo>? subtitleTracks,
    List<VideoTrackInfo>? videoTracks,
    Object? currentAudioTrack = _sentinel,
    Object? currentSubtitleTrack = _sentinel,
    SleepTimerState? sleepTimer,
    Object? abPointA = _sentinel,
    Object? abPointB = _sentinel,
    bool? speedSliderVisible,
    bool? shortcutsExpanded,
    double? videoScale,
    Object? zoomIndicatorValue = _sentinel,
    Object? introEndMs = _sentinel,
    Object? outroStartMs = _sentinel,
    Object? pendingResumePosition = _sentinel,
    Object? activeIndicator = _sentinel,
  }) {
    return PlayerState(
      position: position ?? this.position,
      duration: duration ?? this.duration,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      errorMessage: errorMessage == _sentinel
          ? this.errorMessage
          : errorMessage as String?,
      loadingMessage: loadingMessage == _sentinel
          ? this.loadingMessage
          : loadingMessage as String?,
      isOpening: isOpening ?? this.isOpening,
      slowNetworkHintVisible:
          slowNetworkHintVisible ?? this.slowNetworkHintVisible,
      playbackCompleted: playbackCompleted ?? this.playbackCompleted,
      controlsVisible: controlsVisible ?? this.controlsVisible,
      isLocked: isLocked ?? this.isLocked,
      lockScope: lockScope ?? this.lockScope,
      isKidsLocked: isKidsLocked ?? this.isKidsLocked,
      aspectRatioMode: aspectRatioMode ?? this.aspectRatioMode,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      openPanel: openPanel ?? this.openPanel,
      decoderDialogOpen: decoderDialogOpen ?? this.decoderDialogOpen,
      sleepTimerDialogOpen: sleepTimerDialogOpen ?? this.sleepTimerDialogOpen,
      resumeDialogOpen: resumeDialogOpen ?? this.resumeDialogOpen,
      resumeIsAskMode: resumeIsAskMode ?? this.resumeIsAskMode,
      brightness: brightness ?? this.brightness,
      volume: volume ?? this.volume,
      isLoopEnabled: isLoopEnabled ?? this.isLoopEnabled,
      loopMode: loopMode ?? this.loopMode,
      isMuted: isMuted ?? this.isMuted,
      isShuffleEnabled: isShuffleEnabled ?? this.isShuffleEnabled,
      isMirrorMode: isMirrorMode ?? this.isMirrorMode,
      isVerticalFlip: isVerticalFlip ?? this.isVerticalFlip,
      isNightMode: isNightMode ?? this.isNightMode,
      isBackgroundPlay: isBackgroundPlay ?? this.isBackgroundPlay,
      inSystemPip: inSystemPip ?? this.inSystemPip,
      decoder: decoder ?? this.decoder,
      visibleShortcuts: visibleShortcuts ?? this.visibleShortcuts,
      audioTracks: audioTracks ?? this.audioTracks,
      subtitleTracks: subtitleTracks ?? this.subtitleTracks,
      videoTracks: videoTracks ?? this.videoTracks,
      currentAudioTrack: currentAudioTrack == _sentinel
          ? this.currentAudioTrack
          : currentAudioTrack as AudioTrackInfo?,
      currentSubtitleTrack: currentSubtitleTrack == _sentinel
          ? this.currentSubtitleTrack
          : currentSubtitleTrack as SubtitleTrackInfo?,
      sleepTimer: sleepTimer ?? this.sleepTimer,
      abPointA: abPointA == _sentinel ? this.abPointA : abPointA as Duration?,
      abPointB: abPointB == _sentinel ? this.abPointB : abPointB as Duration?,
      speedSliderVisible: speedSliderVisible ?? this.speedSliderVisible,
      shortcutsExpanded: shortcutsExpanded ?? this.shortcutsExpanded,
      videoScale: videoScale ?? this.videoScale,
      zoomIndicatorValue: zoomIndicatorValue == _sentinel
          ? this.zoomIndicatorValue
          : zoomIndicatorValue as double?,
      introEndMs: introEndMs == _sentinel ? this.introEndMs : introEndMs as int?,
      outroStartMs: outroStartMs == _sentinel ? this.outroStartMs : outroStartMs as int?,
      pendingResumePosition: pendingResumePosition == _sentinel
          ? this.pendingResumePosition
          : pendingResumePosition as Duration?,
      activeIndicator: activeIndicator == _sentinel
          ? this.activeIndicator
          : activeIndicator as GestureIndicator?,
    );
  }
}

const Object _sentinel = Object();
