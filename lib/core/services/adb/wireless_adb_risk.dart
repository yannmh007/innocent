/// WHETHER THIS PHONE'S WIRELESS DEBUGGING IS KNOWN TO BE UNSAFE TO LEAVE ON.
///
/// CVE-2026-0073 (Android Security Bulletin, May 2026): a logic error in
/// adbd's TLS certificate check (`adbd_tls_verify_cert`) lets a device on the
/// same network skip wireless debugging's mutual authentication and reach a
/// shell, with no pairing and no tap. Affected: Android 14, 15 and 16
/// (16-qpr2 included). Fixed by the 2026-05-01 security patch level, or by
/// the Google Play system update that carries the patched adb module — which
/// is why this can only ever say "possibly exposed", never "exposed": a phone
/// with an older patch level may already run the fixed adbd.
///
/// It matters to Innocent more than to most apps, because Innocent can turn
/// wireless debugging back on after every reboot — on an unpatched phone that
/// is the window this flaw needs, kept open for as long as the phone is on.
///
/// Pure, so the rule is tested without a phone (test/wireless_adb_risk_test.dart).
library;

/// The first security patch level that carries the fix.
const String kWirelessAdbFixedPatch = '2026-05-01';

/// True when [sdkInt] is an affected Android version (14 to 16: API 34, 35,
/// 36) and [securityPatch] — `Build.VERSION.SECURITY_PATCH`, "YYYY-MM-DD" —
/// is older than [kWirelessAdbFixedPatch], or cannot be read. An unreadable
/// patch level on an affected version counts as exposed: the warning is
/// cheap, and missing it is not.
bool wirelessAdbPossiblyExposed({
  required int sdkInt,
  required String? securityPatch,
}) {
  if (sdkInt < 34 || sdkInt > 36) return false;
  final patch = (securityPatch ?? '').trim();
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(patch)) return true;
  // ISO dates compare correctly as strings.
  return patch.compareTo(kWirelessAdbFixedPatch) < 0;
}
