import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service wrapping Android's [Equalizer] AudioEffect via MethodChannel.
/// Only works on Android.
class EqualizerService {
  static const _channel = MethodChannel('mx_clone/equalizer');

  bool _initialized = false;
  bool get isInitialized => _initialized;

  // ── Persisted EQ state ─────────────────────────────────────────────
  // The native AudioFx instances forget their settings when the audio
  // session ends (app restart), and the UI panels are rebuilt from
  // scratch each time they open. We cache the full state here and mirror
  // it to SharedPreferences so both the video sheet and the music screen
  // reopen showing exactly what's actually applied — and so the user's
  // tuning survives an app restart, like MX Player.
  List<int> _bandsCache = const [];
  int _bassCache = 0;
  int _virtCache = 0;
  int _reverbCache = 0;
  int _presetCache = -1; // -1 = Custom (no native preset)
  String _effectCache = 'Original';

  List<int> get bandLevels => _bandsCache;
  int get bassStrength => _bassCache;
  int get virtualizerStrength => _virtCache;
  int get reverbPreset => _reverbCache;
  int? get activePresetIndex => _presetCache < 0 ? null : _presetCache;
  String get activeEffect => _effectCache;

  bool _stateLoaded = false;

  /// Read the persisted EQ state into the in-memory cache. Reads from disk
  /// only on the first call (cold start); after that the in-memory cache —
  /// kept current by the setters — is authoritative, so reopening a panel
  /// (or opening the other one) always reflects the latest values without a
  /// stale-read race against the debounced write.
  Future<void> loadState() async {
    if (_stateLoaded) return;
    _stateLoaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final b = sp.getString('eq_bands') ?? '';
      _bandsCache = b.isEmpty
          ? const []
          : b.split(',').map((e) => int.tryParse(e) ?? 0).toList();
      _bassCache = sp.getInt('eq_bass') ?? 0;
      _virtCache = sp.getInt('eq_virt') ?? 0;
      _reverbCache = sp.getInt('eq_reverb') ?? 0;
      _presetCache = sp.getInt('eq_preset') ?? -1;
      _effectCache = sp.getString('eq_effect') ?? 'Original';
    } catch (e) { if (kDebugMode) debugPrint('equalizer_service.best-effort: $e'); }
  }

  Future<void> _persist() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('eq_bands', _bandsCache.join(','));
      await sp.setInt('eq_bass', _bassCache);
      await sp.setInt('eq_virt', _virtCache);
      await sp.setInt('eq_reverb', _reverbCache);
      await sp.setInt('eq_preset', _presetCache);
      await sp.setString('eq_effect', _effectCache);
    } catch (e) { if (kDebugMode) debugPrint('equalizer_service.best-effort: $e'); }
  }

  // Slider / dial drags fire many events per second; debounce the disk
  // write so we persist ~400 ms after the last change instead of on every
  // tick. (The engine itself still updates in real time.)
  Timer? _persistTimer;
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), _persist);
  }

  void _cacheBand(int band, int millibel) {
    if (band < 0) return;
    final list = List<int>.from(_bandsCache);
    while (list.length <= band) {
      list.add(0);
    }
    list[band] = millibel;
    _bandsCache = list;
    _schedulePersist();
  }

  /// Persist which preset chip / effect card is highlighted (UI-only
  /// state with no engine call of its own).
  void cacheSelection({required int? presetIndex, required String effect}) {
    _presetCache = presetIndex ?? -1;
    _effectCache = effect;
    _persist();
  }

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The audio session id the effects are currently bound to. 0 means the
  /// global mix (the old, unreliable default). A real id is generated once
  /// per app run and shared with libmpv so the effect chain sits on the
  /// exact output the video plays through.
  int _sessionId = 0;
  int get sessionId => _sessionId;

  /// Ask the platform for a fresh audio session id. Cached so the SAME id is
  /// handed to both libmpv (as its AudioTrack session) and the Equalizer —
  /// they must match for the effect to apply. Returns 0 on non-Android/web
  /// or on failure (falls back to the global mix).
  Future<int> ensureSessionId() async {
    if (!_isAndroid) return 0;
    if (_sessionId != 0) return _sessionId;
    try {
      final id =
          await _channel.invokeMethod<int>('generateAudioSessionId');
      _sessionId = id ?? 0;
    } catch (_) {
      _sessionId = 0;
    }
    return _sessionId;
  }

  /// Initialize the equalizer, binding it to [sessionId]. When 0, uses the
  /// cached session id from [ensureSessionId] if available (so callers that
  /// don't pass one still get the correct, non-global binding).
  Future<bool> initialize({int sessionId = 0}) async {
    if (!_isAndroid) return false;
    // Make sure we have a REAL audio-session id. Session 0 (the "global mix")
    // is ignored by modern Android when the app plays through its own
    // AudioTrack — which libmpv/media_kit does — so an EQ attached to 0 is
    // silently a no-op. If no id was passed and none is cached yet, generate
    // one now; this is the same id libmpv binds its AudioTrack to, so the
    // effect lands on the actual playback. This ordering fix is what makes
    // Voice Effects / EQ audible during video (initialize used to run before
    // the session id existed and bind to 0).
    if (sessionId == 0 && _sessionId == 0) {
      await ensureSessionId();
    }
    final effectiveSession = sessionId != 0 ? sessionId : _sessionId;
    try {
      final result = await _channel.invokeMethod<bool>(
        'initialize',
        {'sessionId': effectiveSession},
      );
      _initialized = result ?? false;
      return _initialized;
    } catch (_) {
      return false;
    }
  }

  /// Ensure the engine reflects the persisted EQ state. Called at playback
  /// start so a user's saved tuning takes effect on EVERY video (like MX
  /// Player) — not only while the EQ sheet is open. On a cold start the
  /// native AudioFx instances begin flat, so without this the saved curve
  /// would be silently ignored until the user reopened the panel.
  ///
  /// No-op unless [masterEnabled] is true (the audio-effects master switch),
  /// so a user who turned effects off never has them silently re-enabled.
  /// Safe to call repeatedly; it re-initialises only if needed.
  Future<void> reapplyFromCache({required bool masterEnabled}) async {
    if (!_isAndroid) return;
    await loadState();
    if (!masterEnabled) {
      // Master off → make sure the effect is disabled, then stop.
      if (_initialized) {
        try {
          await setEnabled(false);
        } catch (e) {
          if (kDebugMode) debugPrint('equalizer_service.reapply: $e');
        }
      }
      return;
    }
    // Attach to the global output mix if we aren't already.
    if (!_initialized) {
      final ok = await initialize();
      if (!ok) return;
    }
    try {
      await setEnabled(true);
      // Push every cached band level.
      for (var i = 0; i < _bandsCache.length; i++) {
        await setBandLevel(i, _bandsCache[i]);
      }
      // Push the side-effects.
      await setBassBoostEnabled(_bassCache > 0);
      await setBassBoostStrength(_bassCache);
      await setVirtualizerEnabled(_virtCache > 0);
      await setVirtualizerStrength(_virtCache);
      await setReverbPreset(_reverbCache);
    } catch (e) {
      if (kDebugMode) debugPrint('equalizer_service.reapply: $e');
    }
  }
  Future<void> release() async {
    _persistTimer?.cancel();
    await _persist(); // flush any pending debounced write
    if (!_isAndroid || !_initialized) return;
    try {
      await _channel.invokeMethod('release');
    } catch (e) { if (kDebugMode) debugPrint('equalizer_service.best-effort: $e'); }
    _initialized = false;
  }

  /// Enable or disable the equalizer effect.
  Future<bool> setEnabled(bool enabled) async {
    if (!_isAndroid || !_initialized) return false;
    try {
      return (await _channel.invokeMethod<bool>(
            'setEnabled',
            {'enabled': enabled},
          )) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Set a band's gain level (in millibels, e.g. 600 = +6 dB).
  Future<bool> setBandLevel(int band, int millibel) async {
    _cacheBand(band, millibel);
    if (!_isAndroid || !_initialized) return false;
    try {
      return (await _channel.invokeMethod<bool>(
            'setBandLevel',
            {'band': band, 'level': millibel},
          )) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Returns [min, max] band-level range in millibels.
  Future<List<int>> getBandLevelRange() async {
    if (!_isAndroid || !_initialized) return const [-1500, 1500];
    try {
      final result = await _channel.invokeMethod<List>('getBandLevelRange');
      if (result == null) return const [-1500, 1500];
      return result.cast<int>();
    } catch (_) {
      return const [-1500, 1500];
    }
  }

  Future<int> getNumberOfBands() async {
    if (!_isAndroid || !_initialized) return 5;
    try {
      return (await _channel.invokeMethod<int>('getNumberOfBands')) ?? 5;
    } catch (_) {
      return 5;
    }
  }

  /// Get the center frequency of a band in milliHertz.
  Future<int> getCenterFreq(int band) async {
    if (!_isAndroid || !_initialized) return 0;
    try {
      return (await _channel.invokeMethod<int>(
            'getCenterFreq',
            {'band': band},
          )) ??
          0;
    } catch (_) {
      return 0;
    }
  }

  /// Apply a preset by index. Returns resulting band levels.
  Future<List<int>?> usePreset(int presetIndex) async {
    if (!_isAndroid || !_initialized) return null;
    try {
      final result = await _channel.invokeMethod<List>(
        'usePreset',
        {'preset': presetIndex},
      );
      final levels = result?.cast<int>();
      if (levels != null) {
        _bandsCache = List<int>.from(levels);
        _presetCache = presetIndex;
        _persist();
      }
      return levels;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> getPresets() async {
    if (!_isAndroid || !_initialized) return const [];
    try {
      final result = await _channel.invokeMethod<List>('getPresets');
      return result?.cast<String>() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  // ============================================================
  // Phase 45 (audit) — Bass Boost / Virtualizer / Reverb
  //
  // MX Player V3 exposes these Android AudioFx effects in addition to
  // the parametric equalizer:
  //   - BassBoost: 0..1000 strength (millis of bass intensity)
  //   - Virtualizer: 0..1000 strength (stereo-widening)
  //   - PresetReverb: 0..6 (None/SmallRoom/MediumRoom/LargeRoom/
  //                  MediumHall/LargeHall/Plate)
  //
  // The native side (Kotlin) is expected to construct the matching
  // AudioEffect instances and route calls to them. When the native
  // implementation is missing or fails, these methods degrade quietly
  // to no-ops so the UI keeps working.
  // ============================================================

  /// Enable/disable the BassBoost AudioFx. Returns true on success.
  Future<bool> setBassBoostEnabled(bool enabled) async {
    if (!_isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>(
            'setBassBoostEnabled',
            {'enabled': enabled},
          )) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Set BassBoost strength (0..1000 millis). 0 = neutral, 1000 = max.
  Future<bool> setBassBoostStrength(int strength) async {
    final clamped = strength.clamp(0, 1000);
    _bassCache = clamped;
    _schedulePersist();
    if (!_isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>(
            'setBassBoostStrength',
            {'strength': clamped},
          )) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Enable/disable the Virtualizer AudioFx (stereo widening).
  Future<bool> setVirtualizerEnabled(bool enabled) async {
    if (!_isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>(
            'setVirtualizerEnabled',
            {'enabled': enabled},
          )) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Set Virtualizer strength (0..1000 millis).
  Future<bool> setVirtualizerStrength(int strength) async {
    final clamped = strength.clamp(0, 1000);
    _virtCache = clamped;
    _schedulePersist();
    if (!_isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>(
            'setVirtualizerStrength',
            {'strength': clamped},
          )) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Apply a PresetReverb. Indexes match Android's PresetReverb
  /// constants: 0 = None, 1 = SmallRoom, 2 = MediumRoom,
  /// 3 = LargeRoom, 4 = MediumHall, 5 = LargeHall, 6 = Plate.
  Future<bool> setReverbPreset(int presetIndex) async {
    final clamped = presetIndex.clamp(0, 6);
    _reverbCache = clamped;
    _persist();
    if (!_isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>(
            'setReverbPreset',
            {'preset': clamped},
          )) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Get the human-readable list of reverb preset names. Indexes match
  /// the constants used by [setReverbPreset].
  List<String> getReverbPresets() => const [
        'None',
        'Small Room',
        'Medium Room',
        'Large Room',
        'Medium Hall',
        'Large Hall',
        'Plate',
      ];
}

/// A single process-wide EqualizerService instance. Shared between the
/// startup audio-session hook (so libmpv binds to the right session) and the
/// Riverpod `equalizerServiceProvider` used by the UI — they MUST be the same
/// object so the session id and cached effect state stay consistent.
final EqualizerService sharedEqualizerService = EqualizerService();
