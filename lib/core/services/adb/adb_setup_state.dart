/// Where a phone stands on the way to Innocent's own ADB connection, as the
/// ADB screen's checklist shows it.
///
/// Read fresh from Settings each time (see `adbSetupState` in MainActivity):
/// the screen asks on resume and every couple of seconds while it is open,
/// so each line ticks as the person works through Settings, instead of them
/// having to guess which step they are on.
class AdbSetupState {
  const AdbSetupState({
    this.devOptions = false,
    this.wirelessDebugging = false,
    this.wifi = false,
    this.notifications = true,
    this.secureSettings = false,
    this.manufacturer = '',
    this.sdk = 0,
  });

  /// From the platform channel's map; anything missing or of the wrong type
  /// reads as "not yet", except notifications, which read as allowed (a
  /// missing answer must not tell the person to fix something that is fine).
  factory AdbSetupState.fromMap(Map<Object?, Object?>? m) {
    bool flag(String k, {bool or = false}) {
      final v = m?[k];
      return v is bool ? v : or;
    }

    final sdk = m?['sdk'];
    final maker = m?['manufacturer'];
    return AdbSetupState(
      devOptions: flag('devOptions'),
      wirelessDebugging: flag('wirelessDebugging'),
      wifi: flag('wifi'),
      notifications: flag('notifications', or: true),
      secureSettings: flag('secureSettings'),
      manufacturer: maker is String ? maker.toLowerCase() : '',
      sdk: sdk is int ? sdk : 0,
    );
  }

  final bool devOptions;
  final bool wirelessDebugging;
  final bool wifi;
  final bool notifications;

  /// Innocent holds WRITE_SECURE_SETTINGS (it can switch wireless debugging
  /// on by itself).
  final bool secureSettings;
  final String manufacturer;
  final int sdk;

  /// Wireless debugging exists from Android 11 (API 30).
  bool get supported => sdk == 0 || sdk >= 30;

  /// The family of phone, for the tips that only apply to it.
  AdbBrand get brand {
    final m = manufacturer;
    if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
      return AdbBrand.xiaomi;
    }
    if (m.contains('oppo') || m.contains('realme') || m.contains('oneplus')) {
      return AdbBrand.oppo;
    }
    if (m.contains('tecno') || m.contains('infinix') || m.contains('itel')) {
      return AdbBrand.transsion;
    }
    if (m.contains('samsung')) return AdbBrand.samsung;
    return AdbBrand.other;
  }

  /// The first step not yet done, in the order they have to be done — the one
  /// the screen points at. Null once everything Settings can tell is in place.
  AdbSetupStep? next({required bool paired, required bool connected}) {
    if (!devOptions) return AdbSetupStep.devOptions;
    if (!wifi) return AdbSetupStep.wifi;
    if (!wirelessDebugging) return AdbSetupStep.wirelessDebugging;
    if (!paired && !notifications) return AdbSetupStep.notifications;
    if (!paired) return AdbSetupStep.pair;
    if (!connected) return AdbSetupStep.connect;
    return null;
  }
}

enum AdbBrand { xiaomi, oppo, transsion, samsung, other }

enum AdbSetupStep { devOptions, wifi, wirelessDebugging, notifications, pair, connect }
