import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lets a cold start show the cached library WITHOUT rescanning it, when
/// MediaStore says nothing has changed since the last scan.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY
/// ═══════════════════════════════════════════════════════════════════════
///
/// Every launch used to re-read the whole library in the background, to
/// find out whether the cache it had just shown was still right: for the
/// all-videos list that is a MediaStore query plus one file lookup and one
/// stat per video. On the owner's phone (2000+ videos) report ZVDDRQQH
/// measured it at 54 % of a core for the first ten seconds of every launch
/// (photo_manager's pool thread 25 %, Dart 17 %, workers 9 %) — and in
/// almost every launch it found nothing new.
///
/// Android 11+ keeps a counter per storage volume that rises on every
/// insert, update and delete (`MediaStore.getGeneration`). Reading it costs
/// one IPC. If it is where it was when the cache was written, the cache is
/// what a scan would return, and the scan is skipped.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT KEEPS THIS SAFE
/// ═══════════════════════════════════════════════════════════════════════
///
/// * Only the FIRST load of each list in a process is ever skipped. Pull to
///   refresh, a delete, a move, a rename — every later invalidation scans
///   exactly as before.
/// * The stamp is read BEFORE a scan and saved after it, so a change that
///   lands while a scan runs makes the next launch scan again.
/// * The stamp carries MediaStore's version (changes when its database is
///   rebuilt) and whether video access is granted (revoking it counts as a
///   change).
/// * No stamp (Android 10 and older, an error) → scan, as always.
/// * A cache trusted this way is still rescanned at least once a day.
class ScanGate {
  ScanGate._();

  static const MethodChannel _channel = MethodChannel('mx_clone/media_scan');
  static const String _prefix = 'lib_scan_stamp_v1:';
  static const Duration maxTrust = Duration(hours: 24);

  static final Set<String> _decided = <String>{};

  /// Overridable in tests.
  @visibleForTesting
  static Future<String?> Function() readStamp = _readPlatformStamp;

  static Future<String?> _readPlatformStamp() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('generation');
    } catch (_) {
      return null;
    }
  }

  /// True when [key]'s cached list can be shown with no background scan.
  /// Answers true at most once per key per process.
  static Future<bool> trustCache(String key) async {
    if (!_decided.add(key)) return false;
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = sp.getString('$_prefix$key');
      if (saved == null) return false;
      final now = await readStamp();
      return trusts(saved: saved, current: now, clock: DateTime.now());
    } catch (_) {
      return false;
    }
  }

  /// The stamp to save after a scan — read it BEFORE the scan starts.
  static Future<String?> before() async {
    try {
      return await readStamp();
    } catch (_) {
      return null;
    }
  }

  /// Records that [key] was scanned when MediaStore stood at [stamp].
  static Future<void> record(String key, String? stamp) async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (stamp == null) {
        await sp.remove('$_prefix$key');
        return;
      }
      await sp.setString(
        '$_prefix$key',
        '${DateTime.now().millisecondsSinceEpoch}#$stamp',
      );
    } catch (_) {
      // Without a stamp the next launch scans, which is the old behaviour.
    }
  }

  /// Forgets every stamp (the cache itself was cleared).
  static Future<void> clear() async {
    try {
      final sp = await SharedPreferences.getInstance();
      for (final k in sp.getKeys().toList()) {
        if (k.startsWith(_prefix)) await sp.remove(k);
      }
    } catch (_) {}
  }

  /// The decision itself: [saved] is `"<epoch ms>#<stamp>"` as [record]
  /// wrote it, [current] is MediaStore's stamp now.
  @visibleForTesting
  static bool trusts({
    required String saved,
    required String? current,
    required DateTime clock,
  }) {
    if (current == null || current.isEmpty) return false;
    final hash = saved.indexOf('#');
    if (hash <= 0) return false;
    final at = int.tryParse(saved.substring(0, hash));
    if (at == null) return false;
    final age = clock.difference(DateTime.fromMillisecondsSinceEpoch(at));
    if (age.isNegative || age > maxTrust) return false;
    return saved.substring(hash + 1) == current;
  }

  @visibleForTesting
  static void resetForTest() => _decided.clear();
}
