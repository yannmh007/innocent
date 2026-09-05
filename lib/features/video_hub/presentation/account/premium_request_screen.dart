import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../../domain/account.dart';
import '../account_provider.dart';
import '../video_hub_theme.dart';
import '../widgets/vh_insets.dart';

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

  const PremiumRequestScreen({super.key, required this.planId});

  @override
  ConsumerState<PremiumRequestScreen> createState() =>
      _PremiumRequestScreenState();
}

class _PremiumRequestScreenState
    extends ConsumerState<PremiumRequestScreen> {
  final TextEditingController _reference = TextEditingController();
  final TextEditingController _sender = TextEditingController();
  bool _busy = false;
  bool _submitted = false;

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
    super.dispose();
  }

  Future<void> _submit() async {
    if (_reference.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(accountRepositoryProvider).submitPremiumRequest(
            planId: widget.planId,
            reference: _reference.text.trim(),
            senderPhone: _sender.text.trim().isEmpty
                ? null
                : _sender.text.trim(),
          );
      ref.invalidate(myPremiumRequestsProvider);
      if (!mounted) return;
      setState(() => _submitted = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final instructions =
        ref.watch(paymentInstructionsProvider).asData?.value;

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
        title: Text(s.vhPayTitle, style: VH.heading),
      ),
      body: _submitted
          ? _SubmittedState(onDone: () => Navigator.of(context).pop(true))
          : ListView(
              padding: EdgeInsets.fromLTRB(VH.gutter, VH.s2, VH.gutter,
                  VhInsets.scrollBottom(context, extra: VH.s6)),
              children: <Widget>[
                if (instructions != null) ...<Widget>[
                  _Step(
                    number: 1,
                    title: s.vhPayStep1,
                    child: _PayeeCard(
                      instructions: instructions,
                      planId: widget.planId,
                    ),
                  ),
                  _Step(number: 2, title: s.vhPayStep2),
                  _Step(
                    number: 3,
                    title: s.vhPayStep3,
                    child: Column(
                      children: <Widget>[
                        const SizedBox(height: VH.s3),
                        _Field(
                          controller: _reference,
                          hint: s.vhPayReferenceHint,
                          keyboardType: TextInputType.text,
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
                  const SizedBox(height: VH.s4),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
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
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              s.vhPaySubmit,
                              style: VH.label.copyWith(
                                color: VH.textInverse,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: VH.s3),
                  // Said up front, not discovered afterwards. Someone who
                  // expects instant access and waits an hour feels cheated;
                  // someone told to expect a wait does not.
                  Text(
                    s.vhPayManualNote,
                    textAlign: TextAlign.center,
                    style: VH.meta.copyWith(height: 1.4, fontSize: 11.5),
                  ),
                ] else
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: VH.s6),
                    child: Center(child: CircularProgressIndicator()),
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

class _Step extends StatelessWidget {
  final int number;
  final String title;
  final Widget? child;

  const _Step({required this.number, required this.title, this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: VH.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: VH.surface3,
                  borderRadius: BorderRadius.circular(VH.rPill),
                ),
                child: Text(
                  '$number',
                  style: VH.badge.copyWith(letterSpacing: 0),
                ),
              ),
              const SizedBox(width: VH.s3),
              Expanded(
                child: Text(
                  title,
                  style: VH.label.copyWith(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (child != null) child!,
        ],
      ),
    );
  }
}

/// Confirmation that the claim is queued.
///
/// Says "waiting for review", never "you are premium". Telling someone they
/// have access before a human has confirmed the money arrived is how a free
/// account ends up watching paid content, and how the operator ends up
/// arguing with someone who genuinely believes they paid.
class _SubmittedState extends StatelessWidget {
  final VoidCallback onDone;

  const _SubmittedState({required this.onDone});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VH.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.schedule_rounded,
                size: 44, color: VH.textSecondary),
            const SizedBox(height: VH.s4),
            Text(s.vhPayQueuedTitle, style: VH.title,
                textAlign: TextAlign.center),
            const SizedBox(height: VH.s2),
            Text(
              s.vhPayQueuedBody,
              textAlign: TextAlign.center,
              style: VH.body,
            ),
            const SizedBox(height: VH.s5),
            FilledButton(
              onPressed: onDone,
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
                s.vhPayDone,
                style: VH.label.copyWith(
                  color: VH.textInverse,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
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
