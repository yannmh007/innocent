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

  /// Never throws. An unreadable platform reads as [ConnectionKind.unknown].
  static Future<ConnectionKind> read() async {
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
