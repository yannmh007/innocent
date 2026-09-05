// Lightweight connectivity probe — no external dependencies.
//
// Real-world risk this addresses: network streams (http:// / https://
// / rtsp:// URLs) silently fail when the device loses Wi-Fi or
// switches to a metered mobile connection mid-playback. The user
// sees a generic "Playback failed" with no hint that the cause is
// connectivity. With this service the player can detect "offline"
// before showing the error and surface a clearer message + retry CTA.
//
// We deliberately avoid `connectivity_plus` because (a) it adds a
// native plugin to pubspec, (b) the plugin only reports interface
// state — having a Wi-Fi radio attached does not mean the network
// actually reaches the internet. A DNS lookup against a known
// stable host (Cloudflare 1.1.1.1 via its hostname `one.one.one.one`)
// gives a reliable end-to-end check in <100 ms when online and
// times out cleanly when offline.
//
// Usage: `await ConnectivityService.isOnline()`. Returns true on
// non-mobile platforms (desktop / web) since we have no good
// network-state signal there and assume the network works.
import 'dart:io';

class ConnectivityService {
  const ConnectivityService();

  /// Single-shot online probe. Returns true if a DNS lookup against
  /// a stable public host succeeds within [timeout]; false on
  /// timeout, SocketException, or any other failure. Safe to call
  /// from anywhere — never throws.
  Future<bool> isOnline({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    // We only have a meaningful "offline" signal on mobile. Treat
    // desktop / web as always-online to avoid false-negative offline
    // banners on devices we can't probe reliably.
    if (!Platform.isAndroid && !Platform.isIOS) return true;
    try {
      final result = await InternetAddress.lookup('one.one.one.one')
          .timeout(timeout);
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } on Object {
      return false;
    }
  }
}
