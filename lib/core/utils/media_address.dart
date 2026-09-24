/// What the app is allowed to show a viewer about WHERE a video lives.
///
/// THE LEAK THIS CLOSES. The player's Information dialog is shared with the
/// local library, where showing a file's folder is the whole point. Opened
/// over a Video Hub stream it showed the same field — and that field was the
/// signed R2 address:
///
///     https://<account-id>.r2.cloudflarestorage.com/innocent-media/<folder>/video
///
/// which hands anyone holding the phone, or anyone sent a screenshot, the
/// account identifier, the private bucket's name and the layout of every key
/// inside it. None of that is a credential on its own, and none of it should
/// be on a viewer's screen either: it is the map an attacker would otherwise
/// have to guess at, and it was being handed out with the film.
///
/// The near miss is worth recording too. The dialog's sibling field takes
/// everything up to the last `/` in the URI. A presigned SigV4 URL carries
/// `X-Amz-Credential=<ACCESS-KEY-ID>/<date>/auto/s3/aws4_request` in its
/// query string — slashes and all. Today those slashes are percent-encoded
/// by the signer, so the split lands before the filename and the key id
/// stays out of it. That is one encoding decision, in a different file, away
/// from putting an access key id on screen. Addresses are not display
/// material, and this module is where that stops being a matter of luck.
///
/// Pure, so the rule can be tested without a player, a dialog or a network.
library;

/// True when this URI points at something on the network rather than at a
/// file on this device.
///
/// `file://`, a bare `/sdcard/...` path and a Windows-style path are local.
/// Everything with a network scheme — `http`, `https`, and anything else a
/// future source introduces — is remote and therefore not showable.
/// Unrecognised text is treated as REMOTE: the failure that matters is
/// showing an address, so anything this cannot vouch for is withheld.
bool isRemoteAddress(String uri) {
  final t = uri.trim();
  if (t.isEmpty) return false;
  if (t.startsWith('/')) return false;          // absolute on-device path
  if (t.startsWith('file://')) return false;
  if (t.startsWith('content://')) return false; // Android document provider
  final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):').firstMatch(t);
  if (scheme == null) return false;             // relative path
  return true;
}

/// The folder to show, or null when there is nothing safe to show.
///
/// [onDiskDirectory] is the real directory when the dialog managed to
/// resolve one — that is always safe and always preferred. [candidate] is
/// whatever the caller assembled, which for a stream is an address; it is
/// returned only when it is demonstrably a local path AND carries no query
/// string, because a query string is where signatures live.
String? showableLocation({String? onDiskDirectory, String? candidate}) {
  final disk = onDiskDirectory?.trim();
  if (disk != null && disk.isNotEmpty && !isRemoteAddress(disk)) return disk;

  final c = candidate?.trim();
  if (c == null || c.isEmpty) return null;
  if (isRemoteAddress(c)) return null;
  // A local path has no business carrying a query or a fragment, so one
  // here means the string was built from a URL and split by hand.
  if (c.contains('?') || c.contains('#')) return null;
  return c;
}

/// The name to show for the file.
///
/// A streamed title is named by its TITLE, never by its object key. The key
/// is chosen by the uploader and carries the folder scheme with it
/// (`20260922-solar-a1b2c3d4.mp4`), which is both meaningless to a viewer
/// and one more piece of the bucket's shape.
String showableFileName({
  required String uri,
  required String title,
  String? onDiskName,
}) {
  final disk = onDiskName?.trim();
  if (disk != null && disk.isNotEmpty) return disk;
  if (!isRemoteAddress(uri)) {
    final cut = uri.lastIndexOf('/');
    final name = cut >= 0 ? uri.substring(cut + 1) : uri;
    if (name.isNotEmpty && !name.contains('?')) return name;
  }
  return title.trim().isEmpty ? '—' : title.trim();
}
