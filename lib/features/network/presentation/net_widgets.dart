import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/localization/app_strings.dart';
import '../data/net_server.dart';

/// MX's Local Network palette: the hero's blue, the "+" button's sky blue,
/// the Scan button's cyan outline, and the dialog's frosted dark grey.
class NetColors {
  NetColors._();
  static const Color heroTop = Color(0xFF0A55E8);
  static const Color heroBottom = Color(0xFF1B7BFF);
  static const Color fab = Color(0xFF2E9BF0);
  static const Color action = Color(0xFF3AA8F2);
  static const Color scan = Color(0xFF41C4E8);
  static const Color dialog = Color(0xFF2A2A2C);
  static const Color field = Color(0xFF1E1E20);
  static const Color fieldBorder = Color(0xFF5A5A5E);
  static const Color hint = Color(0xFF8A8A8E);
  static const Color folder = Color(0xFFE9E9EB);
  static const Color monitor = Color(0xFF1FBF8F);
  static const Color error = Color(0xFFFF6B6B);
}

/// The blue band at the top of Networks: computer ⟷ phone, and the four
/// protocols — MX's picture, drawn rather than shipped as a bitmap so it is
/// sharp on every density and every width.
class NetHero extends StatelessWidget {
  const NetHero({super.key, this.compact = false});

  /// The smaller version inside the "How to use?" dialog.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final h = compact ? 150.0 : 176.0;
    return SizedBox(
      height: h,
      child: CustomPaint(
        painter: _HeroPainter(),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const _ComputerBadge(),
                const SizedBox(width: 22),
                Transform.rotate(
                  angle: -math.pi / 4,
                  child: const Icon(Icons.link_rounded,
                      color: Colors.white, size: 26),
                ),
                const SizedBox(width: 22),
                _PhoneGlyph(height: compact ? 58 : 70),
              ],
            ),
            SizedBox(height: compact ? 10 : 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(width: 34, height: 1, color: Colors.white38),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    s.supportedProtocols.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xCCFFFFFF),
                      fontSize: 11.5,
                      letterSpacing: 2.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Container(width: 34, height: 1, color: Colors.white38),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                for (final p in NetProtocol.values) ...<Widget>[
                  if (p != NetProtocol.smb)
                    Container(
                      width: 1,
                      height: 12,
                      margin: const EdgeInsets.symmetric(horizontal: 12),
                      color: Colors.white54,
                    ),
                  Text(
                    p.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.clipRect(rect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[NetColors.heroTop, NetColors.heroBottom],
        ).createShader(rect),
    );
    // MX's soft rings, centred below the band.
    final c = Offset(size.width / 2, size.height * 1.05);
    final ring = Paint()..color = const Color(0x14FFFFFF);
    for (var i = 4; i >= 1; i--) {
      canvas.drawCircle(c, size.height * 0.42 * i, ring);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ComputerBadge extends StatelessWidget {
  const _ComputerBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration:
          const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
      child: const Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Icon(Icons.desktop_windows_outlined,
              color: NetColors.monitor, size: 30),
          Padding(
            padding: EdgeInsets.only(bottom: 5),
            child:
                Icon(Icons.folder_rounded, color: NetColors.monitor, size: 13),
          ),
        ],
      ),
    );
  }
}

class _PhoneGlyph extends StatelessWidget {
  const _PhoneGlyph({required this.height});
  final double height;

  @override
  Widget build(BuildContext context) {
    final w = height * 0.52;
    return Container(
      width: w,
      height: height,
      padding:
          EdgeInsets.fromLTRB(w * 0.16, height * 0.14, w * 0.16, height * 0.1),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(w * 0.18),
        border: Border.all(color: const Color(0xFF0D2E6E), width: 1.5),
      ),
      child: GridView.count(
        crossAxisCount: 3,
        mainAxisSpacing: 2.5,
        crossAxisSpacing: 2.5,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: List<Widget>.generate(
          9,
          (_) => DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF2F7BEA),
              borderRadius: BorderRadius.circular(1.2),
            ),
          ),
        ),
      ),
    );
  }
}

/// MX's protocol icon: a folder with the protocol written on it, on a
/// monitor's stand.
class ProtocolGlyph extends StatelessWidget {
  const ProtocolGlyph(this.protocol, {super.key, this.size = 36});
  final NetProtocol protocol;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.topCenter,
        children: <Widget>[
          Icon(Icons.folder_rounded,
              color: NetColors.folder, size: size * 0.92),
          Positioned(
            top: size * 0.3,
            child: Text(
              protocol.label,
              style: TextStyle(
                color: const Color(0xFF2A2A2C),
                fontSize: size * (protocol.label.length > 3 ? 0.2 : 0.23),
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
          Positioned(
            bottom: size * 0.02,
            child: Column(
              children: <Widget>[
                Container(
                    width: size * 0.08,
                    height: size * 0.08,
                    color: NetColors.folder),
                Container(
                  width: size * 0.42,
                  height: size * 0.06,
                  decoration: BoxDecoration(
                    color: NetColors.folder,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "1. Add a server by tapping the (+) button." — the + drawn inline, where
/// the sentence puts it in each language.
class NetHowTo extends StatelessWidget {
  const NetHowTo({super.key, this.extra = true});
  final bool extra;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final mm = s.locale.languageCode == 'my';
    final body = TextStyle(
      color: Colors.white.withValues(alpha: 0.86),
      fontSize: 13.5,
      height: mm ? 1.7 : 1.45,
    );
    final parts = s.netHowStep1.split('{+}');
    Widget line(String n, InlineSpan content) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text.rich(TextSpan(style: body, children: <InlineSpan>[
            TextSpan(text: '$n '),
            content,
          ])),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          s.howToUse,
          style: TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w700,
            height: mm ? 1.6 : 1.3,
          ),
        ),
        const SizedBox(height: 14),
        line(
          '1.',
          TextSpan(children: <InlineSpan>[
            TextSpan(text: parts.first),
            const WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: CircleAvatar(
                  radius: 8,
                  backgroundColor: NetColors.fab,
                  child: Icon(Icons.add, size: 12, color: Colors.white),
                ),
              ),
            ),
            if (parts.length > 1) TextSpan(text: parts.last),
          ]),
        ),
        line('2.', TextSpan(text: s.netHowStep2)),
        if (extra) line('3.', TextSpan(text: s.netHowStep3)),
      ],
    );
  }
}

/// The frosted dark card every Local Network dialog sits on.
class NetDialog extends StatelessWidget {
  const NetDialog({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: NetColors.dialog,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: padding ?? const EdgeInsets.fromLTRB(14, 18, 14, 10),
          child: child,
        ),
      ),
    );
  }
}

/// "How to use?" — MX's (i): the hero, the steps and GOT IT.
Future<void> showNetInfo(BuildContext context) {
  final s = AppStrings.of(context);
  return showDialog<void>(
    context: context,
    builder: (ctx) => NetDialog(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const NetHero(compact: true),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: NetHowTo(),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 12, 10),
              child: TextButton(
                key: const ValueKey('net-got-it'),
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(
                  s.netGotIt,
                  style: const TextStyle(
                    color: NetColors.action,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
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

String netFmtBytes(int b) {
  if (b < 1024) return '$b B';
  const u = <String>['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024.0;
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${u[i]}';
}
