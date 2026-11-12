/// What the player shows of an engine error.
///
/// libmpv names the address it failed on ("Failed to open https://…"), and
/// for a film from the service the whole address is the credential: its
/// signature and expiry ride in the path and query. On screen it went into
/// every screenshot and screen recording of the error. The host stays, so
/// the message still says where; the rest becomes "…".
String scrubPlaybackError(String raw) {
  return raw.replaceAllMapped(_address, (m) {
    final whole = m[0]!;
    // A sentence's own punctuation after the address is not part of it.
    final trail = _trailing.firstMatch(whole)?[0] ?? '';
    var host = m[2]!;
    final at = host.lastIndexOf('@');
    if (at >= 0) host = host.substring(at + 1); // never a user:password
    host = host.replaceAll(_trailing, '');
    final rest = whole.length - trail.length > m[1]!.length + 3 + m[2]!.length;
    return '${m[1]}://$host${rest ? '/…' : ''}$trail';
  });
}

/// scheme://authority, then anything up to the next space.
final RegExp _address =
    RegExp(r'\b([a-zA-Z][a-zA-Z0-9+.\-]*)://([^\s/?#]+)\S*');
final RegExp _trailing = RegExp(r'[.,:;!?)\]]+$');
