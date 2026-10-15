import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// KNOWS WHEN A MENU, SHEET OR DIALOG IS OPEN OVER A TAB.
///
/// The tabs live in the shell's own navigator, and the bottom bar sits
/// outside it. So a popup opened from a tab — a ⋮ menu, a bottom sheet —
/// put its barrier over the tab's content only, and the bar beneath stayed
/// live: tapping Me with the Video tab's menu open went to Me, disposed the
/// Video tab under the open menu, and the menu's next layout asked a
/// disposed button for its context. In a release build that was "Null check
/// operator used on a null value", and Flutter's error card stuck on top of
/// the Me tab, which Reload could not clear (a real phone's report,
/// symbolized: State.context ← PopupMenuButtonState._positionBuilder).
///
/// With this, the shell sees the popup and treats a tap on the bar the way
/// Android treats any tap outside a popup: it closes the popup, and does not
/// also switch tabs underneath it.
class ShellPopupGuard extends NavigatorObserver {
  final List<Route<dynamic>> _popups = <Route<dynamic>>[];

  /// The popup on top, or null when none is open. Published after the frame
  /// that changed it: routes are added and removed while the navigator is
  /// building, and listeners must not rebuild in the middle of that.
  final ValueNotifier<Route<dynamic>?> top =
      ValueNotifier<Route<dynamic>?>(null);

  bool _scheduled = false;

  void _publish() {
    void apply() {
      _scheduled = false;
      top.value = _popups.isEmpty ? null : _popups.last;
    }

    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      apply();
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => apply());
  }

  void _add(Route<dynamic>? route) {
    if (route is PopupRoute) {
      _popups.add(route);
      _publish();
    }
  }

  void _drop(Route<dynamic>? route) {
    if (route != null && _popups.remove(route)) _publish();
  }

  /// THE TAB CHANGED UNDER OPEN POPUPS. Navigation from code — a
  /// notification, a deep link — switches tabs without touching the bar, and
  /// the navigator keeps a sheet opened on the old tab floating over the new
  /// one, its builder belonging to a screen that has been disposed (the same
  /// crash, by another road). The navigator tells its observers nothing about
  /// such a page swap, so [PopupAwareBar] — which sees the tab index — calls
  /// this. They are closed once the frame that changed the tab is over.
  void closeOrphans() {
    if (_popups.isEmpty) return;
    final orphans = List<Route<dynamic>>.of(_popups);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      for (final route in orphans.reversed) {
        if (_popups.contains(route) && route.isActive) {
          route.navigator?.removeRoute(route);
        }
      }
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _drop(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _drop(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _drop(oldRoute);
    _add(newRoute);
  }

  /// A tap on the bar while a popup is open: close it, as a tap on its
  /// barrier would. A popup that may not be dismissed that way is left open.
  void dismissTop() {
    final route = top.value;
    if (route == null) return;
    if (route is ModalRoute && !route.barrierDismissible) return;
    route.navigator?.maybePop();
  }

  @visibleForTesting
  int get openCount => _popups.length;
}

/// The one guard for the app's shell (app_router.dart attaches it).
final ShellPopupGuard shellPopupGuard = ShellPopupGuard();

/// [child] (the bottom bar, or the side rail) that, while a popup is open
/// over the tab, cannot switch tabs: it is shaded like the popup's barrier,
/// and a tap on it closes the popup. And when the tab changes some other way
/// ([tabIndex] moves), popups left from the old tab are closed.
class PopupAwareBar extends StatefulWidget {
  const PopupAwareBar({
    super.key,
    required this.tabIndex,
    required this.child,
    ShellPopupGuard? guard,
  }) : _guard = guard;

  final int tabIndex;
  final Widget child;
  final ShellPopupGuard? _guard;

  @override
  State<PopupAwareBar> createState() => _PopupAwareBarState();
}

class _PopupAwareBarState extends State<PopupAwareBar> {
  ShellPopupGuard get _guard => widget._guard ?? shellPopupGuard;

  @override
  void didUpdateWidget(PopupAwareBar old) {
    super.didUpdateWidget(old);
    if (old.tabIndex != widget.tabIndex) _guard.closeOrphans();
  }

  @override
  Widget build(BuildContext context) {
    final guard = _guard;
    final child = widget.child;
    return ValueListenableBuilder<Route<dynamic>?>(
      valueListenable: guard.top,
      child: child,
      builder: (context, route, bar) {
        if (route == null) return bar!;
        final shade = route is ModalRoute ? route.barrierColor : null;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: guard.dismissTop,
          child: Stack(
            children: <Widget>[
              AbsorbPointer(child: bar),
              if (shade != null && shade.a > 0)
                Positioned.fill(
                    child: IgnorePointer(child: ColoredBox(color: shade))),
            ],
          ),
        );
      },
    );
  }
}
