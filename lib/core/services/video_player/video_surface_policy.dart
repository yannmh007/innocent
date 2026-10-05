import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/player_settings_service.dart';

/// Which surface the Android player draws video into.
///
/// "Efficient" is a Flutter SurfaceProducer: on Android 10+ an ImageReader
/// whose frames Impeller/Vulkan samples directly. "Compatible" is the
/// SurfaceTexture media_kit always used, which on Vulkan costs a copy of
/// every frame through a second OpenGL context (raster thread 7-10 % and
/// most of the player's GPU load on a Galaxy S23 Ultra, report ZVDDRQQH).
/// See third_party/media_kit_video/.../VideoOutput.java.
///
/// Two ways back to "compatible", both read when the player engine starts:
///  * the user's switch, Settings → Decoder → Efficient video output;
///  * the server's `app_releases.player_flags` containing `legacy_surface`
///    (migration 038), cached here by the daily update check, so a phone
///    model that draws it wrong can be fixed for everyone without an APK.
class VideoSurfacePolicy {
  VideoSurfacePolicy._();

  static const String remoteFlagsKey = 'remote_player_flags_v1';
  static const String legacySurfaceFlag = 'legacy_surface';

  /// Whether the engine should ask for the efficient surface.
  static Future<bool> useEfficientSurface() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return decide(
        userSwitch: sp.getBool(PlayerSetting.decEfficientOutput.key) ??
            PlayerSetting.decEfficientOutput.default_,
        remoteFlags: sp.getStringList(remoteFlagsKey) ?? const <String>[],
      );
    } catch (_) {
      // Preferences unreadable: the path every build before 1.64.54 used.
      return false;
    }
  }

  static bool decide({
    required bool userSwitch,
    required Iterable<String> remoteFlags,
  }) =>
      userSwitch && !remoteFlags.contains(legacySurfaceFlag);

  /// Called with each successfully read release row.
  static Future<void> storeRemoteFlags(Set<String> flags) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(remoteFlagsKey, flags.toList()..sort());
    } catch (_) {}
  }
}
