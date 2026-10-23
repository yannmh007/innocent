import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../video_hub/presentation/account_provider.dart';

/// A faint code on a paid film, saying whose screen it is.
///
/// WHY. FLAG_SECURE turns a screenshot or a screen recording of a paid film
/// black — on a phone that honours it. A rooted phone, a capture card, or a
/// second phone pointed at the screen does not, and a copy made that way
/// says nothing about where it came from. With this on the picture, a copy
/// that turns up somewhere names the account it was made from.
///
/// WHAT IT SHOWS: the first 8 hex digits of SHA-256 of the account id — the
/// same hash `request-playback` puts in the token as `u` (16 digits) and the
/// Worker logs, so a code seen in a copy is found in the Worker's log by its
/// first 8 digits, and in the database with docs/security.md §9. Nothing in
/// it is the person: not the email, not the phone number, and nobody who
/// sees it can work back to them. With no account (which a paid film should
/// not have) it is the install's code instead, the hash the Worker logs as
/// `d`.
///
/// WHY IT MOVES. A mark that stays in one corner is cropped off, or blurred
/// over, in one step for the whole film. This one fades to a new place in
/// the picture every [hold], so taking it out means finding it again, and
/// again, all the way through. It moves by fading rather than gliding: a
/// moving thing pulls the eye off the film, and a code that jumps while
/// nobody is looking does not.
///
/// WHERE: on the picture, never on the black bars — a bar is the first
/// thing a copy is cropped to lose. [picture] is the picture's rectangle on
/// screen, as the subtitles use it; null means the whole box.
///
/// NEVER IN THE WAY: no touch lands on it, TalkBack does not read it, and at
/// a fifth of white it is only seen by someone looking for it.
class AccountMark extends ConsumerStatefulWidget {
  const AccountMark({super.key, this.picture});

  /// The picture's rectangle within this box; null for the whole box.
  final Rect? picture;

  /// How long the code stays in one place.
  static const Duration hold = Duration(seconds: 20);

  /// How long the fade out, and the fade back in, take.
  static const Duration fade = Duration(milliseconds: 700);

  @override
  ConsumerState<AccountMark> createState() => _AccountMarkState();
}

/// The code for an account id, or an install id: 8 lower-case hex digits of
/// its SHA-256 — the first 8 of the `u` (or `d`) the Worker logs.
String accountMarkCode(String id) =>
    sha256.convert(utf8.encode(id)).toString().substring(0, 8);

/// Which code a phone shows: its account's, or — signed out, which a paid
/// film should never be — its install's. Null when neither is known yet.
String? accountMarkFor(String? userId, String installId) {
  if (userId != null && userId.isNotEmpty) return accountMarkCode(userId);
  if (installId.isNotEmpty) return accountMarkCode(installId);
  return null;
}

/// The code shown on paid films on this phone (accountMarkFor).
final accountMarkProvider = Provider<String?>((ref) {
  final (user, install) = ref.watch(
      accountProvider.select((s) => (s.user?.id, s.installId)));
  return accountMarkFor(user, install);
});

/// Where the code sits within the picture, as an [Alignment]: anywhere but
/// the outer tenth on each side, where a crop takes it and where the
/// player's own buttons sit when they are up.
Alignment accountMarkSpot(math.Random random) => Alignment(
      random.nextDouble() * 1.6 - 0.8,
      random.nextDouble() * 1.6 - 0.8,
    );

/// The part of [picture] that is on a screen of [view]: a zoomed-in
/// picture runs off the screen, and a code out there is in nobody's copy.
Rect accountMarkArea(Size view, Rect? picture) {
  final screen = Offset.zero & view;
  if (picture == null) return screen;
  final on = picture.intersect(screen);
  return on.width <= 0 || on.height <= 0 ? screen : on;
}

class _AccountMarkState extends ConsumerState<AccountMark> {
  final math.Random _random = math.Random();
  late Alignment _spot = accountMarkSpot(_random);
  bool _shown = true;
  Timer? _every;
  Timer? _back;

  @override
  void initState() {
    super.initState();
    _every = Timer.periodic(AccountMark.hold, (_) => _move());
  }

  void _move() {
    if (!mounted) return;
    setState(() => _shown = false);
    _back?.cancel();
    _back = Timer(AccountMark.fade, () {
      if (!mounted) return;
      setState(() {
        _spot = accountMarkSpot(_random);
        _shown = true;
      });
    });
  }

  @override
  void dispose() {
    _every?.cancel();
    _back?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final code = ref.watch(accountMarkProvider);
    if (code == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(builder: (context, c) {
          final area = accountMarkArea(Size(c.maxWidth, c.maxHeight), widget.picture);
          // About a thirtieth of the picture's short side: readable in a
          // copy at 480p, small enough to forget on a phone held in hand.
          final size = (area.shortestSide * 0.035).clamp(9.0, 16.0);
          return Stack(children: <Widget>[
            Positioned.fromRect(
              rect: area,
              child: AnimatedOpacity(
                opacity: _shown ? 1 : 0,
                duration: AccountMark.fade,
                child: Align(
                  alignment: _spot,
                  child: Text(
                    code,
                    key: const ValueKey<String>('account-mark'),
                    maxLines: 1,
                    softWrap: false,
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      // White letters with a dark edge: on night the letters
                      // show, on a bright sky only the edge does — so the
                      // edge is the stronger of the two, and sharp.
                      color: const Color(0x38FFFFFF),
                      // Drawn above the Material in the player, never inside
                      // it: no inherited underline either way.
                      decoration: TextDecoration.none,
                      fontSize: size,
                      fontWeight: FontWeight.w600,
                      letterSpacing: size * 0.12,
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                      shadows: const <Shadow>[
                        Shadow(color: Color(0x52000000), blurRadius: 1.2, offset: Offset(0.6, 0.6)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ]);
        }),
      ),
    );
  }
}
