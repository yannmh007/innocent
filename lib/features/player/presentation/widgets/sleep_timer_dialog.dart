import 'dart:math' as math;


import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/ui/tv_focus.dart';
import 'player_ui.dart';

/// Sleep timer mode
enum SleepTimerMode { off, custom, endOfVideo }

class SleepTimerOption {
  final String label;
  final Duration? duration;
  final SleepTimerMode mode;

  const SleepTimerOption(this.label, this.duration, this.mode);
}

// === Sleep Timer dialog spec (innocent_sleep_timer_spec) ===
// A fixed 3×4 keypad laid out as explicit Rows (so the "0" can sit centred
// in the bottom row). Identical metrics + tokens in both orientations —
// only the arrangement differs (portrait column / landscape split).
// MX 3.4.3's, from its tree on the owner's phone (reference lab
// 45886561831, `numpad`): 32 dp keys, 74.6 dp apart across and 49.1 down;
// the title's middle 28 dp from the panel's top, the time's 72, its ×
// (MX's iv_clear: it clears the entry, it does not close) at the row's end.
const double _kKeyBtn = 32.0; // circle diameter
const double _kKeyColPitch = 74.6; // column centre-to-centre
const double _kKeyRowPitch = 49.1; // row centre-to-centre
const double _kTimeNumeral = 44.0; // big h/m numerals
const double _kTimeSuffix = 16.0; // small "h" / "m" suffix

/// Sleep timer dialog — a keypad-driven custom timer (enter Hh Mm like
/// MX Player) with a "Play last media to the end" toggle, plus STOP /
/// START actions. Portrait = one centred column; landscape = video on the
/// left, keypad block on the right. Same widgets/metrics/tokens in both.
class SleepTimerDialog extends StatefulWidget {
  final Duration? currentRemaining;
  final void Function(SleepTimerOption option, bool playToEnd) onSelect;
  final VoidCallback onDismiss;

  const SleepTimerDialog({
    super.key,
    this.currentRemaining,
    required this.onSelect,
    required this.onDismiss,
  });

  @override
  State<SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<SleepTimerDialog> {
  bool _playToEnd = false;

  /// Up to 4 entered digits interpreted as HHMM (last two = minutes).
  String _digits = '';

  @override
  void initState() {
    super.initState();
    // Pre-fill the entry buffer from an already-running timer so re-opening
    // shows the remaining time (the user can adjust it or STOP). When no
    // timer is active this stays empty → "0h 00m".
    final rem = widget.currentRemaining;
    if (rem != null && rem > Duration.zero) {
      final h = rem.inHours;
      final m = rem.inMinutes.remainder(60);
      var buf = (h > 0 ? h.toString() : '') + m.toString().padLeft(2, '0');
      if (buf.length > 4) buf = buf.substring(buf.length - 4);
      _digits = buf;
    }
  }

  Duration get _customDuration {
    if (_digits.isEmpty) return Duration.zero;
    final raw = int.parse(_digits);
    final minutes = raw % 100;
    final hours = raw ~/ 100;
    return Duration(hours: hours, minutes: minutes);
  }

  void _tapDigit(String digit) {
    if (_digits.length >= 4) return;
    // Avoid a meaningless leading zero (keeps "0" → empty).
    if (_digits.isEmpty && digit == '0') return;
    setState(() => _digits += digit);
  }

  void _clear() {
    if (_digits.isEmpty) return;
    setState(() => _digits = '');
  }

  void _startCustom() {
    final total = _customDuration;
    if (total <= Duration.zero) return;
    final h = total.inHours;
    final m = total.inMinutes.remainder(60);
    final label = h > 0 ? '${h}h ${m}m' : '${m}m';
    widget.onSelect(
      SleepTimerOption(label, total, SleepTimerMode.custom),
      _playToEnd,
    );
  }

  void _stop() {
    // STOP cancels any running timer (and closes the dialog) via the
    // provider's existing "off" path.
    widget.onSelect(
      const SleepTimerOption('Off', null, SleepTimerMode.off),
      _playToEnd,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final portrait = size.height >= size.width;
    final padding = MediaQuery.paddingOf(context);
    final pad = PlayerUi.pad(context);

    // ON A SURFACE, LIKE EVERY OTHER MENU (12 Nov 2026): the title, the
    // time and the keys were drawn straight onto the film under a 25 %
    // scrim. Upright a bottom sheet, sideways a panel from the right.
    final content = Padding(
      // MX's keys at full size where MX has them (384 dp sideways, as the
      // owner's phone): Innocent's box and Stop / Start keep 48 dp rows
      // (MX's are 32), so the title and the time rows give the room back.
      // It was 0.87 of MX's keypad (reference lab 45896496134).
      padding: EdgeInsets.fromLTRB(pad, 6, pad, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // No ×: MX's panel closes by a tap outside it, or Back.
          SizedBox(
            height: 36,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Semantics(
                header: true,
                child: Text(AppStrings.of(context).sleepTimer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PlayerUi.title),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                _timeDisplay(),
                PositionedDirectional(end: 0, child: _clearButton()),
              ],
            ),
          ),
          const Divider(color: PlayerUi.hairline, height: 1, thickness: 1),
          // The keypad gives way, not STOP and START: four rows of keys are
          // 196 dp, more than a short window has left (an upright window in
          // split screen, 384x411 dp: 104 px cut, 26 Nov 2026;
          // test/player_layout_test.dart). Full size wherever they fit.
          Flexible(
            child: Center(
              child: FittedBox(fit: BoxFit.scaleDown, child: _keypad()),
            ),
          ),
          _checkboxRow(),
          _actionsRow(),
        ],
      ),
    );

    // On the shade, as MX's Sleep Timer and every other panel (the
    // reference lab, run 45862946745; the owner, 26 Nov 2026: "as MX"):
    // sideways a panel from the right, the whole height, MX's reach wide;
    // upright a bottom panel the screen's width, MX's reach tall. Nothing
    // dims the film behind it. It was frosted glass over a dimmed film.
    final surface = PlayerShade(
      sideways: !portrait,
      child: Padding(
        padding: EdgeInsets.only(
          top: portrait ? 2 : padding.top,
          right: portrait ? 0 : padding.right,
          bottom: padding.bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [Flexible(child: content)],
        ),
      ),
    );

    return Stack(
      children: [
        // A tap anywhere outside the panel dismisses it.
        Positioned.fill(
          // Read as Android reads a dialog's backdrop: "Dismiss".
          child: Semantics(
            label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
            child: GestureDetector(
              onTap: widget.onDismiss,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        if (portrait)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            // MX's reach, but never under 320 dp (the keys, the box and
            // STOP / START): a split window's reach is ~190 (layout test,
            // 384x411). No taller than the window.
            height: (math.max(PlayerUi.panelExtent(size), 320.0) +
                    padding.bottom)
                .clamp(0.0, size.height),
            child: surface,
          )
        else
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: PlayerUi.sideWidth(size) + padding.right,
            child: surface,
          ),
      ],
    );
  }

  // ── Shared pieces ──

  Widget _timeDisplay() {
    final d = _customDuration;
    final h = d.inHours.toString();
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    return GestureDetector(
      // Long-press the duration to clear the entry back to 0h 00m. 48 dp
      // tall, the row it sits in, not the 44 of its digits.
      behavior: HitTestBehavior.opaque,
      onLongPress: _digits.isEmpty ? null : _clear,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Center(
        widthFactor: 1,
        child: Text.rich(
        TextSpan(
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w400,
            height: 1.0,
          ),
          children: [
            TextSpan(text: h, style: const TextStyle(fontSize: _kTimeNumeral)),
            const TextSpan(text: 'h', style: TextStyle(fontSize: _kTimeSuffix)),
            TextSpan(
                text: ' $m', style: const TextStyle(fontSize: _kTimeNumeral)),
            const TextSpan(text: 'm', style: TextStyle(fontSize: _kTimeSuffix)),
          ],
        ),
      ),
      ),
      ),
    );
  }

  Widget _clearButton() {
    // MX's iv_clear: a 26 dp disc at the time's end, its edge on the
    // content's, that empties the entry back to 0h 00m; the 48 dp target
    // reaches in from it.
    return RemoteTappable(
      onTap: _clear,
      semanticLabel: AppStrings.of(context).clear,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Container(
            width: 26,
            height: 26,
            decoration: const BoxDecoration(
              color: PlayerUi.raised,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.close_rounded,
                color: PlayerUi.textPrimary, size: 18),
          ),
        ),
      ),
    );
  }

  Widget _keypad() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _keyRow(const ['1', '2', '3']),
        _keyRow(const ['4', '5', '6']),
        _keyRow(const ['7', '8', '9']),
        // Bottom row — "0" centred under the middle column.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: _kKeyColPitch),
            _keyCell('0'),
            const SizedBox(width: _kKeyColPitch),
          ],
        ),
      ],
    );
  }

  Widget _keyRow(List<String> keys) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: keys.map(_keyCell).toList(),
    );
  }

  // The whole 74.6 x 49.1 cell takes the tap; the 32 dp circle is only drawn
  // (it was the target alone, SCREEN_A11Y=1). The circle's ripple stays out
  // of the semantics, or its tap splits the key's node in two.
  Widget _keyCell(String digit) {
    return Semantics(
      button: true,
      label: digit,
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _tapDigit(digit),
      child: SizedBox(
      width: _kKeyColPitch,
      height: _kKeyRowPitch,
      child: Center(
        child: ExcludeSemantics(child: Material(
          color: PlayerUi.raised,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _tapDigit(digit),
            child: SizedBox(
              width: _kKeyBtn,
              height: _kKeyBtn,
              child: Center(
                child: Text(
                  digit,
                  style: const TextStyle(
                    color: PlayerUi.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
        )),
      ),
      ),
      ),
    );
  }

  Widget _checkboxRow() {
    // The whole line toggles, not only the 18 dp box, and it is one
    // control for TalkBack, named by its words.
    // 48 dp tall: the 12 dp above it moved into it (it was a 35 dp line).
    return MergeSemantics(
      child: RemoteTappable(
      onTap: () => setState(() => _playToEnd = !_playToEnd),
      child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: Checkbox(
            value: _playToEnd,
            onChanged: (v) => setState(() => _playToEnd = v ?? false),
            side: const BorderSide(color: PlayerUi.textDisabled, width: 1.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(5),
            ),
            activeColor: PlayerUi.accent,
            checkColor: Colors.white,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        const SizedBox(width: 12),
        // Flexible: in Burmese the label is longer than a 320 dp phone.
        Flexible(
          child: Text(AppStrings.of(context).playLastToEnd,
            style: const TextStyle(color: PlayerUi.textPrimary, fontSize: 14),
          ),
        ),
      ],
      ),
      ),
      ),
    );
  }

  Widget _actionsRow() {
    return OverflowBar(
      alignment: MainAxisAlignment.end,
      overflowAlignment: OverflowBarAlignment.end,
      spacing: 8,
      children: [
        PlayerDialogButton(
          label: AppStrings.of(context).stop,
          onPressed: _stop,
        ),
        PlayerDialogButton(
          label: AppStrings.of(context).start,
          primary: true,
          icon: Icons.bedtime_outlined,
          onPressed: _customDuration > Duration.zero ? _startCustom : null,
        ),
      ],
    );
  }
}
