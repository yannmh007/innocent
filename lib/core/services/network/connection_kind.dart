import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What kind of connection the phone is on right now.
@immutable
class ConnectionKind {
  /// `wifi`, `cellular`, `ethernet`, `vpn`, `other` or `none`.
  final String transport;

  /// True when using this connection costs the user by the megabyte.
  final bool metered;

  const ConnectionKind({required this.transport, required this.metered});

  /// What to assume when the platform cannot be read.
  ///
  /// METERED, AND `other` RATHER THAN `none`. The two mistakes are not
  /// symmetrical. Treating a free connection as metered costs somebody one
  /// settings toggle; treating a metered one as free costs them a data bundle
  /// on a film they never agreed to spend it on. And claiming there is no
  /// connection at all would make a Wi-Fi-only rule refuse a download on a
  /// phone that is perfectly online.
  static const ConnectionKind unknown =
      ConnectionKind(transport: 'other', metered: true);

  bool get isWifi => transport == 'wifi' || transport == 'ethernet';
  bool get isOffline => transport == 'none';

  @override
  String toString() => 'ConnectionKind($transport, metered=$metered)';
}

/// Asks Android what kind of connection this is.
///
/// ═══════════════════════════════════════════════════════════════════════
/// SEPARATE FROM [ConnectivityService], DELIBERATELY
/// ═══════════════════════════════════════════════════════════════════════
///
/// They answer different questions and cost different amounts. This one is a
/// synchronous platform read and says WHAT KIND of connection is attached;
/// `ConnectivityService.isOnline()` costs a DNS round trip and says WHETHER the
/// internet actually works — an interface can be attached, validated and
/// useless behind a captive portal or a SIM with no credit.
///
/// Conflating them would mean either paying for a DNS lookup to draw a label,
/// or drawing the label from an interface that is lying. The download path uses
/// both: this to decide whether it is allowed to spend, that to decide whether
/// it is worth trying.
class ConnectionInfo {
  const ConnectionInfo._();

  static const MethodChannel _channel = MethodChannel('mx_clone/net_info');

  /// The last answer, and when it was given.
  ///
  /// ONE SECOND, AND IT IS ABOUT DRAWING A SCREEN RATHER THAN SAVING WORK.
  /// Opening the hub asks this once per catalogue request — the rows, the
  /// facets, the categories, the detail behind a card — and each one is a
  /// platform channel hop that has to cross to the Android side and back
  /// before anything can be decided. Individually they are milliseconds;
  /// together, on the phones this app is for, they are the difference between
  /// a screen that appears and a screen that arrives.
  ///
  /// A second is short enough that nothing acts on a stale answer in a way a
  /// person would notice: the radio does not change state and get acted upon
  /// inside one frame of one screen. It is deliberately NOT a cached value
  /// with a listener — a stale answer here costs one screen drawn under the
  /// wrong assumption, while a subscription that leaks costs battery for as
  /// long as the app runs.
  static ConnectionKind? _last;
  static DateTime? _lastAt;
  static const Duration _memo = Duration(seconds: 1);

  /// Never throws. An unreadable platform reads as [ConnectionKind.unknown].
  static Future<ConnectionKind> read({bool fresh = false}) async {
    if (!fresh) {
      final was = _last;
      final at = _lastAt;
      if (was != null &&
          at != null &&
          DateTime.now().difference(at) < _memo) {
        return was;
      }
    }
    final answer = await _ask();
    _last = answer;
    _lastAt = DateTime.now();
    return answer;
  }

  static Future<ConnectionKind> _ask() async {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) {
      // No platform to ask. A desktop or test run is treated as unmetered
      // because there is no data bundle to protect, and as attached because
      // refusing to download on a developer machine would be absurd.
      return const ConnectionKind(transport: 'other', metered: false);
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('read');
      if (raw == null) return ConnectionKind.unknown;
      final transport = '${raw['transport'] ?? 'other'}';
      final metered = raw['metered'] as bool? ?? true;
      return ConnectionKind(transport: transport, metered: metered);
    } catch (e) {
      if (kDebugMode) debugPrint('ConnectionInfo.read: $e');
      return ConnectionKind.unknown;
    }
  }
}
