import 'package:shared_preferences/shared_preferences.dart';

/// App theme mode
enum AppThemeMode {
  adaptive('Adaptive'),
  light('Light'),
  dark('Dark');

  final String label;
  const AppThemeMode(this.label);
}

/// Default decoder preference
enum DefaultDecoder {
  hw('Hardware (HW)'),
  hwPlus('Hardware+ (HW+)'),
  sw('Software (SW)');

  final String label;
  const DefaultDecoder(this.label);
}

/// Subtitle text size
enum SubtitleSize {
  small('Small', 14),
  medium('Medium', 18),
  large('Large', 22),
  xLarge('Extra Large', 28);

  final String label;
  final double size;
  const SubtitleSize(this.label, this.size);
}

/// User-configurable app preferences
class AppPreferences {
  // Player
  final bool autoPlayNext;
  final bool autoRotate;
  final bool keepScreenOn;
  final int doubleTapSeekSeconds;
  final double defaultPlaybackSpeed;

  // List
  final bool showHiddenFiles;
  final bool showThumbnails;

  // General
  final AppThemeMode themeMode;
  final bool showFileExtension;

  // Phase 9: Decoder
  final DefaultDecoder defaultDecoder;
  final bool decoderAutoFallbackToSw;

  // Phase 9: Audio
  final double audioVolumeBoost; // 1.0 - 3.0
  final bool audioPauseOnHeadphoneUnplug;

  // Phase 9: Subtitle
  final SubtitleSize subtitleSize;
  final bool subtitleEnabled;

  const AppPreferences({
    this.autoPlayNext = true,
    this.autoRotate = true,
    this.keepScreenOn = true,
    this.doubleTapSeekSeconds = 10,
    this.defaultPlaybackSpeed = 1.0,
    this.showHiddenFiles = false,
    this.showThumbnails = true,
    this.themeMode = AppThemeMode.dark,
    this.showFileExtension = false,
    this.defaultDecoder = DefaultDecoder.hw,
    this.decoderAutoFallbackToSw = true,
    this.audioVolumeBoost = 1.0,
    this.audioPauseOnHeadphoneUnplug = true,
    this.subtitleSize = SubtitleSize.medium,
    this.subtitleEnabled = true,
  });

  AppPreferences copyWith({
    bool? autoPlayNext,
    bool? autoRotate,
    bool? keepScreenOn,
    int? doubleTapSeekSeconds,
    double? defaultPlaybackSpeed,
    bool? showHiddenFiles,
    bool? showThumbnails,
    AppThemeMode? themeMode,
    bool? showFileExtension,
    DefaultDecoder? defaultDecoder,
    bool? decoderAutoFallbackToSw,
    double? audioVolumeBoost,
    bool? audioPauseOnHeadphoneUnplug,
    SubtitleSize? subtitleSize,
    bool? subtitleEnabled,
  }) {
    return AppPreferences(
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      autoRotate: autoRotate ?? this.autoRotate,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      doubleTapSeekSeconds:
          doubleTapSeekSeconds ?? this.doubleTapSeekSeconds,
      defaultPlaybackSpeed:
          defaultPlaybackSpeed ?? this.defaultPlaybackSpeed,
      showHiddenFiles: showHiddenFiles ?? this.showHiddenFiles,
      showThumbnails: showThumbnails ?? this.showThumbnails,
      themeMode: themeMode ?? this.themeMode,
      showFileExtension: showFileExtension ?? this.showFileExtension,
      defaultDecoder: defaultDecoder ?? this.defaultDecoder,
      decoderAutoFallbackToSw:
          decoderAutoFallbackToSw ?? this.decoderAutoFallbackToSw,
      audioVolumeBoost: audioVolumeBoost ?? this.audioVolumeBoost,
      audioPauseOnHeadphoneUnplug:
          audioPauseOnHeadphoneUnplug ?? this.audioPauseOnHeadphoneUnplug,
      subtitleSize: subtitleSize ?? this.subtitleSize,
      subtitleEnabled: subtitleEnabled ?? this.subtitleEnabled,
    );
  }
}

/// Loads/saves AppPreferences via SharedPreferences
class PreferencesService {
  static const String _kAutoPlayNext = 'pref_auto_play_next';
  static const String _kAutoRotate = 'pref_auto_rotate';
  static const String _kKeepScreenOn = 'pref_keep_screen_on';
  static const String _kDoubleTapSeek = 'pref_double_tap_seek';
  static const String _kDefaultSpeed = 'pref_default_speed';
  static const String _kShowHidden = 'pref_show_hidden';
  static const String _kShowThumbnails = 'pref_show_thumbnails';
  static const String _kThemeMode = 'pref_theme_mode';
  static const String _kShowExtension = 'pref_show_extension';
  static const String _kDecoder = 'pref_decoder';
  static const String _kDecoderFallback = 'pref_decoder_fallback';
  static const String _kVolumeBoost = 'pref_volume_boost';
  static const String _kPauseOnUnplug = 'pref_pause_on_unplug';
  static const String _kSubSize = 'pref_sub_size';
  static const String _kSubEnabled = 'pref_sub_enabled';

  Future<AppPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppPreferences(
      autoPlayNext: prefs.getBool(_kAutoPlayNext) ?? true,
      autoRotate: prefs.getBool(_kAutoRotate) ?? true,
      keepScreenOn: prefs.getBool(_kKeepScreenOn) ?? true,
      doubleTapSeekSeconds: prefs.getInt(_kDoubleTapSeek) ?? 10,
      defaultPlaybackSpeed: prefs.getDouble(_kDefaultSpeed) ?? 1.0,
      showHiddenFiles: prefs.getBool(_kShowHidden) ?? false,
      showThumbnails: prefs.getBool(_kShowThumbnails) ?? true,
      themeMode: _parseTheme(prefs.getString(_kThemeMode)),
      showFileExtension: prefs.getBool(_kShowExtension) ?? false,
      defaultDecoder: _parseDecoder(prefs.getString(_kDecoder)),
      decoderAutoFallbackToSw: prefs.getBool(_kDecoderFallback) ?? true,
      audioVolumeBoost: prefs.getDouble(_kVolumeBoost) ?? 1.0,
      audioPauseOnHeadphoneUnplug:
          prefs.getBool(_kPauseOnUnplug) ?? true,
      subtitleSize: _parseSubSize(prefs.getString(_kSubSize)),
      subtitleEnabled: prefs.getBool(_kSubEnabled) ?? true,
    );
  }

  DefaultDecoder _parseDecoder(String? name) {
    if (name == null) return DefaultDecoder.hw;
    return DefaultDecoder.values.firstWhere(
      (m) => m.name == name,
      orElse: () => DefaultDecoder.hw,
    );
  }

  SubtitleSize _parseSubSize(String? name) {
    if (name == null) return SubtitleSize.medium;
    return SubtitleSize.values.firstWhere(
      (m) => m.name == name,
      orElse: () => SubtitleSize.medium,
    );
  }

  Future<void> save(AppPreferences prefs) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kAutoPlayNext, prefs.autoPlayNext);
    await sp.setBool(_kAutoRotate, prefs.autoRotate);
    await sp.setBool(_kKeepScreenOn, prefs.keepScreenOn);
    await sp.setInt(_kDoubleTapSeek, prefs.doubleTapSeekSeconds);
    await sp.setDouble(_kDefaultSpeed, prefs.defaultPlaybackSpeed);
    await sp.setBool(_kShowHidden, prefs.showHiddenFiles);
    await sp.setBool(_kShowThumbnails, prefs.showThumbnails);
    await sp.setString(_kThemeMode, prefs.themeMode.name);
    await sp.setBool(_kShowExtension, prefs.showFileExtension);
    await sp.setString(_kDecoder, prefs.defaultDecoder.name);
    await sp.setBool(_kDecoderFallback, prefs.decoderAutoFallbackToSw);
    await sp.setDouble(_kVolumeBoost, prefs.audioVolumeBoost);
    await sp.setBool(_kPauseOnUnplug, prefs.audioPauseOnHeadphoneUnplug);
    await sp.setString(_kSubSize, prefs.subtitleSize.name);
    await sp.setBool(_kSubEnabled, prefs.subtitleEnabled);
  }

  AppThemeMode _parseTheme(String? name) {
    if (name == null) return AppThemeMode.dark;
    return AppThemeMode.values.firstWhere(
      (m) => m.name == name,
      orElse: () => AppThemeMode.dark,
    );
  }
}
