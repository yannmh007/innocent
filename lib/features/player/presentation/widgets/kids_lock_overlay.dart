import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/theme/app_colors.dart';

/// Kids Lock overlay (v0.49, MX parity).
///
/// Child-proof screen shield rendered above every player layer:
/// - The root [GestureDetector] uses [HitTestBehavior.opaque], so *all*
///   taps, drags, and pinches die here — nothing reaches the seekbar,
///   gesture layer, or side panels underneath.
/// - A tap briefly reveals a small lock chip (auto-hides after 3 s),
///   mirroring how the normal lock overlay behaves.
/// - Unlocking requires PRESS-AND-HOLDING the chip for ~2 s while a
///   progress ring fills. Releasing early rewinds the ring. This is
///   deliberately harder than a tap so a toddler mashing the screen
///   can't exit by accident.
class KidsLockOverlay extends StatefulWidget {
  final VoidCallback onUnlock;

  const KidsLockOverlay({super.key, required this.onUnlock});

  @override
  State<KidsLockOverlay> createState() => _KidsLockOverlayState();
}

class _KidsLockOverlayState extends State<KidsLockOverlay>
    with SingleTickerProviderStateMixin {
  static const _holdDuration = Duration(milliseconds: 2000);

  late final AnimationController _hold;
  Timer? _hideTimer;
  bool _chipVisible = true; // visible on entry so the user learns the exit

  @override
  void initState() {
    super.initState();
    _hold = AnimationController(vsync: this, duration: _holdDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          widget.onUnlock();
        }
      });
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hold.dispose();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      // Never hide mid-hold — the ring must stay visible while filling.
      if (mounted && !_hold.isAnimating) {
        setState(() => _chipVisible = false);
      }
    });
  }

  void _reveal() {
    if (!_chipVisible) setState(() => _chipVisible = true);
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque, // absorb EVERYTHING
        onTap: _reveal,
        child: Stack(
          children: [
            // Bottom-centre unlock chip.
            Positioned(
              left: 0,
              right: 0,
              bottom: 48,
              child: IgnorePointer(
                ignoring: !_chipVisible,
                child: AnimatedOpacity(
                  opacity: _chipVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: Center(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (_) => _reveal(),
                      onLongPressStart: (_) {
                        _hideTimer?.cancel();
                        _hold.forward();
                      },
                      onLongPressEnd: (_) {
                        if (_hold.status != AnimationStatus.completed) {
                          _hold.reverse();
                        }
                        _scheduleHide();
                      },
                      onLongPressCancel: () {
                        if (_hold.status != AnimationStatus.completed) {
                          _hold.reverse();
                        }
                        _scheduleHide();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.black55,
                          borderRadius: BorderRadius.circular(28),
                          border:
                              Border.all(color: Colors.white24, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 30,
                              height: 30,
                              child: AnimatedBuilder(
                                animation: _hold,
                                builder: (_, __) => Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    CircularProgressIndicator(
                                      value: _hold.value,
                                      strokeWidth: 2.5,
                                      backgroundColor: Colors.white12,
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                              AppColors.accentBlue),
                                    ),
                                    const Icon(Icons.lock_outline,
                                        color: Colors.white, size: 15),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              s.kidsLockHoldHint,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
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
          ],
        ),
      ),
    );
  }
}
