import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/theme/tab_title.dart';
import '../../domain/account.dart';
import '../../domain/account_repository.dart';
import '../account_provider.dart';
import '../video_hub_theme.dart';
import '../widgets/vh_insets.dart';

/// Deleting the account, for good (docs/edge/delete-account.ts).
///
/// THREE DELIBERATE STEPS, and no more: reading what goes and what stays, a
/// box that says "I understand", and choosing the account again at Google's
/// prompt. The last is the server's rule (a sign-in from the last ten
/// minutes), and it is also what makes a phone left unlocked on a table not
/// enough to erase somebody.
///
/// SAYS WHAT IS KEPT, not only what is deleted. Payment records stay, with
/// nothing in them that names the person, and a screen that promised
/// "everything is deleted" would be telling them something untrue.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  /// White on this red is 5.6:1, past the 4.5 a button's label needs; the
  /// theme's own error red is 4.0 with white.
  static const Color danger = Color(0xFFC62828);

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  bool _understood = false;
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    final s = AppStrings.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountProvider.notifier).deleteAccount();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).popUntil((r) => r.isFirst);
      messenger.showSnackBar(SnackBar(content: Text(s.vhDeleteAccountDone)));
      return;
    } on SignInCancelled {
      // They backed out of Google's prompt: a decision, not a fault.
    } on AccountDeletionRefused catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.reason) {
            'other_account' => s.vhDeleteAccountOther,
            'sign_in_again' => s.vhDeleteAccountStale,
            'admin' => s.vhDeleteAccountAdmin,
            'offline' => s.vhSignInNoConnection,
            _ => s.vhDeleteAccountFailed,
          });
    } on SignInNotConfigured {
      if (!mounted) return;
      setState(() => _error = s.vhDeleteAccountStale);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = s.vhDeleteAccountFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final user = ref.watch(accountProvider).user;
    final who = user?.email ?? user?.phone ?? user?.displayName;
    Widget point(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: VH.s3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 20, color: VH.textSecondary),
              const SizedBox(width: VH.s3),
              Expanded(child: Text(text, style: VH.body.copyWith(color: VH.textPrimary))),
            ],
          ),
        );

    return Scaffold(
      backgroundColor: VH.canvas,
      appBar: AppBar(
        backgroundColor: VH.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(Icons.arrow_back, color: VH.textPrimary),
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
        ),
        title: Text(s.vhDeleteAccount,
            style: kAppBarTitleStyle.copyWith(color: VH.textPrimary)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(VH.gutter, VH.s4, VH.gutter,
            VhInsets.scrollBottom(context, extra: VH.s6)),
        children: <Widget>[
          Text(s.vhDeleteAccountIntro, style: VH.title.copyWith(color: VH.textPrimary)),
          if (who != null) ...<Widget>[
            const SizedBox(height: VH.s2),
            Text(who, style: VH.meta.copyWith(color: VH.textSecondary)),
          ],
          const SizedBox(height: VH.s5),
          point(Icons.delete_outline_rounded, s.vhDeleteAccountGone),
          point(Icons.receipt_long_outlined, s.vhDeleteAccountKept),
          point(Icons.workspace_premium_outlined, s.vhDeleteAccountPremium),
          point(Icons.phone_android_rounded, s.vhDeleteAccountPhone),
          if (user?.method == AuthMethod.google)
            point(Icons.verified_user_outlined, s.vhDeleteAccountReauth),
          const SizedBox(height: VH.s3),
          CheckboxListTile(
            value: _understood,
            onChanged: _busy ? null : (v) => setState(() => _understood = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            activeColor: DeleteAccountScreen.danger,
            title: Text(s.vhDeleteAccountUnderstand,
                style: VH.body.copyWith(color: VH.textPrimary)),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: VH.s2),
            Text(_error!, style: VH.body.copyWith(color: const Color(0xFFFF8A80))),
          ],
          const SizedBox(height: VH.s4),
          SizedBox(
            height: 48,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: DeleteAccountScreen.danger,
                foregroundColor: Colors.white,
                disabledBackgroundColor: VH.surface3,
                disabledForegroundColor: VH.textTertiary,
              ),
              onPressed: (_understood && !_busy && user != null) ? _delete : null,
              child: _busy
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(s.vhDeleteAccountConfirm),
            ),
          ),
        ],
      ),
    );
  }
}
