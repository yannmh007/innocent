import 'package:flutter/material.dart';

/// A [PopupMenuButton] that cannot crash when it disappears while its menu
/// is open.
///
/// THE CRASH. Flutter 3.32's PopupMenuButton hands its menu a callback into
/// the button's own State (`_positionBuilder`), and the menu calls it on every
/// layout. Remove the button while the menu is up and the next layout asks a
/// disposed State for its `context`: in a release build, "Null check operator
/// used on a null value" (`State.context` → `PopupMenuButtonState.
/// _positionBuilder` → `_PopupMenuRoute.buildPage`, symbolized from a real
/// phone's report). The menu's page is then Flutter's error card, sitting on
/// top of whatever screen the person is on — "Something didn't load" on the
/// Me tab, which no Reload clears, because it is not the Me tab that broke.
///
/// The easiest way to get there was the bottom tab bar: a menu opened on the
/// Video tab lives in the tab's own navigator, so the bar stays tappable, and
/// tapping Me disposes the Video tab — and the menu's button — under the open
/// menu. (The shell now closes the menu instead; see ShellPopupGuard.) The
/// other way is a rebuild that drops the button in place: a selection bar
/// swapped back for the normal one by a refresh, a list row re-keyed.
///
/// This works out where the menu goes ONCE, when it opens, and gives the menu
/// only that position — nothing that points back at this State — so a button
/// that has gone away leaves an ordinary menu behind, which closes the
/// ordinary way. The menu opens on the root navigator, so its barrier covers
/// the whole screen, tab bar included, as every Android popup does. A choice
/// made after the button has gone is dropped, as PopupMenuButton drops it.
///
/// Same parameters as PopupMenuButton, for the ones this app uses.
class SafePopupMenuButton<T> extends StatefulWidget {
  const SafePopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.onCanceled,
    this.onOpened,
    this.initialValue,
    this.tooltip,
    this.icon,
    this.iconSize,
    this.child,
    this.color,
    this.shape,
    this.elevation,
    this.offset = Offset.zero,
    this.position,
    this.enabled = true,
    this.padding = const EdgeInsets.all(8.0),
    this.constraints,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final PopupMenuCanceled? onCanceled;
  final VoidCallback? onOpened;
  final T? initialValue;
  final String? tooltip;
  final Widget? icon;
  final double? iconSize;
  final Widget? child;
  final Color? color;
  final ShapeBorder? shape;
  final double? elevation;
  final Offset offset;
  final PopupMenuPosition? position;
  final bool enabled;
  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;

  @override
  State<SafePopupMenuButton<T>> createState() => _SafePopupMenuButtonState<T>();
}

class _SafePopupMenuButtonState<T> extends State<SafePopupMenuButton<T>> {
  bool _open = false;

  /// Where the menu goes, from where the button is now (PopupMenuButton's
  /// own arithmetic, done once).
  RelativeRect _position(RenderBox button, RenderBox overlay) {
    final theme = PopupMenuTheme.of(context);
    final where = widget.position ?? theme.position ?? PopupMenuPosition.over;
    var offset = widget.offset;
    if (where == PopupMenuPosition.under) {
      offset = Offset(0.0, button.size.height) + widget.offset;
      if (widget.child == null) {
        offset -= Offset(0.0, widget.padding.vertical / 2);
      }
    }
    return RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(offset, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero) + offset,
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
  }

  Future<void> _showMenu() async {
    if (_open) return;
    final items = widget.itemBuilder(context);
    if (items.isEmpty) return;
    final button = context.findRenderObject();
    final overlay = Navigator.of(context, rootNavigator: true)
        .overlay
        ?.context
        .findRenderObject();
    if (button is! RenderBox || overlay is! RenderBox) return;
    final position = _position(button, overlay);
    widget.onOpened?.call();
    _open = true;
    final value = await showMenu<T>(
      context: context,
      position: position,
      items: items,
      initialValue: widget.initialValue,
      color: widget.color,
      shape: widget.shape,
      elevation: widget.elevation,
      constraints: widget.constraints,
      useRootNavigator: true,
    );
    _open = false;
    // The button went away while the menu was open: its actions belong to a
    // screen that is no longer there.
    if (!mounted) return;
    if (value == null) {
      widget.onCanceled?.call();
      return;
    }
    widget.onSelected?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final tooltip =
        widget.tooltip ?? MaterialLocalizations.of(context).showMenuTooltip;
    final child = widget.child;
    if (child != null) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: widget.enabled ? _showMenu : null,
          canRequestFocus: widget.enabled,
          child: child,
        ),
      );
    }
    return IconButton(
      icon: widget.icon ?? Icon(Icons.adaptive.more),
      iconSize: widget.iconSize,
      padding: widget.padding,
      tooltip: tooltip.isEmpty ? null : tooltip,
      onPressed: widget.enabled ? _showMenu : null,
    );
  }
}
