/// The grant a film is playing on, held so that a change of copy can pick
/// from it again without asking the server.
///
/// WHY. A change of quality asked `request-playback` again, every time:
/// 2.9 s on a good line, 8.2 s on a realme C53 in Test Lab (run
/// 39741227453), during which the menu said "switching" and nothing
/// happened. The answer it waited for was the one already held — the same
/// title, the same copies, signed URLs with most of their ten minutes
/// still ahead. YouTube's menu changes copy in a second because the list
/// of copies is already on the phone; so is this one.
///
/// WHAT IS REUSED: the list of copies and their signed URLs, for a choice
/// BETWEEN copies — a pick from the menu, Auto's climb, a step down when
/// the line is too slow. Never for a renewal of an expired link: that is a
/// new request, as it always was, and the server re-decides entitlement,
/// expiry and the device cap.
///
/// WHY THIS GIVES NOTHING AWAY. The URLs reused were handed over by the
/// server and stay valid until their signature runs out whichever copy is
/// on screen; a viewer whose subscription lapsed could play them for those
/// minutes anyway. When they expire the stream proxy asks the server
/// again (its `refresh`), and that answer is a refusal if one is due.
///
/// THE CLOCK. The device's clock is not evidence (see [PlaybackGrant]), so
/// the age that decides is a stopwatch from the moment the grant arrived,
/// against [reuseFor] — well inside the server's ten minutes. The grant's
/// own expiry is read only the safe way round: if the phone's clock says
/// it is nearly out, it is not reused; a phone whose clock says otherwise
/// is still held to the stopwatch.
library;

import 'access.dart';

class HeldGrant {
  /// [age] is how old the grant already was when it was held: a grant asked
  /// for ahead of the tap may be up to forty seconds old.
  HeldGrant(this.grant, {Duration age = Duration.zero})
      : _born = age,
        _clock = Stopwatch()..start();

  final PlaybackGrant grant;
  final Duration _born;
  final Stopwatch _clock;

  /// How long a grant's copies are chosen between without asking again.
  /// The server signs for 600 s (request-playback.ts, EXPIRY_SECONDS).
  static const Duration reuseFor = Duration(minutes: 4);

  /// Not reused when the device's clock reads the signature as running out
  /// within this — the advisory check, in the safe direction only.
  static const Duration expiryMargin = Duration(minutes: 2);

  Duration get age => _born + _clock.elapsed;

  /// True when a change of copy may take its URL from [grant].
  bool reusable({DateTime? now}) {
    if (!grant.isGranted || grant.renditions.isEmpty) return false;
    if (age >= reuseFor) return false;
    final until = grant.expiresAt;
    if (until != null &&
        until.difference(now ?? DateTime.now()) < expiryMargin) {
      return false;
    }
    return true;
  }
}
