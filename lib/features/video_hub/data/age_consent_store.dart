import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
///
/// ─── WHY THIS IS KEYSTORE-BACKED (audit_video_hub.md M6) ─────────────────
///
/// These three keys lived in plain SharedPreferences. Android's Auto Backup
/// uploads that file to the user's Google Drive, and the device-transfer flow
/// copies it to a new handset — and `backup_rules.xml` excludes exactly one
/// SharedPreferences file, `FlutterSecureStorage`, plus the vault's two
/// folders. It says so itself: *"Everything NOT listed here still backs up
/// normally."*
///
/// So `vh_age_consent_version = 1` in a Drive backup was a durable record
/// that this Google account's owner opened the adult section of this app and
/// accepted its terms. In an app that ships a decoy PIN, an intruder selfie
/// and a vault whose whole design assumes the phone may be looked at by
/// someone else, that is out of keeping with everything around it — the
/// vault's own PIN material is excluded from backup for exactly this reason.
///
/// This is the FOURTH instance of one bug class here. `session_store.dart`
/// (v1.55.16) and `device_identity.dart` (v1.63.5) both moved for the same
/// reason and name Auto Backup in their comments; `adb_key.pk8` was excluded
/// in the backup rules as audit_adb.md A4. The pattern below is
/// SessionStore's, deliberately: read secure first, migrate a legacy
/// plaintext value exactly once, then delete it.
///
/// Keystore reads can fail transiently — notably just after the user changes
/// their lock screen — so a failure falls back to the legacy store rather
/// than silently re-asking a question the user has already answered.
class AgeConsentStore {
  const AgeConsentStore();

  /// Bump this whenever the wording changes in a way that alters what is being
  /// agreed to. Not for typos.
  static const int currentVersion = 1;

  static const String _kVersion = 'vh_age_consent_version';
  static const String _kAtMillis = 'vh_age_consent_at';
  static const String _kDeclined = 'vh_age_declined';

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Read a secured value, migrating a legacy plaintext copy exactly once.
  static Future<String?> _read(String key) async {
    try {
      final v = await _secure.read(key: key);
      if (v != null) return v;
    } catch (e) {
      if (kDebugMode) debugPrint('AgeConsentStore.read: $e');
    }
    final String? legacy;
    try {
      final sp = await SharedPreferences.getInstance();
      // `get`, never `getString`. Every build before this one wrote these
      // as an int (version, timestamp) or a bool (declined), and
      // SharedPreferences.getString casts — it would THROW on those keys and
      // the migration would silently do nothing, re-asking the 18+ question
      // of every user who had already answered it.
      legacy = sp.get(key)?.toString();
      if (legacy == null) return null;
      try {
        await _secure.write(key: key, value: legacy);
        await sp.remove(key); // drop the plaintext copy after migration
      } catch (e) {
        if (kDebugMode) debugPrint('AgeConsentStore.migrate: $e');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('AgeConsentStore.legacy: $e');
      return null;
    }
    return legacy;
  }

  static Future<void> _write(String key, String value) async {
    try {
      await _secure.write(key: key, value: value);
    } catch (e) {
      if (kDebugMode) debugPrint('AgeConsentStore.write: $e');
    }
    // Belt and braces against a half-migrated install: a plaintext copy from
    // an older build must not outlive the new one.
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.containsKey(key)) await sp.remove(key);
    } catch (e) {
      if (kDebugMode) debugPrint('AgeConsentStore.write-cleanup: $e');
    }
  }

  static Future<void> _delete(String key) async {
    try {
      await _secure.delete(key: key);
    } catch (e) {
      if (kDebugMode) debugPrint('AgeConsentStore.delete: $e');
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(key);
    } catch (e) {
      if (kDebugMode) debugPrint('AgeConsentStore.delete-legacy: $e');
    }
  }

  /// True when this device has accepted the CURRENT terms.
  Future<bool> isAccepted() async {
    final raw = await _read(_kVersion);
    return (int.tryParse(raw ?? '') ?? 0) >= currentVersion;
  }

  Future<DateTime?> acceptedAt() async {
    final millis = int.tryParse(await _read(_kAtMillis) ?? '');
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// Someone said they are under 18.
  ///
  /// Remembered so the app does not ask again on the next launch and let them
  /// simply answer differently. Not a security control - it is a locked door
  /// on a ground-floor window - but re-asking immediately would make the
  /// question obviously meaningless, and a question that is obviously
  /// meaningless teaches people to lie to every other one.
  Future<bool> hasDeclined() async => await _read(_kDeclined) == 'true';

  Future<void> accept() async {
    await _write(_kVersion, '$currentVersion');
    await _write(_kAtMillis, '${DateTime.now().millisecondsSinceEpoch}');
    await _delete(_kDeclined);
  }

  Future<void> decline() async {
    await _write(_kDeclined, 'true');
    await _delete(_kVersion);
    await _delete(_kAtMillis);
  }

  /// Development escape hatch, and the reason a declined answer is not
  /// permanent: somebody has to be able to test both paths.
  Future<void> reset() async {
    await _delete(_kVersion);
    await _delete(_kAtMillis);
    await _delete(_kDeclined);
  }
}
