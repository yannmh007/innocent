import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
/// Phase 34: Floating Magic Pen FAB — MX Player Pro AI feature.
/// Appears on the right edge above the Resume FAB.
/// Visual: dark purple circle with a stylized "pen + sparkles" icon.
class MagicPenFab extends StatelessWidget {
  final VoidCallback? onTap;
  const MagicPenFab({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap ?? () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppStrings.of(context).magicPenHint),
              duration: const Duration(seconds: 1),
            ),
          );
        },
        customBorder: const CircleBorder(),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF5E47C7),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: CustomPaint(
            painter: _PenSparkPainter(),
            size: const Size(48, 48),
          ),
        ),
      ),
    );
  }
}

/// Stylized pen with a sparkle/wifi-arc above — matches MX's icon.
class _PenSparkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    final cx = size.width / 2;
    final cy = size.height / 2;

    // Wifi-arc / sparkles (top-left)
    final arcRect = Rect.fromCircle(
      center: Offset(cx - 7, cy + 2),
      radius: 6,
    );
    canvas.drawArc(arcRect, -2.4, 0.8, false, paint);

    final arcRect2 = Rect.fromCircle(
      center: Offset(cx - 7, cy + 2),
      radius: 10,
    );
    canvas.drawArc(arcRect2, -2.4, 0.8, false, paint);

    // Pen diagonal line (top-right to bottom-left)
    final fill = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final penPath = Path()
      ..moveTo(cx + 8, cy - 8)
      ..lineTo(cx + 11, cy - 5)
      ..lineTo(cx - 2, cy + 8)
      ..lineTo(cx - 5, cy + 5)
      ..close();
    canvas.drawPath(penPath, fill);

    // Pen tip dot
    final dotPaint = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(cx - 6, cy + 6), 1.5, dotPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
