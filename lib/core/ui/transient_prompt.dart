import 'package:flutter/material.dart';

/// A PROMPT THAT BELONGS TO THE MOMENT IT WAS SHOWN.
///
/// "Resume <video>?" is offered when the app opens. Flutter, following
/// Material's accessibility rule, never times out a snack bar with an action
/// while TalkBack, Switch Access or any accessibility service runs, so its
/// action stays reachable. That is right, but this one then sat over the
/// bottom bar on every screen until dismissed by hand: over the folder bar's
/// Hide button in the device lab (whose driver is such a service), and over
/// the selection bar for a TalkBack user.
///
/// So it stays for as long as the user is still where it was offered, and
/// closes itself the moment they move on: another screen or tab opens
/// ([TransientPromptObserver] on each navigator), or a selection starts
/// (the screen calls [close]). Nothing else is lost: the video is in History.
class TransientPrompt {
  TransientPrompt._();

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _current;

  /// Shows [bar] as the transient prompt, in place of whatever snack bar is
  /// up, so that it is the current one while it lasts.
  static void show(ScaffoldMessengerState messenger, SnackBar bar) {
    _current = null;
    messenger.clearSnackBars();
    final controller = messenger.showSnackBar(bar);
    _current = controller;
    controller.closed.whenComplete(() {
      if (identical(_current, controller)) _current = null;
    });
  }

  /// Closes the prompt if it is still up. After the frame: a navigator
  /// reports a push in the middle of building, where the messenger cannot
  /// change.
  static void close() {
    final controller = _current;
    if (controller == null) return;
    _current = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        controller.close();
      } catch (_) {
        // Already gone: replaced by another snack bar, or its screen closed.
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Whether a prompt is up (for tests).
  static bool get isShowing => _current != null;
}

/// Closes the [TransientPrompt] when the navigator it watches opens or swaps
/// a route. A NavigatorObserver watches one navigator, so each gets its own.
class TransientPromptObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      TransientPrompt.close();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      TransientPrompt.close();

  // A tab switch in a ShellRoute swaps the navigator's page: the old tab's
  // route is removed rather than popped.
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      TransientPrompt.close();
}
