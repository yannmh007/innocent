import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kLocaleKey = 'app_locale';

/// Holds the user's chosen UI language. `null` means "follow the system
/// locale" (the default), so a fresh install shows Burmese automatically on
/// a Burmese phone. The choice is persisted so it survives restarts.
class LocaleNotifier extends StateNotifier<Locale?> {
  LocaleNotifier() : super(null) {
    _load();
  }

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final code = sp.getString(_kLocaleKey);
      if (code != null && code.isNotEmpty) {
        state = Locale(code);
      }
    } catch (e) { if (kDebugMode) debugPrint('locale_provider.best-effort: $e'); }
  }

  /// Pass `null` to go back to following the system locale.
  Future<void> setLocale(Locale? locale) async {
    state = locale;
    try {
      final sp = await SharedPreferences.getInstance();
      if (locale == null) {
        await sp.remove(_kLocaleKey);
      } else {
        await sp.setString(_kLocaleKey, locale.languageCode);
      }
    } catch (e) { if (kDebugMode) debugPrint('locale_provider.best-effort: $e'); }
  }
}

final localeProvider =
    StateNotifierProvider<LocaleNotifier, Locale?>((ref) => LocaleNotifier());

/// The languages the app can actually display, as (code, English name, native
/// name). `null` means "follow the system".
///
/// Single source of truth for every language picker. There used to be two
/// lists: this one, and a longer one in Settings → General that offered
/// Chinese, Japanese, Korean and Hindi. The app has no strings for those, so
/// picking one could only ever show English — the list was longer than the
/// app's abilities. Anything added here must have a matching map in
/// AppStrings and an entry in AppStrings.supportedLocales.
const List<(String?, String, String)> kAppLanguages = <(String?, String, String)>[
  (null, 'System default', ''),
  ('en', 'English', 'English'),
  ('my', 'Myanmar (Burmese)', 'မြန်မာ'),
  ('th', 'Thai', 'ไทย'),
];
