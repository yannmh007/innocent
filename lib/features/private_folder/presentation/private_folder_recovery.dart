import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/private_folder/private_folder_service.dart';
import '../../../core/services/secure_screen/secure_screen_service.dart';
import '../../../core/theme/app_colors.dart';
import '../data/private_folder_providers.dart';

/// Stable IDs for the built-in security questions. We store the ID (not the
/// display text) so the question renders in the user's current language and
/// a language switch never breaks an existing question. The localized text
/// is resolved on demand via [_questionText].
const List<String> _kSecurityQuestionIds = [
  'secQ1',
  'secQ2',
  'secQ3',
  'secQ4',
  'secQ5',
  'secQ6',
];

/// Resolve a question ID to its localized display text. Unknown IDs (e.g. a
/// legacy stored English string) are returned as-is so nothing is lost.
String _questionText(AppStrings s, String id) {
  switch (id) {
    case 'secQ1':
      return s.secQ1;
    case 'secQ2':
      return s.secQ2;
    case 'secQ3':
      return s.secQ3;
    case 'secQ4':
      return s.secQ4;
    case 'secQ5':
      return s.secQ5;
    case 'secQ6':
      return s.secQ6;
    default:
      return id;
  }
}

/// ═══════════════════════════════════════════════════════════════════
/// Recovery SETUP sheet — configure a security question and/or generate a
/// recovery key. Reachable from the vault overflow menu and offered once
/// right after the PIN is first created.
/// ═══════════════════════════════════════════════════════════════════
class RecoverySetupScreen extends ConsumerStatefulWidget {
  const RecoverySetupScreen({super.key});

  @override
  ConsumerState<RecoverySetupScreen> createState() =>
      _RecoverySetupScreenState();
}

class _RecoverySetupScreenState extends ConsumerState<RecoverySetupScreen> {
  bool _hasQuestion = false;
  bool _hasKey = false;
  bool _loading = true;

  PrivateFolderService get _svc => ref.read(privateFolderServiceProvider);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final q = await _svc.hasSecurityQuestion();
    final k = await _svc.hasRecoveryKey();
    if (mounted) {
      setState(() {
        _hasQuestion = q;
        _hasKey = k;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return SecureScreenGuard(
      child: Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(s.recoveryOptions,
            style: const TextStyle(
                color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(s.recoverySetupPrompt,
                    style: const TextStyle(
                        color: AppColors.white70, fontSize: 13.5, height: 1.4)),
                const SizedBox(height: 20),
                // Security question row.
                _optionCard(
                  icon: Icons.help_outline,
                  title: s.securityQuestion,
                  status: _hasQuestion ? s.recoveryConfigured : s.notConfigured,
                  configured: _hasQuestion,
                  onTap: _configureQuestion,
                ),
                const SizedBox(height: 12),
                // Recovery key row.
                _optionCard(
                  icon: Icons.vpn_key_outlined,
                  title: s.recoveryKey,
                  status: _hasKey ? s.recoveryConfigured : s.notConfigured,
                  configured: _hasKey,
                  onTap: _configureKey,
                  trailingLabel: _hasKey ? s.regenerateKey : null,
                ),
              ],
            ),
      ),
    );
  }

  Widget _optionCard({
    required IconData icon,
    required String title,
    required String status,
    required bool configured,
    required VoidCallback onTap,
    String? trailingLabel,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.darkSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: configured
                ? AppColors.accentBlue.withValues(alpha: 0.4)
                : AppColors.darkDivider,
          ),
        ),
        child: Row(
          children: [
            Icon(icon,
                color: configured ? AppColors.accentBlue : AppColors.white55,
                size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (configured)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Icon(Icons.check_circle,
                              color: AppColors.accentBlue, size: 14),
                        ),
                      Text(status,
                          style: TextStyle(
                              color: configured
                                  ? AppColors.accentBlue
                                  : AppColors.white55,
                              fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
            Text(trailingLabel ?? '',
                style: const TextStyle(
                    color: AppColors.accentBlue, fontSize: 12.5)),
            const Icon(Icons.chevron_right, color: AppColors.white40),
          ],
        ),
      ),
    );
  }

  Future<void> _configureQuestion() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => const _SecurityQuestionDialog(),
    );
    if (changed == true) _refresh();
  }

  Future<void> _configureKey() async {
    // Generate a fresh key and show it once.
    final key = await _svc.generateRecoveryKey();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RecoveryKeyDialog(recoveryKey: key),
    );
    _refresh();
  }
}

/// Security-question setup dialog (pick/type a question + answer).
class _SecurityQuestionDialog extends ConsumerStatefulWidget {
  const _SecurityQuestionDialog();

  @override
  ConsumerState<_SecurityQuestionDialog> createState() =>
      _SecurityQuestionDialogState();
}

class _SecurityQuestionDialogState
    extends ConsumerState<_SecurityQuestionDialog> {
  String _questionId = _kSecurityQuestionIds.first;
  final _answerCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _answerCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final answer = _answerCtrl.text.trim();
    if (answer.isEmpty) {
      setState(() => _error = AppStrings.of(context).answerRequired);
      return;
    }
    setState(() => _saving = true);
    await ref
        .read(privateFolderServiceProvider)
        .setSecurityQuestion(_questionId, answer);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return AlertDialog(
      backgroundColor: AppColors.darkSurface,
      title: Text(s.setSecurityQuestion,
          style: const TextStyle(color: Colors.white, fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.chooseAQuestion,
              style:
                  const TextStyle(color: AppColors.white55, fontSize: 12)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.darkBackground,
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButton<String>(
              value: _questionId,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              dropdownColor: AppColors.darkSurface,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: [
                for (final id in _kSecurityQuestionIds)
                  DropdownMenuItem(
                      value: id, child: Text(_questionText(s, id))),
              ],
              onChanged: (v) =>
                  setState(() => _questionId = v ?? _questionId),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _answerCtrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: s.securityAnswer,
              hintStyle: const TextStyle(color: AppColors.white40),
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(s.cancel)),
        TextButton(
            onPressed: _saving ? null : _save,
            child: Text(s.save)),
      ],
    );
  }
}

/// One-time recovery-key reveal. The key is already persisted (hashed);
/// this just shows the plaintext with a copy button and a strong warning.
class _RecoveryKeyDialog extends StatelessWidget {
  final String recoveryKey;
  const _RecoveryKeyDialog({required this.recoveryKey});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return AlertDialog(
      backgroundColor: AppColors.darkSurface,
      title: Text(s.recoveryKeyGenerated,
          style: const TextStyle(color: Colors.white, fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The key, monospaced + selectable, with a copy affordance.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.darkBackground,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.accentBlue.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    recoveryKey,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy,
                      color: AppColors.accentBlue, size: 20),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: recoveryKey));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(s.copiedToClipboard),
                        duration: const Duration(seconds: 1)));
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: AppColors.error, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.recoveryKeyWarning,
                    style: const TextStyle(
                        color: AppColors.white70,
                        fontSize: 12,
                        height: 1.4)),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.iSavedIt)),
      ],
    );
  }
}

/// ═══════════════════════════════════════════════════════════════════
/// Recovery FLOW — reached from "Forgot PIN?" on the unlock screen. Lets
/// the user prove identity via any configured method, then set a new PIN.
/// On success the caller is signalled (pop true) so it can unlock.
/// ═══════════════════════════════════════════════════════════════════
class RecoveryFlowScreen extends ConsumerStatefulWidget {
  const RecoveryFlowScreen({super.key});

  @override
  ConsumerState<RecoveryFlowScreen> createState() =>
      _RecoveryFlowScreenState();
}

enum _RecoveryStep { chooseMethod, answerQuestion, enterKey, setNewPin }

class _RecoveryFlowScreenState extends ConsumerState<RecoveryFlowScreen> {
  _RecoveryStep _step = _RecoveryStep.chooseMethod;
  bool _loading = true;
  bool _hasQuestion = false;
  bool _hasKey = false;
  String? _question;

  final _answerCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _pinConfirmCtrl = TextEditingController();
  String? _error;
  bool _busy = false;

  PrivateFolderService get _svc => ref.read(privateFolderServiceProvider);

  /// Blocks an attempt while a cooling-off period is running, and shows how
  /// long is left. Returns true when the caller must stop.
  ///
  /// Recovery shares ONE counter with the PIN pad on purpose. Two separate
  /// limiters would mean an attacker locked out of the PIN could simply
  /// switch to the security question and keep going at full speed, which is
  /// the same as having no limiter at all.
  Future<bool> _blockedByLockout(AppStrings s) async {
    final remaining = await _svc.lockoutRemaining();
    if (remaining == null) return false;
    if (!mounted) return true;
    setState(() {
      _busy = false;
      _error = s.tooManyAttemptsWait(remaining.inSeconds + 1);
    });
    return true;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final q = await _svc.hasSecurityQuestion();
    final k = await _svc.hasRecoveryKey();
    final qt = q ? await _svc.securityQuestion() : null;
    if (mounted) {
      setState(() {
        _hasQuestion = q;
        _hasKey = k;
        _question = qt;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _answerCtrl.dispose();
    _keyCtrl.dispose();
    _pinCtrl.dispose();
    _pinConfirmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    // If the user is deeper in the flow (answering / entering key / setting
    // a new PIN), a back gesture should step back to the method chooser
    // rather than abandoning recovery entirely. Only at the first step does
    // back leave the screen.
    final canLeave = _step == _RecoveryStep.chooseMethod;
    return SecureScreenGuard(
      child: PopScope(
      canPop: canLeave,
      onPopInvoked: (didPop) {
        if (!didPop) {
          setState(() {
            _error = null;
            _step = _RecoveryStep.chooseMethod;
          });
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.darkBackground,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: canLeave
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => setState(() {
                    _error = null;
                    _step = _RecoveryStep.chooseMethod;
                  }),
                ),
          title: Text(s.recoverVault,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700)),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(20),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.06, 0),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey(_step),
                  child: _buildStep(s),
                ),
              ),
            ),
      ),
      ),
    );
  }

  Widget _buildStep(AppStrings s) {
    switch (_step) {
      case _RecoveryStep.chooseMethod:
        return _chooseMethod(s);
      case _RecoveryStep.answerQuestion:
        return _answerQuestion(s);
      case _RecoveryStep.enterKey:
        return _enterKey(s);
      case _RecoveryStep.setNewPin:
        return _setNewPin(s);
    }
  }

  Widget _chooseMethod(AppStrings s) {
    // No method configured at all → dead end, be honest about it.
    if (!_hasQuestion && !_hasKey) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline,
                color: AppColors.white40, size: 48),
            const SizedBox(height: 16),
            Text(s.recoveryNotSetup,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.white55, fontSize: 14, height: 1.4)),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.chooseRecoveryMethod,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        if (_hasQuestion)
          _methodTile(
            icon: Icons.help_outline,
            label: s.securityQuestion,
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() {
                _error = null;
                _step = _RecoveryStep.answerQuestion;
              });
            },
          ),
        if (_hasKey) ...[
          const SizedBox(height: 12),
          _methodTile(
            icon: Icons.vpn_key_outlined,
            label: s.recoveryKey,
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() {
                _error = null;
                _step = _RecoveryStep.enterKey;
              });
            },
          ),
        ],
      ],
    );
  }

  Widget _methodTile(
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.darkSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.darkDivider),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.accentBlue, size: 24),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
            const Icon(Icons.chevron_right, color: AppColors.white40),
          ],
        ),
      ),
    );
  }

  Widget _answerQuestion(AppStrings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_question != null
            ? _questionText(s, _question!)
            : s.securityQuestion,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        TextField(
          controller: _answerCtrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: s.securityAnswer,
            hintStyle: const TextStyle(color: AppColors.white40),
            errorText: _error,
          ),
          onSubmitted: (_) => _verifyAnswer(s),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        const SizedBox(height: 20),
        _primaryButton(s.recoverVault, _busy ? null : () => _verifyAnswer(s)),
      ],
    );
  }

  Future<void> _verifyAnswer(AppStrings s) async {
    if (_answerCtrl.text.trim().isEmpty) {
      setState(() => _error = s.answerRequired);
      return;
    }
    if (await _blockedByLockout(s)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final ok = await _svc.verifySecurityAnswer(_answerCtrl.text);
    if (!mounted) return;
    if (ok) {
      HapticFeedback.mediumImpact();
      // A proven recovery clears the limiter: the person answering correctly
      // is, as far as the app can tell, the owner.
      await _svc.clearLockout();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = null;
        _step = _RecoveryStep.setNewPin;
      });
      return;
    }
    HapticFeedback.heavyImpact();
    // Counts toward the shared limiter AND toward the break-in log, so an
    // owner who was away sees that someone attacked the recovery path — not
    // only that someone mistyped the PIN.
    final st = await _svc.registerFailedAttempt(
        attempted: _answerCtrl.text.trim(), method: 'answer');
    if (!mounted) return;
    setState(() {
      _busy = false;
      final until = st.until;
      _error = (until != null && DateTime.now().isBefore(until))
          ? s.tooManyAttemptsWait(
              until.difference(DateTime.now()).inSeconds + 1)
          : s.wrongAnswer;
    });
  }

  Widget _enterKey(AppStrings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.enterRecoveryKey,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        TextField(
          controller: _keyCtrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(
              color: Colors.white, fontSize: 18, letterSpacing: 2),
          decoration: InputDecoration(
            hintText: 'XXXX-XXXX-XXXX',
            hintStyle: const TextStyle(color: AppColors.white40),
            errorText: _error,
          ),
          onSubmitted: (_) => _verifyKey(s),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        const SizedBox(height: 20),
        _primaryButton(s.recoverVault, _busy ? null : () => _verifyKey(s)),
      ],
    );
  }

  Future<void> _verifyKey(AppStrings s) async {
    if (await _blockedByLockout(s)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final ok = await _svc.verifyRecoveryKey(_keyCtrl.text);
    if (!mounted) return;
    if (ok) {
      HapticFeedback.mediumImpact();
      await _svc.clearLockout();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = null;
        _step = _RecoveryStep.setNewPin;
      });
      return;
    }
    HapticFeedback.heavyImpact();
    final st = await _svc.registerFailedAttempt(
        attempted: _keyCtrl.text.trim(), method: 'key');
    if (!mounted) return;
    setState(() {
      _busy = false;
      final until = st.until;
      _error = (until != null && DateTime.now().isBefore(until))
          ? s.tooManyAttemptsWait(
              until.difference(DateTime.now()).inSeconds + 1)
          : s.wrongRecoveryKey;
    });
  }

  Widget _setNewPin(AppStrings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.setNewPin,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        TextField(
          controller: _pinCtrl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          style: const TextStyle(color: Colors.white, letterSpacing: 4),
          decoration: InputDecoration(
            hintText: s.setNewPin,
            hintStyle: const TextStyle(color: AppColors.white40),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pinConfirmCtrl,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          style: const TextStyle(color: Colors.white, letterSpacing: 4),
          decoration: InputDecoration(
            hintText: s.confirmPin,
            hintStyle: const TextStyle(color: AppColors.white40),
            errorText: _error,
          ),
          onSubmitted: (_) => _resetPin(s),
        ),
        const SizedBox(height: 20),
        _primaryButton(s.setNewPin, _busy ? null : () => _resetPin(s)),
      ],
    );
  }

  Future<void> _resetPin(AppStrings s) async {
    final pin = _pinCtrl.text;
    if (pin.length < 4) {
      setState(() => _error = s.pinMin4);
      return;
    }
    if (pin != _pinConfirmCtrl.text) {
      setState(() => _error = s.pinsDontMatch);
      return;
    }
    setState(() => _busy = true);
    await _svc.resetPinViaRecovery(pin);
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s.pinResetSuccess),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.accentBlue,
        duration: const Duration(seconds: 2)));
    // Signal success so the unlock screen can proceed straight in.
    Navigator.pop(context, true);
  }

  Widget _primaryButton(String label, VoidCallback? onPressed) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accentBlue,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
        onPressed: onPressed,
        child: Text(label,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}
