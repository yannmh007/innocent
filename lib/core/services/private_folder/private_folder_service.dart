import 'package:flutter/foundation.dart' show kDebugMode, debugPrint, compute, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart' show sha256, Hmac;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../adb/adb_service.dart';

import '../../../core/localization/app_strings.dart';
/// Private folder service — guards a list of videos behind a PIN and,
/// when possible, moves the underlying files into an app-private vault.
/// PIN is hashed with SHA-256 (per-install random salt) before storage.
///
/// Vaulting (see importToVault) copies the file into the app's internal
/// support dir — not indexed by MediaStore and not reachable by other
/// apps / file managers without root — verifies the copy, then deletes
/// the original. Files with content:// (system-managed) URIs that can't
/// be resolved to a real path fall back to "soft hide" (list-only).
/// Thrown out of a vault copy when the user asks to stop.
///
/// A dedicated type rather than a bare Exception so the UI can tell "you
/// cancelled" apart from "this failed", and report each honestly. Getting
/// that wrong in a vault is expensive: a user told their import failed, when
/// really they cancelled it, may go and delete an original they still need.
class VaultCancelled implements Exception {
  const VaultCancelled();
  @override
  String toString() => 'VaultCancelled';
}

/// A recorded failed-unlock attempt: when it happened and, if capture was
/// on and succeeded, the path to the intruder selfie.
class IntruderEvent {
  final DateTime at;
  final String? photoPath;

  /// The digits that were actually entered, and which method was tried.
  ///
  /// Every major vault records this and it is the single most useful line in
  /// a break-in log: a photo tells the owner WHO, the attempted code tells
  /// them WHAT was guessed — "1234, 0000, 1111" reads as a stranger poking
  /// at the phone, while a near-miss of the owner's real PIN reads as a
  /// family member who has watched them unlock it.
  ///
  /// Only WRONG entries ever reach here; a correct PIN is never logged. The
  /// log lives in the same keystore-encrypted store as the PIN hash itself.
  final String? attempted;

  /// 'pin' | 'answer' | 'key' — which door was tried. Recovery attempts are
  /// worth distinguishing: someone working on the security question is not
  /// idly guessing, they are trying to reset the PIN.
  final String? method;

  const IntruderEvent({
    required this.at,
    this.photoPath,
    this.attempted,
    this.method,
  });
}

/// Result of classifying an entered PIN.
enum PinKind {
  /// Matches the real PIN — open the real vault.
  real,

  /// Matches the decoy PIN — open a convincing but empty vault.
  decoy,

  /// Matches neither — a failed attempt.
  none,
}

class PrivateFolderService {
  static const String _kPinHash = 'private_pin_hash_v1';
  static const String _kPinSalt = 'private_pin_salt_v1';
  static const String _kEntries = 'private_entries_v1';
  // v0.51: user-created organiser folders inside the vault. Entries carry
  // a folderId; null = the vault root. Folders are pure metadata (name +
  // id + created time) — the physical vault files stay in one flat dir,
  // so moving an entry between folders is just a field update, never a
  // file copy.
  static const String _kFolders = 'private_folders_v1';
  // Audit fix (brute-force bypass): the unlock screen's failed-attempt
  // counter + cooling-off deadline used to live only in widget memory,
  // so force-closing the app reset them — an attacker could try 5 PINs,
  // kill the app, try 5 more, with no escalating penalty ever sticking.
  // Persisting both here makes the rate-limit survive process death.
  static const String _kLockFailed = 'private_lock_failed_v1';
  static const String _kLockUntil = 'private_lock_until_v1';
  // Recovery (v0.53): two independent PIN-reset paths so a forgotten PIN
  // doesn't strand the vault forever. Neither stores the PIN itself — each
  // is a hashed secret that, once proven, unlocks the ability to SET a new
  // PIN. Structured so an email/OTP method can be added later without
  // touching these.
  //   • Security question: a user-chosen question + the SHA-256 of its
  //     answer (case-folded, trimmed) with the same per-install salt.
  //   • Recovery key: a randomly generated 12-char code shown once at
  //     setup; only its hash is kept.
  static const String _kRecoveryQuestion = 'private_recovery_question_v1';
  static const String _kRecoveryAnswerHash = 'private_recovery_answer_v1';
  static const String _kRecoveryKeyHash = 'private_recovery_key_v1';
  // Decoy PIN (v0.53 anti-coercion): an OPTIONAL second PIN that opens a
  // convincing but empty vault instead of the real one. If someone forces
  // the user to unlock, they enter the decoy and see nothing sensitive.
  // Only the hash is stored; it shares the real PIN's salt.
  static const String _kDecoyPinHash = 'private_decoy_pin_v1';
  // Break-in log (v0.53 anti-theft): a JSON list of failed-unlock events,
  // each { atMs, photoPath? }. The photo (front-camera selfie of whoever
  // was holding the phone) is captured natively when available; the entry
  // is recorded either way so the owner can see WHEN someone tried. Stored
  // encrypted like the rest of the vault metadata.
  static const String _kIntruderLog = 'private_intruder_log_v1';
  // Toggle: capture an intruder selfie on repeated failures. Off by
  // default (needs the camera and the user's consent).
  static const String _kIntruderEnabled = 'private_intruder_enabled_v1';
  // v1.49: how many DIGITS the real / decoy PIN has. Stored inside the same
  // encrypted store as the hashes, so it reveals nothing an attacker holding
  // that store doesn't already have — and it lets the keypad submit the
  // moment the last digit lands instead of making the user hunt for a
  // confirm button. Both lengths are kept because a decoy PIN of a different
  // length must auto-submit too; the keypad treats them as an unordered set
  // so watching the screen can't tell a coercer which is which.
  static const String _kPinLength = 'private_pin_len_v1';
  static const String _kDecoyPinLength = 'private_decoy_len_v1';
  // v1.49: seconds of grace before the vault re-locks itself after the app
  // leaves the foreground. 0 = immediately (the default, and the safest).
  static const String _kAutoLockSeconds = 'private_autolock_v1';

  // Keystore-backed secret store for the PIN hash / salt / lockout.
  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Read a secured value, transparently migrating a value written by an
  /// older (plaintext SharedPreferences) build exactly once. Keystore reads
  /// can transiently fail (e.g. just after the user changes their lock
  /// screen); on failure we fall back to the legacy store rather than
  /// hard-failing the unlock.
  Future<String?> _secureRead(String key) async {
    try {
      final v = await _secure.read(key: key);
      if (v != null) return v;
    } catch (e) { if (kDebugMode) debugPrint('private_folder_service.best-effort: $e'); }
    final sp = await SharedPreferences.getInstance();
    final legacy = sp.getString(key) ??
        (sp.containsKey(key) ? sp.getInt(key)?.toString() : null);
    if (legacy != null) {
      try {
        await _secure.write(key: key, value: legacy);
        await sp.remove(key); // drop the plaintext copy after migration
      } catch (e) { if (kDebugMode) debugPrint('private_folder_service.best-effort: $e'); }
      return legacy;
    }
    return null;
  }

  Future<void> _secureWrite(String key, String value) =>
      _secure.write(key: key, value: value);

  Future<void> _secureDelete(String key) async {
    try {
      await _secure.delete(key: key);
    } catch (e) { if (kDebugMode) debugPrint('private_folder_service.best-effort: $e'); }
    final sp = await SharedPreferences.getInstance();
    await sp.remove(key); // clear any legacy plaintext remnant too
  }

  /// Returns true if a PIN is set
  Future<bool> hasPin() async => (await _secureRead(_kPinHash)) != null;

  /// Set or change the PIN. Throws if [oldPin] doesn't match current.
  Future<void> setPin(String newPin, {String? oldPin}) async {
    if (await hasPin()) {
      if (oldPin == null || !await _verifyPin(oldPin)) {
        throw const FormatException('Current PIN incorrect');
      }
    }
    // Per-install random salt: the old static salt meant a given 4-digit
    // PIN hashed identically on every install, so one precomputed lookup
    // table cracked any device. A random 16-byte salt forces the table to
    // be rebuilt per device — the standard mitigation for a low-entropy
    // (constrained-input) secret.
    final salt = await _ensureSalt();
    await _secureWrite(_kPinHash, await _hashPinAsync(newPin, salt));
    await _secureWrite(_kPinLength, newPin.length.toString());
    // If the new real PIN happens to equal the decoy PIN, the decoy would
    // be shadowed (verifyPinKind checks real first) and silently stop
    // working. Clear it so the user isn't left with a dead decoy they
    // think still protects them.
    //
    // The comparison can no longer be a hash-to-hash equality: v2 hashes
    // embed a round count, so the same PIN legitimately produces different
    // strings. Verify the new PIN against the STORED decoy hash instead,
    // which works across every hash generation.
    final decoy = await _secureRead(_kDecoyPinHash);
    if (decoy != null && await _matchesStored(decoy, newPin, salt)) {
      await _secureDelete(_kDecoyPinHash);
      await _secureDelete(_kDecoyPinLength);
    }
  }

  /// Digit counts that should make the keypad submit on its own: the real
  /// PIN's length and, when configured, the decoy's. Returned as an unordered
  /// set on purpose — the caller must not be able to tell which is which, or
  /// the keypad's behaviour would reveal that a decoy exists.
  Future<Set<int>> autoSubmitLengths() async {
    final out = <int>{};
    final real = int.tryParse(await _secureRead(_kPinLength) ?? '');
    if (real != null && real >= 4) out.add(real);
    final decoy = int.tryParse(await _secureRead(_kDecoyPinLength) ?? '');
    if (decoy != null && decoy >= 4) out.add(decoy);
    return out;
  }

  // ── Auto-lock delay ────────────────────────────────────────────────

  /// Seconds the vault stays open after the app leaves the foreground.
  /// 0 (the default) means it locks the instant the app is backgrounded.
  Future<int> autoLockSeconds() async =>
      int.tryParse(await _secureRead(_kAutoLockSeconds) ?? '') ?? 0;

  Future<void> setAutoLockSeconds(int seconds) async {
    await _secureWrite(_kAutoLockSeconds, seconds.toString());
  }

  /// Verify a PIN attempt
  Future<bool> verifyPin(String pin) => _verifyPin(pin);

  /// Classify an entered PIN: the real one, the decoy, or neither. The
  /// unlock screen uses this to decide which vault to show. The decoy is
  /// checked only if configured, and a value that matches both (which the
  /// setter forbids) resolves to real.
  Future<PinKind> verifyPinKind(String pin) async {
    if (await _verifyPin(pin)) return PinKind.real;
    final decoy = await _secureRead(_kDecoyPinHash);
    if (decoy != null) {
      final salt = await _ensureSalt();
      if (await _matchesStored(decoy, pin, salt)) {
        // Upgrade an old-format decoy hash the same way the real one is
        // upgraded, so the two never drift into different security levels.
        if (!decoy.startsWith(_kHashV2Prefix)) {
          await _secureWrite(_kDecoyPinHash, await _hashPinAsync(pin, salt));
          await _secureWrite(_kDecoyPinLength, pin.length.toString());
        }
        return PinKind.decoy;
      }
    }
    return PinKind.none;
  }

  Future<bool> hasDecoyPin() async =>
      (await _secureRead(_kDecoyPinHash)) != null;

  /// Set (or replace) the decoy PIN. Rejected if it equals the real PIN —
  /// they must be distinguishable or the decoy is pointless.
  Future<void> setDecoyPin(String decoyPin) async {
    if (decoyPin.length < 4) {
      throw const FormatException('Decoy PIN must be at least 4 digits');
    }
    if (await _verifyPin(decoyPin)) {
      throw const FormatException(
          'Decoy PIN must be different from your real PIN');
    }
    final salt = await _ensureSalt();
    await _secureWrite(_kDecoyPinHash, await _hashPinAsync(decoyPin, salt));
    await _secureWrite(_kDecoyPinLength, decoyPin.length.toString());
  }

  Future<void> clearDecoyPin() async {
    await _secureDelete(_kDecoyPinHash);
    await _secureDelete(_kDecoyPinLength);
  }

  // ── Break-in (intruder) log ─────────────────────────────────────────

  /// Whether intruder-selfie capture is enabled.
  Future<bool> intruderCaptureEnabled() async =>
      (await _secureRead(_kIntruderEnabled)) == '1';

  Future<void> setIntruderCaptureEnabled(bool enabled) async {
    await _secureWrite(_kIntruderEnabled, enabled ? '1' : '0');
  }

  /// Load the break-in log, newest first.
  Future<List<IntruderEvent>> loadIntruderLog() async {
    final raw = await _secureRead(_kIntruderLog);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = <IntruderEvent>[];
      for (final e in list) {
        final m = e as Map<String, dynamic>;
        out.add(IntruderEvent(
          at: DateTime.fromMillisecondsSinceEpoch(m['atMs'] as int),
          photoPath: m['photoPath'] as String?,
          attempted: m['attempted'] as String?,
          method: m['method'] as String?,
        ));
      }
      out.sort((a, b) => b.at.compareTo(a.at));
      return out;
    } catch (e) {
      if (kDebugMode) debugPrint('private_folder_service.intruderLog: $e');
      return [];
    }
  }

  /// Record a failed-unlock event (optionally with a captured photo path).
  /// Capped at the 20 most recent to keep storage bounded.
  Future<void> recordIntruder({
    String? photoPath,
    String? attempted,
    String? method,
  }) async {
    final log = await loadIntruderLog();
    log.insert(
        0,
        IntruderEvent(
          at: DateTime.now(),
          photoPath: photoPath,
          // Bound the stored string. A PIN pad cannot produce more than six
          // digits, but recovery answers are free text and there is no
          // reason to keep a paragraph of someone's guess on disk.
          attempted: attempted == null
              ? null
              : (attempted.length > 12
                  ? '${attempted.substring(0, 12)}…'
                  : attempted),
          method: method,
        ));
    final trimmed = log.take(20).toList();
    await _secureWrite(
      _kIntruderLog,
      jsonEncode(trimmed
          .map((e) => {
                'atMs': e.at.millisecondsSinceEpoch,
                if (e.photoPath != null) 'photoPath': e.photoPath,
                if (e.attempted != null) 'attempted': e.attempted,
                if (e.method != null) 'method': e.method,
              })
          .toList()),
    );
  }

  /// Clear the whole break-in log, deleting any captured photos too.
  Future<void> clearIntruderLog() async {
    final log = await loadIntruderLog();
    for (final e in log) {
      final path = e.photoPath;
      if (path != null) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (err) {
          if (kDebugMode) {
            debugPrint('private_folder_service.clearIntruder: $err');
          }
        }
      }
    }
    await _secureDelete(_kIntruderLog);
  }

  /// Directory where intruder selfies are stored (inside app-private
  /// storage, never in a public gallery).
  Future<Directory> intruderPhotoDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'intruder_shots'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static const MethodChannel _intruderCam =
      MethodChannel('mx_clone/intruder_cam');

  /// Capture an intruder selfie (if enabled + a front camera is available)
  /// and record the break-in event. Always records the timestamp, even if
  /// the photo fails, so the owner sees that SOMEONE tried. Best-effort and
  /// completely silent — never throws into the unlock flow.
  Future<void> captureAndRecordIntruder({
    String? attempted,
    String? method,
  }) async {
    String? photoPath;
    try {
      if (await intruderCaptureEnabled()) {
        final dir = await intruderPhotoDir();
        final target =
            p.join(dir.path, 'shot_${DateTime.now().millisecondsSinceEpoch}.jpg');
        final res = await _intruderCam
            .invokeMethod<String>('capture', {'path': target});
        if (res != null) photoPath = res;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('private_folder_service.capture: $e');
    }
    await recordIntruder(
        photoPath: photoPath, attempted: attempted, method: method);
  }

  // === Persisted rate-limit (survives app restart) ===

  /// Load the persisted failed-attempt count + cooling-off deadline.
  /// `until` is null when no lockout is in effect.
  Future<({int failed, DateTime? until})> loadLockout() async {
    final failed = int.tryParse(await _secureRead(_kLockFailed) ?? '') ?? 0;
    final untilMs = int.tryParse(await _secureRead(_kLockUntil) ?? '') ?? 0;
    return (
      failed: failed,
      until: untilMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(untilMs)
          : null,
    );
  }

  /// Persist the failed-attempt count + cooling-off deadline. Pass
  /// `failed: 0, until: null` to clear after a successful unlock.
  Future<void> saveLockout(int failed, DateTime? until) async {
    await _secureWrite(_kLockFailed, failed.toString());
    await _secureWrite(
        _kLockUntil, (until?.millisecondsSinceEpoch ?? 0).toString());
  }

  // ── Shared attempt limiter (v1.49) ─────────────────────────────────
  //
  // This logic used to live in the unlock WIDGET, which meant it protected
  // exactly one door. The vault has more than one: "Forgot PIN" leads to a
  // security question and a recovery key, and either of those, once guessed,
  // grants a full PIN reset. Those screens counted nothing and waited for
  // nothing, so the cheapest attack on the vault was never to attack the PIN
  // at all — it was to tap "Forgot PIN" and guess an answer like a pet's name
  // as fast as a finger can move.
  //
  // One counter, owned by the service, shared by every surface that can open
  // the vault, persisted so force-closing the app cannot reset it. A failure
  // anywhere slows down attempts everywhere, which is the only version of
  // this that actually holds.

  static const int _kLockoutThreshold = 5;

  /// Escalating cooling-off: 5 misses → 15s, 10 → 1min, 15 → 5min, 20+ → 15min.
  /// The first tier stays short because the overwhelmingly likely cause of
  /// five misses is the owner mistyping, and punishing them for it is how
  /// security features get switched off.
  static const List<int> _kLockoutTiers = <int>[15, 60, 300, 900];

  /// Remaining cooling-off, or null when attempts are allowed right now.
  Future<Duration?> lockoutRemaining() async {
    final st = await loadLockout();
    final until = st.until;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left > Duration.zero ? left : null;
  }

  /// Record ONE failed attempt from any surface and return the new state.
  ///
  /// Also fires the break-in camera: on the third consecutive miss (past the
  /// point where a typo is the likely explanation) and on every lockout
  /// trigger after that. Fire-and-forget by design — the capture must never
  /// delay the "wrong PIN" feedback, or the pause itself would tell whoever
  /// is holding the phone that a photo was just taken.
  Future<({int failed, DateTime? until})> registerFailedAttempt({
    String? attempted,
    String? method,
  }) async {
    final st = await loadLockout();
    final failed = st.failed + 1;
    DateTime? until = st.until;
    // Drop an expired deadline rather than carrying it forward; otherwise the
    // stored "until" is a time in the past and every reader has to re-check it.
    if (until != null && !DateTime.now().isBefore(until)) until = null;
    if (failed % _kLockoutThreshold == 0) {
      final tier =
          (failed ~/ _kLockoutThreshold).clamp(1, _kLockoutTiers.length);
      until = DateTime.now()
          .add(Duration(seconds: _kLockoutTiers[tier - 1]));
    }
    await saveLockout(failed, until);
    if (failed == 3 || failed % _kLockoutThreshold == 0) {
      // ignore: discarded_futures
      captureAndRecordIntruder(attempted: attempted, method: method);
    }
    return (failed: failed, until: until);
  }

  /// Clear the limiter after any successful entry (real PIN, decoy PIN,
  /// biometric, or a completed recovery).
  Future<void> clearLockout() => saveLockout(0, null);

  Future<bool> _verifyPin(String pin) async {
    final stored = await _secureRead(_kPinHash);
    if (stored == null) return false;
    final salt = await _ensureSalt();
    final ok = await _matchesStored(stored, pin, salt);
    if (ok && !stored.startsWith(_kHashV2Prefix)) {
      // Silent upgrade: a correct PIN proven against an old-format hash is
      // immediately re-hashed with the current KDF. The user never sees it,
      // and every later unlock is verified at full strength.
      await _secureWrite(_kPinHash, await _hashPinAsync(pin, salt));
      await _secureWrite(_kPinLength, pin.length.toString());
    }
    return ok;
  }

  /// Compare an entered PIN against a STORED hash of any generation.
  ///
  /// Three formats have shipped and all three must keep working — an upgrade
  /// that locks a user out of their own vault is worse than the weakness it
  /// fixes:
  ///   v2  `v2$<rounds>$<hex>`  PBKDF2-HMAC-SHA256, per-device round count
  ///   v1  bare hex             sha256('<per-install salt>::<pin>')
  ///   v0  bare hex             sha256('mx_clone_salt::<pin>')  (static salt)
  Future<bool> _matchesStored(String stored, String pin, String salt) async {
    if (stored.startsWith(_kHashV2Prefix)) {
      final rounds = _roundsOf(stored);
      final candidate = await _deriveV2(pin, salt, rounds);
      return _constantTimeEquals(stored, candidate);
    }
    if (_constantTimeEquals(stored, _hashPinLegacy(pin, salt))) return true;
    return _constantTimeEquals(
        stored, sha256.convert(utf8.encode('mx_clone_salt::$pin')).toString());
  }

  // ─── TEST WINDOWS ──────────────────────────────────────────────────────
  //
  // Dart's `_` is LIBRARY-private, so a file in test/ cannot reach any of the
  // helpers below however much it wants to. These three wrappers are the
  // narrowest opening that lets the security-critical parts be tested at all.
  //
  // They add no behaviour, hold no state and are annotated so the analyzer
  // flags any production call site. Everything else in this class stays shut.
  //
  // Why it is worth opening anything: `_pbkdf2Sha256` is hand-written rather
  // than taken from a package - deliberately, so it stays auditable - and a
  // hand-written primitive that has never been checked against a reference
  // implementation is a hope, not a control. It is the function standing
  // between a stolen hash and the user's PIN.

  /// PBKDF2-HMAC-SHA256, exactly as used for storage. See
  /// `test/private_folder_crypto_test.dart` for the published vectors.
  @visibleForTesting
  static String pbkdf2ForTest(String password, String salt, int rounds) =>
      _pbkdf2Sha256(password: password, salt: salt, rounds: rounds);

  /// Parses the round count back out of a stored v2 hash.
  @visibleForTesting
  static int roundsOfForTest(String storedV2) => _roundsOf(storedV2);

  /// The timing-safe comparison used for every hash check.
  @visibleForTesting
  static bool constantTimeEqualsForTest(String a, String b) =>
      _constantTimeEquals(a, b);

  /// Round count embedded in a v2 hash. Reading it from the STRING (rather
  /// than a constant) is what makes the cost tunable later without stranding
  /// anyone: a hash written at 40 000 rounds still verifies at 40 000 rounds
  /// on a phone whose current default is 200 000.
  static int _roundsOf(String storedV2) {
    final parts = storedV2.split(_kHashSep);
    if (parts.length < 3) return _kMinRounds;
    return int.tryParse(parts[1]) ?? _kMinRounds;
  }

  /// Length-independent, early-exit-free comparison. A plain `==` on Dart
  /// strings returns as soon as two bytes differ, so the time it takes leaks
  /// how many leading characters were right — the classic timing side channel
  /// on a hash compare. The cost here is microseconds; there is no reason not
  /// to close it.
  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    final n = x.length < y.length ? x.length : y.length;
    for (var i = 0; i < n; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  /// Lazily create + persist a 16-byte random salt. The hash is only stored
  /// by callers *after* the salt it depends on is committed, so a crash
  /// mid-write can't orphan the hash (which would be a permanent lockout).
  Future<String> _ensureSalt() async {
    final existing = await _secureRead(_kPinSalt);
    if (existing != null && existing.isNotEmpty) return existing;
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final salt = base64Encode(bytes);
    await _secureWrite(_kPinSalt, salt);
    return salt;
  }

  /// The ORIGINAL hash: one round of SHA-256. Kept only so existing installs
  /// can still be verified (and then upgraded). Never used to write.
  String _hashPinLegacy(String pin, String salt) {
    return sha256.convert(utf8.encode('$salt::$pin')).toString();
  }

  // ── PIN key-derivation (v1.49) ─────────────────────────────────────
  //
  // WHY THE OLD SCHEME WAS NOT ENOUGH
  // A PIN is four to six digits: at most a million possibilities, usually ten
  // thousand. One round of SHA-256 over that keyspace is a rounding error on
  // any machine built this decade — an attacker who ever gets the stored hash
  // recovers the PIN essentially instantly. The per-install salt already
  // shipped here does the one thing salt can do (it kills shared rainbow
  // tables) but it does nothing about speed.
  //
  // PBKDF2 attacks the speed directly: verifying one candidate now costs a
  // fixed, deliberately large amount of work, and that cost multiplies across
  // the attacker's whole search. It is the same trick every password store
  // uses, and it is the only lever available when the secret itself cannot be
  // made longer.
  //
  // BE HONEST ABOUT THE LIMIT: a four-digit PIN can never be made
  // offline-safe by a KDF alone. This raises the cost of an offline attack by
  // orders of magnitude; it does not eliminate it. The keystore (which keeps
  // the hash off a plain filesystem dump in the first place) and the
  // persisted lockout below are the other two thirds of the defence, and each
  // matters more than this one.
  //
  // WHY THE ROUND COUNT IS CALIBRATED, NOT CONSTANT
  // A number tuned on a flagship makes an entry-level phone wait seconds; a
  // number safe on an entry-level phone wastes the flagship's headroom. This
  // app has to work on nearly every Myanmar handset, so instead of guessing,
  // each device measures itself once when the PIN is set and stores the round
  // count it arrived at INSIDE the hash string. Unlock always costs about the
  // same wall-clock time everywhere, and every device pays as much as it can
  // afford.
  static const String _kHashV2Prefix = r'v2$';
  /// Field separator inside a v2 hash. A raw-string constant rather than an
  /// inline escape: a bare `\$` in an interpolated Dart string is one of the
  /// easiest characters in this codebase to get wrong, and getting it wrong
  /// here would write a hash nobody can ever verify against.
  static const String _kHashSep = r'$';
  static const int _kMinRounds = 20000;
  static const int _kMaxRounds = 400000;

  /// Wall-clock budget for one PIN verification, in milliseconds. Long enough
  /// to hurt a bulk attacker, short enough that unlocking still feels
  /// instant — the delay is hidden behind the keypad's own press animation.
  static const int _kTargetMillis = 320;

  /// Derive and format a v2 hash for [pin]. Runs on a background isolate:
  /// hundreds of thousands of HMAC rounds on the UI thread would freeze the
  /// keypad mid-press, which is exactly the moment the app must feel solid.
  Future<String> _deriveV2(String pin, String salt, int rounds) async {
    final hex = await compute(
        _pbkdf2Worker, <String>[pin, salt, rounds.toString()]);
    return '$_kHashV2Prefix$rounds$_kHashSep$hex';
  }

  /// Hash a PIN for STORAGE at this device's calibrated cost.
  Future<String> _hashPinAsync(String pin, String salt) async {
    final rounds = await _calibratedRounds();
    return _deriveV2(pin, salt, rounds);
  }

  /// Rounds this device can do inside [_kTargetMillis]. Measured with a short
  /// probe on a background isolate, then scaled up. Clamped at both ends so a
  /// freak measurement (a phone throttling mid-probe, or an emulator running
  /// absurdly fast) can never produce a value that is either insecure or
  /// unusable.
  static int? _cachedRounds;

  Future<int> _calibratedRounds() async {
    final cached = _cachedRounds;
    if (cached != null) return cached;
    var rounds = _kMinRounds;
    try {
      final micros = await compute(_pbkdf2ProbeWorker, _kProbeRounds);
      if (micros > 0) {
        final perRound = micros / _kProbeRounds;
        rounds = (_kTargetMillis * 1000 / perRound).round();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('private_folder_service.calibrate: $e');
    }
    if (rounds < _kMinRounds) rounds = _kMinRounds;
    if (rounds > _kMaxRounds) rounds = _kMaxRounds;
    _cachedRounds = rounds;
    return rounds;
  }

  static const int _kProbeRounds = 3000;

  /// Clear PIN (only after verification — caller should verify first)
  /// Clear the PIN and lockout state only. Deliberately does NOT touch the
  /// vault entries or folders — removing the PIN must never destroy the
  /// user's hidden files. (Currently unused; kept for a future
  /// "reset PIN" flow.)
  Future<void> clearPin() async {
    await _secureDelete(_kPinHash);
    await _secureDelete(_kPinSalt);
    await _secureDelete(_kLockFailed);
    await _secureDelete(_kLockUntil);
  }

  // ═══════════════════════════════════════════════════════════════════
  // Recovery (forgotten-PIN reset). Two paths, either of which proves the
  // owner's identity and then permits setting a fresh PIN. The vault files
  // and their encrypted metadata are never touched by recovery — only the
  // PIN gate is reset.
  // ═══════════════════════════════════════════════════════════════════

  /// Normalise a security answer so trivial formatting differences (case,
  /// surrounding spaces, internal double-spaces) don't cause a false
  /// mismatch. Answers are compared on this canonical form.
  String _canonicalAnswer(String a) =>
      a.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// True once ANY recovery method is configured.
  Future<bool> hasRecovery() async =>
      (await _secureRead(_kRecoveryAnswerHash)) != null ||
      (await _secureRead(_kRecoveryKeyHash)) != null;

  Future<bool> hasSecurityQuestion() async =>
      (await _secureRead(_kRecoveryQuestion)) != null;

  Future<bool> hasRecoveryKey() async =>
      (await _secureRead(_kRecoveryKeyHash)) != null;

  /// The stored security question text (null if none set).
  Future<String?> securityQuestion() => _secureRead(_kRecoveryQuestion);

  /// Set (or replace) the security question + answer. The answer is hashed
  /// with the per-install salt, never stored in the clear.
  Future<void> setSecurityQuestion(String question, String answer) async {
    final q = question.trim();
    final a = _canonicalAnswer(answer);
    if (q.isEmpty || a.isEmpty) {
      throw const FormatException('Question and answer are required');
    }
    final salt = await _ensureSalt();
    await _secureWrite(_kRecoveryQuestion, q);
    await _secureWrite(_kRecoveryAnswerHash, await _hashPinAsync(a, salt));
  }

  Future<void> clearSecurityQuestion() async {
    await _secureDelete(_kRecoveryQuestion);
    await _secureDelete(_kRecoveryAnswerHash);
  }

  /// Verify a security-question answer.
  Future<bool> verifySecurityAnswer(String answer) async {
    final stored = await _secureRead(_kRecoveryAnswerHash);
    if (stored == null) return false;
    final salt = await _ensureSalt();
    return _matchesStored(stored, _canonicalAnswer(answer), salt);
  }

  /// Generate a fresh recovery key, persist ONLY its hash, and return the
  /// plaintext to show the user exactly once. Format: XXXX-XXXX-XXXX using
  /// an unambiguous alphabet (no 0/O/1/I/L) for easy hand-copying.
  Future<String> generateRecoveryKey() async {
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    final buf = StringBuffer();
    for (var g = 0; g < 3; g++) {
      if (g > 0) buf.write('-');
      for (var i = 0; i < 4; i++) {
        buf.write(alphabet[rng.nextInt(alphabet.length)]);
      }
    }
    final key = buf.toString();
    final salt = await _ensureSalt();
    await _secureWrite(_kRecoveryKeyHash, await _hashPinAsync(key, salt));
    return key;
  }

  Future<void> clearRecoveryKey() async {
    await _secureDelete(_kRecoveryKeyHash);
  }

  /// Verify a recovery key (case-insensitive; dashes and spaces ignored so
  /// the user can type it loosely).
  Future<bool> verifyRecoveryKey(String key) async {
    final stored = await _secureRead(_kRecoveryKeyHash);
    if (stored == null) return false;
    final normalised =
        key.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    // Re-insert dashes to match the stored canonical format.
    if (normalised.length != 12) return false;
    final canonical =
        '${normalised.substring(0, 4)}-${normalised.substring(4, 8)}'
        '-${normalised.substring(8, 12)}';
    final salt = await _ensureSalt();
    return _matchesStored(stored, canonical, salt);
  }

  /// Reset the PIN via a proven recovery path. The caller MUST have already
  /// verified a recovery method (security answer or recovery key); this
  /// just installs the new PIN and clears the lockout. Returns nothing —
  /// the vault contents are untouched.
  Future<void> resetPinViaRecovery(String newPin) async {
    if (newPin.length < 4) {
      throw const FormatException('PIN must be at least 4 digits');
    }
    final salt = await _ensureSalt();
    await _secureWrite(_kPinHash, await _hashPinAsync(newPin, salt));
    await _secureWrite(_kPinLength, newPin.length.toString());
    // A successful recovery clears any active lockout.
    await saveLockout(0, null);
  }

  // === Entries ===

  Future<List<PrivateEntry>> loadEntries() async {
    var raw = await _secureRead(_kEntries);
    if (raw == null) {
      // One-time migration: pull any legacy plaintext list out of
      // SharedPreferences, re-save it encrypted, then wipe the plaintext.
      final sp = await SharedPreferences.getInstance();
      final legacy = sp.getString(_kEntries);
      if (legacy != null) {
        await _secureWrite(_kEntries, legacy);
        await sp.remove(_kEntries);
        raw = legacy;
      }
    }
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      // Decode entry-by-entry: a single malformed record (e.g. from a
      // partial write or a schema change) must not drop the user's entire
      // private list and orphan every vault file. Skip just the bad one.
      final out = <PrivateEntry>[];
      for (final e in list) {
        try {
          out.add(PrivateEntry.fromJson(e as Map<String, dynamic>));
        } catch (e) { if (kDebugMode) debugPrint('private_folder_service.best-effort: $e'); }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveEntries(List<PrivateEntry> entries) async {
    // Keystore-encrypted — the metadata (titles, original + vault paths)
    // is never written to disk in the clear.
    await _secureWrite(
      _kEntries,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> addEntry(PrivateEntry entry) async {
    final entries = await loadEntries();
    entries.removeWhere((e) => e.videoUri == entry.videoUri);
    entries.insert(0, entry);
    await saveEntries(entries);
  }

  Future<void> removeEntry(String videoUri) async {
    final entries = await loadEntries();
    entries.removeWhere((e) => e.videoUri == videoUri);
    await saveEntries(entries);
  }

  Future<bool> isPrivate(String videoUri) async {
    final entries = await loadEntries();
    return entries.any((e) => e.videoUri == videoUri);
  }

  // === Organiser folders (v0.51) ===

  Future<List<PrivateFolderMeta>> loadFolders() async {
    var raw = await _secureRead(_kFolders);
    if (raw == null) {
      final sp = await SharedPreferences.getInstance();
      final legacy = sp.getString(_kFolders);
      if (legacy != null) {
        await _secureWrite(_kFolders, legacy);
        await sp.remove(_kFolders);
        raw = legacy;
      }
    }
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = <PrivateFolderMeta>[];
      for (final e in list) {
        try {
          out.add(PrivateFolderMeta.fromJson(e as Map<String, dynamic>));
        } catch (e) {
          if (kDebugMode) debugPrint('private_folder_service.best-effort: $e');
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveFolders(List<PrivateFolderMeta> folders) async {
    await _secureWrite(
        _kFolders, jsonEncode(folders.map((f) => f.toJson()).toList()));
  }

  /// Create a folder and return it. Names need not be unique (id is the
  /// key) but we trim and reject blank names.
  Future<PrivateFolderMeta> createFolder(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Folder name cannot be empty');
    }
    final folders = await loadFolders();
    final meta = PrivateFolderMeta(
      id: _randomVaultName(16),
      name: trimmed,
      createdAt: DateTime.now(),
    );
    folders.insert(0, meta);
    await _saveFolders(folders);
    return meta;
  }

  Future<void> renameFolder(String folderId, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final folders = await loadFolders();
    final i = folders.indexWhere((f) => f.id == folderId);
    if (i == -1) return;
    folders[i] = folders[i].copyWith(name: trimmed);
    await _saveFolders(folders);
  }

  /// Delete a folder. Its entries are moved back to the vault root (their
  /// files are untouched) so nothing is ever lost.
  /// Delete a folder and move its contents back to the vault root
  /// (nothing is erased — the files stay locked, just unfiled).
  Future<void> deleteFolder(String folderId) async {
    final folders = await loadFolders();
    folders.removeWhere((f) => f.id == folderId);
    await _saveFolders(folders);
    final entries = await loadEntries();
    var changed = false;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].folderId == folderId) {
        entries[i] = entries[i].copyWith(clearFolder: true);
        changed = true;
      }
    }
    if (changed) await saveEntries(entries);
  }

  /// Delete a folder AND permanently erase every file inside it. The vault
  /// copies are deleted from disk and the entries dropped from the index,
  /// then a single MediaStore rescan runs. Use only after an explicit
  /// "delete everything" confirmation.
  Future<void> deleteFolderWithContents(String folderId) async {
    final entries = await loadEntries();
    final inFolder =
        entries.where((e) => e.folderId == folderId).toList();
    // Erase each vaulted file (best-effort) and collect paths for rescan.
    final scanned = <String>[];
    for (final e in inFolder) {
      final vp = e.vaultPath;
      if (vp != null) {
        try {
          final f = File(vp);
          if (await f.exists()) await f.delete();
          scanned.add(vp);
        } catch (err) {
          if (kDebugMode) {
            debugPrint('private_folder_service.deleteFolderContents: $err');
          }
        }
      }
    }
    final removeUris = inFolder.map((e) => e.videoUri).toSet();
    entries.removeWhere((e) => removeUris.contains(e.videoUri));
    await saveEntries(entries);
    // Drop the folder itself.
    final folders = await loadFolders();
    folders.removeWhere((f) => f.id == folderId);
    await _saveFolders(folders);
    if (scanned.isNotEmpty) await _mediaScan(scanned);
  }

  /// Move an entry into a folder (or to the root when [folderId] is null).
  Future<void> moveEntry(String videoUri, String? folderId) async {
    final entries = await loadEntries();
    final i = entries.indexWhere((e) => e.videoUri == videoUri);
    if (i == -1) return;
    entries[i] = entries[i]
        .copyWith(folderId: folderId, clearFolder: folderId == null);
    await saveEntries(entries);
  }

  /// Move several entries in ONE read-modify-write. Calling [moveEntry] in
  /// a loop would reload and rewrite the whole list once per item (N loads
  /// + N saves for N items); this does it once.
  Future<void> moveEntries(Set<String> videoUris, String? folderId) async {
    if (videoUris.isEmpty) return;
    final entries = await loadEntries();
    var changed = false;
    for (var i = 0; i < entries.length; i++) {
      if (videoUris.contains(entries[i].videoUri)) {
        entries[i] = entries[i]
            .copyWith(folderId: folderId, clearFolder: folderId == null);
        changed = true;
      }
    }
    if (changed) await saveEntries(entries);
  }

  /// Delete several vaulted files (erasing each from disk) and drop them
  /// from the index in ONE save. Disk deletes are best-effort per file;
  /// the index is rewritten once at the end.
  Future<void> deleteVaultedBatch(List<PrivateEntry> items) async {
    if (items.isEmpty) return;
    final scanned = <String>[];
    for (final e in items) {
      final vp = e.vaultPath;
      if (vp != null) {
        try {
          final f = File(vp);
          if (await f.exists()) await f.delete();
          scanned.add(vp);
        } catch (err) {
          if (kDebugMode) {
            debugPrint('private_folder_service.deleteBatch: $err');
          }
        }
      }
    }
    final uris = items.map((e) => e.videoUri).toSet();
    final entries = await loadEntries();
    entries.removeWhere((e) => uris.contains(e.videoUri));
    await saveEntries(entries);
    if (scanned.isNotEmpty) await _mediaScan(scanned);
  }

  /// Rename a vaulted entry's display title (does not touch the file on
  /// disk — only the label shown in the vault). No-op if the entry is
  /// missing or the new name is blank.
  Future<void> renameEntry(String videoUri, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) return;
    final entries = await loadEntries();
    final i = entries.indexWhere((e) => e.videoUri == videoUri);
    if (i < 0) return;
    entries[i] = entries[i].copyWith(videoTitle: trimmed);
    await saveEntries(entries);
  }

  Future<int> folderItemCount(String folderId) async {
    final entries = await loadEntries();
    return entries.where((e) => e.folderId == folderId).length;
  }

  // === Real vaulting (move file into app-private sandbox) ===
  //
  // Upgrades the old "soft hide" (URI tracked, file left in place) to
  // genuine privacy: the video is COPIED into the app's internal
  // support dir (not indexed by MediaStore, not visible to other apps
  // or file managers without root), VERIFIED byte-for-byte by length,
  // and only THEN is the original deleted. The copy-verify-delete order
  // is deliberate — if anything fails we keep the original, so a failed
  // lock can never lose the user's only copy. Files whose URI can't be
  // resolved to a real path (content:// system-managed) fall back to the
  // old soft-hide behaviour with vaultPath == null.

  /// Resolve a video URI to an on-disk path, or null for system-managed
  /// (content://) URIs that dart:io can't open directly.
  String? resolveFilePath(String uri) {
    if (uri.startsWith('file://')) {
      try {
        return Uri.parse(uri).toFilePath();
      } catch (_) {
        return null;
      }
    }
    if (uri.startsWith('/')) return uri;
    return null;
  }

  /// Free bytes on the volume that holds the vault, or -1 when unknown.
  ///
  /// WHY THE VAULT NEEDS ITS OWN ANSWER, not the Transfer receiver's:
  /// vaulting COPIES into `getApplicationSupportDirectory()` - app-internal
  /// storage - while the receiver writes to public external storage. They are
  /// usually the same physical volume and are not required to be, and a
  /// free-space check against the wrong volume is worse than none: it reports
  /// a reassuring number about somewhere else.
  ///
  /// Uses the same native `freeBytes` channel the receiver has used since the
  /// day a Wi-Fi transfer filled a disk on the last file of a 200-file batch.
  /// The vault has exactly that failure available to it and had no guard.
  Future<int> freeSpaceBytes() async {
    try {
      final dir = await _vaultDir();
      final v = await const MethodChannel('mx_clone/media_scan')
          .invokeMethod<int>('freeBytes', <String, dynamic>{'dir': dir.path});
      return v ?? -1;
    } catch (e) {
      if (kDebugMode) debugPrint('PrivateFolderService.freeSpace: $e');
      return -1;
    }
  }

  Future<Directory> _vaultDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'private_vault'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // Belt-and-suspenders: mark the folder so any media scanner that
    // could reach it skips indexing.
    final noMedia = File(p.join(dir.path, '.nomedia'));
    if (!await noMedia.exists()) {
      try {
        await noMedia.create();
      } catch (e) { if (kDebugMode) debugPrint('private_folder_service.best-effort: $e'); }
    }
    return dir;
  }

  /// A cheap content fingerprint: SHA-256 over the file length + up to the
  /// first and last 64 KB. Reading only the ends keeps this fast even for
  /// multi-gigabyte videos while still detecting truncation and edge
  /// corruption that a length check alone would miss.
  Future<String> _fileSignature(File f, int len) async {
    const window = 64 * 1024;
    final raf = await f.open();
    try {
      final head = await raf.read(window < len ? window : len);
      List<int> tail = const [];
      if (len > window) {
        final tailStart = len - window;
        await raf.setPosition(tailStart);
        tail = await raf.read(window);
      }
      final digest = sha256.convert([
        ...utf8.encode('$len:'),
        ...head,
        ...tail,
      ]);
      return digest.toString();
    } finally {
      await raf.close();
    }
  }

  /// Copy [src] to [destPath], reporting progress and honouring cancel.
  ///
  /// Why not `File.copy()`: it returns one Future and nothing else. There is
  /// no byte count to show, no point at which a user's "Cancel" can take
  /// effect, and — the part that actually bites — when it throws (storage
  /// full is the common one) the bytes it already wrote stay on disk. Nothing
  /// in the vault index points at them, so they are invisible to the user and
  /// permanent. A 4 GB film that failed to import silently costs 4 GB
  /// forever.
  ///
  /// Streaming fixes all three. `addStream` applies back-pressure, so memory
  /// stays flat regardless of file size, and the counting `map` sits in the
  /// middle of the pipe where every chunk must pass. The partial file is
  /// deleted on ANY abnormal exit, cancel included.
  Future<void> _copyWithProgress(
    File src,
    String destPath,
    int total, {
    void Function(int copied, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final dest = File(destPath);
    IOSink? sink;
    var copied = 0;
    try {
      sink = dest.openWrite();
      // Throwing from inside the map aborts addStream, which unwinds into the
      // catch below — the same path a disk error takes, so cleanup is shared.
      final counted = src.openRead().map<List<int>>((chunk) {
        if (isCancelled != null && isCancelled()) {
          throw const VaultCancelled();
        }
        copied += chunk.length;
        onProgress?.call(copied, total);
        return chunk;
      });
      await sink.addStream(counted);
      await sink.flush();
      await sink.close();
      sink = null;
    } catch (_) {
      // Close first: on Android an unclosed sink keeps the fd open and the
      // delete below can fail, which would defeat the entire point.
      if (sink != null) {
        try {
          await sink.close();
        } catch (e) {
          if (kDebugMode) debugPrint('private_folder_service.sink: $e');
        }
      }
      try {
        if (await dest.exists()) await dest.delete();
      } catch (e) {
        if (kDebugMode) debugPrint('private_folder_service.partial: $e');
      }
      rethrow;
    }
  }

  String _randomVaultName(int length) {
    const charset = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random.secure();
    return List.generate(
        length, (_) => charset[rnd.nextInt(charset.length)]).join();
  }

  /// Move a video into the vault. Returns the created entry. Safe by
  /// construction: the original is deleted only after a verified copy.
  Future<PrivateEntry> importToVault({
    required String videoUri,
    required String videoTitle,
    String? folderId,
    void Function(int copied, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    // Android/data files (adb:// uris) aren't reachable via dart:io — they live
    // in another app's private storage and are only readable over ADB. To make
    // the vault work WITHOUT a live ADB connection afterwards, we first pull the
    // file's bytes out to a real local path, then vault THAT (copy + verify +
    // delete the temp). The result is a self-contained copy inside the app's
    // private vault that plays whether or not iADB is connected.
    if (videoUri.startsWith('adb://')) {
      return _importAdbToVault(
        videoUri: videoUri,
        videoTitle: videoTitle,
        folderId: folderId,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }
    final srcPath = resolveFilePath(videoUri);
    // Fallback: unresolvable URI → soft-hide only (old behaviour).
    if (srcPath == null) {
      final entry = PrivateEntry(
        videoUri: videoUri,
        videoTitle: videoTitle,
        addedAt: DateTime.now(),
        folderId: folderId,
      );
      await addEntry(entry);
      return entry;
    }
    final src = File(srcPath);
    if (!await src.exists()) {
      // Source already gone — record a soft entry so the UI is honest.
      final entry = PrivateEntry(
        videoUri: videoUri,
        videoTitle: videoTitle,
        addedAt: DateTime.now(),
        folderId: folderId,
      );
      await addEntry(entry);
      return entry;
    }

    final srcLen = await src.length();
    final dir = await _vaultDir();
    final ext = p.extension(srcPath);
    final destPath = p.join(dir.path, '${_randomVaultName(24)}$ext');

    // 1) Non-destructive copy — streamed, so the caller can show real
    //    progress and the user can stop a large import part-way.
    await _copyWithProgress(src, destPath, srcLen,
        onProgress: onProgress, isCancelled: isCancelled);

    // 2) Verify the copy before touching the original. Length alone can't
    //    distinguish a same-size corruption, and hashing a multi-GB video
    //    end-to-end would double the read I/O — so we check length PLUS a
    //    content fingerprint of the head + tail (64 KB each). That catches
    //    truncation, partial writes and head/tail corruption cheaply,
    //    while staying fast on large files.
    final dest = File(destPath);
    final destLen = await dest.length();
    final srcSig = await _fileSignature(src, srcLen);
    final destSig = await _fileSignature(dest, destLen);
    if (destLen != srcLen || srcLen == 0 || srcSig != destSig) {
      // Bad copy — clean up and abort WITHOUT deleting the original.
      try {
        await dest.delete();
      } catch (e) { if (kDebugMode) debugPrint('private_folder_service.best-effort: $e'); }
      throw Exception(
          'Vault copy verification failed (integrity) — original kept.');
    }

    // 3) Only now remove the original. If this fails (no permission),
    // we still keep the vault copy and flag it so the UI can warn that
    // the original is still on the device.
    bool originalRemoved = false;
    try {
      await src.delete();
      originalRemoved = true;
      // Privacy: purge the now-dangling MediaStore row so the video's
      // title/thumbnail vanishes from Gallery and other apps at once.
      await _mediaScan([srcPath]);
    } catch (_) {
      originalRemoved = false;
    }

    final entry = PrivateEntry(
      videoUri: videoUri,
      videoTitle: videoTitle,
      addedAt: DateTime.now(),
      vaultPath: destPath,
      originalRemoved: originalRemoved,
      folderId: folderId,
    );
    await addEntry(entry);
    return entry;
  }

  /// Vault an Android/data file reached over ADB (adb:// uri). Pulls the bytes
  /// to a local temp path first (needs a live ADB connection at THIS moment),
  /// then copies + verifies into the vault and deletes the temp. Afterwards the
  /// vault copy is fully local, so it opens with no ADB connection. The
  /// original in the other app's Android/data is left untouched (we can't and
  /// shouldn't delete another app's cache). Falls back to a soft-hide entry if
  /// the pull fails (e.g. connection dropped), so the UI stays honest.
  Future<PrivateEntry> _importAdbToVault({
    required String videoUri,
    required String videoTitle,
    String? folderId,
    void Function(int copied, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final src = videoUri.substring('adb://'.length);
    String pulled;
    try {
      pulled = await AdbService.instance.pullForPlayback(src);
    } catch (e) {
      pulled = 'ERROR: $e';
    }
    if (pulled.startsWith('ERROR')) {
      // Couldn't pull (no connection / read failure) — record a soft entry so
      // the item still appears, and surface the failure to the caller's
      // ok/failed tally by throwing.
      throw Exception('Could not pull Android/data file over ADB — '
          'connect iADB and try again.');
    }

    final tmp = File(pulled);
    if (!await tmp.exists()) {
      throw Exception('Pulled file missing — vault import aborted.');
    }
    final srcLen = await tmp.length();
    final dir = await _vaultDir();
    // Prefer the real extension from the source path; fall back to the pulled
    // temp's extension.
    final ext =
        p.extension(src).isNotEmpty ? p.extension(src) : p.extension(pulled);
    final destPath = p.join(dir.path, '${_randomVaultName(24)}$ext');

    // Copy the pulled bytes into the vault, then verify (length + head/tail
    // fingerprint) exactly like the on-device path.
    await _copyWithProgress(tmp, destPath, srcLen,
        onProgress: onProgress, isCancelled: isCancelled);
    final dest = File(destPath);
    final destLen = await dest.length();
    final srcSig = await _fileSignature(tmp, srcLen);
    final destSig = await _fileSignature(dest, destLen);
    if (destLen != srcLen || srcLen == 0 || srcSig != destSig) {
      try {
        await dest.delete();
      } catch (e) {
        if (kDebugMode) debugPrint('private_folder_service.best-effort: $e');
      }
      // Clean up the temp too before aborting.
      try {
        await tmp.delete();
      } catch (_) {}
      throw Exception('Vault copy verification failed (integrity).');
    }

    // Remove the pulled temp — the vault now holds the only local copy.
    try {
      await tmp.delete();
    } catch (e) {
      if (kDebugMode) debugPrint('private_folder_service.best-effort: $e');
    }

    final entry = PrivateEntry(
      videoUri: videoUri,
      videoTitle: videoTitle,
      addedAt: DateTime.now(),
      vaultPath: destPath,
      // The Android/data original is another app's cache — we never delete it,
      // so it's honestly "not removed", but the vault copy is self-contained.
      originalRemoved: false,
      folderId: folderId,
    );
    await addEntry(entry);
    return entry;
  }
  /// entries (which are simply un-hidden). Non-destructive: the vault
  /// copy is deleted only after a verified copy back out.
  static const MethodChannel _scanChannel =
      MethodChannel('mx_clone/media_scan');

  /// Ask Android to rescan these paths so the MediaStore index reflects
  /// reality (drop rows for vaulted files, add rows for restored ones).
  /// Best-effort and Android-only.
  Future<void> _mediaScan(List<String> paths) async {
    try {
      await _scanChannel.invokeMethod('scan', {'paths': paths});
    } catch (e) {
      if (kDebugMode) debugPrint('private_folder_service.scan: $e');
    }
  }

  Future<String?> restoreFromVault(
    PrivateEntry e, {
    void Function(int copied, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final vp = e.vaultPath;
    if (vp == null) {
      // Legacy soft-hide entry — nothing was moved, just un-hide.
      await removeEntry(e.videoUri);
      return null;
    }
    final vaultFile = File(vp);
    if (!await vaultFile.exists()) {
      await removeEntry(e.videoUri);
      return null;
    }

    // Restore to the original folder when its path is still writable,
    // otherwise fall back to the public Movies dir / app docs.
    final origPath = resolveFilePath(e.videoUri);
    // If the original was never deleted at import time (e.g. delete
    // permission was denied, so originalRemoved == false) and it's still
    // on disk, the vault copy is just a verified duplicate. Restoring then
    // means simply dropping the vault copy — copying a multi-GB file back
    // would only create a confusing "(restored)" twin alongside the
    // original that's already in place.
    if (!e.originalRemoved && origPath != null) {
      final orig = File(origPath);
      if (await orig.exists()) {
        try {
          await vaultFile.delete();
        } catch (e) { if (kDebugMode) debugPrint('private_folder_service.best-effort: $e'); }
        await removeEntry(e.videoUri);
        return origPath;
      }
    }
    Directory targetDir;
    String fileName;
    if (origPath != null) {
      targetDir = Directory(p.dirname(origPath));
      fileName = p.basename(origPath);
    } else {
      final ext = p.extension(vp);
      targetDir = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      fileName = '${e.videoTitle}$ext';
    }
    if (!await targetDir.exists()) {
      targetDir = await getApplicationDocumentsDirectory();
    }

    var destPath = p.join(targetDir.path, fileName);
    if (await File(destPath).exists()) {
      final base = p.basenameWithoutExtension(fileName);
      final ext = p.extension(fileName);
      destPath = p.join(targetDir.path, '$base (restored)$ext');
    }

    await _copyWithProgress(
        vaultFile, destPath, await vaultFile.length(),
        onProgress: onProgress, isCancelled: isCancelled);
    final restored = File(destPath);
    if (await restored.length() != await vaultFile.length()) {
      // Restore copy failed verification — keep the vault copy, abort.
      try {
        await restored.delete();
      } catch (e) { if (kDebugMode) debugPrint('private_folder_service.best-effort: $e'); }
      throw Exception('Restore copy verification failed — vault copy kept.');
    }
    try {
      await vaultFile.delete();
    } catch (e) { if (kDebugMode) debugPrint('private_folder_service.best-effort: $e'); }
    // Re-index the restored file so it shows up again in Gallery / other
    // players immediately (mirror of the purge done on lock).
    await _mediaScan([destPath]);
    await removeEntry(e.videoUri);
    return destPath;
  }

  /// Delete a vaulted file outright (used when the user removes an entry
  /// and does NOT want it back). Removes both the vault copy and entry.
  Future<void> deleteVaulted(PrivateEntry e) async {
    final vp = e.vaultPath;
    if (vp != null) {
      try {
        final f = File(vp);
        if (await f.exists()) await f.delete();
      } catch (e) { if (kDebugMode) debugPrint('private_folder_service.best-effort: $e'); }
    }
    await removeEntry(e.videoUri);
  }
}

// ═══════════════════════════════════════════════════════════════════
// PBKDF2-HMAC-SHA256, top-level so `compute` can run it on an isolate.
// ═══════════════════════════════════════════════════════════════════

/// One derivation. Args are [pin, salt, rounds] as strings because a plain
/// list of strings is unambiguously sendable across every isolate API.
String _pbkdf2Worker(List<String> args) {
  return _pbkdf2Sha256(
    password: args[0],
    salt: args[1],
    rounds: int.tryParse(args[2]) ?? 20000,
  );
}

/// Timing probe: how many MICROSECONDS this device needs for [rounds].
int _pbkdf2ProbeWorker(int rounds) {
  final sw = Stopwatch()..start();
  _pbkdf2Sha256(password: 'probe', salt: 'probe', rounds: rounds);
  sw.stop();
  return sw.elapsedMicroseconds;
}

/// Textbook PBKDF2 with a 32-byte output, so exactly one block is needed:
///
///   DK = U(1) xor U(2) xor ... xor U(c)
///   U(1) = HMAC(P, S || INT_BE(1))
///   U(i) = HMAC(P, U(i-1))
///
/// Written out rather than pulled from a package because the whole point is
/// that it stays readable and auditable — this is the function standing
/// between a stolen hash and the user's PIN.
String _pbkdf2Sha256({
  required String password,
  required String salt,
  required int rounds,
}) {
  final hmac = Hmac(sha256, utf8.encode(password));
  // Block index 1, big-endian, appended to the salt per the spec.
  final firstInput = <int>[...utf8.encode(salt), 0, 0, 0, 1];
  var u = hmac.convert(firstInput).bytes;
  final out = List<int>.from(u);
  for (var i = 1; i < rounds; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  final buf = StringBuffer();
  for (final b in out) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

/// A private folder entry. When [vaultPath] is set the underlying file
/// was physically moved into the app-private vault (real privacy); when
/// null this is a legacy "soft-hide" entry (file still at [videoUri]).
class PrivateEntry {
  final String videoUri;
  final String videoTitle;
  final DateTime addedAt;

  /// Absolute path inside the app-private vault, or null for soft-hide.
  final String? vaultPath;

  /// Whether the original file was successfully deleted after vaulting.
  /// False means a vault copy exists but the original is still on the
  /// device (e.g. delete permission was denied).
  final bool originalRemoved;

  /// Organiser folder this entry lives in, or null for the vault root.
  final String? folderId;

  const PrivateEntry({
    required this.videoUri,
    required this.videoTitle,
    required this.addedAt,
    this.vaultPath,
    this.originalRemoved = false,
    this.folderId,
  });

  PrivateEntry copyWith({
    String? videoTitle,
    String? vaultPath,
    bool? originalRemoved,
    String? folderId,
    bool clearFolder = false,
  }) =>
      PrivateEntry(
        videoUri: videoUri,
        videoTitle: videoTitle ?? this.videoTitle,
        addedAt: addedAt,
        vaultPath: vaultPath ?? this.vaultPath,
        originalRemoved: originalRemoved ?? this.originalRemoved,
        folderId: clearFolder ? null : (folderId ?? this.folderId),
      );

  /// The path to actually play from: the vault copy when present,
  /// otherwise the original URI.
  String get playablePath => vaultPath ?? videoUri;

  bool get isVaulted => vaultPath != null;

  Map<String, dynamic> toJson() => {
        'videoUri': videoUri,
        'videoTitle': videoTitle,
        'addedAt': addedAt.millisecondsSinceEpoch,
        if (vaultPath != null) 'vaultPath': vaultPath,
        'originalRemoved': originalRemoved,
        if (folderId != null) 'folderId': folderId,
      };

  factory PrivateEntry.fromJson(Map<String, dynamic> j) => PrivateEntry(
        videoUri: j['videoUri'] as String,
        videoTitle: j['videoTitle'] as String,
        addedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['addedAt'] as num).toInt()),
        vaultPath: j['vaultPath'] as String?,
        originalRemoved: (j['originalRemoved'] as bool?) ?? false,
        folderId: j['folderId'] as String?,
      );
}

/// An organiser folder inside the Private Folder (v0.51). Pure metadata —
/// files stay in one flat vault dir, so membership is just [PrivateEntry.
/// folderId]. This keeps "move to folder" instant and never risks a file
/// copy.
class PrivateFolderMeta {
  final String id;
  final String name;
  final DateTime createdAt;

  const PrivateFolderMeta({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  PrivateFolderMeta copyWith({String? name}) => PrivateFolderMeta(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory PrivateFolderMeta.fromJson(Map<String, dynamic> j) =>
      PrivateFolderMeta(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num).toInt()),
      );
}
