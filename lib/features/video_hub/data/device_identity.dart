import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stable identifier for this INSTALL.
///
/// Sent with every playback request so the server can bind grants to a device
/// and cap how many stream at once. That cap is what actually decides whether
/// one subscription serves a group chat, and it can only be counted server-
/// side: a client-side count knows about the streams that are not the problem.
///
/// WHAT THIS IS NOT:
///
/// Not a hardware identifier. No IMEI, no MAC, no Android ID, no advertising
/// id. Those are privacy-hostile, increasingly restricted by the platform, and
/// they do not even solve the problem - a hardware id is as forgeable as a
/// random one to anyone who has already patched the app.
///
/// It is a random value generated once and kept. Reinstalling produces a new
/// one, which is correct: a reinstall IS a new install, and treating it as the
/// same device would mean a lost phone keeps its slot forever.
///
/// ─── WHY THIS MOVED OUT OF SharedPreferences (v1.63.5) ───────────────────
///
/// It used to live in plain SharedPreferences. The stated worry was "Clear
/// data wipes it", and that turned out to be the wrong worry: clearing data is
/// indistinguishable from a reinstall, and a reinstall is SUPPOSED to mint a
/// new id.
///
/// The real defect was the opposite one. **Android's Auto Backup uploads
/// SharedPreferences to Google Drive, and the device-transfer flow copies it
/// to a new handset.** So the one value whose entire job is to say "this is a
/// different phone" was being carried onto the different phone automatically.
/// Two handsets would present one device id, the concurrency cap would count
/// them as one, and the honest user setting up a replacement phone would
/// silently inherit the old slot instead of claiming a new one - which is
/// precisely the case the server's device table exists to handle.
///
/// `flutter_secure_storage` writes to a SharedPreferences file named
/// `FlutterSecureStorage`, and both `backup_rules.xml` and
/// `data_extraction_rules.xml` already exclude that file from cloud backup AND
/// from device transfer - they were written for the vault. Moving the id there
/// closes both channels with no manifest change and no new dependency.
///
/// HONEST LIMITS, both unchanged by this move:
///
///  * a determined attacker can clear the value and get a fresh id, so this
///    does not stop one person using many slots. What it does is make CASUAL
///    sharing - one login passed around a group - visible and rate-limitable,
///    which is the sharing that actually happens;
///  * the encryption is not the point here. The id is not a secret; nobody is
///    harmed by reading it. The backup EXCLUSION is the point, and the
///    encryption comes along with the file that has it.
class DeviceIdentity {
  const DeviceIdentity._();

  static const String _key = 'vh_device_id';

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String? _cached;

  /// Serialises concurrent first calls.
  ///
  /// Without it, the several requests a cold start fires at once each miss the
  /// cache, each generate a value and each write it - and the id the server
  /// sees changes between headers within one session. One future, awaited by
  /// everyone, means exactly one value is ever generated.
  static Future<String>? _inFlight;

  /// Reads, or creates on first call.
  static Future<String> get() {
    final cached = _cached;
    if (cached != null) return Future<String>.value(cached);
    return _inFlight ??= _resolve().whenComplete(() {
      _inFlight = null;
    });
  }

  static Future<String> _resolve() async {
    // 1. The keystore-backed store, which is where it belongs.
    try {
      final secured = await _secure.read(key: _key);
      if (secured != null && secured.isNotEmpty) {
        _cached = secured;
        return secured;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('DeviceIdentity.read: $e');
    }

    // 2. A value written by a build before v1.63.5. Migrate it rather than
    //    minting a new one: an existing install must keep the id the server
    //    already knows, or every early user looks like a new device on the
    //    first launch after updating.
    final legacy = await _readLegacy();
    if (legacy != null && legacy.isNotEmpty) {
      await _persist(legacy);
      _cached = legacy;
      return legacy;
    }

    // 3. First run on this install.
    final fresh = _generate();
    await _persist(fresh);
    _cached = fresh;
    return fresh;
  }

  static Future<String?> _readLegacy() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getString(_key);
    } catch (e) {
      if (kDebugMode) debugPrint('DeviceIdentity.legacy: $e');
      return null;
    }
  }

  /// Write to the secure store, then drop any plaintext copy.
  ///
  /// FALLBACK, DELIBERATE: if the keystore write fails - it can, transiently,
  /// notably just after the user changes their lock screen - the value is left
  /// in SharedPreferences instead. An id that is backed up is a smaller
  /// problem than an id that changes on every launch, which would look to the
  /// server like a new device every time and would burn through the
  /// concurrency cap in an afternoon.
  static Future<void> _persist(String value) async {
    var secured = false;
    try {
      await _secure.write(key: _key, value: value);
      secured = true;
    } catch (e) {
      if (kDebugMode) debugPrint('DeviceIdentity.write: $e');
    }

    try {
      final sp = await SharedPreferences.getInstance();
      if (secured) {
        if (sp.containsKey(_key)) await sp.remove(_key);
      } else {
        await sp.setString(_key, value);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('DeviceIdentity.persist-legacy: $e');
    }
  }

  /// 128 bits from a cryptographic source, base64url without padding.
  ///
  /// `Random.secure()` rather than `Random()`: a predictable device id would
  /// let someone else's slot be impersonated, which is the one thing this
  /// value must not allow.
  static String _generate() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
