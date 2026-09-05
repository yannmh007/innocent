import 'package:flutter/foundation.dart';

/// What went wrong reading a link, in terms the UI can offer an action for.
///
/// yt-dlp's own messages are written for someone at a terminal — the bot-wall
/// error is five lines long and ends with two wiki URLs. Dumping that in a
/// snackbar (which is what v0.99.0 did) tells a phone user nothing they can
/// act on. Classifying it lets the screen say one short sentence and put the
/// actual fix one tap away.
enum ProbeFailureKind {
  /// YouTube's "Sign in to confirm you're not a bot". Fixed by a newer
  /// extractor (engine update) or by supplying cookies.
  botWall,

  /// Members-only, age-gated, private, or region-locked.
  needsAccount,

  /// Network unreachable / timed out.
  network,

  /// The site is supported but the extractor broke — usually an outdated
  /// engine.
  extractorBroken,

  /// Nothing downloadable at this URL.
  unsupported,

  /// The user cancelled.
  cancelled,

  /// The SITE is refusing us for asking too often — HTTP 429.
  ///
  /// Nothing is broken and nothing needs fixing: the network this phone is on
  /// has made too many requests recently and the answer is to stop making
  /// them. Retrying is the one response that makes it worse and keeps it
  /// alive, which is exactly what a person naturally does when a screen says
  /// "failed" with no explanation. It earns its own kind so it can say so.
  rateLimited,

  /// Anything else; show the raw message.
  unknown,
}

@immutable
class ProbeFailure {
  const ProbeFailure(this.kind, this.raw);

  final ProbeFailureKind kind;
  final String raw;

  /// True when updating the bundled yt-dlp is a plausible fix, and therefore
  /// worth offering as a one-tap action.
  bool get updateMayHelp =>
      kind == ProbeFailureKind.botWall ||
      kind == ProbeFailureKind.extractorBroken ||
      kind == ProbeFailureKind.unsupported;

  /// True when signing in (via a cookies file) is the plausible fix.
  bool get cookiesMayHelp =>
      kind == ProbeFailureKind.botWall || kind == ProbeFailureKind.needsAccount;

  /// The first sentence of the engine's message, with yt-dlp's boilerplate
  /// stripped — enough to be useful in a details row without the wiki links.
  String get shortRaw {
    String text = raw.replaceAll(RegExp(r'https?://\S+'), '').trim();
    // Drop the "ERROR: [extractor] id: " prefix; it is noise to a phone user.
    text = text.replaceFirst(RegExp(r'^ERROR:\s*'), '');
    text = text.replaceFirst(RegExp(r'^\[[^\]]+\]\s*\S+:\s*'), '');
    final int stop = text.indexOf('. ');
    if (stop > 0) text = text.substring(0, stop + 1);
    text = text.trim();
    if (text.length > 180) text = '${text.substring(0, 180)}…';
    return text;
  }

  static ProbeFailure classify(String message) {
    final String m = message.toLowerCase();
    if (m.contains('cancelled') || m.contains('canceled')) {
      return ProbeFailure(ProbeFailureKind.cancelled, message);
    }
    // BEFORE every other test. A 429 often arrives wearing another failure's
    // words — "unable to download webpage", "no title found in player
    // responses" — and whichever of those we matched first would send the
    // person off fixing something that is not broken.
    if (m.contains('429') || m.contains('too many requests')) {
      return ProbeFailure(ProbeFailureKind.rateLimited, message);
    }
    if (m.contains('not a bot') || m.contains('confirm you')) {
      return ProbeFailure(ProbeFailureKind.botWall, message);
    }
    if (m.contains('private video') ||
        m.contains('members-only') ||
        m.contains('members only') ||
        m.contains('age') && m.contains('verif') ||
        m.contains('login required') ||
        m.contains('sign in')) {
      return ProbeFailure(ProbeFailureKind.needsAccount, message);
    }
    if (m.contains('timed out') ||
        m.contains('timeout') ||
        m.contains('unable to connect') ||
        m.contains('connection reset') ||
        m.contains('network is unreachable') ||
        m.contains('name or service not known') ||
        m.contains('temporary failure in name resolution')) {
      return ProbeFailure(ProbeFailureKind.network, message);
    }
    if (m.contains('unable to extract') ||
        m.contains('failed to extract') ||
        m.contains('player response') ||
        m.contains('nsig') ||
        m.contains('signature')) {
      return ProbeFailure(ProbeFailureKind.extractorBroken, message);
    }
    if (m.contains('unsupported url') ||
        m.contains('no video formats') ||
        m.contains('no media found') ||
        m.contains('is not a valid url')) {
      return ProbeFailure(ProbeFailureKind.unsupported, message);
    }
    return ProbeFailure(ProbeFailureKind.unknown, message);
  }
}
