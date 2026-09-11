import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

import '../../../../core/localization/app_strings.dart';
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
const double _kKeyBtn = 44.0; // circle diameter
const double _kKeyColPitch = 70.0; // column centre-to-centre
const double _kKeyRowPitch = 46.0; // row centre-to-centre
const double _kTimeNumeral = 36.0; // big h/m numerals
const double _kTimeSuffix = 14.0; // small "h" / "m" suffix

const TextStyle _kTitleStyle = TextStyle(
  color: Colors.white,
  fontSize: 17,
  fontWeight: FontWeight.w700,
);

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
    final isPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;
    return Stack(
      children: [
        // Light scrim — keeps the video visible behind the dialog while a
        // tap anywhere outside the controls dismisses it.
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onDismiss,
            child: Container(color: AppColors.black25),
          ),
        ),
        SafeArea(
          child:
              isPortrait ? _buildPortrait(context) : _buildLandscape(context),
        ),
      ],
    );
  }

  // ── Portrait: one centred column, bottom-aligned, video letterboxed above.
  Widget _buildPortrait(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        // Cap the width so the column stays tidy on tablets.
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(AppStrings.of(context).sleepTimer, style: _kTitleStyle),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _timeDisplay(),
                  const Spacer(),
                  _closeButton(),
                ],
              ),
              const SizedBox(height: 8),
              const Divider(
                color: AppColors.specSleepDivider,
                height: 1,
                thickness: 1,
              ),
              const SizedBox(height: 14),
              Center(child: _keypad()),
              const SizedBox(height: 18),
              _checkboxRow(),
              const SizedBox(height: 2),
              _actionsRow(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Landscape: title top-centre, video on the left, keypad block right.
  Widget _buildLandscape(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    // Right-hand panel holds the time, keypad, checkbox and actions; the
    // left of the screen stays clear so the video shows through. Capped so
    // the keypad doesn't drift apart on very wide laptop screens.
    final panelW = math.min(380.0, screenW * 0.42);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Stack(
              children: [
                Center(child: Text(AppStrings.of(context).sleepTimer, style: _kTitleStyle)),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _timeDisplay(),
                      const SizedBox(width: 16),
                      _closeButton(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              children: [
                const Spacer(),
                SizedBox(
                  width: panelW,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(
                        color: AppColors.specSleepDivider,
                        height: 1,
                        thickness: 1,
                      ),
                      const SizedBox(height: 16),
                      Center(child: _keypad()),
                      const Spacer(),
                      _checkboxRow(),
                      const SizedBox(height: 2),
                      _actionsRow(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Shared pieces ──

  Widget _timeDisplay() {
    final d = _customDuration;
    final h = d.inHours.toString();
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    return GestureDetector(
      // Long-press the duration to clear the entry back to 0h 00m.
      onLongPress: _digits.isEmpty ? null : _clear,
      child: Text.rich(
        TextSpan(
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
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
    );
  }

  Widget _closeButton() {
    return GestureDetector(
      onTap: widget.onDismiss,
      child: Container(
        width: 32,
        height: 32,
        decoration: const BoxDecoration(
          color: AppColors.specSleepClose,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.close, color: Colors.white, size: 20),
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

  Widget _keyCell(String digit) {
    return SizedBox(
      width: _kKeyColPitch,
      height: _kKeyRowPitch,
      child: Center(
        child: Material(
          color: AppColors.specSleepKeyFill,
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
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _checkboxRow() {
    return Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: Checkbox(
            value: _playToEnd,
            onChanged: (v) => setState(() => _playToEnd = v ?? false),
            side: const BorderSide(
              color: AppColors.specSleepCheckBorder,
              width: 2,
            ),
            activeColor: AppColors.specCheckbox,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        const SizedBox(width: 12),
        Text(AppStrings.of(context).playLastToEnd,
          style: const TextStyle(color: AppColors.white70, fontSize: 15),
        ),
      ],
    );
  }

  Widget _actionsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: _stop,
          style: TextButton.styleFrom(foregroundColor: AppColors.specCheckbox),
          child: Text(AppStrings.of(context).stop.toUpperCase(),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 24),
        TextButton(
          onPressed: _customDuration > Duration.zero ? _startCustom : null,
          style: TextButton.styleFrom(foregroundColor: AppColors.specCheckbox),
          child: Text(AppStrings.of(context).start.toUpperCase(),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
