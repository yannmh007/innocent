import 'package:flutter/material.dart';

/// [showModalBottomSheet], with the sheet's content kept above the phone's
/// navigation bar.
///
/// WHY. The app draws edge to edge (main.dart): the window runs behind the
/// Back · Home · Recents bar, and every screen is responsible for keeping
/// its own buttons out from under it. Flutter's modal sheet does not: it
/// wraps the content in `SafeArea(bottom: false)` (bottom_sheet.dart), even
/// with `useSafeArea: true`, so the sheet's last row — a Cancel, a Save, the
/// last choice of a list — sat under the bar, half covered on a phone with
/// three-button navigation. Half the app's sheets worked around it by hand
/// and half did not.
///
/// This pads the content by the bar's height at the bottom only. The sheet
/// itself still runs behind the bar, so its colour reaches the screen edge
/// as Android draws its own sheets; only what is ON it stops above the bar.
/// Content that already made room itself is not pushed up twice: below this
/// SafeArea the bar's inset reads as zero.
///
/// tool/raw_bottom_sheet.py keeps new code from calling the raw function.
Future<T?> showAppModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
}) {
  // ignore: avoid_raw_bottom_sheet
  return showModalBottomSheet<T>(
    context: context,
    builder: (BuildContext sheetContext) => SafeArea(
      top: false,
      left: false,
      right: false,
      child: Builder(builder: builder),
    ),
    backgroundColor: backgroundColor,
    barrierLabel: barrierLabel,
    elevation: elevation,
    shape: shape,
    clipBehavior: clipBehavior,
    constraints: constraints,
    barrierColor: barrierColor,
    isScrollControlled: isScrollControlled,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
    transitionAnimationController: transitionAnimationController,
    anchorPoint: anchorPoint,
  );
}
