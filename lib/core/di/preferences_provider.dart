import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/preferences/preferences_service.dart';

final preferencesServiceProvider = Provider<PreferencesService>((ref) {
  return PreferencesService();
});

class PreferencesNotifier extends StateNotifier<AppPreferences> {
  final PreferencesService _service;

  PreferencesNotifier(this._service) : super(const AppPreferences()) {
    _load();
  }

  Future<void> _load() async {
    state = await _service.load();
  }

  Future<void> _save(AppPreferences next) async {
    state = next;
    await _service.save(next);
  }

  // Setters
  Future<void> setAutoPlayNext(bool v) => _save(state.copyWith(autoPlayNext: v));
  Future<void> setAutoRotate(bool v) => _save(state.copyWith(autoRotate: v));
  Future<void> setKeepScreenOn(bool v) => _save(state.copyWith(keepScreenOn: v));
  Future<void> setDoubleTapSeek(int v) => _save(state.copyWith(doubleTapSeekSeconds: v));
  Future<void> setDefaultSpeed(double v) => _save(state.copyWith(defaultPlaybackSpeed: v));
  Future<void> setShowHidden(bool v) => _save(state.copyWith(showHiddenFiles: v));
  Future<void> setShowThumbnails(bool v) => _save(state.copyWith(showThumbnails: v));
  Future<void> setThemeMode(AppThemeMode v) => _save(state.copyWith(themeMode: v));
  Future<void> setShowExtension(bool v) => _save(state.copyWith(showFileExtension: v));
  Future<void> setDefaultDecoder(DefaultDecoder v) => _save(state.copyWith(defaultDecoder: v));
  Future<void> setDecoderAutoFallback(bool v) => _save(state.copyWith(decoderAutoFallbackToSw: v));
  Future<void> setAudioVolumeBoost(double v) => _save(state.copyWith(audioVolumeBoost: v));
  Future<void> setAudioPauseOnUnplug(bool v) => _save(state.copyWith(audioPauseOnHeadphoneUnplug: v));
  Future<void> setSubtitleSize(SubtitleSize v) => _save(state.copyWith(subtitleSize: v));
  Future<void> setSubtitleEnabled(bool v) => _save(state.copyWith(subtitleEnabled: v));
}

final preferencesProvider =
    StateNotifierProvider<PreferencesNotifier, AppPreferences>((ref) {
  return PreferencesNotifier(ref.read(preferencesServiceProvider));
});
