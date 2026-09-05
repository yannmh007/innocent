// Part of private_folder_screen.dart — the PIN surfaces (Setup /
// Unlock / Change-PIN field) and the in-vault image viewer, split out
// to keep the main screen file focused on the file-manager itself.
part of 'private_folder_screen.dart';

/// Fullscreen pinch-zoom viewer for images locked in the vault.
class _VaultImageViewer extends StatelessWidget {
  final String path;
  final String title;
  const _VaultImageViewer({required this.path, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 15)),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 6,
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Icon(
                Icons.broken_image_outlined,
                color: Colors.white38,
                size: 64),
          ),
        ),
      ),
    );
  }
}

/// First-time PIN setup — enter a PIN, confirm it, opt into biometric.
///
/// Two steps on one keypad rather than two fields on a form: the user cannot
/// see either entry, so putting them side by side never helped, and a phone
/// keyboard covering the confirm field is how mismatched PINs get set.
class _SetPinPanel extends ConsumerStatefulWidget {
  final VoidCallback onPinSet;
  const _SetPinPanel({required this.onPinSet});

  @override
  ConsumerState<_SetPinPanel> createState() => _SetPinPanelState();
}

class _SetPinPanelState extends ConsumerState<_SetPinPanel> {
  final GlobalKey<VaultPinPadState> _padKey = GlobalKey<VaultPinPadState>();
  String? _first;
  String? _error;
  bool _saving = false;
  bool _done = false;
  // Incremented ONLY on a real rejection — see VaultPinPad.errorNonce.
  int _errNonce = 0;

  Future<void> _onSubmit(String pin) async {
    if (_first == null) {
      HapticFeedback.selectionClick();
      setState(() {
        _first = pin;
        _error = null;
      });
      _padKey.currentState?.clear();
      return;
    }
    if (pin != _first) {
      // Start over from the first step. Keeping the accepted first entry and
      // only clearing the confirm would let a typo in step ONE become the
      // real PIN, which the user then cannot guess.
      setState(() {
        _error = AppStrings.of(context).pinsDontMatch;
        _errNonce++;
        _first = null;
      });
      _padKey.currentState?.clear();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(privateFolderServiceProvider).setPin(pin);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      // Flash the dots green, hold a beat, then hand off. Without it the
      // screen simply swaps and the user is left unsure the PIN took.
      setState(() => _done = true);
      await Future<void>.delayed(const Duration(milliseconds: 260));
      if (!mounted) return;
      widget.onPinSet();
    } catch (e) {
      // The user can leave while setPin is in flight (PBKDF2 calibration
      // makes it long enough to matter), so guard before touching state.
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = AppStrings.of(context).pinSetFailed;
        _errNonce++;
        _first = null;
      });
      _padKey.currentState?.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final confirming = _first != null;
    return VaultPinPad(
      key: _padKey,
      title: confirming ? s.confirmPin : s.setupPinTitle,
      subtitle: confirming ? s.setupPinConfirmHint : s.setupPinHint,
      errorText: _error,
      errorNonce: _errNonce,
      success: _done,
      busy: _saving || _done,
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
      onSubmit: _onSubmit,
      footer: confirming ? null : const _BiometricOptIn(),
    );
  }
}

/// Biometric opt-in shown under the setup keypad.
///
/// Deliberately worded as a SHORTCUT to the PIN, never a replacement: anyone
/// whose fingerprint is enrolled on this handset can open the vault with it,
/// and a user who does not realise that may hand the phone over thinking the
/// PIN still stands between them and the contents.
class _BiometricOptIn extends ConsumerWidget {
  const _BiometricOptIn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final enabled =
        ref.watch(playerSettingsProvider).get(PlayerSetting.privateFolderBiometric);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 10, 28, 0),
      child: Row(
        children: [
          const Icon(Icons.fingerprint, size: 20, color: AppColors.white55),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.useBiometric,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(s.biometricSubtitle,
                    style: const TextStyle(
                        color: AppColors.white55,
                        fontSize: 11,
                        height: 1.3)),
              ],
            ),
          ),
          Transform.scale(
            scale: 0.82,
            alignment: Alignment.centerRight,
            child: Switch(
              value: enabled,
              activeColor: Colors.white,
              activeTrackColor: AppColors.accentBlue,
              onChanged: (v) async {
                if (v) {
                  // Confirm enrollment BEFORE storing the preference,
                  // otherwise the switch reads "on" and nothing ever happens.
                  final bio = ref.read(biometricServiceProvider);
                  if (!await bio.canCheck()) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(
                        content: Text(s.biometricEnrollFirst),
                        duration: const Duration(seconds: 3),
                        behavior: SnackBarBehavior.floating,
                      ));
                    return;
                  }
                }
                await ref
                    .read(playerSettingsProvider.notifier)
                    .setValue(PlayerSetting.privateFolderBiometric, v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Unlock panel.
class _PinEntryPanel extends ConsumerStatefulWidget {
  /// Called on a successful unlock, with which vault to open: the real
  /// contents or the decoy (empty) view.
  final ValueChanged<PinKind> onUnlocked;
  const _PinEntryPanel({required this.onUnlocked});

  @override
  ConsumerState<_PinEntryPanel> createState() => _PinEntryPanelState();
}

class _PinEntryPanelState extends ConsumerState<_PinEntryPanel> {
  final GlobalKey<VaultPinPadState> _padKey = GlobalKey<VaultPinPadState>();
  String? _error;
  bool _verifying = false;
  bool _done = false;

  /// Bumped ONLY by a genuine wrong PIN. THE BUG THIS FIXES: the pad shook
  /// and fired a heavy haptic whenever its error TEXT changed, and the
  /// countdown below rewrites that text once per second — so a locked-out
  /// vault vibrated every second for up to fifteen minutes.
  int _errNonce = 0;

  /// Digit counts that auto-submit — the real PIN's length plus the decoy's.
  /// Empty until loaded, and empty forever on installs that set their PIN
  /// before the length was recorded; the pad falls back to its confirm key.
  Set<int> _autoLengths = const <int>{};

  /// Live countdown while a cooling-off period is running. Ticking it in the
  /// UI (rather than only re-checking on the next attempt) is what turns an
  /// opaque "too many attempts" into something a user can wait out.
  Timer? _lockTicker;
  Duration? _lockRemaining;

  PrivateFolderService get _svc => ref.read(privateFolderServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    if (!mounted) return;
    final lengths = await _svc.autoSubmitLengths();
    final remaining = await _svc.lockoutRemaining();
    if (!mounted) return;
    setState(() {
      _autoLengths = lengths;
      if (remaining != null) _startLockCountdown(remaining);
    });
    // Offer biometric straight away when the user opted in — but never while
    // a cooling-off period is running, or the limiter would be a formality
    // anyone could step around by tapping the fingerprint key.
    if (remaining != null) return;
    if (!mounted) return;
    final enabled = ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.privateFolderBiometric);
    if (!enabled) return;
    final bio = ref.read(biometricServiceProvider);
    if (!await bio.canCheck()) return;
    if (!mounted) return;
    final ok = await bio.authenticate(
      reason: AppStrings.of(context).unlockPrivateReason,
    );
    if (ok && mounted) {
      await _svc.clearLockout();
      if (mounted) widget.onUnlocked(PinKind.real);
    }
  }

  void _startLockCountdown(Duration remaining) {
    _lockTicker?.cancel();
    _lockRemaining = remaining;
    _error = AppStrings.of(context)
        .tooManyAttemptsWait(remaining.inSeconds + 1);
    _lockTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final left = (_lockRemaining ?? Duration.zero) -
          const Duration(seconds: 1);
      setState(() {
        if (left <= Duration.zero) {
          _lockRemaining = null;
          _error = null;
          t.cancel();
        } else {
          _lockRemaining = left;
          _error = AppStrings.of(context)
              .tooManyAttemptsWait(left.inSeconds + 1);
        }
      });
    });
  }

  Future<void> _verify(String pin) async {
    // Re-read the deadline from the store rather than trusting the local
    // countdown: the limiter has to hold even if this widget was rebuilt,
    // the app was killed mid-lockout, or the attempt came from another
    // surface in between.
    final remaining = await _svc.lockoutRemaining();
    if (!mounted) return;
    if (remaining != null) {
      setState(() => _startLockCountdown(remaining));
      _padKey.currentState?.clear();
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    final kind = await _svc.verifyPinKind(pin);
    if (!mounted) return;
    if (kind != PinKind.none) {
      // Real and decoy both count as success for the limiter. A coercer must
      // not be able to tell them apart by watching whether the lockout
      // counter resets — that would expose the decoy completely.
      await _svc.clearLockout();
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _done = true);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;
      widget.onUnlocked(kind);
      return;
    }
    final st =
        await _svc.registerFailedAttempt(attempted: pin, method: 'pin');
    if (!mounted) return;
    setState(() {
      _verifying = false;
      _errNonce++;
      final until = st.until;
      if (until != null && DateTime.now().isBefore(until)) {
        _startLockCountdown(until.difference(DateTime.now()));
      } else {
        _error = AppStrings.of(context).incorrectPin;
      }
    });
  }

  Future<void> _tryBiometric() async {
    final remaining = await _svc.lockoutRemaining();
    if (!mounted) return;
    if (remaining != null) {
      setState(() => _startLockCountdown(remaining));
      return;
    }
    final bio = ref.read(biometricServiceProvider);
    final canCheck = await bio.canCheck();
    // canCheck() is a platform round-trip; the user can leave during it.
    // Without this guard the AppStrings lookup below runs against a defunct
    // element and throws.
    if (!mounted) return;
    if (!canCheck) {
      setState(() => _error = AppStrings.of(context).biometricNotEnrolled);
      return;
    }
    final reason = AppStrings.of(context).unlockPrivateReason;
    final ok = await bio.authenticate(reason: reason);
    if (ok && mounted) {
      await _svc.clearLockout();
      if (mounted) widget.onUnlocked(PinKind.real);
    }
  }

  @override
  void dispose() {
    _lockTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final locked = _lockRemaining != null;
    final bioOn = ref
        .watch(playerSettingsProvider)
        .get(PlayerSetting.privateFolderBiometric);
    return VaultPinPad(
      key: _padKey,
      title: s.enterPin,
      subtitle: locked ? s.vaultTemporarilyLocked : s.unlockHint,
      errorText: _error,
      errorNonce: _errNonce,
      success: _done,
      busy: _verifying || locked || _done,
      autoSubmitLengths: locked ? const <int>{} : _autoLengths,
      onBiometric: bioOn ? _tryBiometric : null,
      onChanged: (_) {
        if (_error != null && !locked) setState(() => _error = null);
      },
      onSubmit: _verify,
      footer: _ForgotPinLink(
        enabled: !_verifying,
        onRecovered: () => widget.onUnlocked(PinKind.real),
      ),
    );
  }
}

/// "Forgot PIN?" — only rendered once a recovery method exists, because
/// offering a door that leads nowhere is worse than offering none.
class _ForgotPinLink extends ConsumerWidget {
  final bool enabled;
  final VoidCallback onRecovered;
  const _ForgotPinLink({required this.enabled, required this.onRecovered});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    return FutureBuilder<bool>(
      future: ref.read(privateFolderServiceProvider).hasRecovery(),
      builder: (ctx, snap) {
        if (snap.data != true) return const SizedBox.shrink();
        return TextButton(
          onPressed: !enabled
              ? null
              : () async {
                  final ok = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                        builder: (_) => const RecoveryFlowScreen()),
                  );
                  if (ok == true && context.mounted) onRecovered();
                },
          child: Text(s.forgotPin,
              style: const TextStyle(
                  color: AppColors.accentBlue, fontSize: 13.5)),
        );
      },
    );
  }
}
