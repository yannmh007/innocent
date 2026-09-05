import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/private_folder/private_folder_service.dart';
import '../../../core/services/secure_screen/secure_screen_service.dart';
import '../../../core/theme/app_colors.dart';
import 'vault_pin_pad.dart';

/// Multi-step PIN entry built on [VaultPinPad].
///
/// Three flows used to set a PIN in this feature and all three were different:
/// setup was a two-field scrolling form, change-PIN was a three-field
/// AlertDialog, and the decoy PIN was a two-field AlertDialog. Same secret,
/// three behaviours, three sets of validation rules, three places for a bug
/// to hide — and every one of them handed the digits to the system keyboard.
///
/// This is the one implementation they now share. Each flow is a list of
/// steps; the shell owns the step machine, the error text and the back
/// behaviour, and the caller only says what the steps are and what to do with
/// the result.
class VaultPinFlowStep {
  final String title;
  final String subtitle;

  /// Validate the value entered at THIS step. Return null to accept, or the
  /// message to show. May be async (the change-PIN flow verifies the current
  /// PIN against the keystore here).
  final Future<String?> Function(String entered, List<String> previous)?
      validate;

  const VaultPinFlowStep({
    required this.title,
    required this.subtitle,
    this.validate,
  });
}

class VaultPinFlowScreen extends StatefulWidget {
  final String appBarTitle;
  final List<VaultPinFlowStep> steps;

  /// Runs once every step has passed. Receives the values in step order.
  /// Return null on success, or a message to show on the LAST step.
  final Future<String?> Function(List<String> values) onComplete;

  final IconData icon;

  const VaultPinFlowScreen({
    super.key,
    required this.appBarTitle,
    required this.steps,
    required this.onComplete,
    this.icon = Icons.lock_outline,
  });

  @override
  State<VaultPinFlowScreen> createState() => _VaultPinFlowScreenState();
}

class _VaultPinFlowScreenState extends State<VaultPinFlowScreen> {
  final GlobalKey<VaultPinPadState> _padKey = GlobalKey<VaultPinPadState>();
  final List<String> _values = <String>[];
  int _step = 0;
  String? _error;
  bool _busy = false;
  bool _done = false;
  int _errNonce = 0;

  Future<void> _onSubmit(String entered) async {
    final step = widget.steps[_step];
    setState(() {
      _busy = true;
      _error = null;
    });
    final validator = step.validate;
    if (validator != null) {
      final err = await validator(entered, List<String>.unmodifiable(_values));
      if (!mounted) return;
      if (err != null) {
        setState(() {
          _busy = false;
          _error = err;
          _errNonce++;
        });
        return;
      }
    }
    _values.add(entered);
    if (_step < widget.steps.length - 1) {
      HapticFeedback.selectionClick();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step++;
      });
      _padKey.currentState?.clear();
      return;
    }
    final err = await widget.onComplete(List<String>.unmodifiable(_values));
    if (!mounted) return;
    if (err != null) {
      // Failed at the last hurdle: drop back to the FIRST step. Leaving the
      // user on the confirm step with two accepted values and a rejection
      // they cannot act on is the kind of dead end that makes people force-
      // quit the app.
      setState(() {
        _busy = false;
        _error = err;
        _errNonce++;
        _step = 0;
        _values.clear();
      });
      _padKey.currentState?.clear();
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _done = true);
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (mounted) Navigator.of(context).pop(true);
  }

  /// Back steps BACKWARD through the flow before it leaves the screen —
  /// mistyping the confirmation should not throw away the first entry.
  bool _stepBack() {
    if (_step == 0) return false;
    setState(() {
      _step--;
      _values.removeLast();
      _error = null;
    });
    _padKey.currentState?.clear();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_step];
    return SecureScreenGuard(
      child: PopScope(
        canPop: _step == 0,
        onPopInvoked: (didPop) {
          if (!didPop) _stepBack();
        },
        child: Scaffold(
          backgroundColor: AppColors.darkBackground,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () {
                if (!_stepBack()) Navigator.of(context).pop(false);
              },
            ),
            title: Text(
              widget.appBarTitle,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700),
            ),
            bottom: widget.steps.length > 1
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(3),
                    child: _progressBar(),
                  )
                : null,
          ),
          body: SafeArea(
            child: VaultPinPad(
              key: _padKey,
              icon: widget.icon,
              title: step.title,
              subtitle: step.subtitle,
              errorText: _error,
              errorNonce: _errNonce,
              success: _done,
              busy: _busy || _done,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmit: _onSubmit,
            ),
          ),
        ),
      ),
    );
  }

  /// A hairline showing how far through a multi-step flow the user is. Small,
  /// but it is the difference between "why is it asking again?" and "right,
  /// two of three".
  Widget _progressBar() {
    return Row(
      children: List.generate(widget.steps.length, (i) {
        return Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            height: 3,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            color: i <= _step ? AppColors.accentBlue : AppColors.white08,
          ),
        );
      }),
    );
  }
}

/// Change the vault PIN: prove the current one, then enter the new one twice.
class ChangePinScreen extends StatelessWidget {
  final PrivateFolderService service;
  const ChangePinScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return VaultPinFlowScreen(
      appBarTitle: s.changePin,
      icon: Icons.password_outlined,
      steps: [
        VaultPinFlowStep(
          title: s.currentPin,
          subtitle: s.changePinCurrentHint,
          // Verified against the keystore right here rather than at the end,
          // so a wrong current PIN is reported before the user picks a new
          // one — not after they have chosen and confirmed it.
          validate: (entered, _) async {
            final ok = await service.verifyPin(entered);
            return ok ? null : s.incorrectPin;
          },
        ),
        VaultPinFlowStep(
          title: s.newPin,
          subtitle: s.changePinNewHint,
        ),
        VaultPinFlowStep(
          title: s.confirmNewPin,
          subtitle: s.changePinConfirmHint,
          validate: (entered, previous) async =>
              entered == previous[1] ? null : s.newPinsDontMatch,
        ),
      ],
      onComplete: (values) async {
        try {
          await service.setPin(values[1], oldPin: values[0]);
          return null;
        } catch (e) {
          return s.changePinFailed;
        }
      },
    );
  }
}

/// Set the decoy PIN: enter twice, rejected if it equals the real PIN.
class SetDecoyPinScreen extends StatelessWidget {
  final PrivateFolderService service;
  const SetDecoyPinScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return VaultPinFlowScreen(
      appBarTitle: s.setDecoyPin,
      icon: Icons.theater_comedy_outlined,
      steps: [
        VaultPinFlowStep(
          title: s.decoyPin,
          subtitle: s.decoyPinEntryHint,
          // Caught at entry, not at save: telling someone their decoy clashed
          // with the real PIN only after they typed it twice is a needless
          // round trip, and the check is the same either way.
          validate: (entered, _) async {
            final clash = await service.verifyPin(entered);
            return clash ? s.decoySameAsReal : null;
          },
        ),
        VaultPinFlowStep(
          title: s.confirmPin,
          subtitle: s.decoyPinConfirmHint,
          validate: (entered, previous) async =>
              entered == previous[0] ? null : s.pinsDontMatch,
        ),
      ],
      onComplete: (values) async {
        try {
          await service.setDecoyPin(values[0]);
          return null;
        } on FormatException {
          return s.decoySameAsReal;
        }
      },
    );
  }
}
