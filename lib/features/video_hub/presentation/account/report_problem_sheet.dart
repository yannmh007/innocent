import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../../data/diagnostics_report.dart';
import '../account_provider.dart';
import '../video_hub_theme.dart';

/// "Report a problem": say what will be sent, take an optional line, send it,
/// and hand back a code to quote. See [DiagnosticsReport].
class ReportProblemSheet extends ConsumerStatefulWidget {
  const ReportProblemSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: VH.surface1,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (_) => const ReportProblemSheet(),
      );

  @override
  ConsumerState<ReportProblemSheet> createState() => _ReportProblemSheetState();
}

class _ReportProblemSheetState extends ConsumerState<ReportProblemSheet> {
  final _note = TextEditingController();
  bool _busy = false;
  String? _code;
  bool _failed = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final code = await DiagnosticsReport.send(
        ref.read(apiClientProvider),
        note: _note.text,
      );
      if (!mounted) return;
      setState(() => _code = code);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(VH.gutter, VH.s4, VH.gutter, VH.s5 + inset),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(s.vhDiagTitle, style: VH.heading),
            const SizedBox(height: VH.s2),
            if (_code == null) ...<Widget>[
              Text(s.vhDiagBody,
                  style: VH.body.copyWith(color: VH.textSecondary, height: 1.5)),
              const SizedBox(height: VH.s3),
              TextField(
                key: const ValueKey('diag-note'),
                controller: _note,
                maxLines: 3,
                maxLength: 1000,
                enabled: !_busy,
                style: VH.body,
                decoration: InputDecoration(
                  hintText: s.vhDiagNoteHint,
                  hintStyle: VH.meta,
                  filled: true,
                  fillColor: VH.surface2,
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(VH.rControl),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              if (_failed) ...<Widget>[
                const SizedBox(height: VH.s2),
                Text(s.vhDiagFailed,
                    style: VH.meta.copyWith(color: const Color(0xFFE5484D))),
              ],
              const SizedBox(height: VH.s3),
              SizedBox(
                height: 48,
                child: FilledButton(
                  key: const ValueKey('diag-send'),
                  onPressed: _busy ? null : _send,
                  style: FilledButton.styleFrom(
                    backgroundColor: VH.textPrimary,
                    foregroundColor: VH.textInverse,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(VH.rControl)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(s.send,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ] else ...<Widget>[
              Text(s.vhDiagSent, style: VH.body.copyWith(color: VH.textSecondary)),
              const SizedBox(height: VH.s3),
              // The code, big enough to read off a screen to somebody, and a
              // tap away from the clipboard.
              Material(
                color: VH.surface2,
                borderRadius: BorderRadius.circular(VH.rControl),
                child: InkWell(
                  key: const ValueKey('diag-code'),
                  borderRadius: BorderRadius.circular(VH.rControl),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: _code!));
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(s.vhDiagCopied)));
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: VH.s4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        SelectableText(_code!,
                            style: VH.heading.copyWith(
                                fontSize: 26,
                                letterSpacing: 4,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(width: VH.s3),
                        const Icon(Icons.copy_rounded,
                            size: 18, color: VH.textSecondary),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: VH.s3),
              Text(s.vhDiagSentHint,
                  style: VH.meta.copyWith(fontSize: 12.5, height: 1.45)),
            ],
          ],
        ),
      ),
    );
  }
}
