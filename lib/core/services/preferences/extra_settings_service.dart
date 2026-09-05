import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase 45 (audit): String / int / double preferences for MX Player parity.
///
/// The boolean-only [PlayerSetting] enum is structurally simple but can't
/// represent settings like:
///   - resume_last: ask / resume / startover (string enum)
///   - default_playback_speed: 25..400 (int percent)
///   - sticky_video: stop / background / pip (string enum)
///   - audio_language / subtitle_language: ISO codes (string)
///   - subtitle_charset: utf-8 / euc-kr / auto (string)
///   - audio_delay / bluetooth_audio_delay: ±ms (int)
///   - default_subtitle_sync: ±ms (int)
///   - new_tagged_period: days as int
///   - http_user_agent: free-form string
///   - subtitle_folder / typeface_dir: directory paths
///
/// MX Player V3 stores each as a separate SharedPreferences key (verified by
/// inspecting the decompiled APK's `frag_*.xml` preference XMLs). We do the
/// same so users can pick up where they left off if they ever export/import
/// settings.

/// All string-valued preferences for MX Player parity.
///
/// Each enum value carries its SharedPreferences key as its name (lowercased
/// via [key]) and a sensible default that matches MX Player's
/// `frag_*.xml` `android:defaultValue`.
enum StringSetting {
  /// `resume_last`: Resume policy for the last playback position.
  /// Values: 'ask' (default), 'resume', 'startover'.
  resumeLast(default_: 'ask'),

  /// `sticky_video`: What to do when the user presses Home / app goes
  /// background. Values: 'stop', 'background', 'pip' (default).
  stickyVideo(default_: 'pip'),

  /// `audio_language`: ISO 639-1 / 639-3 code for preferred audio track when
  /// the file contains multiple tracks. Empty string = no preference (use
  /// whatever ffmpeg picks).
  audioLanguage(default_: ''),

  /// `subtitle_language`: ISO 639-1 / 639-3 code for preferred subtitle
  /// track. Empty string = no preference.
  subtitleLanguage(default_: ''),

  /// `subtitle_charset`: Encoding used for non-UTF-8 subtitle files.
  /// Empty string = auto-detect, otherwise an encoding name like 'UTF-8',
  /// 'EUC-KR', 'Windows-1252' etc.
  subtitleCharset(default_: ''),

  /// `subtitle_folder`: extra directory where the player looks for
  /// .srt/.ass/.vtt files. Empty string = only same folder as video.
  subtitleFolder(default_: ''),

  /// `typeface_dir`: directory containing user-supplied .ttf/.otf files
  /// for subtitle rendering. Empty string = use system fonts.
  typefaceDir(default_: ''),

  /// `http_user_agent.2`: custom User-Agent string for network streams.
  /// Empty string = default (libmpv's built-in).
  httpUserAgent(default_: ''),

  // Note: `playbackTheme` was declared as a visual-theme selector but
  // never referenced anywhere; the app is dark-only by design. Removed
  // as dead code.

  /// `aspect_ratio_override`: explicit aspect ratio for libmpv's
  /// `video-aspect-override` property. MX Player V3 has 12 ratios
  /// (Default/1:1/4:3/16:9/16:10/21:9/64:27/2.21:1/2.35:1/2.39:1/
  /// 5:4/Custom). Stored as the enum name from
  /// [AspectRatioOverride] — 'defaultAuto' means use the file's
  /// intrinsic SAR/DAR.
  aspectRatioOverride(default_: 'defaultAuto'),

  /// Phase 45 (audit refined, build 63):
  /// `audio_device` (frag_audio.xml). Audio output routing. Values:
  /// 'auto' (default — follow system routing), 'speaker' (force
  /// speaker even when headphones plugged in), 'headphone',
  /// 'bluetooth'. libmpv consults `audio-device` on every play.
  audioDevice(default_: 'auto'),

  /// `user_locale` (frag_general.xml). App language ISO code.
  /// Empty = follow system locale. Examples: 'en', 'my' (Burmese),
  /// 'th' (Thai), 'zh' (Chinese), 'ja', 'ko', 'hi'.
  userLocale(default_: ''),

  /// `omxdecoder.2` (frag_decoder.xml). HW decoder selector — 4-mode:
  /// 'auto' (default), 'never', 'localOnly', 'everywhere'. Separate
  /// from per-stream decTryHw / decTryHwPlus toggles.
  omxDecoderMode(default_: 'auto'),

  /// Phase 45 (audit refined, build 64): pipe-separated list of
  /// storage roots to scan. Default = 'Internal storage' only. Stored
  /// as `Internal storage|SD Card|USB Storage` etc.
  scanFolders(default_: 'Internal storage'),

  /// Phase 45 (audit refined, build 64): pipe-separated list of file
  /// extensions to include in library scan. Each entry includes the
  /// leading dot (e.g. `.mp4|.mkv|.avi`). Empty = use the built-in
  /// default set defined in the UI.
  scanExtensions(default_: '.mp4|.mkv|.avi|.mov|.webm'),

  /// Phase 45 (audit refined, build 64): pipe-separated list of video
  /// codecs allowed for HW+ decoder.
  hwPlusVideoCodecs(default_: 'H.264/AVC|H.265/HEVC'),

  /// Phase 45 (audit refined, build 64): pipe-separated list of audio
  /// codecs allowed for HW+ decoder.
  hwPlusAudioCodecs(default_: 'AAC|MP3'),

  /// Which shortcut icons the player's quick row shows, as a pipe-separated
  /// list of `ShortcutItem` names.
  ///
  /// Empty string means "never customised" — the player falls back to its
  /// built-in four. The single character `-` means "customised to show none",
  /// which has to be distinguishable from the empty case or the master switch
  /// could never be turned off: saving an empty list would read back as
  /// "never customised" and the four defaults would reappear.
  playerShortcuts(default_: ''),

  /// Audit fix (standard high-quality): subtitle background colour
  /// as a libmpv-compatible ARGB hex string, e.g. '#80000000'
  /// (50 % black). Empty string = no background (transparent).
  /// Default '#80000000' which matches the bg-tinted style most
  /// users expect when toggling "Show background" on.
  subtitleBackgroundColor(default_: '#80000000'),

  /// Audit fix (standard high-quality): scope of the "Lock controls"
  /// button on the player. One of: 'all' (default — hide controls
  /// AND ignore gestures), 'rotation' (only freeze screen rotation,
  /// leave controls + gestures usable), 'touch' (hide controls AND
  /// disable all gestures including tap-to-show, leaving only the
  /// dedicated unlock area). Stored as the string identifier so
  /// future modes can be added without enum migration.
  lockMode(default_: 'all'),

  /// Audit fix (standard high-quality): what the on-screen
  /// forward/backward buttons in the bottom controls do. One of:
  /// 'nextPrev' (default — skip to next/prev file in the queue),
  /// 'seek10' (seek ±10 s), 'seek30' (seek ±30 s),
  /// 'seek60' (seek ±60 s).
  forwardBackButtonAction(default_: 'nextPrev'),

  /// Audit fix (standard high-quality): initial player orientation
  /// preference. 'system' = follow `screenAutoRotation` toggle and
  /// the device's rotation lock. 'landscape', 'portrait',
  /// 'landscapeReverse' = pin to that orientation regardless of
  /// device rotation lock. Applied at openVideo time.
  defaultPlayerOrientation(default_: 'system'),

  /// Audit fix (standard high-quality): top toolbar (back / title /
  /// decoder / sleep-timer pill) position. 'top' (default) keeps it
  /// at the top of the screen; 'bottom' moves it just above the
  /// playback controls. Useful for one-hand reach with the device
  /// in the right hand (phone-grip ergonomics).
  toolbarPosition(default_: 'top');

  final String default_;
  const StringSetting({required this.default_});

  String get key => 'string_setting_$name';
}

/// All integer-valued preferences for MX Player parity.
enum IntSetting {
  /// `default_playback_speed`: 25..400, expressed as percent. 100 = 1.0x.
  defaultPlaybackSpeed(default_: 100, min: 25, max: 400),

  /// `audio_delay`: global audio delay in milliseconds (-2000..+2000). When
  /// non-zero, libmpv's `audio-delay` property is set on every play.
  audioDelay(default_: 0, min: -2000, max: 2000),

  /// `bluetooth_audio_delay`: separate delay applied only when audio is
  /// routed through Bluetooth. Many BT codecs introduce 150-300ms latency.
  bluetoothAudioDelay(default_: 0, min: -2000, max: 2000),

  /// `subtitle_default_sync`: global subtitle delay in milliseconds.
  /// libmpv `sub-delay` property.
  subtitleDefaultSync(default_: 0, min: -10000, max: 10000),

  /// `new_tagged_period`: number of days a video stays "NEW" in the
  /// folder grid after being added. Default 7 (matches MX Player).
  newTaggedPeriod(default_: 7, min: 0, max: 90),

  /// `video_zoom_delay`: ms before a long-press-and-drag pinch zoom
  /// activates. 0 = immediate.
  videoZoomDelay(default_: 0, min: 0, max: 2000),

  /// Phase 45 (audit refined, build 63):
  /// `calibrate_hw_play_position`: HW decoder subtitle sync offset in
  /// SECONDS. MX Player `frag_subtitle.xml` default 0. When non-zero,
  /// adjusts the position reported to subtitle renderer to compensate
  /// for HW decoder presentation latency.
  calibrateHwPlayPosition(default_: 0, min: -10, max: 10),

  /// Phase 45 (audit refined, build 63): subtitle text scale as
  /// percent of base size (10..200, default 100 = 1.0x). Stored as
  /// percent INT to avoid float precision issues; the player divides
  /// by 100 when reading. Maps to libmpv's `sub-scale` property.
  subtitleScale(default_: 100, min: 10, max: 200),

  /// Subtitle shadow intensity (0..3): 0=None, 1=Subtle, 2=Default,
  /// 3=Strong. Affects `sub-shadow-color` alpha + `sub-shadow-offset`.
  subtitleShadow(default_: 2, min: 0, max: 3),

  /// Subtitle background opacity 0..2: 0=Transparent, 1=Translucent,
  /// 2=Opaque. Affects `sub-back-color` alpha.
  subtitleBackgroundOpacity(default_: 0, min: 0, max: 2),

  /// Subtitle bottom margin as percent of screen height (0..20%).
  /// libmpv `sub-margin-y` (in pixels) is computed from this.
  subtitleBottomMargin(default_: 4, min: 0, max: 20),

  /// Phase 45 (audit refined, build 63):
  /// Subtitle text color preset (0..5). 0=White, 1=Yellow, 2=Cyan,
  /// 3=Green, 4=Red, 5=Black. MX Player V3 ships a fixed colour
  /// picker — we mirror the same six options.
  subtitleTextColor(default_: 0, min: 0, max: 5),

  /// Subtitle border (outline) color (0..5). Same palette as
  /// [subtitleTextColor]. libmpv `sub-border-color`.
  subtitleBorderColor(default_: 5, min: 0, max: 5),

  /// Subtitle background colour when [subtitleBackgroundOpacity] > 0.
  subtitleBackgroundColor(default_: 5, min: 0, max: 5),

  /// Subtitle horizontal alignment (0=Left, 1=Center, 2=Right).
  /// libmpv `sub-align-x`.
  subtitleAlignment(default_: 1, min: 0, max: 2),

  /// Phase 45 (audit refined, build 64):
  /// Subtitle border style (0..4). MX Player V3 ships 5 options:
  /// 0=None, 1=Outline (default), 2=Drop shadow, 3=Raised, 4=Depressed.
  /// Maps to combinations of libmpv `sub-border-size` +
  /// `sub-shadow-offset`. Note: libmpv can't fully replicate
  /// Raised/Depressed 3D effects — we approximate using shadow
  /// direction.
  subtitleBorderStyle(default_: 1, min: 0, max: 4),

  /// Subtitle font size preset (0..4): 0=Tiny, 1=Small, 2=Medium
  /// (default), 3=Large, 4=Huge. Combined with [subtitleScale] for
  /// final rendered size — this preset sets the base scale, scale
  /// then multiplies. Stored as percent of base (50/75/100/125/150).
  subtitleFontSize(default_: 2, min: 0, max: 4),

  /// Audit fix (A2): tunable auto-hide delay for the player controls,
  /// in seconds. Industry players range from 2s (Netflix) to 8s
  /// (VLC); 4s is a common default. Below 2s would frustrate users
  /// trying to read the timestamp; above 15s defeats the purpose.
  controlsHideDelay(default_: 4, min: 2, max: 15),

  /// Audit fix (standard high-quality): default initial brightness
  /// when the player first opens a file (before any per-URI
  /// override). 0..100 percent. Default -1 means "follow system
  /// brightness" (the existing behaviour). The player respects
  /// per-URI brightness from `user_video_brightness_v1` first;
  /// this is only the fallback baseline.
  defaultBrightnessPct(default_: -1, min: -1, max: 100),

  /// Audit fix (standard high-quality): cap on libmpv video decoder
  /// threads (`vd-lavc-threads`). Default 0 = libmpv auto-picks
  /// based on CPU. Useful for users on thermally constrained
  /// devices who want to manually limit thread count to prevent
  /// throttling-induced stutters.
  videoDecoderThreads(default_: 0, min: 0, max: 16),

  /// Audit fix (standard high-quality): subtitle vertical position
  /// as a percent down from the top. libmpv's `sub-pos` is in this
  /// range: 0 = top, 100 = bottom. Default 100 (standard bottom).
  subtitleVerticalPos(default_: 100, min: 0, max: 100),

  /// Audit fix (standard high-quality): subtitle horizontal margin
  /// (left/right padding) in pixels. libmpv `sub-margin-x`. Default
  /// 25 px which matches libmpv's documented default.
  subtitleMarginX(default_: 25, min: 0, max: 200),

  /// Audit fix (standard high-quality): subtitle bottom margin in
  /// pixels. libmpv `sub-margin-y`. Default 25 px. Independent of
  /// vertical position which is percentage-based.
  subtitleMarginY(default_: 25, min: 0, max: 200),

  /// Audit fix (standard high-quality): subtitle horizontal alignment.
  /// Maps to libmpv `sub-align-x`. 0 = left, 1 = center (default),
  /// 2 = right. The enum is stored as int for forward compat.
  subtitleHorizontalAlign(default_: 1, min: 0, max: 2);

  final int default_;
  final int min;
  final int max;
  const IntSetting({
    required this.default_,
    required this.min,
    required this.max,
  });

  String get key => 'int_setting_$name';
}

/// Snapshot of all string + int settings. Acts like a strongly typed map.
@immutable
class ExtraSettings {
  final Map<StringSetting, String> _strings;
  final Map<IntSetting, int> _ints;
  const ExtraSettings(this._strings, this._ints);

  String getStr(StringSetting s) => _strings[s] ?? s.default_;
  int getInt(IntSetting s) => _ints[s] ?? s.default_;

  ExtraSettings setStr(StringSetting s, String value) {
    final next = Map<StringSetting, String>.from(_strings);
    next[s] = value;
    return ExtraSettings(next, _ints);
  }

  ExtraSettings setInt(IntSetting s, int value) {
    final next = Map<IntSetting, int>.from(_ints);
    next[s] = value.clamp(s.min, s.max);
    return ExtraSettings(_strings, next);
  }

  /// Defaults snapshot. Used at initial app launch before SharedPreferences
  /// is loaded.
  factory ExtraSettings.defaults() => ExtraSettings(
        {for (final s in StringSetting.values) s: s.default_},
        {for (final s in IntSetting.values) s: s.default_},
      );
}

class ExtraSettingsService {
  Future<ExtraSettings> load() async {
    final sp = await SharedPreferences.getInstance();
    final strings = <StringSetting, String>{};
    for (final s in StringSetting.values) {
      strings[s] = sp.getString(s.key) ?? s.default_;
    }
    final ints = <IntSetting, int>{};
    for (final s in IntSetting.values) {
      ints[s] = sp.getInt(s.key) ?? s.default_;
    }
    return ExtraSettings(strings, ints);
  }

  Future<void> setStr(StringSetting s, String value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(s.key, value);
  }

  Future<void> setInt(IntSetting s, int value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(s.key, value.clamp(s.min, s.max));
  }

  /// Reset every value to its declared default.
  Future<void> resetAll() async {
    final sp = await SharedPreferences.getInstance();
    for (final s in StringSetting.values) {
      await sp.remove(s.key);
    }
    for (final s in IntSetting.values) {
      await sp.remove(s.key);
    }
  }
}

class ExtraSettingsNotifier extends StateNotifier<ExtraSettings> {
  final ExtraSettingsService _service;
  ExtraSettingsNotifier(this._service) : super(ExtraSettings.defaults()) {
    _load();
  }

  Future<void> _load() async {
    state = await _service.load();
  }

  Future<void> setStr(StringSetting s, String value) async {
    state = state.setStr(s, value);
    await _service.setStr(s, value);
  }

  Future<void> setInt(IntSetting s, int value) async {
    state = state.setInt(s, value);
    await _service.setInt(s, value);
  }

  Future<void> resetAll() async {
    await _service.resetAll();
    state = ExtraSettings.defaults();
  }
}

final extraSettingsServiceProvider = Provider<ExtraSettingsService>((ref) {
  return ExtraSettingsService();
});

final extraSettingsProvider =
    StateNotifierProvider<ExtraSettingsNotifier, ExtraSettings>((ref) {
  return ExtraSettingsNotifier(ref.watch(extraSettingsServiceProvider));
});
