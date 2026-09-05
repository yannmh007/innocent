import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase 41: persist the App Language selection so it survives an app
/// restart. Stored as a single string ('system', 'en', 'my', …) under
/// [_key]. Defaults to 'system' (follow device locale).
class AppLanguageService {
  static const String _key = 'pref_app_language';

  Future<String> load() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_key) ?? 'system';
  }

  Future<void> save(String code) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, code);
  }
}

class AppLanguageNotifier extends StateNotifier<String> {
  final AppLanguageService _service;
  AppLanguageNotifier(this._service) : super('system') {
    _load();
  }

  Future<void> _load() async {
    state = await _service.load();
  }

  Future<void> setLanguage(String code) async {
    state = code;
    await _service.save(code);
  }
}

final appLanguageServiceProvider = Provider<AppLanguageService>((ref) {
  return AppLanguageService();
});

final appLanguageProvider =
    StateNotifierProvider<AppLanguageNotifier, String>((ref) {
  return AppLanguageNotifier(ref.watch(appLanguageServiceProvider));
});
