import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Dart side of the Turbo direct link (see TurboLink.kt).
///
/// Everything here is best-effort by design: Turbo is an accelerator, and a
/// phone that can't do it must still transfer over ordinary Wi-Fi. So every
/// call returns a result object rather than throwing, and every failure
/// carries a [reason] that the UI turns into a sentence the user can act on
/// ("turn Wi-Fi on", "turn Location on") instead of a dead end.
class TurboLink {
  TurboLink._();
  static final TurboLink instance = TurboLink._();

  static const MethodChannel _ch = MethodChannel('mx_clone/turbo');

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Cached from [preconditions] so the permission choice doesn't need an
  /// extra platform round trip every time.
  int _sdk = 0;

  Future<TurboPreconditions> preconditions() async {
    if (!_supported) {
      return const TurboPreconditions(
          wifiOn: false, locationOn: false, sdk: 0, supported: false);
    }
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('preconditions');
      _sdk = (m?['sdk'] as num?)?.toInt() ?? 0;
      return TurboPreconditions(
        wifiOn: m?['wifi'] == true,
        locationOn: m?['location'] == true,
        sdk: _sdk,
        // Wi-Fi Direct groups need API 29; a local-only hotspot needs 26.
        supported: _sdk >= 26,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('TurboLink.preconditions: $e');
      return const TurboPreconditions(
          wifiOn: false, locationOn: false, sdk: 0, supported: false);
    }
  }

  /// Ask for whichever permission this Android version actually gates the
  /// Wi-Fi peer APIs behind.
  ///
  /// Android 13 moved these calls from ACCESS_FINE_LOCATION to
  /// NEARBY_WIFI_DEVICES. Requesting the wrong one is silently useless: the
  /// dialog appears, the user says yes, and createGroup still throws
  /// SecurityException.
  Future<bool> ensurePermission() async {
    if (!_supported) return false;
    if (_sdk == 0) await preconditions();
    try {
      final perm =
          _sdk >= 33 ? Permission.nearbyWifiDevices : Permission.location;
      var status = await perm.status;
      if (status.isGranted) return true;
      status = await perm.request();
      return status.isGranted;
    } catch (e) {
      if (kDebugMode) debugPrint('TurboLink.ensurePermission: $e');
      return false;
    }
  }

  Future<void> openSettings(String which) async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod('openSettings', {'which': which});
    } catch (_) {}
  }

  // ---- host ------------------------------------------------------------

  Future<TurboHostResult> hostStart() async {
    if (!_supported) {
      return const TurboHostResult(ok: false, reason: 'unsupported');
    }
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('hostStart');
      if (m == null || m['ok'] != true) {
        return TurboHostResult(
            ok: false, reason: (m?['reason'] as String?) ?? 'unknown');
      }
      return TurboHostResult(
        ok: true,
        mode: m['mode'] as String? ?? '',
        ssid: m['ssid'] as String?,
        passphrase: m['pass'] as String?,
        ip: m['ip'] as String?,
        band: m['band'] as String? ?? '',
        staWasConnected: m['staConnected'] == true,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('TurboLink.hostStart: $e');
      return const TurboHostResult(ok: false, reason: 'platform_error');
    }
  }

  Future<void> hostStop() async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod('hostStop');
    } catch (e) {
      if (kDebugMode) debugPrint('TurboLink.hostStop: $e');
    }
  }

  // ---- join ------------------------------------------------------------

  Future<TurboJoinResult> joinStart(String ssid, String passphrase) async {
    if (!_supported) {
      return const TurboJoinResult(ok: false, reason: 'unsupported');
    }
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>(
          'joinStart', {'ssid': ssid, 'pass': passphrase});
      if (m == null || m['ok'] != true) {
        return TurboJoinResult(
            ok: false, reason: (m?['reason'] as String?) ?? 'unknown');
      }
      return TurboJoinResult(
          ok: true,
          bound: m['bound'] == true,
          mode: m['mode'] as String? ?? '');
    } catch (e) {
      if (kDebugMode) debugPrint('TurboLink.joinStart: $e');
      return const TurboJoinResult(ok: false, reason: 'platform_error');
    }
  }

  /// Always safe to call, and MUST be called once a Turbo receive is over:
  /// while joined, the whole process is pinned to a network with no internet,
  /// so every other feature in the app (downloader, subtitle fetch) would fail
  /// until this runs.
  Future<void> joinStop() async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod('joinStop');
    } catch (e) {
      if (kDebugMode) debugPrint('TurboLink.joinStop: $e');
    }
  }

  /// Path to Innocent's own APK, so the app can be handed to a phone that
  /// doesn't have it — over the very link this file sets up, with no internet
  /// involved anywhere.
  Future<TurboSelfApk?> selfApk() async {
    if (!_supported) return null;
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('selfApk');
      final path = m?['path'] as String?;
      if (path == null || path.isEmpty) return null;
      return TurboSelfApk(
        path: path,
        sizeBytes: (m?['size'] as num?)?.toInt() ?? 0,
        name: m?['name'] as String? ?? 'Innocent.apk',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('TurboLink.selfApk: $e');
      return null;
    }
  }
}

class TurboPreconditions {
  final bool wifiOn;
  final bool locationOn;
  final int sdk;
  final bool supported;
  const TurboPreconditions({
    required this.wifiOn,
    required this.locationOn,
    required this.sdk,
    required this.supported,
  });
}

class TurboHostResult {
  final bool ok;
  final String reason;
  final String mode; // p2p | lohs
  final String? ssid;
  final String? passphrase;
  final String? ip;

  /// "5", "2.4" or "" — measured from the group's real frequency, never from
  /// the band we requested.
  ///
  /// The distinction is the whole ballgame. Most Wi-Fi chips only do single
  /// channel concurrency, so with this phone connected to a 2.4 GHz router the
  /// group owner is dragged onto 2.4 GHz and `createGroup` still reports
  /// success. Labelling that "5 GHz" because we asked for 5 GHz would promise
  /// the user roughly four times the speed the radio can actually deliver.
  final String band;

  /// This phone was on a Wi-Fi network when the link came up — the condition
  /// that causes the band to be forced. Lets the UI explain a 2.4 GHz result
  /// instead of leaving it looking like a defect.
  final bool staWasConnected;

  const TurboHostResult({
    required this.ok,
    this.reason = '',
    this.mode = '',
    this.ssid,
    this.passphrase,
    this.ip,
    this.band = '',
    this.staWasConnected = false,
  });

  bool get isFiveGhz => band == '5';
}

class TurboJoinResult {
  final bool ok;
  final String reason;
  final bool bound;
  final String mode; // specifier | legacy
  const TurboJoinResult({
    required this.ok,
    this.reason = '',
    this.bound = false,
    this.mode = '',
  });
}

class TurboSelfApk {
  final String path;
  final int sizeBytes;
  final String name;
  const TurboSelfApk(
      {required this.path, required this.sizeBytes, required this.name});
}

/// Everything the receiving phone needs, packed into one QR code.
///
/// A custom scheme rather than the plain share URL, because under Turbo the
/// receiver has to join a Wi-Fi network before any URL is reachable at all —
/// so the credentials have to travel with the address. Plain http:// QR codes
/// still work and still mean "same network, just connect", which keeps every
/// older build of Innocent compatible with a new one.
class TurboInvite {
  final String ssid;
  final String passphrase;
  final String host;
  final int port;
  final String token;
  final String senderName;
  final String mode;

  const TurboInvite({
    required this.ssid,
    required this.passphrase,
    required this.host,
    required this.port,
    required this.token,
    required this.senderName,
    required this.mode,
  });

  static const String scheme = 'innocent';
  static const String hostPart = 'turbo';

  String encode() => Uri(
        scheme: scheme,
        host: hostPart,
        queryParameters: {
          's': ssid,
          'p': passphrase,
          'h': host,
          'o': '$port',
          'k': token,
          'n': senderName,
          'm': mode,
        },
      ).toString();

  /// Returns null when [raw] isn't a Turbo invite (e.g. a plain share URL),
  /// which the caller treats as "same-network connect" instead of an error.
  static TurboInvite? tryParse(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('$scheme://$hostPart')) return null;
    try {
      final u = Uri.parse(trimmed);
      final q = u.queryParameters;
      final ssid = q['s'] ?? '';
      final host = q['h'] ?? '';
      final port = int.tryParse(q['o'] ?? '') ?? 0;
      final token = q['k'] ?? '';
      if (ssid.isEmpty || host.isEmpty || port <= 0 || token.isEmpty) {
        return null;
      }
      return TurboInvite(
        ssid: ssid,
        passphrase: q['p'] ?? '',
        host: host,
        port: port,
        token: token,
        senderName: q['n'] ?? 'Innocent phone',
        mode: q['m'] ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  String get baseUrl => 'http://$host:$port/$token';
}
