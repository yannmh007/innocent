import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/services/preferences/player_settings_service.dart';
import '../../data/local_account_repository.dart';
import '../../domain/access.dart';
import '../../domain/account.dart';
import '../account_provider.dart';
import '../bookmarks_provider.dart';
import '../bookmarks_screen.dart';
import '../data_saver_panel.dart';
import '../video_hub_theme.dart';
import '../widgets/vh_insets.dart';
import '../downloads_screen.dart';
import 'premium_request_screen.dart';
import 'report_problem_sheet.dart';
import 'sign_in_sheet.dart';
import '../../../../core/theme/tab_title.dart';

/// Account and subscription status.
///
/// Exists because a manually-approved subscription has a WAIT in the middle of
/// it, and a wait with no visible state is indistinguishable from a failure.
/// Someone who paid twenty minutes ago needs to see "submitted, under review"
/// rather than a screen that still says Upgrade - otherwise they pay again, or
/// they message support, or they leave.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final account = ref.watch(accountProvider);
    final requests = ref.watch(myPremiumRequestsProvider).asData?.value ??
        const <PremiumRequest>[];

    final library = <Widget>[
          // Library entries, ABOVE the payment history. Someone opening
          // this screen is far more often looking for what they saved than
          // for a receipt, and the common errand belongs at the top.
          const SizedBox(height: VH.s5),
          _LibraryTile(
            icon: Icons.bookmark_border_rounded,
            label: s.vhLibraryBookmarks,
            subtitle: s.vhLibraryBookmarksHint,
            // OPEN TO EVERYONE. Saving needs no account: bookmarks live on
            // the phone, and signing in only adds that they follow the
            // viewer to other phones.
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const BookmarksScreen()),
            ),
            locked: false,
            trailing: ref.watch(titleBookmarksProvider).length,
          ),
          const SizedBox(height: VH.s2),
          _LibraryTile(
            icon: Icons.download_outlined,
            label: s.vhLibraryDownloads,
            subtitle: s.vhLibraryDownloadsHint,
            // NOT LOCKED. It said "Premium" with a padlock, but free titles
            // download for everyone (AccessPolicy.canDownload) — the device
            // lab downloaded one on a free account and then found its shelf
            // behind a lock. A premium title's own button says what it costs.
            locked: false,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DownloadsScreen(),
              ),
            ),
          ),
          const SizedBox(height: VH.s2),
          _LibraryTile(
            icon: Icons.data_saver_on_rounded,
            label: s.vhDataSaver,
            subtitle: s.vhLibraryDataSaverHint,
            locked: false,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DataSaverScreen()),
            ),
            trailingText: ref.watch(playerSettingsProvider)
                    .get(PlayerSetting.albumDataSaver)
                ? s.vhOn
                : null,
          ),
          const SizedBox(height: VH.s2),
          // REPORT A PROBLEM, beside the things it is usually about. What it
          // sends, and why it exists, is in DiagnosticsReport.
          _LibraryTile(
            icon: Icons.support_agent_rounded,
            label: s.vhDiagTitle,
            subtitle: s.vhDiagHint,
            locked: false,
            onTap: () => ReportProblemSheet.show(context),
          ),
    ];

    return Scaffold(
      backgroundColor: VH.canvas,
      appBar: AppBar(
        backgroundColor: VH.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: VH.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(s.vhAccountTitle, style: kAppBarTitleStyle.copyWith(color: VH.textPrimary)),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(accountProvider.notifier).refresh();
          ref.invalidate(myPremiumRequestsProvider);
        },
        backgroundColor: VH.surface2,
        color: VH.textPrimary,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(VH.gutter, VH.s3, VH.gutter,
              VhInsets.scrollBottom(context, extra: VH.s6)),
          children: <Widget>[
            if (!account.isSignedIn)
              ...<Widget>[
                _SignedOut(onSignIn: () => SignInSheet.show(context)),
                ...library,
              ]
            else ...<Widget>[
              _IdentityCard(user: account.user!),
              const SizedBox(height: VH.s4),
              _StatusCard(
                entitlement: account.entitlement,
                onUpgrade: () => Navigator.of(context).push(
                  MaterialPageRoute<bool>(
                    builder: (_) =>
                        const PremiumRequestScreen(planId: 'yearly'),
                  ),
                ),
              ),
              ...library,
            if (requests.isNotEmpty) ...<Widget>[
                const SizedBox(height: VH.s5),
                Text(s.vhAccountRequests, style: VH.heading),
                const SizedBox(height: VH.s3),
                ...requests.map((r) => _RequestRow(request: r)),
              ],
              const SizedBox(height: VH.s5),
              // DEV ONLY. Stands in for the operator approving a payment in
              // the admin dashboard; nothing equivalent exists once the real
              // backend is wired, because the app must only ever READ the
              // result of an approval.
              _DevTools(
                onApprove: () async {
                  final repo = ref.read(accountRepositoryProvider);
                  if (repo is LocalAccountRepository) {
                    await repo.devApproveLatest();
                    await ref.read(accountProvider.notifier).refresh();
                    ref.invalidate(myPremiumRequestsProvider);
                  }
                },
                onSignOut: () async {
                  await ref.read(accountProvider.notifier).signOut();
                  ref.invalidate(myPremiumRequestsProvider);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LibraryTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool locked;
  final VoidCallback onTap;

  /// A count shown as a pill before the chevron (saved titles), or null.
  final int? trailing;

  /// A word shown instead, e.g. "On" for the data saver.
  final String? trailingText;

  const _LibraryTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.locked,
    required this.onTap,
    this.trailing,
    this.trailingText,
  });

  @override
  Widget build(BuildContext context) {
    final pill = trailingText ?? ((trailing ?? 0) > 0 ? '$trailing' : null);
    return Material(
      color: VH.surface1,
      borderRadius: BorderRadius.circular(VH.rCard),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(VH.rCard),
        child: Container(
          padding: const EdgeInsets.fromLTRB(VH.s3, VH.s3, VH.s2, VH.s3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(VH.rCard),
            border: Border.all(color: VH.hairline),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: VH.surface3,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: VH.textPrimary),
              ),
              const SizedBox(width: VH.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(label, style: VH.label.copyWith(fontSize: 14.5)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: VH.meta.copyWith(fontSize: 11.5)),
                  ],
                ),
              ),
              if (pill != null)
                Container(
                  margin: const EdgeInsets.only(left: VH.s2),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: VH.surface3,
                    borderRadius: BorderRadius.circular(VH.rPill),
                  ),
                  child: Text(pill,
                      style: VH.badge.copyWith(color: VH.textPrimary, fontSize: 11)),
                ),
              const SizedBox(width: VH.s1),
              if (locked)
                const Icon(Icons.lock_outline_rounded,
                    size: 16, color: VH.textTertiary)
              else
                const Icon(Icons.chevron_right_rounded,
                    size: 22, color: VH.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignedOut extends StatelessWidget {
  final VoidCallback onSignIn;

  const _SignedOut({required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VH.s6),
      child: Column(
        children: <Widget>[
          const Icon(Icons.account_circle_outlined,
              size: 48, color: VH.textTertiary),
          const SizedBox(height: VH.s4),
          Text(s.vhSignInWhy, textAlign: TextAlign.center, style: VH.body),
          const SizedBox(height: VH.s5),
          FilledButton(
            onPressed: onSignIn,
            style: FilledButton.styleFrom(
              backgroundColor: VH.textPrimary,
              foregroundColor: VH.textInverse,
              padding: const EdgeInsets.symmetric(
                  horizontal: VH.s6, vertical: VH.s3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(VH.rControl),
              ),
            ),
            child: Text(
              s.vhSignInTitle,
              style: VH.label.copyWith(
                color: VH.textInverse,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  final AuthUser user;

  const _IdentityCard({required this.user});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(VH.s4),
      decoration: BoxDecoration(
        color: VH.surface1,
        borderRadius: BorderRadius.circular(VH.rControl),
        border: Border.all(color: VH.hairline),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: VH.surface3,
              borderRadius: BorderRadius.circular(VH.rPill),
            ),
            child: const Icon(Icons.person_rounded,
                size: 20, color: VH.textSecondary),
          ),
          const SizedBox(width: VH.s3),
          Expanded(
            child: Text(
              user.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: VH.label.copyWith(fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final Entitlement entitlement;
  final VoidCallback onUpgrade;

  const _StatusCard({required this.entitlement, required this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final active = entitlement.isActive;
    final expires = entitlement.expiresAt;

    return Container(
      padding: const EdgeInsets.all(VH.s4),
      decoration: BoxDecoration(
        color: active ? VH.textPrimary : VH.surface1,
        borderRadius: BorderRadius.circular(VH.rControl),
        border: Border.all(color: active ? Colors.transparent : VH.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                active
                    ? Icons.workspace_premium_rounded
                    : Icons.lock_outline_rounded,
                size: 20,
                color: active ? VH.textInverse : VH.textSecondary,
              ),
              const SizedBox(width: VH.s2),
              Text(
                active ? s.vhPremiumActive : s.vhAccountFreePlan,
                style: VH.label.copyWith(
                  color: active ? VH.textInverse : VH.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (active && expires != null) ...<Widget>[
            const SizedBox(height: VH.s2),
            // The expiry date, plainly. A subscription that lapses without
            // warning reads as the app breaking.
            Text(
              s.vhAccountExpires(_formatDate(expires)),
              style: VH.meta.copyWith(
                color: VH.textInverse.withOpacity(0.75),
                fontSize: 12,
              ),
            ),
          ],
          if (!active) ...<Widget>[
            const SizedBox(height: VH.s4),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: onUpgrade,
                style: FilledButton.styleFrom(
                  backgroundColor: VH.textPrimary,
                  foregroundColor: VH.textInverse,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(VH.rControl),
                  ),
                ),
                child: Text(
                  s.vhUpgrade,
                  style: VH.label.copyWith(
                    color: VH.textInverse,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// yyyy-MM-dd without pulling in a formatter. Unambiguous in every locale,
  /// which a numeric day/month order is not.
  static String _formatDate(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }
}

/// One payment, as the payer sees it: what state it is in, in a colour that
/// says so; what they wrote with it; and Innocent's reply — the reason on a
/// rejection, a word on an approval.
class _RequestRow extends StatelessWidget {
  final PremiumRequest request;

  const _RequestRow({required this.request});

  static const Color _amber = Color(0xFFF0B429);
  static const Color _green = Color(0xFF34D399);
  static const Color _red = Color(0xFFF87171);

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final (IconData icon, String label, Color tone) = switch (request.status) {
      PremiumRequestStatus.pending =>
        (Icons.schedule_rounded, s.vhRequestPending, _amber),
      PremiumRequestStatus.approved =>
        (Icons.check_circle_rounded, s.vhRequestApproved, _green),
      PremiumRequestStatus.rejected =>
        (Icons.cancel_rounded, s.vhRequestRejected, _red),
    };
    final plan = request.planId == 'yearly'
        ? s.vhPlanYearly
        : request.planId == 'monthly'
            ? s.vhPlanMonthly
            : request.planId;
    final d = request.submittedAt;
    final when = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final message = request.message;
    final note = request.note;

    return Container(
      margin: const EdgeInsets.only(bottom: VH.s3),
      padding: const EdgeInsets.all(VH.s4),
      decoration: BoxDecoration(
        color: VH.surface1,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tone.withAlpha(0x40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: tone.withAlpha(0x24),
                  borderRadius: BorderRadius.circular(VH.rPill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(icon, size: 14, color: tone),
                    const SizedBox(width: 5),
                    Text(label,
                        style: VH.label.copyWith(
                            fontSize: 12, color: tone, height: 1.35)),
                  ],
                ),
              ),
              const Spacer(),
              Text(plan,
                  style: VH.label.copyWith(
                      fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: VH.s2),
          Text(
            [when, if (request.reference.isNotEmpty) request.reference]
                .join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: VH.meta.copyWith(fontSize: 11.5),
          ),
          if (message != null && message.isNotEmpty) ...<Widget>[
            const SizedBox(height: VH.s3),
            _Quote(label: s.vhRequestYouWrote, text: message,
                color: VH.textTertiary),
          ],
          if (note != null && note.isNotEmpty) ...<Widget>[
            const SizedBox(height: VH.s3),
            _Quote(label: s.vhRequestReply, text: note, color: tone),
          ],
        ],
      ),
    );
  }
}

class _Quote extends StatelessWidget {
  final String label;
  final String text;
  final Color color;

  const _Quote({required this.label, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(VH.s3, VH.s2, VH.s3, VH.s2),
      decoration: BoxDecoration(
        color: VH.surface2,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(10),
          bottomRight: Radius.circular(10),
        ),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label,
              style: VH.meta.copyWith(fontSize: 11, color: color, height: 1.4)),
          const SizedBox(height: 2),
          Text(text, style: VH.body.copyWith(fontSize: 13, height: 1.55)),
        ],
      ),
    );
  }
}

class _DevTools extends StatelessWidget {
  final VoidCallback onApprove;
  final VoidCallback onSignOut;

  const _DevTools({required this.onApprove, required this.onSignOut});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Column(
      children: <Widget>[
        const Divider(color: VH.hairline, height: VH.s6),
        // DEBUG BUILDS ONLY.
        //
        // This button stands in for an operator approving a KPay transfer
        // against the real statement. In a release build it is a one-tap
        // self-upgrade: anyone signed in could grant themselves thirty days
        // and unlock every locked still and the full album. `LocalAccountRepository`
        // makes it harmless once a backend is configured — but "harmless as
        // long as a config value is set" is not a control, and the build that
        // ships to testers is exactly the build with no backend.
        //
        // `kDebugMode` is a compile-time constant, so the tree-shaker removes
        // this branch from a release binary entirely: the button is not
        // hidden, it is absent.
        if (kDebugMode)
          TextButton(
            onPressed: onApprove,
            child: Text(
              s.vhDevApprove,
              style: VH.label.copyWith(color: VH.textTertiary, fontSize: 12.5),
            ),
          ),
        TextButton(
          onPressed: onSignOut,
          child: Text(
            s.vhSignOut,
            style: VH.label.copyWith(color: VH.textSecondary),
          ),
        ),
      ],
    );
  }
}
