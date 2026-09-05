import 'package:shared_preferences/shared_preferences.dart';

/// The record that someone confirmed their age and accepted the terms.
///
/// VERSIONED, and that is the point. A consent recorded against terms that
/// have since changed is not consent to the current terms - it is a stale
/// checkbox. Bumping [currentVersion] re-prompts everyone, which is the only
/// honest way to change what people agreed to.
///
/// The timestamp exists because "when" is the first thing anyone asks when a
/// consent is questioned, and it cannot be reconstructed afterwards.
class AgeConsentStore {
  const AgeConsentStore();

  /// Bump this whenever the wording changes in a way that alters what is being
  /// agreed to. Not for typos.
  static const int currentVersion = 1;

  static const String _kVersion = 'vh_age_consent_version';
  static const String _kAtMillis = 'vh_age_consent_at';
  static const String _kDeclined = 'vh_age_declined';

  /// True when this device has accepted the CURRENT terms.
  Future<bool> isAccepted() async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getInt(_kVersion) ?? 0) >= currentVersion;
  }

  Future<DateTime?> acceptedAt() async {
    final sp = await SharedPreferences.getInstance();
    final millis = sp.getInt(_kAtMillis);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// Someone said they are under 18.
  ///
  /// Remembered so the app does not ask again on the next launch and let them
  /// simply answer differently. Not a security control - it is a locked door
  /// on a ground-floor window - but re-asking immediately would make the
  /// question obviously meaningless, and a question that is obviously
  /// meaningless teaches people to lie to every other one.
  Future<bool> hasDeclined() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kDeclined) ?? false;
  }

  Future<void> accept() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kVersion, currentVersion);
    await sp.setInt(_kAtMillis, DateTime.now().millisecondsSinceEpoch);
    await sp.remove(_kDeclined);
  }

  Future<void> decline() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kDeclined, true);
    await sp.remove(_kVersion);
    await sp.remove(_kAtMillis);
  }

  /// Development escape hatch, and the reason a declined answer is not
  /// permanent: somebody has to be able to test both paths.
  Future<void> reset() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kVersion);
    await sp.remove(_kAtMillis);
    await sp.remove(_kDeclined);
  }
}
