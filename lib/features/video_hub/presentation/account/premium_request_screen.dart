import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../../data/api/api_exception.dart';
import '../../domain/account.dart';
import '../account_provider.dart';
import '../video_hub_theme.dart';
import '../widgets/vh_insets.dart';
import 'receipt_picker.dart';
import '../../../../core/theme/tab_title.dart';

/// KPay payment instructions, and the form that records the claim.
///
/// The app CANNOT verify a KPay transfer and does not pretend to. This screen
/// does two honest things: it tells the payer exactly where to send money, and
/// it records their claim so a person can check it against the real KPay
/// statement. Approval happens outside the app entirely.
///
/// The order on screen matters. Instructions first, form second: asking for a
/// transaction id before saying where to pay is asking for something the user
/// does not have yet, and a form field they cannot fill is where they leave.
class PremiumRequestScreen extends ConsumerStatefulWidget {
  final String planId;

  /// Opens on the sent page — for the screen harness, which has no server
  /// to send to.
  @visibleForTesting
  final bool startSubmitted;

  const PremiumRequestScreen({
    super.key,
    required this.planId,
    this.startSubmitted = false,
  });

  @override
  ConsumerState<PremiumRequestScreen> createState() =>
      _PremiumRequestScreenState();
}

class _PremiumRequestScreenState
    extends ConsumerState<PremiumRequestScreen> {
  final TextEditingController _reference = TextEditingController();
  final TextEditingController _sender = TextEditingController();

  /// The payer's own words (migration 042): "paid from my sister's KPay",
  /// "sent it at 9 pm". A screenshot shows the money; this explains it.
  final TextEditingController _note = TextEditingController();
  bool _busy = false;
  late bool _submitted = widget.startSubmitted;

  /// The receipt's screenshot — the proof (migration 040). The transaction
  /// id is optional once there is one.
  Uint8List? _proof;

  /// The transaction id field, folded away until asked for: most people do
  /// not know what it is, and a field they cannot fill is where they stop.
  bool _showTxn = false;

  /// audit_video_hub.md M1. There was no such field, because there was no
  /// catch: `_submit` was try/finally. On a timeout the spinner became a
  /// button again and NOTHING else happened — no message, no retry — on the
  /// screen a user reaches AFTER sending Kyat through KPay. They either
  /// submit again, writing a second premium_requests row for one payment
  /// (the reconciliation problem premium_backend_spec.md §5 warns about by
  /// name), or close the app believing the claim is queued and wait for an
  /// approval nobody knows to make.
  String? _error;

  @override
  void initState() {
    super.initState();
    // The signed-in number is almost always the sending number, so it is
    // pre-filled rather than re-typed - and still editable, because sometimes
    // a family member pays.
    final phone = ref.read(accountProvider).user?.phone;
    if (phone != null) _sender.text = phone;
  }

  @override
  void dispose() {
    _reference.dispose();
    _sender.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final s = AppStrings.of(context);
    if (_proof == null && _reference.text.trim().isEmpty) {
      setState(() => _error = s.vhPayNeedProof);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final proof = _proof == null ? null : await shrinkReceipt(_proof!);
      final price = ref
          .read(paymentInstructionsProvider)
          .asData
          ?.value
          .prices[widget.planId];
      await ref.read(accountRepositoryProvider).submitPremiumRequest(
            planId: widget.planId,
            reference: _reference.text.trim(),
            senderPhone: _sender.text.trim().isEmpty
                ? null
                : _sender.text.trim(),
            proof: proof,
            priceShown: price,
            message: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
      ref.invalidate(myPremiumRequestsProvider);
      if (!mounted) return;
      setState(() => _submitted = true);
    } on ApiException catch (e) {
      if (!mounted) return;
      final s = AppStrings.of(context);
      setState(() => _error = e.kind == ApiErrorKind.tooManyRequests
          ? s.vhPayTooMany
          : (e.code == 'bad_image' || e.code == 'too_big')
              ? s.vhPayBadImage
              : s.vhPaySubmitFailed);
    } catch (_) {
      // The message says NOTHING WAS RECORDED, deliberately. A user who is
      // unsure whether their claim went through submits again, and a second
      // row for one payment is the operator's problem to untangle later. The
      // form keeps its contents so retrying is one tap, not a re-type of a
      // KPay transaction id copied off another screen.
      if (!mounted) return;
      setState(() => _error = AppStrings.of(context).vhPaySubmitFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final instructionsAsync = ref.watch(paymentInstructionsProvider);
    final instructions = instructionsAsync.asData?.value;
    // audit_video_hub.md M2. `isPayable` is false only for the bundled
    // placeholder — `09-000-000-000`, which is not a KPay account. The screen
    // must not lay that out as something to send money to, so the whole flow
    // (payee card, form, submit) is replaced by an honest refusal. A cached
    // answer IS payable: real digits, possibly stale prices, shown with a
    // warning.

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
        title: Text(s.vhPayTitle, style: kAppBarTitleStyle.copyWith(color: VH.textPrimary)),
      ),
      body: _submitted
          ? _SubmittedState(onDone: () => Navigator.of(context).pop(true))
          : ListView(
              padding: EdgeInsets.fromLTRB(VH.gutter, VH.s2, VH.gutter,
                  VhInsets.scrollBottom(context, extra: VH.s6)),
              children: <Widget>[
                if (instructions != null && instructions.isPayable) ...<Widget>[
                  if (instructions.source == PaymentSource.cached) ...<Widget>[
                    _Notice(
                      icon: Icons.cloud_off,
                      message: s.vhPayDetailsStale,
                    ),
                    const SizedBox(height: VH.s4),
                  ],
                  _PlanHero(
                    planId: widget.planId,
                    price: instructions.prices[widget.planId] ?? '',
                  ),
                  const SizedBox(height: VH.s5),
                  _Step(
                    number: 1,
                    title: s.vhPayStep1,
                    child: _PayeeCard(
                      instructions: instructions,
                      planId: widget.planId,
                    ),
                  ),
                  _Step(
                    number: 2,
                    title: s.vhPayStep2,
                    // One tap to the wallet, with the number already copied
                    // from the card above.
                    child: Padding(
                      padding: const EdgeInsets.only(top: VH.s3),
                      child: OutlinedButton.icon(
                        onPressed: () => _openKpay(context),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: Text(s.vhPayOpenKpay),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: VH.textPrimary,
                          side: const BorderSide(color: VH.hairline),
                          padding: const EdgeInsets.symmetric(
                              horizontal: VH.s4, vertical: VH.s3),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(VH.rControl),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _Step(
                    number: 3,
                    title: s.vhPayStep3,
                    done: _proof != null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const SizedBox(height: VH.s3),
                        ReceiptPicker(
                          selected: _proof,
                          onChanged: (b) => setState(() {
                            _proof = b;
                            _error = null;
                          }),
                        ),
                        const SizedBox(height: VH.s3),
                        if (_showTxn || _reference.text.isNotEmpty)
                          _Field(
                            controller: _reference,
                            hint: s.vhPayReferenceHint,
                            keyboardType: TextInputType.text,
                          )
                        else
                          TextButton.icon(
                            onPressed: () => setState(() => _showTxn = true),
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: Text(s.vhPayAddTxn),
                            style: TextButton.styleFrom(
                                foregroundColor: VH.textSecondary),
                          ),
                        const SizedBox(height: VH.s3),
                        _Field(
                          controller: _sender,
                          hint: s.vhPaySenderHint,
                          keyboardType: TextInputType.phone,
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9+ -]')),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _Step(
                    number: 4,
                    title: s.vhPayStep4,
                    last: true,
                    child: Padding(
                      padding: const EdgeInsets.only(top: VH.s3),
                      child: _NoteField(controller: _note),
                    ),
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: VH.s2),
                    _Notice(
                      icon: Icons.error_outline,
                      message: _error!,
                      emphasise: true,
                    ),
                  ],
                  const SizedBox(height: VH.s4),
                  _GoldButton(
                    label: s.vhPaySubmit,
                    icon: Icons.send_rounded,
                    busy: _busy,
                    onPressed: _busy ? null : _submit,
                  ),
                  const SizedBox(height: VH.s3),
                  // Where the screenshot goes, said where it is sent: a
                  // receipt carries a name and a number.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const Icon(Icons.lock_outline_rounded,
                          size: 13, color: VH.textTertiary),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          s.vhPayPrivate,
                          textAlign: TextAlign.center,
                          style: VH.meta.copyWith(fontSize: 11.5, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: VH.s2),
                  // Said up front, not discovered afterwards. Someone who
                  // expects instant access and waits an hour feels cheated;
                  // someone told to expect a wait does not.
                  Text(
                    s.vhPayManualNote,
                    textAlign: TextAlign.center,
                    style: VH.meta.copyWith(height: 1.5, fontSize: 11.5),
                  ),
                ] else if (instructionsAsync.isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: VH.s6),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...<Widget>[
                  // Nothing payable: either the fetch failed with no cached
                  // answer, or it returned a row with no payee. Both used to
                  // land on the bundled `09-000-000-000` with a Copy button
                  // under "send the money here". Refusing is the only honest
                  // thing a payment screen can do when it does not know where
                  // the money goes.
                  const SizedBox(height: VH.s6),
                  _Notice(
                    icon: Icons.error_outline,
                    message: s.vhPayDetailsUnavailable,
                    emphasise: true,
                  ),
                  const SizedBox(height: VH.s4),
                  Center(
                    child: FilledButton(
                      onPressed: () =>
                          ref.invalidate(paymentInstructionsProvider),
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
                        s.vhRetry,
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
}

/// KPay's package. Opening it saves hunting for the wallet on the home
/// screen with the amount and the number in mind.
const String _kpayPackage = 'com.kbzbank.kpaycustomer';

Future<void> _openKpay(BuildContext context) async {
  bool opened = false;
  try {
    opened = await const MethodChannel('mx_clone/apps').invokeMethod<bool>(
            'launchPackage', <String, dynamic>{'package': _kpayPackage}) ??
        false;
  } catch (_) {}
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(AppStrings.of(context).vhPayNoKpay),
      duration: const Duration(seconds: 2),
    ));
  }
}

/// A line the user has to read before acting — a stale-details warning, or a
/// submit that failed. Deliberately not a SnackBar: both of these are about
/// money and must stay on screen next to the thing they describe, rather than
/// sliding away after two seconds while the user is reading their KPay app.
class _Notice extends StatelessWidget {
  final IconData icon;
  final String message;
  final bool emphasise;

  const _Notice({
    required this.icon,
    required this.message,
    this.emphasise = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = emphasise ? VH.accent : VH.textSecondary;
    return Container(
      padding: const EdgeInsets.all(VH.s3),
      decoration: BoxDecoration(
        color: VH.surface1,
        borderRadius: BorderRadius.circular(VH.rControl),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 17, color: color),
          const SizedBox(width: VH.s3),
          Expanded(
            child: Text(
              message,
              style: VH.body.copyWith(fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _PayeeCard extends StatelessWidget {
  final PaymentInstructions instructions;
  final String planId;

  const _PayeeCard({required this.instructions, required this.planId});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final price = instructions.prices[planId] ?? '';

    return Container(
      margin: const EdgeInsets.only(top: VH.s3),
      padding: const EdgeInsets.all(VH.s4),
      decoration: BoxDecoration(
        color: VH.surface1,
        borderRadius: BorderRadius.circular(VH.rControl),
        border: Border.all(color: VH.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Row(label: s.vhPayPayee, value: instructions.payeeName),
          const SizedBox(height: VH.s3),
          // Copyable, because a mistyped digit sends money to a stranger and
          // produces a support conversation nobody can resolve.
          _Row(
            label: s.vhPayNumber,
            value: instructions.payeeNumber,
            copyable: true,
          ),
          if (price.isNotEmpty) ...<Widget>[
            const SizedBox(height: VH.s3),
            _Row(label: s.vhPayAmount, value: price, emphasise: true),
          ],
          if (instructions.note != null) ...<Widget>[
            const SizedBox(height: VH.s3),
            Text(instructions.note!, style: VH.meta.copyWith(fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool copyable;
  final bool emphasise;

  const _Row({
    required this.label,
    required this.value,
    this.copyable = false,
    this.emphasise = false,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(label, style: VH.meta.copyWith(fontSize: 12)),
        ),
        Text(
          value,
          style: VH.label.copyWith(
            fontSize: emphasise ? 16 : 14.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (copyable) ...<Widget>[
          const SizedBox(width: VH.s2),
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(s.vhPayCopied),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
            customBorder: const CircleBorder(),
            child: const SizedBox(
              width: 34,
              height: 34,
              child: Icon(Icons.copy_rounded, size: 16, color: VH.textSecondary),
            ),
          ),
        ],
      ],
    );
  }
}

/// The gold of Premium — the console's accent, so the two ends of a payment
/// look like one thing.
const Color _gold = Color(0xFFF0B429);
const Color _goldDeep = Color(0xFFC88A12);

/// One step of the payment, drawn as a vertical stepper: a numbered disc,
/// a line down to the next step, and a tick once the step is done.
class _Step extends StatelessWidget {
  final int number;
  final String title;
  final Widget? child;
  final bool done;
  final bool last;

  const _Step({
    required this.number,
    required this.title,
    this.child,
    this.done = false,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 28,
            child: Column(
              children: <Widget>[
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: done ? _gold : VH.surface2,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: done ? _gold : _gold.withAlpha(0x66), width: 1.4),
                  ),
                  child: done
                      ? const Icon(Icons.check_rounded,
                          size: 16, color: VH.textInverse)
                      : Text(
                          '$number',
                          style: VH.badge.copyWith(
                              letterSpacing: 0,
                              color: _gold,
                              fontSize: 12,
                              fontWeight: FontWeight.w800),
                        ),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 1.4,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: VH.hairline,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: VH.s3),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? VH.s3 : VH.s5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      title,
                      style: VH.label.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.45,
                      ),
                    ),
                  ),
                  if (child != null) child!,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What is being bought, at the top: the plan, its price, and what it
/// opens — so the screen that asks for money first says what for.
class _PlanHero extends StatelessWidget {
  final String planId;
  final String price;

  const _PlanHero({required this.planId, required this.price});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final plan = planId == 'yearly'
        ? s.vhPlanYearly
        : planId == 'monthly'
            ? s.vhPlanMonthly
            : planId;
    return Container(
      padding: const EdgeInsets.fromLTRB(VH.s4, VH.s4, VH.s4, VH.s4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withAlpha(0x55)),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF2A2108), Color(0xFF14120C), VH.surface1],
          stops: <double>[0, 0.55, 1],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[_gold, _goldDeep],
                  ),
                ),
                child: const Icon(Icons.workspace_premium_rounded,
                    size: 22, color: VH.textInverse),
              ),
              const SizedBox(width: VH.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(s.vhPaywallTitle,
                        style: VH.label.copyWith(
                            fontSize: 15.5, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(plan,
                        style: VH.meta.copyWith(
                            fontSize: 12.5, color: _gold, height: 1.4)),
                  ],
                ),
              ),
              if (price.isNotEmpty)
                Text(
                  price,
                  style: VH.label.copyWith(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: VH.textPrimary,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: VH.s3),
          const Divider(height: 1, color: VH.hairline),
          const SizedBox(height: VH.s3),
          _Perk(icon: Icons.play_circle_outline_rounded, text: s.vhPerkPlay),
          _Perk(icon: Icons.photo_library_outlined, text: s.vhPerkMedia),
          _Perk(icon: Icons.hd_outlined, text: s.vhPerkQuality, last: true),
        ],
      ),
    );
  }
}

class _Perk extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool last;

  const _Perk({required this.icon, required this.text, this.last = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : VH.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 17, color: _gold),
          const SizedBox(width: VH.s3),
          Expanded(
            child: Text(text,
                style: VH.body.copyWith(fontSize: 13, height: 1.45)),
          ),
        ],
      ),
    );
  }
}

/// The payer's note: several lines, with a counter as the limit nears.
class _NoteField extends StatelessWidget {
  final TextEditingController controller;

  const _NoteField({required this.controller});

  static const int limit = 500;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return TextField(
      controller: controller,
      minLines: 3,
      maxLines: 6,
      maxLength: limit,
      maxLengthEnforcement: MaxLengthEnforcement.enforced,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      style: VH.label.copyWith(
          fontSize: 14.5, fontWeight: FontWeight.w400, height: 1.55),
      buildCounter: (context,
              {required int currentLength,
              required bool isFocused,
              required int? maxLength}) =>
          currentLength > limit - 100
              ? Text('$currentLength / $limit',
                  style: VH.meta.copyWith(fontSize: 11))
              : null,
      decoration: InputDecoration(
        hintText: s.vhPayNoteHint,
        hintMaxLines: 3,
        hintStyle: VH.label.copyWith(
          color: VH.textTertiary,
          fontSize: 14,
          fontWeight: FontWeight.w400,
          height: 1.55,
        ),
        filled: true,
        fillColor: VH.surface3,
        contentPadding: const EdgeInsets.all(VH.s4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VH.rControl),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VH.rControl),
          borderSide: BorderSide(color: _gold.withAlpha(0x99)),
        ),
      ),
    );
  }
}

/// The one loud thing on the screen: gold, full width.
class _GoldButton extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final IconData? icon;

  const _GoldButton(
      {required this.label,
      required this.busy,
      required this.onPressed,
      this.icon});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        opacity: onPressed == null && !busy ? 0.5 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(
                colors: <Color>[Color(0xFFF7C948), _gold, _goldDeep]),
            boxShadow: <BoxShadow>[
              BoxShadow(
                  color: _gold.withAlpha(0x40),
                  blurRadius: 18,
                  offset: const Offset(0, 6)),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onPressed,
              child: SizedBox(
                height: 54,
                child: Center(
                  child: busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.4, color: VH.textInverse),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (icon != null) ...<Widget>[
                              Icon(icon, size: 18, color: VH.textInverse),
                              const SizedBox(width: VH.s2),
                            ],
                            Text(
                              label,
                              style: VH.label.copyWith(
                                color: VH.textInverse,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Confirmation that the claim is queued.
///
/// Says "waiting for review", never "you are premium". Telling someone they
/// have access before a human has confirmed the money arrived is how a free
/// account ends up watching paid content, and how the operator ends up
/// arguing with someone who genuinely believes they paid. And says what
/// happens next, in order, so the wait has a shape.
class _SubmittedState extends StatelessWidget {
  final VoidCallback onDone;

  const _SubmittedState({required this.onDone});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(VH.s5, VH.s6, VH.s5,
          VhInsets.scrollBottom(context, extra: VH.s6)),
      children: <Widget>[
        Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.6, end: 1),
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutBack,
            builder: (context, v, child) =>
                Transform.scale(scale: v, child: child),
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[_gold, _goldDeep],
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(color: _gold.withAlpha(0x4D), blurRadius: 28),
                ],
              ),
              child: const Icon(Icons.check_rounded,
                  size: 46, color: VH.textInverse),
            ),
          ),
        ),
        const SizedBox(height: VH.s5),
        Text(s.vhPayQueuedTitle,
            style: VH.title.copyWith(height: 1.4), textAlign: TextAlign.center),
        const SizedBox(height: VH.s2),
        Text(
          s.vhPayQueuedBody,
          textAlign: TextAlign.center,
          style: VH.body.copyWith(height: 1.6),
        ),
        const SizedBox(height: VH.s6),
        Container(
          padding: const EdgeInsets.all(VH.s4),
          decoration: BoxDecoration(
            color: VH.surface1,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: VH.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(s.vhPayNextTitle,
                  style: VH.label.copyWith(
                      fontSize: 13, color: VH.textSecondary, height: 1.4)),
              const SizedBox(height: VH.s3),
              _NextRow(icon: Icons.inbox_rounded, text: s.vhPayNext1, done: true),
              _NextRow(icon: Icons.fact_check_outlined, text: s.vhPayNext2),
              _NextRow(
                  icon: Icons.workspace_premium_rounded,
                  text: s.vhPayNext3,
                  last: true),
            ],
          ),
        ),
        const SizedBox(height: VH.s6),
        _GoldButton(label: s.vhPayDone, busy: false, onPressed: onDone),
      ],
    );
  }
}

class _NextRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool done;
  final bool last;

  const _NextRow(
      {required this.icon,
      required this.text,
      this.done = false,
      this.last = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : VH.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: done ? _gold.withAlpha(0x2E) : VH.surface3,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(done ? Icons.check_rounded : icon,
                size: 17, color: done ? _gold : VH.textSecondary),
          ),
          const SizedBox(width: VH.s3),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(text,
                  style: VH.body.copyWith(fontSize: 13.5, height: 1.5)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  const _Field({
    required this.controller,
    required this.hint,
    required this.keyboardType,
    this.inputFormatters,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
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
