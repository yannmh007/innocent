import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../../data/age_consent_store.dart';
import '../account_provider.dart';
import '../video_hub_theme.dart';
import '../widgets/vh_insets.dart';

/// The door.
///
/// Everything behind it is adult material, so the 18+ decision belongs HERE
/// rather than on a category tab - a tab that always matches everything is not
/// a filter, it is a formality people learn to tap through.
///
/// The shape is the one every adult platform uses, and each part of it is
/// doing a job:
///
///   * TWO explicit buttons, not one. "I am 18 or older" next to "I am under
///     18" forces an actual answer. A single "Enter" with fine print above it
///     is a door with a sign on it, and everyone walks through signs.
///   * The refusal is REAL. Answering under-18 does not reopen the question on
///     the next launch. It is a locked door on a ground-floor window - anyone
///     determined gets past it - but a question that visibly means nothing
///     teaches people to lie to every other question the app asks.
///   * The terms are ON THIS SCREEN, scrollable, not behind a link. A link is
///     a way of not showing someone something while being able to say you did.
class AgeGateScreen extends ConsumerStatefulWidget {
  /// Shown once the gate is passed.
  final Widget child;

  const AgeGateScreen({super.key, required this.child});

  @override
  ConsumerState<AgeGateScreen> createState() => _AgeGateScreenState();
}

enum _GateState { checking, asking, declined, passed }

class _AgeGateScreenState extends ConsumerState<AgeGateScreen> {
  static const AgeConsentStore _store = AgeConsentStore();

  _GateState _state = _GateState.checking;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final declined = await _store.hasDeclined();
    final accepted = await _store.isAccepted();
    if (!mounted) return;
    setState(() {
      _state = declined
          ? _GateState.declined
          : (accepted ? _GateState.passed : _GateState.asking);
    });
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    await _store.accept();

    // Recorded server-side too, once there is a server. The device copy stops
    // the prompt reappearing; the server copy is the one that can still be
    // produced in a year, which is the only kind that is worth anything if the
    // consent is ever questioned.
    final at = await _store.acceptedAt() ?? DateTime.now();
    // ignore: discarded_futures
    ref
        .read(accountRepositoryProvider)
        .recordAgeConsent(
          version: AgeConsentStore.currentVersion,
          acceptedAt: at,
        )
        .catchError((_) {});

    if (!mounted) return;
    setState(() {
      _busy = false;
      _state = _GateState.passed;
    });
  }

  Future<void> _decline() async {
    await _store.decline();
    if (!mounted) return;
    setState(() => _state = _GateState.declined);
  }

  /// Deliberate confirmation before the refusal is undone. Defaults to
  /// dismissing (a tap outside, or Back, returns false), so the path of least
  /// resistance is the one that leaves the door shut.
  Future<bool> _confirmReconsider(BuildContext context) async {
    final s = AppStrings.of(context);
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VH.surface2,
        title: Text(s.vhGateMistakeConfirmTitle, style: VH.heading),
        content: Text(s.vhGateMistakeConfirmBody, style: VH.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(s.cancel,
                style: VH.label.copyWith(color: VH.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(s.vhGateMistakeConfirmYes,
                style: VH.label.copyWith(color: VH.textPrimary)),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    switch (_state) {
      case _GateState.passed:
        return widget.child;
      case _GateState.checking:
        // Blank canvas, not a spinner: this resolves in milliseconds from
        // local storage, and a spinner that flashes for one frame reads as a
        // stutter.
        return const ColoredBox(
          color: VH.canvas,
          child: SizedBox.expand(),
        );
      case _GateState.declined:
        return _DeclinedView(onReconsider: () async {
          // A CONFIRMATION, NOT A RESET BUTTON.
          //
          // The refusal is meant to be real: answering under-18 should not
          // reopen the question on the next launch, because a question that
          // visibly means nothing teaches people to lie to every other one.
          // A single tap that wipes the answer and re-asks made the link a
          // "try again" button, which is the same thing with extra steps.
          //
          // Requiring an explicit "yes, I mis-tapped" keeps the way back for
          // the person who genuinely mis-tapped — the only reason the link
          // exists — while making it a decision rather than a reflex. It is
          // still a locked door on a ground-floor window; the point is that
          // it does not advertise the window.
          final sure = await _confirmReconsider(context);
          if (!sure || !mounted) return;
          await _store.reset();
          if (!mounted) return;
          setState(() => _state = _GateState.asking);
        });
      case _GateState.asking:
        return _AskView(busy: _busy, onAccept: _accept, onDecline: _decline);
    }
  }
}

class _AskView extends StatelessWidget {
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _AskView({
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);

    return Scaffold(
      backgroundColor: VH.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                    VH.gutter, VH.s6, VH.gutter, VH.s4),
                children: <Widget>[
                  Center(
                    child: Container(
                      width: 56,
                      height: 56,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: VH.surface2,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: VH.hairline),
                      ),
                      child: const Text(
                        '18+',
                        style: TextStyle(
                          color: VH.textPrimary,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: VH.s5),
                  Text(
                    s.vhGateTitle,
                    textAlign: TextAlign.center,
                    style: VH.display.copyWith(fontSize: 23),
                  ),
                  const SizedBox(height: VH.s3),
                  Text(
                    s.vhGateLead,
                    textAlign: TextAlign.center,
                    style: VH.body,
                  ),
                  const SizedBox(height: VH.s5),
                  _Terms(),
                ],
              ),
            ),
            _Actions(busy: busy, onAccept: onAccept, onDecline: onDecline),
          ],
        ),
      ),
    );
  }
}

/// The agreement itself.
///
/// Each line is a separate commitment rather than one wall of prose, because a
/// paragraph gets skimmed and a list gets read. The voluntary-entry line is
/// there at the operator's request and it matters: it records that the person
/// came here of their own accord and was not sent, pushed or tricked into it.
class _Terms extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final points = <String>[
      s.vhGateTerm1,
      s.vhGateTerm2,
      s.vhGateTerm3,
      s.vhGateTerm4,
      s.vhGateTerm5,
      s.vhGateTerm6,
    ];

    return Container(
      padding: const EdgeInsets.all(VH.s4),
      decoration: BoxDecoration(
        color: VH.surface1,
        borderRadius: BorderRadius.circular(VH.rControl),
        border: Border.all(color: VH.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            s.vhGateTermsHeading.toUpperCase(),
            style: VH.label.copyWith(
              color: VH.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: VH.s3),
          ...points.map((p) => Padding(
                padding: const EdgeInsets.only(bottom: VH.s3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.only(top: 5),
                      child: Icon(Icons.circle,
                          size: 5, color: VH.textTertiary),
                    ),
                    const SizedBox(width: VH.s3),
                    Expanded(
                      child: Text(p, style: VH.body.copyWith(fontSize: 13)),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _Actions({
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);

    return Container(
      padding: EdgeInsets.fromLTRB(
        VH.gutter,
        VH.s3,
        VH.gutter,
        VhInsets.scrollBottom(context, extra: VH.s3),
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: VH.hairline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              onPressed: busy ? null : onAccept,
              style: FilledButton.styleFrom(
                backgroundColor: VH.textPrimary,
                foregroundColor: VH.textInverse,
                disabledBackgroundColor: VH.surface3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(VH.rControl),
                ),
              ),
              child: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      s.vhGateEnter,
                      style: VH.label.copyWith(
                        color: VH.textInverse,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: VH.s2),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: OutlinedButton(
              onPressed: busy ? null : onDecline,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: VH.hairline),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(VH.rControl),
                ),
              ),
              child: Text(
                s.vhGateLeave,
                style: VH.label.copyWith(
                  color: VH.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown to someone who said they are under 18.
///
/// Kind, not scolding, and it does NOT re-offer the 18+ button. Putting the
/// way back in on the same screen would turn the whole question into a
/// two-tap formality.
class _DeclinedView extends StatelessWidget {
  final VoidCallback onReconsider;

  const _DeclinedView({required this.onReconsider});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);

    return Scaffold(
      backgroundColor: VH.canvas,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: VH.s6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.block_rounded, size: 46, color: VH.textTertiary),
              const SizedBox(height: VH.s5),
              Text(
                s.vhGateBlockedTitle,
                textAlign: TextAlign.center,
                style: VH.title,
              ),
              const SizedBox(height: VH.s3),
              Text(
                s.vhGateBlockedBody,
                textAlign: TextAlign.center,
                style: VH.body,
              ),
              const SizedBox(height: VH.s6),
              // Deliberately a quiet text link, not a button. Someone who
              // mis-tapped needs a way back; nobody should be invited to
              // simply answer again.
              TextButton(
                onPressed: onReconsider,
                child: Text(
                  s.vhGateMistake,
                  style: VH.label.copyWith(
                    color: VH.textTertiary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
