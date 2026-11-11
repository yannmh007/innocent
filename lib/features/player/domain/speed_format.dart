/// A playback speed as people write it: "1.25", "1.5", "2", "0.75".
///
/// Four places printed speeds four ways. The shortcut's "1X" badge and the
/// speed badge over the picture rounded a quarter speed to one place —
/// 1.25 read "1.3X" and 0.75 "0.8X" while the toast beside them said
/// "1.25x" — and the toast wrote 2 as "2.00x".
String formatSpeed(double speed) {
  final fixed = speed.toStringAsFixed(2);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// The speed the "1X" shortcut moves to from [current]: the next one up in
/// [cycle], round to the first after the last.
///
/// From a speed the cycle does not hold (1.75, set on the speed slider) it
/// used to fall back to the first, 0.5: a tap meant to go faster went to
/// half speed.
double nextSpeedInCycle(double current, List<double> cycle) =>
    cycle.firstWhere((s) => s > current + 0.001, orElse: () => cycle.first);
