import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What this phone's connection last actually delivered, in kilobits/second.
///
/// WHY IT IS REMEMBERED AT ALL. The rung a viewer should receive depends on
/// their bandwidth, and bandwidth cannot be known at the moment it is first
/// needed: the decision is made BEFORE the first byte of the film is
/// requested. Measuring during playback and remembering it means the second
/// film opens at the right size, and the third, and every one after.
///
/// THE MEASUREMENT IS LIBMPV'S, NOT A SPEED TEST. `cache-speed` is how fast
/// bytes were arriving while a real video was playing over the real path —
/// the same Worker, the same R2 bucket, the same tower. A generic speed test
/// measures a different server on a different route and reports a number
/// that is true about nothing this app does.
///
/// IT MOVES TOWARDS A NEW READING RATHER THAN REPLACING IT. One sample taken
/// in a lift would otherwise pin every future playback to the smallest rung
/// until something happened to overwrite it. A weighted average follows a
/// genuine change in circumstances over a couple of films and shrugs off a
/// single bad moment.
///
/// IT IS A CACHE, NOT A RECORD. A wrong value costs one playback opened at
/// the wrong size, which the stall watchdog then corrects. Every access is
/// wrapped: on a device where preferences cannot be read at all this reports
/// "never measured" and the caller uses its own default.
class ThroughputMemory {
  ThroughputMemory._();

  static const String _key = 'net.throughput_kbps';

  /// How much of a new reading replaces the old one, when the news is good.
  ///
  /// A THIRD. Three consecutive films on a genuinely better connection move
  /// the estimate most of the way there; one lucky burst moves it a third of
  /// the way and is undone by the next normal reading. Rising slowly is the
  /// safe direction: over-estimating hands somebody a rung their connection
  /// cannot carry, which is the stutter all of this exists to end.
  static const double _weightUp = 1 / 3;

  /// And when the news is bad.
  ///
  /// THREE QUARTERS, BECAUSE THE TWO DIRECTIONS ARE NOT SYMMETRIC. Somebody
  /// who walks out of their wifi and onto the street has not had a bad
  /// moment, they have a different connection — and a symmetric average
  /// would take three films to notice, which is three films of stuttering.
  /// Over-reacting downwards costs a picture that is softer than it needed
  /// to be for one film, and the next reading corrects it.
  ///
  /// This app has no way to tell wifi from mobile — that needs a plugin the
  /// project deliberately does not carry — so this asymmetry is the whole
  /// mechanism for noticing that the connection changed.
  static const double _weightDown = 3 / 4;

  /// Readings outside these are not measurements, they are artefacts. A
  /// reading taken in the first moment of a stall can be near zero because
  /// nothing is in flight yet, and one taken while a buffer drains from
  /// local memory can read as hundreds of megabits.
  static const int _floorKbps = 120;
  static const int _ceilingKbps = 200000;

  static int? _cached;
  static bool _loaded = false;

  /// The last known estimate, or null when nothing credible has been seen.
  static Future<int?> read() async {
    if (_loaded) return _cached;
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getInt(_key);
      _cached = (v != null && v >= _floorKbps) ? v : null;
    } catch (e) {
      if (kDebugMode) debugPrint('throughput read failed: $e');
      _cached = null;
    }
    _loaded = true;
    return _cached;
  }

  /// The estimate as it stands, without waiting for storage.
  ///
  /// The choice of rung happens on the path to opening a video, and a disk
  /// read there is a delay in exactly the place this project has spent weeks
  /// removing delays from. [read] warms this once; the decision uses this.
  static int? get current => _cached;

  /// Fold in a new measurement.
  static Future<void> observe(int kbps) async {
    if (kbps < _floorKbps || kbps > _ceilingKbps) return;
    final before = _cached;
    final weight = before == null || kbps >= before ? _weightUp : _weightDown;
    final next = before == null
        ? kbps
        : (before + (kbps - before) * weight).round();
    _cached = next;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_key, next);
    } catch (e) {
      if (kDebugMode) debugPrint('throughput write failed: $e');
    }
  }

  /// For tests, which must not inherit a value from another test.
  @visibleForTesting
  static void resetForTest({int? value}) {
    _cached = value;
    _loaded = true;
  }
}
