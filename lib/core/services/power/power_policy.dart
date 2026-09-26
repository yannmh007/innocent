import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the phone will and will not allow a download to do in the background.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS IS NOT ALREADY SOLVED BY THE FOREGROUND SERVICE
/// ═══════════════════════════════════════════════════════════════════════
///
/// `OfflineService` declares the transfer to Android, holds a partial WakeLock
/// and a WifiLock, and survives a swipe out of recents. On stock Android that
/// is the whole answer.
///
/// It is not the answer on the phones this app is used on. Xiaomi, Oppo, Vivo,
/// Realme and Huawei all ship battery managers that freeze or kill backgrounded
/// processes on a timer, by default, whether or not a foreground service is
/// running. A 900 MB film forty per cent downloaded stops, and the viewer — on
/// the mobile connection that made downloading the right answer — is told
/// nothing and concludes the app is broken.
///
/// No app can override that. Two things can be done and this is both of them:
/// ask once with the platform's own dialog, and otherwise SAY SO, next to the
/// download that stopped.
@immutable
class PowerState {
  /// False when Doze may defer this app's work while the phone is idle.
  /// The dialog fixes this one.
  final bool exempt;

  /// True when background work has been switched off for this app entirely.
  ///
  /// A SEPARATE FIELD AND NOT A FLAVOUR OF [exempt], because the fix is
  /// different and offering the wrong one wastes the only tap the user will
  /// give. The exemption dialog does not touch this; it is a per-app switch
  /// under Battery, so the only honest action is to open that page.
  final bool restricted;

  /// So the message can name the phone. The settings page that actually
  /// matters is called something different on every one of these ROMs, and a
  /// viewer told "your phone is restricting this" learns nothing.
  final String manufacturer;

  final int sdk;

  const PowerState({
    this.exempt = true,
    this.restricted = false,
    this.manufacturer = '',
    this.sdk = 0,
  });

  /// What to assume when the platform cannot be read.
  ///
  /// PERMISSIVE, and the asymmetry is the point: a card telling somebody to fix
  /// a problem they do not have is worse than silence, because the thing on
  /// their screen is a download that is working.
  static const PowerState unknown = PowerState();

  /// True when there is something worth telling the user about.
  bool get restrictsDownloads => restricted || !exempt;
}

class PowerPolicy {
  const PowerPolicy._();

  static const MethodChannel _channel = MethodChannel('mx_clone/power_policy');

  /// Cached for the process, because it is read to decide whether to draw a
  /// card and a card must not cost a platform call per rebuild.
  ///
  /// INVALIDATED BY [read] WITH `fresh: true`, which is what the screen does
  /// after the user comes back from the dialog — the answer has changed and the
  /// cached one would leave the card on screen saying the problem is still
  /// there.
  static PowerState? _cached;

  static PowerState get cached => _cached ?? PowerState.unknown;

  /// Never throws. An unreadable platform reads as [PowerState.unknown].
  static Future<PowerState> read({bool fresh = false}) async {
    if (!fresh) {
      final have = _cached;
      if (have != null) return have;
    }
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) {
      // No platform to ask, and nothing on a desktop or a test run defers a
      // download.
      _cached = PowerState.unknown;
      return PowerState.unknown;
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('read');
      if (raw == null) return PowerState.unknown;
      final state = PowerState(
        // ABSENT READS AS PERMISSIVE for both, for the reason on
        // PowerState.unknown: a missing field must not invent a warning.
        exempt: raw['exempt'] != false,
        restricted: raw['restricted'] == true,
        manufacturer: '${raw['manufacturer'] ?? ''}',
        sdk: raw['sdk'] is int ? raw['sdk'] as int : 0,
      );
      _cached = state;
      return state;
    } catch (e) {
      if (kDebugMode) debugPrint('PowerPolicy.read: $e');
      return PowerState.unknown;
    }
  }

  /// Shows the system dialog that asks for the Doze exemption.
  ///
  /// Returns false when there was nothing to ask — already exempt, or no
  /// activity to show it over. It is deliberately not retried and not looped:
  /// the dialog is the user's decision, and an app that reopens it is an app
  /// people uninstall.
  static Future<bool> requestExemption() async {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('open');
      // The answer has changed, or the user declined; either way the cached
      // one is now a guess.
      _cached = null;
      return ok == true;
    } catch (e) {
      if (kDebugMode) debugPrint('PowerPolicy.requestExemption: $e');
      return false;
    }
  }

  /// Opens this app's own settings page, for the case the dialog cannot fix.
  ///
  /// `restricted` is switched by hand and can only be switched back by hand, so
  /// the honest action is to put the user on the page that holds the switch.
  /// App details rather than the OEM's own battery list: that page exists under
  /// that name on every ROM, and guessing at an activity name per manufacturer
  /// is how a button starts crashing on a phone nobody here owns.
  static Future<bool> openSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('settings');
      _cached = null;
      return ok == true;
    } catch (e) {
      if (kDebugMode) debugPrint('PowerPolicy.openSettings: $e');
      return false;
    }
  }

  @visibleForTesting
  static void resetForTest() => _cached = null;
}
