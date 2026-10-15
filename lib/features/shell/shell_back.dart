import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// BACK INSIDE A TAB.
///
/// Android's rule, and MX Player's, Files', Photos': Back undoes what the
/// screen is in the middle of — a selection, an open search — before it
/// leaves the screen. On the Video tab it did not: with videos selected,
/// Back left the app, and only the ✕ in the corner cleared the selection.
///
/// The Video tab had a PopScope for exactly this, and it never ran. Each tab
/// is the only page of the shell's own navigator, and the shell the only
/// page of the root one; with nothing on either that can pop, GoRouter
/// answers Back with "nothing to pop" and Android closes the app — neither
/// PopScope is asked (measured: test/shell_back_test.dart). Only the shell's
/// rule ever sees Back. So a tab tells the shell what Back should undo here
/// ([tabBackProvider], through [TabBack]), and the shell holds Back and does
/// it ([ShellBackScope]).

/// What Back should undo on tab [index] right now, or null for nothing.
final tabBackProvider =
    StateProvider.family<VoidCallback?, int>((ref, index) => null);

/// For a tab screen's State: call [tabBack] at the end of every build with
/// what Back should undo now — closing a selection, then a search — or null.
mixin TabBack<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// Which tab this screen is (0 Video, 1 Music, 2 Transfer, 3 Me).
  int get tabIndex;

  StateController<VoidCallback?>? _published;
  int? _publishedTab;
  VoidCallback? _undo;

  // One stable callback for the shell: the latest [_undo] runs through it,
  // so a rebuild with a new closure does not count as a change.
  void _runUndo() => _undo?.call();

  void tabBack(VoidCallback? undo) {
    _undo = undo;
    // A State reused for another tab takes its undo off the old one.
    if (_publishedTab != null && _publishedTab != tabIndex) _unpublish();
    final StateController<VoidCallback?> controller =
        _published ?? ref.read(tabBackProvider(tabIndex).notifier);
    _published = controller;
    _publishedTab = tabIndex;
    final want = undo == null ? null : _runUndo;
    if (controller.state == want) return;
    // After the frame: a provider may not change while widgets build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.mounted) return;
      final now = _undo == null || !mounted ? null : _runUndo;
      if (controller.state != now) controller.state = now;
    });
  }

  /// Takes this screen's undo off the tab it was published for, after the
  /// frame, through the controller taken while mounted (in dispose, `ref`
  /// is on its way out).
  void _unpublish() {
    final controller = _published;
    _published = null;
    _publishedTab = null;
    if (controller == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.mounted && controller.state == _runUndo) {
        controller.state = null;
      }
    });
  }

  @override
  void dispose() {
    _unpublish();
    super.dispose();
  }
}

/// The shell's Back: [undo] first when the tab has something to undo; then,
/// on any tab but the first, the first tab ([toFirstTab]); only on the first
/// tab with nothing to undo does Back leave the app.
class ShellBackScope extends StatelessWidget {
  const ShellBackScope({
    super.key,
    required this.onFirstTab,
    required this.undo,
    required this.toFirstTab,
    required this.child,
  });

  final bool onFirstTab;
  final VoidCallback? undo;
  final VoidCallback toFirstTab;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: onFirstTab && undo == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final u = undo;
        if (u != null) {
          u();
        } else {
          toFirstTab();
        }
      },
      child: child,
    );
  }
}
