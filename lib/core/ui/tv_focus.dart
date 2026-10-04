import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';

/// ONE visible focus ring for the whole app, drawn over whatever has focus.
///
/// On Android TV (and with a keyboard) the D-pad moves focus from widget to
/// widget, and the person three metres away has to SEE where it is. Material
/// marks a focused button with a faint overlay meant for a desk, nearly
/// invisible on this app's black screens — and teaching every list tile,
/// chip and icon in the app to draw its own ring would be hundreds of edits
/// that drift apart. Instead this layer, installed once above the navigator,
/// draws a clear blue frame around the focused widget's rectangle.
///
/// * Touch never shows it: it draws only in [FocusHighlightMode.traditional],
///   which Flutter enters on a key press and leaves on the next touch.
/// * It costs nothing at rest: it re-reads the rectangle in a persistent
///   frame callback, which runs only when something else drew a frame (a
///   scroll, an animation), and asks for a frame only when the rectangle
///   actually moved.
/// * Something that fills the screen (the player listening for the remote)
///   gets no frame — a border round the whole TV says nothing.
class FocusRingLayer extends StatefulWidget {
  const FocusRingLayer({super.key, required this.child});

  final Widget child;

  @override
  State<FocusRingLayer> createState() => _FocusRingLayerState();
}

class _FocusRingLayerState extends State<FocusRingLayer> {
  Rect? _rect;

  // A persistent frame callback cannot be removed, so there is exactly one,
  // and it serves whichever layer is current.
  static _FocusRingLayerState? _current;
  static bool _callbackAdded = false;

  @override
  void initState() {
    super.initState();
    _current = this;
    FocusManager.instance.addListener(_update);
    FocusManager.instance.addHighlightModeListener(_onMode);
    if (!_callbackAdded) {
      _callbackAdded = true;
      SchedulerBinding.instance.addPersistentFrameCallback((_) {
        final s = _current;
        if (s == null || !s.mounted || s._rect == null &&
            FocusManager.instance.highlightMode != FocusHighlightMode.traditional) {
          return;
        }
        // After layout of this frame: read, and redraw only on a change.
        SchedulerBinding.instance.addPostFrameCallback((_) => s._update());
      });
    }
  }

  void _onMode(FocusHighlightMode _) => _update();

  void _update() {
    if (!mounted) return;
    Rect? next;
    final f = FocusManager.instance.primaryFocus;
    if (FocusManager.instance.highlightMode == FocusHighlightMode.traditional &&
        f != null &&
        f.context != null &&
        f.context!.mounted) {
      try {
        final r = f.rect;
        final screen = MediaQuery.maybeSizeOf(context);
        final fillsScreen = screen != null &&
            r.width * r.height >= screen.width * screen.height * 0.8;
        if (!r.isEmpty && r.isFinite && !fillsScreen) next = r;
      } catch (_) {
        next = null;
      }
    }
    if (next != _rect) setState(() => _rect = next);
  }

  @override
  void dispose() {
    if (_current == this) _current = null;
    FocusManager.instance.removeListener(_update);
    FocusManager.instance.removeHighlightModeListener(_onMode);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _rect;
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        if (r != null)
          Positioned.fromRect(
            rect: r.inflate(3),
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.specPrimary, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.specPrimary.withValues(alpha: 0.35),
                      blurRadius: 10,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A tap target a TV remote can reach: focusable, and the remote's select
/// key (or Enter) does what a tap does. For the places that used a bare
/// GestureDetector, which a D-pad can never land on.
class RemoteTappable extends StatelessWidget {
  const RemoteTappable({
    super.key,
    required this.onTap,
    required this.child,
    this.onLongPress,
  });

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      enabled: onTap != null,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: child,
      ),
    );
  }
}
