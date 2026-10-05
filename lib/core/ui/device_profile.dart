import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What kind of Android screen the app is on, decided once at start-up.
enum DeviceKind { phone, tablet, tv }

/// The app runs on phones, tablets, foldables and Android TV. Some decisions
/// cannot be made from the window size alone — a TV is landscape and has no
/// touch screen; a tablet held upright is still a tablet — so they are made
/// here, once, and read everywhere.
class DeviceProfile {
  DeviceProfile._();

  static DeviceKind kind = DeviceKind.phone;

  static bool get isPhone => kind == DeviceKind.phone;
  static bool get isTablet => kind == DeviceKind.tablet;
  static bool get isTv => kind == DeviceKind.tv;

  static const MethodChannel _channel = MethodChannel('mx_clone/pip');

  /// Call once before runApp.
  ///
  /// The size comes from Android's configuration (smallestScreenWidthDp), not
  /// from Flutter's display list: before runApp that list can still be empty
  /// or zero-sized, and reading it there classified a 900 dp tablet as a
  /// phone and locked it to portrait.
  static Future<void> init() async {
    if (kIsWeb || !Platform.isAndroid) return;
    var tv = false;
    double? sw;
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('deviceClass');
      tv = m?['tv'] == true;
      final v = (m?['sw'] as num?)?.toDouble();
      if (v != null && v > 0) sw = v;
    } catch (_) {
      try {
        tv = await _channel.invokeMethod<bool>('isTv') ?? false;
      } catch (_) {}
    }
    if (tv) {
      kind = DeviceKind.tv;
      return;
    }
    kind = classify(sw ?? _displayShortestSide());
    if (const bool.fromEnvironment('INNOCENT_LAB')) {
      debugPrint('LAB device kind=$kind sw=$sw');
    }
  }

  /// A screen whose shorter side is 600 dp or more is a tablet — Android's
  /// own threshold (sw600dp), and Material's.
  @visibleForTesting
  static DeviceKind classify(double? shortestSideDp) =>
      shortestSideDp != null && shortestSideDp >= 600
          ? DeviceKind.tablet
          : DeviceKind.phone;

  static double? _displayShortestSide() {
    try {
      final displays = ui.PlatformDispatcher.instance.displays;
      if (displays.isEmpty) return null;
      final d = displays.first;
      if (d.devicePixelRatio <= 0) return null;
      final s = d.size / d.devicePixelRatio;
      return s.shortestSide;
    } catch (_) {
      return null;
    }
  }

  /// Orientations the app allows outside the player. Phones keep the
  /// portrait lock the app was designed around; a tablet follows the device
  /// (people hold tablets both ways, and a portrait lock on a landscape
  /// tablet is the classic "phone app blown up" sign); a TV must never be
  /// asked for portrait. An empty list means "whatever the device does".
  static List<DeviceOrientation> get appOrientations =>
      isPhone ? const [DeviceOrientation.portraitUp] : const [];

  static Future<void> applyAppOrientation() =>
      SystemChrome.setPreferredOrientations(appOrientations);
}
