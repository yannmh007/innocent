import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// THE LIST AND THE OPEN PAGE SIDE BY SIDE, on a wide window
/// (docs/devices_2026_11.md, Phase 2).
///
/// Material's list-detail layout: at the "expanded" window width — 840 dp and
/// up: a tablet held sideways, a foldable opened and turned, a Chromebook
/// window, a TV — a screen that is a list of things to open (Settings, the
/// Video tab's folders) shows the list and the open thing together. Below
/// it, the list alone, and a tap opens the page over it as it always has: a
/// phone is never two panes. By the WINDOW, never "is it a tablet": a tablet
/// upright (800 dp) keeps one pane, and a window resized across the line
/// changes its mind as it crosses it.
class ListDetail {
  ListDetail._();

  /// Where two panes begin: Material's expanded width class.
  static const double minWidth = 840;

  /// Whether the window is wide enough for two panes.
  static bool twoPanes(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= minWidth;

  /// The list pane's width in a body [width] wide: about a third, from 360
  /// (Material's list pane) to 400 dp — a phone's width, which every list
  /// here was drawn for, so the list looks as it does on a phone and the page
  /// has the rest (400 dp at the tightest: a foldable turned, beside the
  /// rail). At 320 the Video tab's title gave way to its four buttons.
  static double listWidth(double width) => (width * 0.36).clamp(360.0, 400.0);

  /// The person is moving by keys — a TV's D-pad, a keyboard — not by touch
  /// (Flutter's focus highlight mode: traditional from a key press until the
  /// next touch).
  static bool get usingKeys =>
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
}

/// The two panes: [list] at [ListDetail.listWidth], a hairline, [detail] in
/// the rest, both the full height (each pane brings its own top bar, so the
/// two bars meet at the hairline).
///
/// It keeps clear of the left and right insets — a TV's overscan margins, a
/// cutout sideways — which a list's own padding does not (a vertical list
/// takes only the top and bottom ones), and hands them to neither pane.
///
/// [onDetailFocus] hears focus enter and leave the detail pane: on a TV a
/// D-pad's Back from inside the page goes back to the list's open row
/// before it leaves the screen (Android TV's rule: Back steps out of a
/// pane, then out of the screen), as a touch never needs.
class ListDetailPanes extends StatelessWidget {
  const ListDetailPanes({
    super.key,
    required this.list,
    required this.detail,
    this.onDetailFocus,
  });

  final Widget list;
  final Widget detail;
  final ValueChanged<bool>? onDetailFocus;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: ListDetail.listWidth(constraints.maxWidth),
              child: list,
            ),
            const VerticalDivider(
              width: 1,
              thickness: 1,
              color: AppColors.white10,
            ),
            Expanded(
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onFocusChange: onDetailFocus,
                child: detail,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The page pane's own navigator. A page opened FROM the open page (Settings
/// → Player → Controls) opens in this pane with its back arrow, beside the
/// list rather than over it; the page at the bottom of the pane has no back
/// arrow (nothing in the pane is under it). Back closes the pane's top page
/// first, then the screen (a [NavigatorPopHandler]: the system's Back, a
/// remote's, a predictive back gesture).
///
/// Dialogs still open over the whole window: showDialog uses the root
/// navigator. So a dialog closes itself through ITS context — a page's
/// context here finds this navigator, and `Navigator.of(pageContext).pop()`
/// would close the page under the dialog (settings_dialogs.dart did, 12 Nov).
///
/// Key it by what it shows: a new page is a new navigator, so a page opened
/// inside the last one does not linger under the next.
class DetailNavigator extends StatefulWidget {
  const DetailNavigator({super.key, required this.page, this.backToList});

  /// The page at the bottom of the pane.
  final Widget page;

  /// What Back does at the page at the bottom of the pane instead of
  /// leaving the screen — focus to the list's open row, when the person is
  /// on the page by D-pad or keyboard ([ListDetailPanes.onDetailFocus]).
  /// Null: Back leaves.
  final VoidCallback? backToList;

  @override
  State<DetailNavigator> createState() => DetailNavigatorState();
}

class DetailNavigatorState extends State<DetailNavigator> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  /// [DetailNavigator.backToList], for the page at the bottom: the route is
  /// built once, so it listens rather than being rebuilt.
  late final ValueNotifier<VoidCallback?> _backToList =
      ValueNotifier<VoidCallback?>(widget.backToList);

  @override
  void didUpdateWidget(DetailNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _backToList.value = widget.backToList;
  }

  @override
  void dispose() {
    _backToList.dispose();
    super.dispose();
  }

  /// Back to the page at the bottom of the pane (its row tapped again).
  void popToRoot() => _navigator.currentState?.popUntil((r) => r.isFirst);

  @override
  Widget build(BuildContext context) {
    // Its own semantics container: every page of a Navigator has a
    // ModalBarrier, and a ModalBarrier's BlockSemantics drops everything
    // painted before it in the same container — the list pane, as it once
    // dropped the rail (shell_screen.dart, test/rail_semantics_test.dart).
    return Semantics(
      container: true,
      child: NavigatorPopHandler<Object?>(
        onPopWithResult: (_) => _navigator.currentState?.maybePop(),
        child: Navigator(
          key: _navigator,
          onGenerateInitialRoutes: (_, __) => [
            // In place at once: the pane's content changing is not a page
            // being opened over another (the switch above fades it).
            PageRouteBuilder<void>(
              settings: const RouteSettings(name: 'detail'),
              // A Back the page at the bottom holds (canPop false) is one
              // this navigator handles (NavigatorPopHandler): focus goes to
              // the list instead of the screen closing.
              pageBuilder: (_, __, ___) =>
                  ValueListenableBuilder<VoidCallback?>(
                valueListenable: _backToList,
                builder: (_, back, page) => PopScope<Object?>(
                  canPop: back == null,
                  onPopInvokedWithResult: (didPop, _) {
                    if (!didPop) back?.call();
                  },
                  child: page!,
                ),
                child: widget.page,
              ),
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
            ),
          ],
        ),
      ),
    );
  }
}

/// A row of a list pane, selected: the accent at 16 % behind it, inset and
/// rounded (ui-design: selected = accent text and icon, container accent
/// 16 %; tile radius 14) — the open page's row, which stays marked while
/// the page is beside it.
BoxDecoration listDetailSelection(Color accent) => BoxDecoration(
      color: accent.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(14),
    );
