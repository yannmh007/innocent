import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase 40: dedicated preferences for the 20+ toggles in Settings → Player,
/// extended in Phase 41 to cover every boolean toggle across Settings →
/// List / Audio / Subtitle / General as well. We keep the historic
/// [PlayerSetting] enum name to avoid a noisy rename, but it really means
/// "any app-wide boolean preference".
///
/// We keep these separate from the main [AppPreferences] model so that the
/// existing prefs persistence stays untouched. Each toggle is a single
/// SharedPreferences bool keyed by its enum name, defaulted to a sensible
/// MX-Player-parity value.
enum PlayerSetting {
  // ─── Settings → Player → Interface ───
  doubleTapBack(default_: true),
  quickZoom(default_: true),
  // ─── Settings → Player → Playback ───
  resumeOnlyFirst(default_: false),
  rememberSelections(default_: true),
  backToList(default_: false),
  previewSeek(default_: true),
  previewSeekNetwork(default_: false),
  // Default flipped to false when this switch was finally connected. It had
  // never been read, and the player's actual behaviour all along was PRECISE
  // seeking — the seek bar lands exactly where you release it. Honouring the
  // old `true` would have handed every existing user keyframe-only seeking
  // they never asked for. False preserves what the app has always done; the
  // switch now genuinely turns fast seeking on for anyone who wants it.
  fastSeeking(default_: false),
  // Flipped when connected: the player has always taken exclusive audio
  // focus, so other apps' audio already stops. A `false` default would have
  // meant a podcast keeps playing over your film the first time anyone
  // updated — the opposite of what everyone has been experiencing.
  playAlone(default_: true),
  mediaButtons(default_: true),
  suppressError(default_: false),
  useCustomPip(default_: true),
  // ─── Settings → Player → Background play ───
  bgPipMode(default_: true),
  // Same reasoning, and it matters more here: this is the DEFAULT state of
  // the in-player background-play toggle, and background play runs a
  // foreground service holding a partial wake lock. A `true` default would
  // have started that service on every video for every user the moment the
  // setting was connected — a notification and a wake lock nobody asked for.
  // MX Player's equivalent is off by default too.
  bgPlayAudio(default_: false),
  albumArt(default_: true),
  smoothSwitch(default_: true),
  // ─── Settings → Player → Miscellaneous ───
  // Left false — the app has never limited zoom, so off preserves that, and
  // the switch now genuinely caps it for people who keep overshooting.
  limitResize(default_: false),
  turnOffBacklight(default_: false),
  loadingCircle(default_: true),
  softwareNavButtons(default_: true),
  android40Mode(default_: false),
  smartPrevious(default_: false),
  // Flipped when connected: the play button has always toggled. `false` would
  // have turned it into a play-only button that cannot pause.
  togglePlayback(default_: true),

  // ─── Settings → List (Phase 41) ───
  listLastMediaInFolder(default_: true),
  listScrollToLastMedia(default_: false),
  listSelectThumbnail(default_: false),
  listFloatingButton(default_: true),
  // Note: `listPeriodTaggedNew` (boolean) was superseded by
  // IntSetting.newTaggedPeriod (days count) which exposes the same
  // information with finer control. Removed as dead code.
  listRecognizeNomedia(default_: true),
  listShowHiddenFiles(default_: false),

  // ─── Settings → Audio (Phase 41) ───
  audioAsPlayer(default_: false),
  audioVolumeBoost(default_: true),
  audioSystemVolume(default_: true),
  audioSystemVolumePanel(default_: true),
  audioPauseOnHeadsetDisconnect(default_: true),
  audioFadeOnStart(default_: true),
  audioFadeOnSeek(default_: true),

  // ─── Settings → Subtitle (Phase 41) ───
  subtitleItalicEffect(default_: false),
  subtitleForceLtr(default_: true),

  // ─── Settings → General (Phase 41) ───
  generalPlayMediaLinks(default_: true),
  generalQuitButton(default_: false),
  generalAllowEditing(default_: true),
  generalDeleteSubtitleFiles(default_: true),
  generalCacheThumbnail(default_: true),

  // ─── Settings → Player → Controls (Phase 41) ───
  ctlSwipeBrightness(default_: true),
  ctlSwipeVolume(default_: true),
  ctlSwipeSeek(default_: true),
  ctlDoubleTapSeek(default_: true),
  ctlLongPressSpeed(default_: true),
  ctlPinchZoom(default_: true),
  ctlTapToggle(default_: true),
  ctlLockOnRotation(default_: false),

  // ─── Settings → Player → Navigation (Phase 41) ───
  navShowSeekBar(default_: true),
  navSeekBarPreview(default_: true),
  navShowPrevNext(default_: true),

  // ─── Settings → Player → Screen (Phase 41) ───
  screenAutoRotation(default_: true),
  // Flipped when connected: the player has always hidden the system bars
  // during playback. `false` would have put the status bar and navigation bar
  // back over everyone's video.
  screenFullScreen(default_: true),
  screenKeepOn(default_: true),
  screenAutoBrightness(default_: false),
  screenDimNotch(default_: false),
  screenUseCutout(default_: true),

  // ─── Settings → Player → Style (Phase 41) ───
  styleShowTitle(default_: true),
  styleShowClock(default_: true),
  styleShowBattery(default_: true),
  styleShowSourceUrl(default_: false),
  styleCompactMode(default_: false),

  // ─── Settings → Decoder (Phase 41) ───
  // Both flipped to true when they were finally connected. They had never
  // been read, and the player's real behaviour all along was hardware-first
  // for every source — decTryHw below has always been on. Honouring the old
  // `false` would have handed every existing user SOFTWARE decoding for every
  // video: several times the CPU, a hot phone, and a battery gone by lunch.
  // True preserves what the app has always done; the switches now genuinely
  // turn hardware decoding off per source type for anyone who needs that
  // (a device whose HW decoder mishandles a particular codec, usually).
  decHwLocal(default_: true),
  decHwNetwork(default_: true),
  decTryHw(default_: true),
  decTryHwPlus(default_: true),
  decHwAudioOnSwVideo(default_: true),
  decCorrectAspect(default_: true),
  decHwAudioTrackSelectable(default_: true),
  decSwLocal(default_: false),
  decSwNetwork(default_: false),
  decSwAudio(default_: false),
  decSwAudioLocal(default_: false),
  decSwAudioNetwork(default_: false),
  // Flipped the other way: the engine baseline has always set vd-lavc-fast,
  // so the behaviour every user has had is speedups ON. Connecting the switch
  // with its old `false` default would have quietly REMOVED them and made
  // software decoding slower and hotter on exactly the weak devices that need
  // them most.
  //
  // What ON means changed in 1.64.25 and the default did not. It now grants
  // PERMISSION for the loop-filter skip rather than applying it: the picture
  // starts at full quality on every file and the shortcut is spent only on a
  // decoder measured dropping frames. A weak device still gets it, within
  // seconds; every other device stops paying for it.
  decSpeedupTricks(default_: true),

  // ─── Downloads (watch offline) ───
  //
  // DEFAULT OFF, AND THAT IS THE DELIBERATE CHOICE FOR THIS AUDIENCE. Every
  // download feature ships this switch and most ship it ON, because most were
  // built where home wifi is assumed. Most viewers of this app are on Myanmar
  // mobile data and have no wifi to wait for — defaulting this on would mean a
  // Download button that appears to do nothing, for the majority, for ever.
  // It is here for the minority who do have wifi and would rather wait for it.
  downloadWifiOnly(default_: false),
  decDeinterlace(default_: false),
  decCustomCodec(default_: false),

  // ─── Settings → Subtitle sub-screens (Phase 41) ───
  subLayoutShowBackground(default_: false),
  subTextBold(default_: false),

  // ─── Settings → Development (Phase 41) ───
  devShowBufferInfo(default_: false),
  devShowDecoderInfo(default_: false),
  devShowFps(default_: false),
  devEnableDebugLog(default_: false),
  devDisableHwAccel(default_: false),

  // ─── Me → Custom Pop-up Play (Phase 41) ───
  /// false = Previous/Next (default), true = Fast Forward/Rewind
  customPopupFastForward(default_: false),

  // ─── Phase 45 (audit refined, build 63) — 6 new MX Player parity ───
  /// `audio_effects_enabled` (frag_audio.xml). Master on/off toggle for
  /// the EQ + Bass Boost + Virtualizer + Reverb pipeline. When OFF, all
  /// effects are bypassed regardless of individual effect state. MX
  /// Player default is FALSE (effects disabled until user enables).
  audioEffectsEnabled(default_: false),

  /// `prefer_audio_passthrough_mode` (frag_audio.xml). When ON, libmpv
  /// passes Dolby/DTS bitstream untouched to the AV receiver instead of
  /// decoding to PCM. Required when using an external surround setup.
  /// MX Player default is TRUE.
  preferAudioPassthrough(default_: true),

  /// `subtitle_show_hw` (frag_subtitle.xml). When ON, allows subtitles
  /// to render even when the hardware decoder is active. Some devices
  /// have buggy HW decoders that drop subtitle frames, so the default
  /// is FALSE (use SW decoder for subtitles).
  subtitleShowHw(default_: false),

  /// `subtitle_hw_accel` (frag_subtitle.xml + frag_general.xml).
  /// Hardware acceleration for subtitle rendering (separate from
  /// [subtitleShowHw]). Default TRUE.
  subtitleHwAccel(default_: true),

  /// `honour_headset_hook_multi_press` (frag_player.xml). When ON,
  /// double/triple presses on the headphone button trigger
  /// next/previous. Default TRUE.
  honourHeadsetMultiPress(default_: true),

  /// `tv_mode` (frag_general.xml). Switches the UI to TV-friendly mode
  /// (larger fonts, D-pad navigation focus rings). Default FALSE.
  tvMode(default_: false),

  /// Original feature (not in MX Player): when ON, the app stops
  /// writing to history, resume positions, recently-added, and any
  /// other on-device watch trail for the duration the toggle is
  /// active. Existing history is not deleted; nothing leaves the
  /// device either way. Intended as a per-session "incognito watch"
  /// — turn on, watch, turn off — without having to clear the
  /// library afterwards.
  privacyMode(default_: false),

  /// Audit fix (A4): pin the player controls so they never auto-hide.
  /// Useful for tutorial recordings, accessibility, or any context
  /// where the user wants the timestamp / seek bar / play button
  /// permanently visible. The 4-second auto-hide timer becomes a
  /// no-op while this is on. Default OFF (auto-hide is the standard).
  alwaysShowControls(default_: false),

  /// Audit fix (Phase 4 #15): loudness normalization via libmpv's
  /// `dynaudnorm` audio filter. When on, quiet scenes/songs come up
  /// to a comfortable level and loud explosions don't blow out the
  /// listener — same idea as Spotify's "Loudness Normalization" or
  /// YouTube's per-video loudness algorithm. Best-effort: requires
  /// the libmpv build to include the filter (the call silently
  /// no-ops if unavailable).
  loudnessNormalization(default_: false),

  /// Audit fix (standard high-quality): allow biometric unlock as a
  /// shortcut to PIN entry on the Private Folder. The PIN is still
  /// the underlying secret — biometric only bypasses keystroke
  /// re-entry. Defaults to OFF; user opts in explicitly so they
  /// understand the trade-off (anyone with their enrolled
  /// fingerprint or face can open the folder).
  privateFolderBiometric(default_: false),

  /// Phase 45 (audit refined, build 63): subtitle text appearance
  /// toggles wired from the visible-only UI in subtitle_text_screen.
  /// `subText.improveStroke` improves the anti-aliasing of subtitle
  /// stroke outlines at a small CPU cost. Default TRUE on modern
  /// devices.
  subTextImproveStroke(default_: true);

  // ignore: non_constant_identifier_names
  final bool default_;
  const PlayerSetting({required this.default_});

  String get key => 'pref_player_$name';
}

/// Snapshot of every player toggle. Acts as a [Map<PlayerSetting,bool>] but
/// strongly typed via the helper accessor.
@immutable
class PlayerSettings {
  final Map<PlayerSetting, bool> _values;
  const PlayerSettings(this._values);

  bool get(PlayerSetting s) => _values[s] ?? s.default_;

  PlayerSettings setValue(PlayerSetting s, bool value) {
    final next = Map<PlayerSetting, bool>.from(_values);
    next[s] = value;
    return PlayerSettings(next);
  }

  /// Defaults snapshot.
  factory PlayerSettings.defaults() => PlayerSettings({
        for (final s in PlayerSetting.values) s: s.default_,
      });
}

class PlayerSettingsService {
  Future<PlayerSettings> load() async {
    final sp = await SharedPreferences.getInstance();
    final map = <PlayerSetting, bool>{};
    for (final s in PlayerSetting.values) {
      map[s] = sp.getBool(s.key) ?? s.default_;
    }
    return PlayerSettings(map);
  }

  Future<void> setValue(PlayerSetting s, bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(s.key, value);
  }

  /// Phase 41: wipe every persisted boolean and return to defaults.
  /// Used by Settings → Development → "Reset all settings".
  Future<void> resetAll() async {
    final sp = await SharedPreferences.getInstance();
    for (final s in PlayerSetting.values) {
      await sp.remove(s.key);
    }
  }
}

class PlayerSettingsNotifier extends StateNotifier<PlayerSettings> {
  final PlayerSettingsService _service;
  PlayerSettingsNotifier(this._service) : super(PlayerSettings.defaults()) {
    _load();
  }

  Future<void> _load() async {
    state = await _service.load();
  }

  Future<void> setValue(PlayerSetting s, bool value) async {
    state = state.setValue(s, value);
    await _service.setValue(s, value);
  }

  /// Phase 41: reset every toggle to its declared default, both in memory
  /// and on disk.
  Future<void> resetAll() async {
    await _service.resetAll();
    state = PlayerSettings.defaults();
  }
}

final playerSettingsServiceProvider = Provider<PlayerSettingsService>((ref) {
  return PlayerSettingsService();
});

final playerSettingsProvider =
    StateNotifierProvider<PlayerSettingsNotifier, PlayerSettings>((ref) {
  return PlayerSettingsNotifier(ref.watch(playerSettingsServiceProvider));
});
