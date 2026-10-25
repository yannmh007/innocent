import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// What a player message is about, which sets its mark.
enum PlayerToastKind {
  /// A fact: "Loaded: film.srt".
  info,

  /// Something the viewer asked for has happened: "Now playing 480p".
  success,

  /// Asked for and not done, or done another way: "Couldn't switch".
  warning,

  /// Under way: a spinner, and no timeout of its own — the next message,
  /// or [PlayerToastController.hide], takes it away.
  busy,
}

@immutable
class PlayerToastData {
  const PlayerToastData(this.text, {this.kind = PlayerToastKind.info, this.icon, this.serial = 0});

  final String text;
  final PlayerToastKind kind;

  /// In place of the kind's own mark.
  final IconData? icon;

  /// Tells two messages with the same words apart, so a repeat animates in.
  final int serial;
}

/// THE PLAYER'S ONE VOICE for a passing message.
///
/// It replaces the Material SnackBar the player used: a light bar along the
/// bottom edge, over the seek bar and the buttons a viewer reaches for next,
/// and white on a dark film (the owner's report, 1.64.74). Here the message
/// sits near the top, under the top controls, dark and translucent, with a
/// mark that says what kind it is — the way YouTube and Netflix speak over a
/// film. One at a time: a new one replaces the last.
class PlayerToastController extends ValueNotifier<PlayerToastData?> {
  PlayerToastController() : super(null);

  Timer? _timer;
  int _serial = 0;

  /// Shows [text]; [duration] overrides the reading time, and a busy
  /// message stays until replaced or hidden.
  void show(String text, {PlayerToastKind kind = PlayerToastKind.info, IconData? icon, Duration? duration}) {
    _timer?.cancel();
    _timer = null;
    value = PlayerToastData(text, kind: kind, icon: icon, serial: ++_serial);
    final d = duration ?? (kind == PlayerToastKind.busy ? null : readingTime(text, kind));
    if (d != null) _timer = Timer(d, hide);
  }

  void hide() {
    _timer?.cancel();
    _timer = null;
    value = null;
  }

  /// Long enough to read: two seconds and a little per character, a second
  /// more for a warning, never past seven.
  @visibleForTesting
  static Duration readingTime(String text, PlayerToastKind kind) {
    final ms = 2000 + text.length * 45 + (kind == PlayerToastKind.warning ? 1000 : 0);
    return Duration(milliseconds: ms.clamp(2000, 7000));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// The message itself, placed by the caller: centred across the width,
/// [top] from the screen's top edge.
class PlayerToastView extends StatelessWidget {
  const PlayerToastView({super.key, required this.controller, required this.top});

  final PlayerToastController controller;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: ValueListenableBuilder<PlayerToastData?>(
        valueListenable: controller,
        builder: (context, data, _) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          reverseDuration: const Duration(milliseconds: 160),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, -0.35), end: Offset.zero).animate(animation),
              child: child,
            ),
          ),
          child: data == null
              ? const SizedBox.shrink(key: ValueKey<int>(-1))
              : Center(
                  key: ValueKey<int>(data.serial),
                  child: PlayerToastPill(data: data, onTap: controller.hide),
                ),
        ),
      ),
    );
  }
}

/// The dark pill a player message is drawn in; also used for the player's
/// standing notices, so every message over a film looks the same.
class PlayerToastPill extends StatelessWidget {
  const PlayerToastPill({super.key, required this.data, this.onTap});

  final PlayerToastData data;
  final VoidCallback? onTap;

  static const Color _fill = Color(0xE6181B21);
  static const Color _edge = Color(0x24FFFFFF);

  static Color markColor(PlayerToastKind kind) {
    switch (kind) {
      case PlayerToastKind.info:
      case PlayerToastKind.busy:
        return AppColors.accentBlueLight;
      case PlayerToastKind.success:
        return const Color(0xFF6DD58C);
      case PlayerToastKind.warning:
        return const Color(0xFFFFC857);
    }
  }

  static IconData markIcon(PlayerToastKind kind) {
    switch (kind) {
      case PlayerToastKind.info:
      case PlayerToastKind.busy:
        return Icons.info_outline_rounded;
      case PlayerToastKind.success:
        return Icons.check_circle_rounded;
      case PlayerToastKind.warning:
        return Icons.error_outline_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = markColor(data.kind);
    final mark = data.kind == PlayerToastKind.busy
        ? SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : Icon(data.icon ?? markIcon(data.kind), color: color, size: 18);
    // Said once by a screen reader when it appears, as a SnackBar was.
    return Semantics(
      liveRegion: true,
      container: true,
      label: data.text,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _fill,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: _edge, width: 0.8),
              boxShadow: const [
                BoxShadow(color: Color(0x4D000000), blurRadius: 14, offset: Offset(0, 3)),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 18, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  mark,
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      data.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
