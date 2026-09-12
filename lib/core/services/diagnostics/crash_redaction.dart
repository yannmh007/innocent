/// Strip personal detail out of text that is about to leave the device.
///
/// WHY THIS EXISTS. Innocent is a media player with a PIN-locked Private
/// Folder. The breadcrumb messages it records are all structural
/// ("AudioService.init ok"), but the *exceptions* are not: a
/// `FileSystemException` carries the path it failed on, and that path is the
/// name of a video someone chose to keep. `PathNotFoundException: ... path =
/// '/storage/emulated/0/Innocent/Private/holiday in phuket.mp4'` is a crash
/// report and a disclosure in the same string.
///
/// So nothing goes to Sentry without passing through here first.
///
/// WHAT IT DELIBERATELY KEEPS. A redactor that removes everything produces
/// reports nobody can act on. These are kept because they are diagnostic
/// rather than personal:
///
///   * the storage root — `/storage/emulated/0` vs `/data/user/0` is the
///     difference between shared storage and app-private, which is usually
///     the bug
///   * the file extension — `.mkv` failing where `.mp4` works is the bug
///   * the URI authority — `content://com.android.externalstorage.documents`
///     names the provider, which is a real class of SAF failure
///   * the URL scheme and host — the downloader failing on one site and not
///     another is the report; *which video* is not
///
/// WHAT IT NEVER KEEPS: filenames, folder names below the root, SAF document
/// ids, URL paths and query strings.
///
/// STACK FRAMES ARE NOT TOUCHED. `package:innocent/features/...` and
/// `dart:async` are the entire value of a stack trace and contain nothing
/// personal, so every pattern here is anchored to an absolute Android
/// filesystem root or a URI scheme. A Dart source location matches none of
/// them.
library;

/// Redacts one string. Safe to call on anything, including empty text.
///
/// Pure and synchronous on purpose: it is unit-tested directly
/// (`test/crash_redaction_test.dart`) rather than through Sentry, because the
/// thing worth proving is the output, not the plumbing.
String redactSensitive(String input) {
  if (input.isEmpty) return input;
  var out = input;

  // 1. content:// and similar provider URIs. Keep the authority, drop the
  //    document id — the id encodes the tree and the filename.
  out = out.replaceAllMapped(
    RegExp(r'\b(content|android\.resource)://([A-Za-z0-9._-]*)[^\s"\x27)\]}]*'),
    (m) => '${m[1]}://${m[2]}/<redacted>',
  );

  // 2. http(s) URLs. Keep scheme and host — "fails on this site" is the
  //    report — and drop the path and query, which identify the video.
  out = out.replaceAllMapped(
    RegExp(r'\bhttps?://([A-Za-z0-9.:-]+)(/[^\s"\x27)\]}]*)?'),
    (m) => 'https://${m[1]}/<redacted>',
  );

  // 3. file:// URLs, handled as paths so they redact the same way.
  out = out.replaceAllMapped(
    RegExp(r'\bfile://(/[^\s"\x27)\]}]*)'),
    (m) => 'file://${_redactPath(m[1]!)}',
  );

  // 4. Bare absolute paths, anchored to the Android roots this app touches.
  //    Anchored rather than "any /..." so a Dart stack frame, a `dart:` URI
  //    and a `package:` URI all pass through untouched.
  out = out.replaceAllMapped(
    RegExp(r'(?<![\w:/])/(storage|sdcard|data|mnt)(/[^\s"\x27)\]},;]*)?'),
    (m) => _redactPath('/${m[1]}${m[2] ?? ''}'),
  );

  return out;
}

/// Keeps the first two path segments and the extension, redacts the middle.
///
///     /storage/emulated/0/Movies/holiday.mp4  ->  /storage/emulated/<redacted>.mp4
///     /data/user/0/com.innocent.media/cache/x ->  /data/user/<redacted>
///
/// Two segments is a judgement, not a standard: `/storage/emulated` and
/// `/data/user` are the parts that identify *which kind of storage*, and
/// everything below them starts being about the person using the phone.
String _redactPath(String path) {
  final bool endsWithSlash = path.endsWith('/');
  final List<String> parts =
      path.split('/').where((String s) => s.isNotEmpty).toList();
  if (parts.length <= 2) return path;

  final String head = '/${parts.take(2).join('/')}';
  final String last = parts.last;
  final int dot = last.lastIndexOf('.');
  // A trailing dot, or a leading one (a dotfile), is not an extension.
  final String ext =
      (dot > 0 && dot < last.length - 1) ? last.substring(dot) : '';
  return '$head/<redacted>$ext${endsWithSlash ? '/' : ''}';
}
