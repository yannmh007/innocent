import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/ui/app_sheet.dart';

/// The player's look, in one place (skill `ui-design`).
///
/// WHY. Each menu of the player had been drawn on its own: ⋮ on a 92 %
/// grey over a 38 % scrim, so the clock, ♪, "Default" and the seek bar
/// showed through it; the subtitle panel on 90 % black; the sheets on
/// another grey; outline rings, radios and checkboxes each their own size.
/// The owner's word for the result was "a toy" (12 Nov 2026). Every menu
/// now takes its surface, header, rows and tiles from here.
class PlayerUi {
  PlayerUi._();

  /// Behind an open panel or dialog: the picture, dimmed — lightly, since
  /// the menu itself is frosted glass.
  static const Color scrim = Color(0x66000000);

  /// A panel, sheet or dialog where there is no glass (a phone too weak to
  /// blur the film every frame): opaque, nothing shows through.
  static const Color surface = Color(0xFF1C1C1E);

  /// FROSTED GLASS (owner, 12 Nov: "a background like misted glass"): the
  /// film behind a menu blurred to its colours, under this tint. Dark
  /// enough that white text reads on a white scene; light enough that the
  /// film is still there. The library's ⋮ sheet is the same glass.
  static const Color glassTint = Color(0xB81C1C1E);
  static const Color glassEdge = Color(0x1FFFFFFF);
  static const double glassBlur = 30;

  /// Frosted glass, or [surface] on a phone that cannot afford it: Android
  /// Go (a low-RAM device) and 32-bit-only phones — the blur is redrawn on
  /// every frame of the film under it. See [probeGlass].
  static bool glass = true;

  /// Asks the phone once whether it can afford [glass].
  static Future<void> probeGlass() async {
    if (_probed || !Platform.isAndroid) return;
    _probed = true;
    try {
      final a = await DeviceInfoPlugin().androidInfo;
      glass = !a.isLowRamDevice && a.supported64BitAbis.isNotEmpty;
    } catch (_) {
      // Unknown: keep the glass.
    }
  }

  static bool _probed = false;

  /// A tile, card or chip on a menu: a light film over the glass.
  static const Color raised = Color(0x1FFFFFFF);

  static const Color hairline = Color(0x1AFFFFFF);
  static const Color textPrimary = Color(0xEBFFFFFF);
  static const Color textSecondary = Color(0x9EFFFFFF);
  static const Color textDisabled = Color(0x61FFFFFF);
  static const Color accent = AppColors.specPrimary;
  static const Color accentContainer = Color(0x293D8DF0);
  static const Color danger = Color(0xFFFF6B6B);

  static const double radius = 20;
  static const double tileRadius = 14;
  static const Duration motion = Duration(milliseconds: 220);

  static const TextStyle title = TextStyle(
    color: textPrimary,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  );
  static const TextStyle sectionLabel = TextStyle(
    color: textSecondary,
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
  );
  // Regular, not medium: Noto Sans Myanmar has no medium, so a Latin
  // title beside a Burmese one read bolder than it.
  static const TextStyle rowTitle = TextStyle(
    color: textPrimary,
    fontSize: 15,
  );
  static const TextStyle rowValue = TextStyle(
    color: textSecondary,
    fontSize: 13,
  );
  static const TextStyle body = TextStyle(
    color: textSecondary,
    fontSize: 14,
    height: 1.45,
  );
  static const TextStyle tileLabel = TextStyle(
    color: textPrimary,
    fontSize: 12,
    fontWeight: FontWeight.w500,
  );

  /// Side padding of a panel: a little less on the narrowest phones.
  static double pad(BuildContext context) =>
      MediaQuery.sizeOf(context).shortestSide < 360 ? 16 : 20;

  /// A dialog's surface: the panel's colour and corners.
  static ShapeBorder get dialogShape => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      );
}

/// A menu of the player: a side panel from the right with the phone held
/// sideways, a bottom sheet upright. Opaque, over a dimmed picture; a tap
/// on the picture closes it. Its body scrolls, and fades at an edge that
/// has more. It slides in.
class PlayerPanel extends StatelessWidget {
  const PlayerPanel({
    super.key,
    required this.children,
    required this.onDismiss,
    this.title,
    this.trailing,
  });

  final String? title;
  final Widget? trailing;
  final List<Widget> children;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final portrait = size.height >= size.width;
    final pad = PlayerUi.pad(context);
    final padding = MediaQuery.paddingOf(context);

    final surface = PlayerGlass(
      borderRadius: portrait
          ? const BorderRadius.vertical(top: Radius.circular(PlayerUi.radius))
          : const BorderRadius.horizontal(
              left: Radius.circular(PlayerUi.radius)),
      child: Padding(
        // Sideways the panel runs under the status bar and the navigation
        // buttons; its content keeps clear of both.
        padding: EdgeInsets.only(
          top: portrait ? 0 : padding.top,
          right: portrait ? 0 : padding.right,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (portrait) const PlayerDragHandle(),
            if (title != null)
              _PanelHeader(
                title: title!,
                trailing: trailing,
                top: portrait ? 2 : 14,
              ),
            Flexible(
              child: _FadingScroll(
                padding: EdgeInsets.fromLTRB(
                  pad,
                  title == null ? (portrait ? 4 : 18) : 2,
                  pad,
                  20 + (portrait ? padding.bottom : 0),
                ),
                children: children,
              ),
            ),
          ],
        ),
      ),
    );

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: PlayerUi.motion,
      curve: Curves.easeOutCubic,
      builder: (context, t, panel) => Stack(
        children: [
          Positioned.fill(
            // Read as Android reads a dialog's backdrop: "Dismiss".
            child: Semantics(
              label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
              child: GestureDetector(
                onTap: onDismiss,
                behavior: HitTestBehavior.opaque,
                child: Opacity(
                  opacity: t,
                  child: const ColoredBox(color: PlayerUi.scrim),
                ),
              ),
            ),
          ),
          if (portrait)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FractionalTranslation(
                translation: Offset(0, 1 - t),
                // No wider than 640, centred: on a tablet held upright the
                // tiles stood 200 dp apart across the screen (Google's
                // large-screen guideline: no full-width bottom sheets).
                child: Align(
                  alignment: Alignment.bottomCenter,
                  heightFactor: 1,
                  child: ConstrainedBox(
                    // 55 %, not 72: upright it rose over the whole picture
                    // (owner's screenshot, 12 Nov). What it covers shows
                    // through its glass.
                    constraints: BoxConstraints(
                        maxWidth: 640, maxHeight: size.height * 0.55),
                    child: panel,
                  ),
                ),
              ),
            )
          else
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              // Up to 400 dp of content; the navigation buttons' strip is
              // added to it, not taken from it.
              width: (size.width * 0.46).clamp(300.0, 400.0) + padding.right,
              child: FractionalTranslation(
                translation: Offset(1 - t, 0),
                child: panel,
              ),
            ),
        ],
      ),
      child: surface,
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.title, required this.top, this.trailing});

  final String title;
  final Widget? trailing;
  final double top;

  @override
  Widget build(BuildContext context) {
    final pad = PlayerUi.pad(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, top, pad - 8, 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        // The action at the right edge, as wide as it needs up to half the
        // row; the title takes the rest. (Both flexible, they split the
        // row in two and the action sat in the middle.)
        child: LayoutBuilder(
          builder: (context, c) => Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PlayerUi.title,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: c.maxWidth * 0.5),
                  child: trailing,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The handle at the top of a bottom sheet.
class PlayerDragHandle extends StatelessWidget {
  const PlayerDragHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          margin: const EdgeInsets.only(top: 10, bottom: 6),
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

/// A scrolling column that fades at an edge with more beyond it, so a
/// list that runs on reads as one that scrolls, not as one cut off (the
/// last row of ⋮ was half shown with nothing to say there was more).
class _FadingScroll extends StatefulWidget {
  const _FadingScroll({required this.padding, required this.children});

  final EdgeInsets padding;
  final List<Widget> children;

  @override
  State<_FadingScroll> createState() => _FadingScrollState();
}

class _FadingScrollState extends State<_FadingScroll> {
  final _ctl = ScrollController();
  bool _moreAbove = false;
  bool _moreBelow = false;

  void _measure() {
    if (!mounted || !_ctl.hasClients) return;
    final p = _ctl.position;
    if (!p.hasContentDimensions) return;
    final above = p.pixels > 1;
    final below = p.pixels < p.maxScrollExtent - 1;
    if (above != _moreAbove || below != _moreBelow) {
      setState(() {
        _moreAbove = above;
        _moreBelow = below;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_measure);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
        return false;
      },
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _moreAbove ? Colors.transparent : Colors.white,
            Colors.white,
            Colors.white,
            _moreBelow ? Colors.transparent : Colors.white,
          ],
          stops: const [0, 0.07, 0.88, 1],
        ).createShader(r),
        child: SingleChildScrollView(
          controller: _ctl,
          padding: widget.padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: widget.children,
          ),
        ),
      ),
    );
  }
}

/// The player's switch: accent track, white thumb, no outline; drawn only
/// (the row around it takes the tap, so TalkBack and a TV remote meet one
/// control, not two).
class PlayerSwitch extends StatelessWidget {
  const PlayerSwitch({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: ExcludeFocus(
        child: IgnorePointer(
          child: Transform.scale(
            scale: 0.8,
            alignment: Alignment.centerRight,
            child: Switch(
              value: value,
              onChanged: (_) {},
              thumbColor: WidgetStateProperty.all(Colors.white),
              trackColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected)
                      ? PlayerUi.accent
                      : const Color(0x33FFFFFF)),
              trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ),
    );
  }
}

/// A section of a panel: its label, then what it holds.
class PanelSection extends StatelessWidget {
  const PanelSection({
    super.key,
    required this.label,
    required this.child,
    this.first = false,
  });

  final String label;
  final Widget child;

  /// The first section sits right under the header.
  final bool first;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
            child: Semantics(
              header: true,
              child: Text(label, style: PlayerUi.sectionLabel),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// A row of a panel or sheet: icon, title, and what it is set to; a check
/// for the chosen one of a list, a chevron for one that opens more.
class PanelRow extends StatelessWidget {
  const PanelRow({
    super.key,
    required this.title,
    required this.onTap,
    this.icon,
    this.value,
    this.selected = false,
    this.choice = false,
    this.chevron = false,
  });

  final IconData? icon;
  final String title;
  final String? value;
  final bool selected;

  /// One of a list of choices (tracks, speeds, modes): the check of the
  /// chosen one sits where an icon would, so every title in the panel
  /// starts at the same edge.
  final bool choice;
  final bool chevron;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colour = selected ? PlayerUi.accent : PlayerUi.textPrimary;
    return Semantics(
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                if (choice)
                  SizedBox(
                    width: 22,
                    child: selected
                        ? const Icon(Icons.check_rounded,
                            size: 22, color: PlayerUi.accent)
                        : null,
                  )
                else if (icon != null)
                  Icon(icon,
                      size: 22,
                      color:
                          selected ? PlayerUi.accent : PlayerUi.textSecondary),
                if (choice || icon != null) const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    style: PlayerUi.rowTitle.copyWith(color: colour),
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      value!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: PlayerUi.rowValue,
                    ),
                  ),
                ],
                if (selected && !choice) ...[
                  const SizedBox(width: 12),
                  const Icon(Icons.check_rounded,
                      size: 22, color: PlayerUi.accent),
                ] else if (chevron) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right_rounded,
                      size: 22, color: PlayerUi.textDisabled),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row with a switch: the row takes the tap, the switch shows the state.
class PanelSwitchRow extends StatelessWidget {
  const PanelSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.icon,
  });

  final IconData? icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        toggled: value,
        child: InkWell(
          onTap: () => onChanged(!value),
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 22, color: PlayerUi.textSecondary),
                    const SizedBox(width: 16),
                  ],
                  Expanded(child: Text(title, style: PlayerUi.rowTitle)),
                  const SizedBox(width: 8),
                  PlayerSwitch(value: value),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tile of a panel's grid: a tonal circle with the icon, the label under
/// it. Quiet: a filled circle, not an outline ring around every action.
class PanelTile extends StatelessWidget {
  const PanelTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.dot = false,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool dot;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label.replaceAll('\n', ' '),
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PlayerUi.tileRadius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color:
                          selected ? PlayerUi.accentContainer : PlayerUi.raised,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon,
                        size: 22,
                        color:
                            selected ? PlayerUi.accent : PlayerUi.textPrimary),
                  ),
                  if (dot)
                    Positioned(
                      top: 1,
                      right: 1,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: AppColors.specNotifDot,
                          shape: BoxShape.circle,
                          border:
                              Border.all(color: PlayerUi.surface, width: 1.5),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // Three lines at most: two hold every label at the usual
              // sizes; the third keeps a Burmese one whole on a 320 dp
              // phone at the largest font ("ဖွင့်နေသော စ…").
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: PlayerUi.tileLabel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [children] in a grid [columns] across; each row as tall as its tallest
/// cell (a Burmese label is nearly twice as tall per line as a Latin one).
class PanelGrid extends StatelessWidget {
  const PanelGrid({
    super.key,
    required this.children,
    this.columns = 4,
    this.rowGap = 0,
  });

  final List<Widget> children;
  final int columns;
  final double rowGap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var r = 0; r < children.length; r += columns) ...[
          if (r > 0 && rowGap > 0) SizedBox(height: rowGap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = r; c < r + columns; c++)
                Expanded(
                  child: c < children.length
                      ? children[c]
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A raised card on a panel, holding rows or a checklist.
class PanelCard extends StatelessWidget {
  const PanelCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: PlayerUi.raised,
        borderRadius: BorderRadius.circular(PlayerUi.tileRadius),
      ),
      padding: padding ?? const EdgeInsets.all(6),
      child: child,
    );
  }
}

/// The header of a player bottom sheet: the drag handle, the title and an
/// optional action, a hairline. Shown with [showPlayerSheet], which gives
/// it the glass.
class PlayerSheetHeader extends StatelessWidget {
  const PlayerSheetHeader({
    super.key,
    required this.title,
    this.trailing,
    this.divider = true,
  });

  final String title;
  final Widget? trailing;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final upright = size.height >= size.width;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sideways a sheet is a side panel (showPlayerSheet): nothing to
        // drag.
        if (upright) const PlayerDragHandle(),
        _PanelHeader(title: title, trailing: trailing, top: upright ? 2 : 14),
        if (divider)
          const Divider(height: 1, thickness: 1, color: PlayerUi.hairline),
      ],
    );
  }
}

/// A sheet of the player. Upright, a bottom sheet of frosted glass, as tall
/// as its content up to 85 % of the screen, no wider than 640 dp. Sideways,
/// the same content in a glass panel from the right, the whole height — as
/// ⋮ and the subtitle panel are: a bottom sheet on a phone held sideways had
/// some 300 dp and cut the lists, the sliders and the buttons (12 Nov).
/// [barrierColor] transparent for a sheet that changes the picture, so the
/// change can be seen.
Future<T?> showPlayerSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  Color? barrierColor,
}) {
  final size = MediaQuery.sizeOf(context);
  if (size.width > size.height) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: barrierColor ?? PlayerUi.scrim,
      transitionDuration: PlayerUi.motion,
      pageBuilder: (_, __, ___) => _PlayerSideSheet(builder: builder),
      transitionBuilder: (_, animation, __, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }
  return showAppModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: barrierColor ?? PlayerUi.scrim,
    isScrollControlled: true,
    constraints: tallSheetConstraints(context),
    builder: (sheet) => PlayerGlass(
      borderRadius:
          const BorderRadius.vertical(top: Radius.circular(PlayerUi.radius)),
      child: builder(sheet),
    ),
  );
}

/// A player sheet held sideways: a glass panel from the right, as wide as
/// [PlayerPanel]'s, the whole height, the content at its top.
class _PlayerSideSheet extends StatelessWidget {
  const _PlayerSideSheet({required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: (size.width * 0.46).clamp(300.0, 400.0) + padding.right,
        height: size.height,
        child: PlayerGlass(
          borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(PlayerUi.radius)),
          child: Padding(
            padding: EdgeInsets.only(top: padding.top, right: padding.right),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [Flexible(child: Builder(builder: builder))],
            ),
          ),
        ),
      ),
    );
  }
}

/// Frosted glass: the film behind blurred, under [PlayerUi.glassTint], a
/// faint edge; [PlayerUi.surface] where the phone cannot afford the blur.
/// Ink (a row's ripple) draws on it.
class PlayerGlass extends StatelessWidget {
  const PlayerGlass({
    super.key,
    required this.borderRadius,
    required this.child,
  });

  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final glass = PlayerUi.glass;
    final body = DecoratedBox(
      decoration: BoxDecoration(
        color: glass ? PlayerUi.glassTint : PlayerUi.surface,
        borderRadius: borderRadius,
        border: Border.all(color: PlayerUi.glassEdge),
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
    return ClipRRect(
      borderRadius: borderRadius,
      child: glass
          ? BackdropFilter(
              filter: ImageFilter.blur(
                  sigmaX: PlayerUi.glassBlur, sigmaY: PlayerUi.glassBlur),
              child: body,
            )
          : body,
    );
  }
}

/// A small text action for a panel or sheet header ("Online subtitles",
/// "Reset"): accent text, no fill.
class PanelHeaderAction extends StatelessWidget {
  const PanelHeaderAction({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      foregroundColor: PlayerUi.accent,
      disabledForegroundColor: PlayerUi.textDisabled,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      minimumSize: const Size(44, 40),
      shape: const StadiumBorder(),
    );
    // The size on the Text, merged into the button's own style: a button
    // `textStyle` replaces the theme's, Roboto with it (the harness drew
    // this label in its fallback font).
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
    );
    if (icon == null) {
      return TextButton(onPressed: onPressed, style: style, child: text);
    }
    return TextButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 18),
      label: text,
    );
  }
}

/// What a player dialog holds: an optional icon and the title, the content
/// (it scrolls when the screen is short), the actions at the end.
class PlayerDialogBody extends StatelessWidget {
  const PlayerDialogBody({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.actions = const <Widget>[],
  });

  final String title;
  final IconData? icon;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 20, 18, actions.isEmpty ? 12 : 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 22, color: PlayerUi.accent),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(title, style: PlayerUi.title),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Flexible(child: SingleChildScrollView(child: child)),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 8,
              overflowSpacing: 4,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

/// A dialog drawn inside the player (not a route): the panels' surface and
/// corners in the middle of the dimmed picture; a tap beside it closes it
/// ([onDismiss] null: it stays until a choice is made).
class PlayerDialog extends StatelessWidget {
  const PlayerDialog({
    super.key,
    required this.title,
    required this.child,
    this.onDismiss,
    this.icon,
    this.actions = const <Widget>[],
    this.maxWidth = 400,
  });

  final String title;
  final IconData? icon;
  final Widget child;
  final List<Widget> actions;
  final VoidCallback? onDismiss;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final card = PlayerGlass(
      borderRadius: BorderRadius.circular(PlayerUi.radius),
      child: PlayerDialogBody(
        title: title,
        icon: icon,
        actions: actions,
        child: child,
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      builder: (context, t, dialog) => Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
              child: GestureDetector(
                onTap: onDismiss,
                behavior: HitTestBehavior.opaque,
                child: Opacity(
                  opacity: t,
                  child: const ColoredBox(color: PlayerUi.scrim),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16 + safe.left, 16 + safe.top,
                  16 + safe.right, 16 + safe.bottom),
              child: Center(
                child: Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.96 + 0.04 * t,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxWidth),
                      child: dialog,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      child: card,
    );
  }
}

/// A route dialog of the player (showDialog): the same surface, corners
/// and body as [PlayerDialog].
class PlayerRouteDialog extends StatelessWidget {
  const PlayerRouteDialog({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.actions = const <Widget>[],
    this.maxWidth = 400,
  });

  final String title;
  final IconData? icon;
  final Widget child;
  final List<Widget> actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: PlayerGlass(
          borderRadius: BorderRadius.circular(PlayerUi.radius),
          child: PlayerDialogBody(
            title: title,
            icon: icon,
            actions: actions,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The two kinds of dialog button: the main action filled in the accent,
/// the other plain.
class PlayerDialogButton extends StatelessWidget {
  const PlayerDialogButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final text = Text(label);
    if (!primary) {
      return TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: PlayerUi.textPrimary,
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: const StadiumBorder(),
        ),
        child: text,
      );
    }
    final style = FilledButton.styleFrom(
      backgroundColor: PlayerUi.accent,
      foregroundColor: Colors.white,
      minimumSize: const Size(64, 44),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      shape: const StadiumBorder(),
    );
    if (icon == null) {
      return FilledButton(onPressed: onPressed, style: style, child: text);
    }
    return FilledButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 18),
      label: text,
    );
  }
}

/// A check box and what it says, the whole row one target ("Use by
/// default", "Play to the end").
class PanelCheckRow extends StatelessWidget {
  const PanelCheckRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: ExcludeFocus(
                    child: Checkbox(
                      value: value,
                      onChanged: (v) => onChanged(v ?? false),
                      activeColor: PlayerUi.accent,
                      checkColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                      side: const BorderSide(
                          color: PlayerUi.textDisabled, width: 1.5),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                        color: PlayerUi.textPrimary, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One choice of a small set laid out as a grid (aspect ratios, speeds):
/// a raised pill, the chosen one in the accent.
class PanelChoiceChip extends StatelessWidget {
  const PanelChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? PlayerUi.accentContainer : PlayerUi.raised,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Center(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? PlayerUi.accent : PlayerUi.textPrimary,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
