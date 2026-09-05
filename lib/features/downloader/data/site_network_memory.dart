import 'package:shared_preferences/shared_preferences.dart';

/// What this phone has learned about which network each site needs.
///
/// WHY THIS EXISTS. On this user's connection two groups of sites want opposite
/// things and cannot both be satisfied at once: their router blocks the adult
/// sites, so those are only reachable through a VPN — and YouTube then refuses,
/// because a shared exit address is exactly what its bot check is looking for.
/// There is no setting that makes both true. The app cannot fix that, and
/// pretending otherwise would waste somebody's evening.
///
/// What it CAN do is stop making them find out the slow way. Each fifteen-second
/// wait that ends in "Sign in to confirm you're not a bot" is fifteen seconds
/// spent rediscovering something this phone already knew. So every successful
/// read writes down which network it happened on, and the next failure on the
/// other one can say precisely that — not "try turning things off", but "this
/// site last worked with the VPN off".
///
/// Deliberately coarse and deliberately local: one word per host, on or off, in
/// the app's own preferences. No address is stored and nothing is sent
/// anywhere. The exact network would be a better key and is not worth what it
/// would cost to learn.
class SiteNetworkMemory {
  const SiteNetworkMemory._();

  static const String _prefix = 'site_network_v1_';

  /// The registrable-ish host, so `www.youtube.com` and `m.youtube.com` share
  /// one memory. A site's bot check does not care which subdomain asked.
  static String? keyFor(String url) {
    final String host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return null;
    final List<String> parts = host.split('.');
    if (parts.length <= 2) return host;
    return parts.sublist(parts.length - 2).join('.');
  }

  /// Records that this site was read successfully on this network.
  static Future<void> remember(String url, String networkKey) async {
    final String? key = keyFor(url);
    if (key == null) return;
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString('$_prefix$key', networkKey);
    } catch (_) {
      // A forgotten lesson is a slower answer, never a wrong one.
    }
  }

  /// The network this site last worked on, or null if it never has.
  static Future<String?> lastWorkingNetwork(String url) async {
    final String? key = keyFor(url);
    if (key == null) return null;
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      return sp.getString('$_prefix$key');
    } catch (_) {
      return null;
    }
  }

  /// True when this site has worked before, but not on the network in use now.
  ///
  /// The whole point of the class in one question. A `false` here means either
  /// "we have never seen this work" or "you are on the network it worked on" —
  /// and in both of those cases there is nothing useful to say, so nothing is
  /// said. Advice offered when it might be wrong is advice that stops being
  /// read.
  static Future<bool> mismatched(String url, String networkKey) async {
    final String? known = await lastWorkingNetwork(url);
    return known != null && known != networkKey;
  }
}
