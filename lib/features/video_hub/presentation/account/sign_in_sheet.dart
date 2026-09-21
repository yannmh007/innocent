import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/backend_config.dart';
import '../../data/local_account_repository.dart';
import '../../domain/account_repository.dart';
import '../account_provider.dart';
import '../video_hub_theme.dart';

/// Phone sign-in, as a bottom sheet.
///
/// Identity exists here for one operational reason: with manual KPay
/// activation somebody has to be able to look at a transfer and say which
/// account it belongs to. An anonymous app has nothing to attach that answer
/// to.
///
/// Phone leads because KPay is phone-based - the number that pays is almost
/// always the number that signs in, which turns manual matching from an
/// investigation into a glance.
///
/// Returns true when a session was established.
class SignInSheet extends ConsumerStatefulWidget {
  const SignInSheet({super.key});

  static Future<bool> show(BuildContext context) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const SignInSheet(),
    );
    return ok ?? false;
  }

  @override
  ConsumerState<SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends ConsumerState<SignInSheet> {
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _code = TextEditingController();

  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Myanmar numbers are typed as 09..., stored as +959...
  ///
  /// Normalised once, at the edge. A subscription keyed on "09..." and a KPay
  /// statement listing "+959..." are the same person, and code that has to
  /// remember that at every comparison is code that will eventually forget.
  String _normalise(String input) {
    final t = input.trim().replaceAll(RegExp(r'[\s-]'), '');
    if (t.startsWith('+')) return t;
    if (t.startsWith('09')) return '+959${t.substring(2)}';
    if (t.startsWith('9')) return '+95$t';
    return t;
  }

  Future<void> _sendCode() async {
    final phone = _normalise(_phone.text);
    if (phone.length < 8) {
      setState(() => _error = AppStrings.of(context).vhSignInBadPhone);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountRepositoryProvider).startPhoneSignIn(phone);
      if (!mounted) return;
      setState(() => _codeSent = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _sendCodeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A sentence a person can act on, for a code request that failed.
  ///
  /// NEVER `e.toString()`, which is what this used to be. ApiException renders
  /// as `ApiException(server:400)` — the class name and the HTTP status, shown
  /// to someone holding a phone who wants to buy something. The two other
  /// catch blocks in this file already got this right; this one was the odd
  /// one out.
  ///
  /// The cause is not narrowed further, and that is deliberate rather than
  /// lazy: api_client does NOT copy the server's error body into the
  /// exception, because those bodies quote request context and occasionally
  /// tokens, and this string can reach a crash report. So from here the
  /// honest distinction is "your connection" versus "not right now", and the
  /// real reason lives in the project's auth logs, where the operator can
  /// read it and the user cannot be expected to.
  String _sendCodeError(Object e) {
    final s = AppStrings.of(context);
    if (e is ApiException && e.kind == ApiErrorKind.network) {
      return s.vhSignInNoConnection;
    }
    return s.vhSignInSendFailed;
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountRepositoryProvider).signInWithGoogle();
      await ref.read(accountProvider.notifier).refresh();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on SignInCancelled {
      // NOTHING. They backed out of Google's account chooser, which is a
      // decision, not a fault. An error message here would tell someone who
      // just changed their mind that the app is broken.
    } on SignInNotConfigured {
      // The button is hidden when Google is unconfigured, so this is the
      // backstop - plus the case where Google itself refuses the client
      // (wrong SHA-1, wrong package name), which looks the same to a user:
      // this method is not available, use another one.
      if (!mounted) return;
      setState(() => _error = AppStrings.of(context).vhSignInGoogleSoon);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.kind == ApiErrorKind.network
          ? AppStrings.of(context).vhSignInNoConnection
          : AppStrings.of(context).vhSignInGoogleFailed);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = AppStrings.of(context).vhSignInGoogleFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountProvider.notifier).verifyPhone(
            phoneE164: _normalise(_phone.text),
            code: _code.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = AppStrings.of(context).vhSignInBadCode);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);

    return Padding(
      // Lifts the sheet above the keyboard; without it the code field is
      // exactly what the keyboard covers.
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: VH.surface2,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(VH.rSheet)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                VH.gutter, VH.s3, VH.gutter, VH.s4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 34,
                    height: 4,
                    decoration: BoxDecoration(
                      color: VH.textTertiary.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: VH.s4),
                Text(s.vhSignInTitle, style: VH.title),
                const SizedBox(height: VH.s2),
                Text(s.vhSignInWhy, style: VH.body),
                const SizedBox(height: VH.s5),
                // Google first for people who would rather not hand over a
                // number - which, for an adult app, is a real and reasonable
                // preference and not an edge case.
                //
                // AND ONLY WHEN THE BUILD CAN ACTUALLY DO IT. This button used
                // to be unconditional and always threw; offering a way in that
                // cannot work is worse than offering one fewer. The divider
                // goes with it, or an "or" is left separating one thing from
                // nothing.
                if (BackendConfig.googleEnabled) ...<Widget>[
                  _GoogleButton(
                    busy: _busy,
                    onTap: _signInWithGoogle,
                  ),
                  const SizedBox(height: VH.s4),
                  Row(
                    children: <Widget>[
                      const Expanded(child: Divider(color: VH.hairline)),
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: VH.s3),
                        child: Text(
                          s.vhSignInOr,
                          style: VH.meta.copyWith(fontSize: 11.5),
                        ),
                      ),
                      const Expanded(child: Divider(color: VH.hairline)),
                    ],
                  ),
                  const SizedBox(height: VH.s4),
                ],
                _Field(
                  controller: _phone,
                  hint: s.vhSignInPhoneHint,
                  keyboardType: TextInputType.phone,
                  enabled: !_codeSent && !_busy,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9+ -]')),
                  ],
                ),
                if (_codeSent) ...<Widget>[
                  const SizedBox(height: VH.s3),
                  _Field(
                    controller: _code,
                    hint: s.vhSignInCodeHint,
                    keyboardType: TextInputType.number,
                    enabled: !_busy,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                  ),
                  // audit_video_hub.md M3. The line below used to render on
                  // EVERY phone sign-in, with `_codeSent` as its only
                  // condition — so a production build, against the live
                  // backend, told the user in their own language to type
                  // 000000 after a real SMS had been sent. They type it, the
                  // server rejects it, and _verify says "That code is not
                  // correct" about the code the app just told them to use.
                  // Sign-in gates the payment flow, so this is where people
                  // gave up.
                  //
                  // Its comment was right and was in the wrong build. The
                  // identical hazard in account_screen.dart (the dev
                  // approve-my-own-payment button) IS guarded, with a
                  // paragraph explaining that "harmless as long as a config
                  // value is set" is not a control — so kDebugMode is a
                  // compile-time constant and the tree-shaker removes the
                  // branch from a release binary entirely. Both conditions
                  // are kept here: the stub is the only thing that accepts
                  // this code, and a debug build wired to a real backend must
                  // not claim otherwise either.
                  if (kDebugMode &&
                      ref.read(accountRepositoryProvider)
                          is LocalAccountRepository) ...<Widget>[
                    const SizedBox(height: VH.s2),
                    Text(
                      s.vhSignInDevCode(LocalAccountRepository.devCode),
                      style: VH.meta.copyWith(fontSize: 11.5),
                    ),
                  ],
                ],
                if (_error != null) ...<Widget>[
                  const SizedBox(height: VH.s3),
                  Text(
                    _error!,
                    style: VH.meta.copyWith(color: VH.accent, fontSize: 12),
                  ),
                ],
                const SizedBox(height: VH.s4),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: FilledButton(
                    onPressed: _busy ? null : (_codeSent ? _verify : _sendCode),
                    style: FilledButton.styleFrom(
                      backgroundColor: VH.textPrimary,
                      foregroundColor: VH.textInverse,
                      disabledBackgroundColor: VH.surface3,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(VH.rControl),
                      ),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _codeSent ? s.vhSignInVerify : s.vhSignInSendCode,
                            style: VH.label.copyWith(
                              color: VH.textInverse,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GoogleButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;

  const _GoogleButton({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton.icon(
        onPressed: busy ? null : onTap,
        icon: const Icon(Icons.account_circle_outlined,
            size: 20, color: VH.textPrimary),
        label: Text(
          s.vhSignInGoogle,
          style: VH.label.copyWith(fontSize: 14.5, fontWeight: FontWeight.w600),
        ),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: VH.hairline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(VH.rControl),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final TextInputType keyboardType;
  final bool enabled;
  final List<TextInputFormatter>? inputFormatters;

  const _Field({
    required this.controller,
    required this.hint,
    required this.keyboardType,
    required this.enabled,
    this.inputFormatters,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      style: VH.label.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: VH.label.copyWith(
          color: VH.textTertiary,
          fontSize: 15,
          fontWeight: FontWeight.w400,
        ),
        filled: true,
        fillColor: VH.surface3,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: VH.s4, vertical: VH.s3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VH.rControl),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
