import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';

/// The Private Folder's PIN surface: a dot indicator over a purpose-built
/// numeric keypad.
///
/// WHY NOT A TEXT FIELD
/// ────────────────────
/// Every PIN screen in the app used to be a `TextField` that summoned the
/// system keyboard. That is the single clearest "this is a side project" tell
/// in the whole feature, and it is not only cosmetic:
///
///   • The soft keyboard is a THIRD-PARTY APP. On most phones here that is
///     Gboard or an OEM keyboard, and it sees every digit of the vault PIN.
///     Keyboards keep clipboard history, learn typed sequences, and sync to
///     the cloud. A dedicated keypad means the PIN never leaves this process.
///   • The keyboard covers half the screen, so the layout had to be wrapped
///     in a scroll view and the button could end up under the keyboard.
///   • Key sizes are whatever the keyboard vendor chose. A vault is used
///     one-handed, often in a hurry; 72dp targets in a fixed grid are faster
///     and far harder to mistype.
///   • No haptics, no error animation, no control over the digit count.
///
/// The keypad below is a plain, self-contained widget so the unlock, setup,
/// change-PIN and decoy-PIN flows can all share exactly one PIN surface —
/// which is also why they can no longer drift apart in behaviour.
class VaultPinPad extends StatefulWidget {
  /// Large heading, e.g. "Enter PIN".
  final String title;

  /// One-line explanation under the heading.
  final String subtitle;

  /// Error text shown in red under the dots.
  final String? errorText;

  /// Bump this ONLY on a genuine new rejection. It, and not [errorText], is
  /// what drives the shake and the error haptic.
  ///
  /// This exists because of a real bug: the pad used to animate whenever
  /// `errorText` changed, and the unlock panel's cooling-off countdown
  /// rewrites that string once a second. A locked-out vault therefore shook
  /// and buzzed every second for as long as the lockout lasted. A re-worded
  /// countdown is not a new rejection, and now nothing about the text can
  /// imply that it is.
  final int errorNonce;

  /// Flashes the dots green and holds for a beat before the caller navigates
  /// away. Cheap, and it is the difference between "did that work?" and a
  /// screen change that feels earned.
  final bool success;

  /// Disables input and shows a spinner in place of the confirm key while a
  /// verification is in flight.
  final bool busy;

  /// Minimum digits before the entry can be submitted at all.
  final int minLength;

  /// Hard cap on digits the pad will accept.
  final int maxLength;

  /// Digit counts that submit on their own the moment they are reached.
  ///
  /// Passed as a SET, never as a single "the PIN is N digits" value: when a
  /// decoy PIN of a different length exists, both lengths must auto-submit or
  /// the decoy would visibly behave differently from the real PIN and give
  /// itself away to the person doing the coercing.
  final Set<int> autoSubmitLengths;

  /// Called with the entered digits. The pad does NOT clear itself — the
  /// caller decides, because on success the screen is usually replaced and
  /// clearing would flash the dots empty for a frame.
  final ValueChanged<String> onSubmit;

  /// Fired on every change so the caller can clear a stale error.
  final ValueChanged<String>? onChanged;

  /// Shows a fingerprint key in the bottom-left when non-null.
  final VoidCallback? onBiometric;

  /// Optional link row under the pad (e.g. "Forgot PIN?").
  final Widget? footer;

  /// Icon in the header medallion.
  final IconData icon;

  const VaultPinPad({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onSubmit,
    this.errorText,
    this.errorNonce = 0,
    this.success = false,
    this.busy = false,
    this.minLength = 4,
    this.maxLength = 6,
    this.autoSubmitLengths = const <int>{},
    this.onChanged,
    this.onBiometric,
    this.footer,
    this.icon = Icons.lock_outline,
  });

  @override
  State<VaultPinPad> createState() => VaultPinPadState();
}

class VaultPinPadState extends State<VaultPinPad>
    with SingleTickerProviderStateMixin {
  String _entry = '';
  late final AnimationController _shake;
  Timer? _autoSubmit;

  /// ITU E.161, the layout on every phone keypad ever made. Purely a visual
  /// anchor — the pad accepts digits only — but it is one of the strongest
  /// "this is a real keypad" cues there is, and it gives the eye something
  /// to aim at when entering a PIN without looking.
  static const Map<String, String> _letters = <String, String>{
    '2': 'ABC',
    '3': 'DEF',
    '4': 'GHI',
    '5': 'JKL',
    '6': 'MNO',
    '7': 'PQRS',
    '8': 'TUV',
    '9': 'WXYZ',
  };

  /// Clears the entry from outside — used between steps of a multi-step flow
  /// (current PIN → new PIN → confirm) so one pad can serve all three.
  void clear() {
    if (!mounted) return;
    setState(() => _entry = '');
  }

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
  }

  @override
  void didUpdateWidget(VaultPinPad old) {
    super.didUpdateWidget(old);
    // Keyed to the NONCE, never to the text. See [errorNonce].
    if (widget.errorNonce != old.errorNonce && widget.errorNonce > 0) {
      _entry = '';
      _autoSubmit?.cancel();
      _shake.forward(from: 0);
      HapticFeedback.heavyImpact();
    }
  }

  @override
  void dispose() {
    _autoSubmit?.cancel();
    _shake.dispose();
    super.dispose();
  }

  void _press(String digit) {
    if (widget.busy || _entry.length >= widget.maxLength) return;
    // A short, light tick per key. On a vault this is not decoration: it is
    // the confirmation that a press registered, on a screen where the user
    // cannot see what they typed.
    HapticFeedback.selectionClick();
    _autoSubmit?.cancel();
    setState(() => _entry += digit);
    widget.onChanged?.call(_entry);
    if (widget.autoSubmitLengths.contains(_entry.length)) {
      // Let the dot's fill animation land before the screen changes —
      // submitting on the same frame makes the last press feel unregistered.
      // Held in a CANCELLABLE timer so a sixth digit typed quickly after a
      // fourth cancels the four-digit submit instead of racing it (real PINs
      // and decoy PINs can legitimately differ in length).
      _autoSubmit = Timer(const Duration(milliseconds: 130), () {
        if (!mounted || widget.busy) return;
        if (widget.autoSubmitLengths.contains(_entry.length)) _submit();
      });
    }
  }

  void _backspace() {
    if (widget.busy || _entry.isEmpty) return;
    HapticFeedback.selectionClick();
    _autoSubmit?.cancel();
    setState(() => _entry = _entry.substring(0, _entry.length - 1));
    widget.onChanged?.call(_entry);
  }

  void _clearAll() {
    if (widget.busy || _entry.isEmpty) return;
    HapticFeedback.mediumImpact();
    _autoSubmit?.cancel();
    setState(() => _entry = '');
    widget.onChanged?.call(_entry);
  }

  void _submit() {
    if (widget.busy || _entry.length < widget.minLength) return;
    _autoSubmit?.cancel();
    widget.onSubmit(_entry);
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _entry.length >= widget.minLength && !widget.busy;
    // THE PAD OWNS ITS OWN BOTTOM INSET.
    //
    // `MediaQuery.paddingOf` reports what the system bars still cover. A
    // `SafeArea` ancestor consumes that and reports 0 to its descendants, so
    // this is self-correcting: inside one it adds nothing and cannot
    // double-pad, outside one it supplies the gap the host forgot. Two of the
    // four screens that host this pad return it without a SafeArea, and the
    // gesture bar sat over the bottom row of keys on both.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, box) {
        // The pad must never scroll: a PIN screen that moves under the thumb
        // is a PIN screen people mistype. Instead the key size adapts to the
        // space actually available, so it fits a small phone and stays
        // comfortable on a tablet.
        final keySize = _keySize(box.maxHeight - bottomInset, box.maxWidth);
        // LAST RESORT ONLY. The pad is designed never to scroll — a PIN screen
        // that moves under the thumb is a PIN screen people mistype — but on a
        // screen so short that even 44px keys will not fit, scrolling is the
        // difference between an awkward pad and one whose bottom row cannot be
        // reached at all. Silent clipping was the old behaviour and it is the
        // one option that is never acceptable here.
        final needed = _keypadHeight(keySize) + _chromeHeight + bottomInset;
        final needsScroll = needed > box.maxHeight;
        final pad = Column(
          children: [
            const Spacer(flex: 2),
            _header(),
            const SizedBox(height: 26),
            _dots(),
            const SizedBox(height: 12),
            // FIXED-HEIGHT error slot. Previously the row appeared and
            // disappeared, so the dots and the whole header jumped up and
            // down by ~16px on every wrong PIN — on the one screen where the
            // user's thumb is aiming at a fixed target. Reserving the space
            // costs nothing and the pad stops moving underneath them.
            SizedBox(
              height: 30,
              child: AnimatedOpacity(
                opacity: widget.errorText != null ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                child: widget.errorText != null
                    ? _error()
                    : const SizedBox.shrink(),
              ),
            ),
            const Spacer(flex: 3),
            _keypad(keySize, canSubmit),
            if (widget.footer != null) ...[
              const SizedBox(height: 6),
              widget.footer!,
            ],
            const Spacer(),
          ],
        );
        if (!needsScroll) {
          return Padding(
            padding: EdgeInsets.only(bottom: bottomInset),
            child: pad,
          );
        }
        // SizedBox, NOT ConstrainedBox.
        //
        // `SingleChildScrollView` hands its child an UNBOUNDED height, and the
        // Column above is full of `Spacer`s — a flex child under an unbounded
        // constraint is a hard RenderFlex assertion, not a layout warning. A
        // `ConstrainedBox` with only `minHeight` leaves the maximum unbounded
        // and crashes exactly the same way. A fixed height bounds it, so the
        // Spacers resolve and the view scrolls to reach the rest.
        return SingleChildScrollView(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: SizedBox(
            height: _keypadHeight(keySize) + _chromeHeight,
            child: pad,
          ),
        );
      },
    );
  }

  /// Height this Column needs OUTSIDE the keypad: the fixed gaps between the
  /// header, the dots and the error slot, plus room for the header itself.
  ///
  /// Measured rather than guessed, because the previous version reserved a
  /// flat 58% of the screen for everything above the keys and then clamped the
  /// key size to a 52px floor. On a short phone those two rules contradict
  /// each other: the keypad no longer fits in what is left, the `Spacer`s
  /// collapse to nothing, and a `Column` that cannot fit its children
  /// OVERFLOWS RATHER THAN SHRINKING — so the bottom row and the footer were
  /// pushed off the screen. On a PIN pad that is not cosmetic: the user could
  /// not reach 0, or the confirm key, and the screen was unusable.
  static const double _chromeHeight = 18 + 26 + 12 + 30 + 62 + 24;

  /// Height of the keypad at a given key size: four rows, each with 6px of
  /// padding above and below.
  static double _keypadHeight(double keySize) => 4 * (keySize + 12);

  double _keySize(double maxH, double maxW) {
    final byWidth = (math.min(maxW, 340) - 2 * 18) / 3 - 12;
    // What is actually left for the keys after the header, dots and error slot
    // have taken their fixed share.
    final free = maxH - _chromeHeight - (widget.footer != null ? 34 : 0);
    final byHeight = free / 4 - 12;
    final size = math.min(byWidth, byHeight);
    // 44 is the floor, not 52. Below a comfortable target but still tappable,
    // and reachable beats comfortable: a key that has been pushed off the
    // screen has a tap target of zero.
    return size.clamp(44.0, 76.0);
  }

  Widget _header() {
    return Column(
      children: [
        Container(
          width: 58,
          height: 58,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: AppColors.accentBlue15,
            shape: BoxShape.circle,
          ),
          child: Icon(widget.icon, color: AppColors.accentBlue, size: 27),
        ),
        const SizedBox(height: 18),
        Text(
          widget.title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ),
        const SizedBox(height: 7),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            widget.subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.white55,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }

  /// Dot row. Shows [maxLength] slots so the user can see how many digits are
  /// still accepted, with the filled ones tinted and slightly larger.
  Widget _dots() {
    final hasError = widget.errorText != null;
    final ok = widget.success;
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        // Damped sine: three decreasing swings, ending exactly at zero so the
        // row never settles off-centre.
        final t = _shake.value;
        final dx = t == 0
            ? 0.0
            : math.sin(t * math.pi * 6) * 11 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(widget.maxLength, (i) {
          final filled = i < _entry.length;
          final optional = i >= widget.minLength;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: filled ? 13 : 10,
            height: filled ? 13 : 10,
            margin: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled
                  ? (hasError
                      ? AppColors.error
                      : (ok ? AppColors.success : AppColors.accentBlue))
                  : Colors.transparent,
              border: filled
                  ? null
                  : Border.all(
                      // Slots past the minimum are drawn fainter, so the pad
                      // silently communicates "4 is enough, 6 is allowed".
                      color: optional ? AppColors.white15 : AppColors.white30,
                      width: 1.4,
                    ),
            ),
          );
        }),
      ),
    );
  }

  Widget _error() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: AppColors.error, size: 14),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              widget.errorText!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.error, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _keypad(double keySize, bool canSubmit) {
    Widget row(List<Widget> children) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: children,
          ),
        );

    Widget gap(Widget child) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: child,
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row([
          gap(_digit('1', keySize)),
          gap(_digit('2', keySize)),
          gap(_digit('3', keySize)),
        ]),
        row([
          gap(_digit('4', keySize)),
          gap(_digit('5', keySize)),
          gap(_digit('6', keySize)),
        ]),
        row([
          gap(_digit('7', keySize)),
          gap(_digit('8', keySize)),
          gap(_digit('9', keySize)),
        ]),
        row([
          // Bottom-left: biometric when opted in, otherwise a clear-all that
          // only appears once there is something to clear. Never an empty
          // hole — an unbalanced keypad looks broken.
          gap(widget.onBiometric != null
              ? _action(
                  icon: Icons.fingerprint,
                  size: keySize,
                  onTap: widget.busy ? null : widget.onBiometric,
                  semantics: 'Unlock with fingerprint',
                )
              : _action(
                  icon: Icons.close,
                  size: keySize,
                  onTap: _entry.isEmpty ? null : _clearAll,
                  semantics: 'Clear',
                )),
          gap(_digit('0', keySize)),
          // Bottom-right: backspace until the entry is long enough to submit,
          // then the confirm key. Auto-submit usually gets there first, so
          // this is the fallback for installs where the PIN length is not yet
          // known (upgrades from before it was recorded).
          gap(canSubmit
              ? _action(
                  icon: Icons.arrow_forward,
                  size: keySize,
                  onTap: _submit,
                  filled: true,
                  busy: widget.busy,
                  semantics: 'Confirm',
                )
              : _action(
                  icon: Icons.backspace_outlined,
                  size: keySize,
                  onTap: _entry.isEmpty ? null : _backspace,
                  // Long-press wipes the whole entry. Standard on every
                  // keypad, and it matters most here: with the biometric key
                  // occupying the bottom-left there is no dedicated clear.
                  onLongPress: _entry.isEmpty ? null : _clearAll,
                  busy: widget.busy,
                  semantics: 'Backspace',
                )),
        ]),
      ],
    );
  }

  Widget _digit(String d, double size) {
    final letters = _letters[d];
    return Semantics(
      button: true,
      label: d,
      child: _PadKey(
        size: size,
        onTap: widget.busy ? null : () => _press(d),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              d,
              style: TextStyle(
                color: widget.busy ? AppColors.white40 : Colors.white,
                fontSize: size * 0.38,
                fontWeight: FontWeight.w400,
                height: 1,
              ),
            ),
            // Dropped on small keys rather than squeezed: below ~58px the
            // letters stop being legible and start being noise.
            if (letters != null && size >= 58) ...[
              const SizedBox(height: 2),
              Text(
                letters,
                style: TextStyle(
                  color: widget.busy
                      ? AppColors.white20
                      : AppColors.white40,
                  fontSize: size * 0.125,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w500,
                  height: 1,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required double size,
    required VoidCallback? onTap,
    VoidCallback? onLongPress,
    bool filled = false,
    bool busy = false,
    String? semantics,
  }) {
    return _PadKey(
      size: size,
      onTap: onTap,
      onLongPress: onLongPress,
      semanticsLabel: semantics,
      filled: filled,
      transparent: !filled,
      child: busy && filled
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : Icon(
              icon,
              size: size * 0.34,
              color: onTap == null
                  ? AppColors.white20
                  : (filled ? Colors.white : AppColors.white70),
            ),
    );
  }
}

/// One key. Circular, with a press-scale so the pad feels physical — the
/// press animation is also what hides the PBKDF2 verification delay on slower
/// phones, which is why it is not merely cosmetic.
class _PadKey extends StatefulWidget {
  final double size;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;
  final bool filled;
  final bool transparent;
  final String? semanticsLabel;

  const _PadKey({
    required this.size,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.filled = false,
    this.transparent = false,
    this.semanticsLabel,
  });

  @override
  State<_PadKey> createState() => _PadKeyState();
}

class _PadKeyState extends State<_PadKey> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final key = GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              setState(() => _down = false);
              widget.onLongPress!();
            },
      child: AnimatedScale(
        scale: _down ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: widget.size,
          height: widget.size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.filled
                ? AppColors.accentBlue
                : (widget.transparent
                    ? (_down ? AppColors.white10 : Colors.transparent)
                    : (_down ? AppColors.white15 : AppColors.white06)),
            border: widget.filled || widget.transparent
                ? null
                : Border.all(color: AppColors.white08, width: 1),
          ),
          child: widget.child,
        ),
      ),
    );
    final label = widget.semanticsLabel;
    if (label == null) return key;
    return Semantics(button: true, label: label, child: key);
  }
}
