import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../../domain/video_content.dart';
import '../account/premium_request_screen.dart';
import '../account/sign_in_sheet.dart';
import '../account_provider.dart';
import '../video_hub_theme.dart';

/// The upgrade prompt.
///
/// Shown when a viewer reaches something they have not paid for. Three things
/// the research is unambiguous about, and which are easy to get wrong:
///
///   1. SAY WHAT IS BEING BOUGHT, SPECIFICALLY. Access to full content is the
///      single biggest reason people upgrade, so the sheet names the title and
///      counts what is locked ("unlock 11 more") rather than pitching the
///      abstract idea of a subscription.
///   2. SHOW THE PRICE UP FRONT. Hiding it behind a tap, or revealing the real
///      billing frequency at the last step, is the classic conversion killer -
///      and it is a dark pattern that costs more in retention than it wins.
///   3. LEAVE THE DOOR OPEN. A dismissible sheet over the content the user was
///      already looking at converts better than a wall, because they can still
///      see the thing they want.
///
/// PLANS ARE PLACEHOLDERS. They render the real layout so the screen can be
/// judged, and they are wired to nothing: [_purchase] records an entitlement
/// locally and takes no money. A real integration replaces that one call.
class PaywallSheet extends ConsumerWidget {
  /// The title that triggered this, when there is one. Null for a generic
  /// upgrade entry point.
  final VideoContent? content;

  /// How many items in that title are still locked.
  final int lockedCount;

  const PaywallSheet({super.key, this.content, this.lockedCount = 0});

  static Future<bool> show(
    BuildContext context, {
    VideoContent? content,
    int lockedCount = 0,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => PaywallSheet(content: content, lockedCount: lockedCount),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.84,
      ),
      decoration: const BoxDecoration(
        color: VH.surface2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(VH.rSheet)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: VH.s2, bottom: VH.s1),
              child: Center(
                child: Container(
                  width: 34,
                  height: 4,
                  decoration: BoxDecoration(
                    color: VH.textTertiary.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(
                    VH.gutter, VH.s3, VH.gutter, 0),
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: VH.textPrimary,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Icon(Icons.workspace_premium_rounded,
                            size: 20, color: VH.textInverse),
                      ),
                      const SizedBox(width: VH.s3),
                      Expanded(child: Text(s.vhPaywallTitle, style: VH.title)),
                    ],
                  ),
                  const SizedBox(height: VH.s3),
                  Text(_subtitle(s), style: VH.body),
                  const SizedBox(height: VH.s5),
                  _Benefit(icon: Icons.play_circle_outline, text: s.vhPerkPlay),
                  _Benefit(
                      icon: Icons.photo_library_outlined, text: s.vhPerkMedia),
                  _Benefit(icon: Icons.hd_outlined, text: s.vhPerkQuality),
                  const SizedBox(height: VH.s5),
                  // Both options visible at once with the annual saving stated.
                  // Making the user tap a toggle to discover the other price is
                  // where trust starts leaking.
                  _Plan(
                    label: s.vhPlanYearly,
                    price: s.vhPlanYearlyPrice,
                    note: s.vhPlanYearlyNote,
                    recommended: true,
                    onTap: () => _purchase(context, ref, 'yearly'),
                  ),
                  const SizedBox(height: VH.s2),
                  _Plan(
                    label: s.vhPlanMonthly,
                    price: s.vhPlanMonthlyPrice,
                    onTap: () => _purchase(context, ref, 'monthly'),
                  ),
                  const SizedBox(height: VH.s3),
                  Text(
                    s.vhPaywallFinePrint,
                    textAlign: TextAlign.center,
                    style: VH.meta.copyWith(height: 1.4),
                  ),
                  const SizedBox(height: VH.s3),
                  Center(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(
                        s.vhPaywallNotNow,
                        style: VH.label.copyWith(color: VH.textSecondary),
                      ),
                    ),
                  ),
                  const SizedBox(height: VH.s2),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle(AppStrings s) {
    final c = content;
    if (c == null) return s.vhPaywallGeneric;
    if (lockedCount > 0) return s.vhPaywallLockedCount(lockedCount);
    return s.vhPaywallForTitle(c.title);
  }

  /// Routes to payment. Grants NOTHING.
  ///
  /// The app cannot verify a KPay transfer, so it does not try: it collects a
  /// claim and a human checks it against the real statement. A client that
  /// decides for itself that it has been paid is a client that always has.
  ///
  /// Sign-in comes first because a payment has to attach to an account -
  /// there is no way to answer "who paid?" about an anonymous device.
  Future<void> _purchase(
      BuildContext context, WidgetRef ref, String planId) async {
    if (!ref.read(accountProvider).isSignedIn) {
      final signedIn = await SignInSheet.show(context);
      if (!signedIn || !context.mounted) return;
    }
    final submitted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PremiumRequestScreen(planId: planId),
      ),
    );
    if (!context.mounted) return;
    // false, not true: a queued claim is not access. Returning true here would
    // make the caller retry playback and show an error to someone who has just
    // paid correctly.
    Navigator.of(context).pop(false);
    if (submitted == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).vhPayQueuedTitle),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
}

class _Benefit extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Benefit({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: VH.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: VH.textPrimary),
          const SizedBox(width: VH.s3),
          Expanded(
            child: Text(
              text,
              style: VH.label.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class _Plan extends StatelessWidget {
  final String label;
  final String price;
  final String? note;
  final bool recommended;
  final VoidCallback onTap;

  const _Plan({
    required this.label,
    required this.price,
    required this.onTap,
    this.note,
    this.recommended = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VH.rControl),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: VH.s4, vertical: VH.s3),
        decoration: BoxDecoration(
          // The recommended plan is the one solid surface, the same way the
          // primary action is elsewhere - one loud element per screen.
          color: recommended ? VH.textPrimary : VH.surface3,
          borderRadius: BorderRadius.circular(VH.rControl),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    style: VH.label.copyWith(
                      color:
                          recommended ? VH.textInverse : VH.textPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (note != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      note!,
                      style: VH.meta.copyWith(
                        color: recommended
                            ? VH.textInverse.withOpacity(0.7)
                            : VH.textTertiary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Text(
              price,
              style: VH.label.copyWith(
                color: recommended ? VH.textInverse : VH.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
