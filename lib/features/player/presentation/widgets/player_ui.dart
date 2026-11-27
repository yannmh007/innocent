import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

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

  /// THE SHADE (the owner, 22 Nov 2026, after the reference lab: "as MX —
  /// it disturbs the film less while it plays than the misted glass"; and
  /// again: "MX's is more see-through, the film behind shows; ours is still
  /// heavier"). A panel or sheet neither blurs nor dims the picture as a
  /// whole. Behind it a shade of [shadeColour] lets [shadeSeeThrough] of the
  /// film show through — 40 %, as much as MX lets through its panels
  /// (measured over a white and a black frame, grey levels only: run
  /// 45019756405) — and before its edge the shade thins out over
  /// [shadeFade] dp, to [shadeMid] at [shadeMidAt] dp before the edge and
  /// to nothing at the far end, as MX's does. MX's see-through, never its
  /// colours. The words and icons on it carry [shadeInk], a soft dark
  /// halo, so they still read over a white, a busy or a colourful frame
  /// (test/player_legibility_test.dart: 4.5:1 for text, 3:1 for icons).
  static const double shadeSeeThrough = 0.40;

  /// The shade's colour: the scrim's black, not [surface]'s grey — at the
  /// same see-through a grey shade over a bright film left words 15 % less
  /// contrast (the legibility test, 22 Nov 2026).
  static const Color shadeColour = Color(0xFF000000);
  static const double shadeFade = 360;
  static const double shadeMidAt = 160;
  static const double shadeMid = 0.20;
  ///
  /// Two blurs, not three (27 Nov 2026, the smoothness session): a word's
  /// blurred shadow is drawn anew whenever the word is painted again or
  /// scrolls back into view (Impeller's TextShadowCache, see
  /// [ownLayer]), and on the realme the third — a 1 dp rim under the 3 dp
  /// one — was a third of that work for nothing: over the same five frames,
  /// my/en/th, the lowest word over a white film read 4.04:1 with these two
  /// against 3.77 with the three (median change +0.04; 4 words under 4.5
  /// against 5). 1.64.89's three are [shadeInk3], for the lab's `base`.
  static const List<Shadow> shadeInk = <Shadow>[
    // A dark rim round every stroke, then a quiet ground under a word.
    Shadow(color: Color(0xF2000000), blurRadius: 3),
    Shadow(color: Color(0x80000000), blurRadius: 10),
  ];

  /// 1.64.89's halo, three blurs (the smoothness lab's `base`).
  static const List<Shadow> shadeInk3 = <Shadow>[
    Shadow(color: Color(0xFF000000), blurRadius: 1),
    Shadow(color: Color(0xE6000000), blurRadius: 3),
    Shadow(color: Color(0x80000000), blurRadius: 10),
  ];

  /// The halo every word and icon on the shade and on the film carries:
  /// [shadeInk] — or, in a lab build, the look the smoothness lab asked for
  /// ([labLook]).
  static List<Shadow> get ink {
    if (!const bool.fromEnvironment('INNOCENT_LAB')) return shadeInk;
    return switch (_labInk) {
      'none' => const <Shadow>[],
      'rim' => rimInk,
      'blur3' => shadeInk3,
      _ => shadeInk,
    };
  }

  /// A candidate for [shadeInk] that the GPU draws without a blur: the
  /// dark rim as unblurred copies of the word round it (the smoothness lab,
  /// 27 Nov 2026).
  static const List<Shadow> rimInk = <Shadow>[
    Shadow(color: Color(0xB3000000), offset: Offset(0.9, 0)),
    Shadow(color: Color(0xB3000000), offset: Offset(-0.9, 0)),
    Shadow(color: Color(0xB3000000), offset: Offset(0, 0.9)),
    Shadow(color: Color(0xB3000000), offset: Offset(0, -0.9)),
  ];

  // LAB BUILDS ONLY (INNOCENT_LAB): the smoothness lab's switches
  // (lab/smooth_lab.dart), so one run on one phone times 1.64.89's drawing
  // beside each change. A store build never reads them: [ink], [labMask],
  // [labBoundary] and [labTick] fold to the build's own choices.
  static String? _labInk;
  static bool? _labMask;
  static bool? _labBoundary;
  static bool? _labTick;
  static bool? _labStretch;

  /// Whether a list on the shade stretches at its ends (Android 12's
  /// overscroll): while it does, Flutter draws the list into a layer of
  /// its own and scales it every frame (a saveLayer and a filtered
  /// transform). Measured, the Playing Queue's one-row list — nothing to
  /// scroll, every fling a stretch — had 12-17 % of its frames late on the
  /// realme and the OPPO with every fix in (Test Lab 45965335653).
  static bool get labStretch => const bool.fromEnvironment('INNOCENT_LAB')
      ? (_labStretch ?? false)
      : false;

  /// Whether a panel's list fades at its edges through a mask.
  static bool get labMask => const bool.fromEnvironment('INNOCENT_LAB')
      ? (_labMask ?? true)
      : true;

  /// Whether a panel's list draws into a layer of its own (yes since
  /// 27 Nov 2026; see [_FadingScrollState._boundary]).
  static bool get labBoundary => const bool.fromEnvironment('INNOCENT_LAB')
      ? (_labBoundary ?? true)
      : true;

  /// Whether the player screen rebuilds on every position tick, as before
  /// 27 Nov 2026 (PlayerState.look).
  static bool get labTick => const bool.fromEnvironment('INNOCENT_LAB')
      ? (_labTick ?? false)
      : false;

  /// [child] in a layer of its own (a RepaintBoundary): a list a sheet or
  /// panel scrolls, a bar of the controls. Recorded once, it is moved by a
  /// scroll and kept while what is beside it is painted again — and with
  /// it Impeller's cache of its words' blurred halos ([shadeInk]), which
  /// holds only while the same recorded words are drawn again (27 Nov 2026;
  /// see [_FadingScrollState._boundary]).
  static Widget ownLayer(Widget child) =>
      labBoundary ? RepaintBoundary(child: child) : child;

  /// Sets the lab's switches from a look (SmoothLab.looks); an empty look
  /// is the build's own.
  static void labLook(Map<String, Object> look) {
    if (!const bool.fromEnvironment('INNOCENT_LAB')) return;
    _labInk = look['ink'] as String?;
    _labMask = look['mask'] as bool?;
    _labBoundary = look['rb'] as bool?;
    _labTick = look['tick'] as bool?;
    _labStretch = look['stretch'] as bool?;
  }

  static void labReset() => labLook(const <String, Object>{});

  /// How far a panel or sheet reaches from its edge: as MX's (one square,
  /// the screen's short side — 384 dp, 46.6 % of the owner's 823 dp
  /// screen, upright and sideways alike; reference lab, 22 Nov 2026), never
  /// more than 46.6 % of the long side (a tablet). It was 55 % upright, 46 %
  /// sideways.
  ///
  /// On a tablet (the owner, 26 Nov 2026, from MX on a 10" tablet,
  /// reference lab 45828625924): MX's panels were 480 dp exactly, both ways
  /// (37.5 % of 1280): the short side, at most 480. With the 46.6 % of the
  /// phone measure still a cap (a split window: MX was not measured there).
  static double panelExtent(Size size) {
    final cap = size.longestSide * 0.466;
    final reach = size.shortestSide < cap ? size.shortestSide : cap;
    return reach < 480 ? reach : 480;
  }

  /// Sideways, a side panel's width: the reach, 480 at most (MX's on a
  /// tablet), 280 at least (a narrow window).
  static double sideWidth(Size size) => panelExtent(size).clamp(280.0, 480.0);

  /// How many player sheets are open (showPlayerSheet): the player lifts
  /// the subtitle over an upright one, as over an open panel.
  static final ValueNotifier<int> openSheets = ValueNotifier<int>(0);

  /// A tile, card or chip on a menu: a light film over the glass.
  static const Color raised = Color(0x1FFFFFFF);

  /// The disc under a tile's icon on the see-through shade: darker than
  /// the shade, so the icon keeps its ground over a bright film.
  static const Color tileDisc = Color(0x4D000000);

  /// The ring round a tile's disc, as MX rings its tiles (the owner, 26 Nov
  /// 2026); the box round the subtitle tracks; an idle radio or check box —
  /// an outline only, as MX's: over a white film the shade under it is
  /// grey 102 at most, and the ring (white 70 %) reads 3.7:1 there. A dark
  /// halo under it filled the idle box and ring black (run 45775539414).
  static const Color tileRing = Color(0x8CFFFFFF);
  static const Color boxEdge = Color(0x66FFFFFF);
  static const Color markIdle = Color(0xB3FFFFFF);

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
  // A row's value is told from its title by size, not by grey: on the
  // shade over a white film the 62 % grey read 2.35:1 (♪'s "0 ms", the
  // legibility test, 26 Nov 2026); white (with the shade's ink) passes.
  static const TextStyle rowValue = TextStyle(
    color: textPrimary,
    fontSize: 13,
  );
  static const TextStyle body = TextStyle(
    color: textSecondary,
    fontSize: 14,
    height: 1.45,
  );
  /// White, not [textPrimary]: the smallest word on the shade (26 Nov
  /// 2026: ⋮'s labels over a white film read 3.7-4.3:1 at 92 % white, 11
  /// below 4.5 sideways; at 100 %, 2).
  static const TextStyle tileLabel = TextStyle(
    color: Colors.white,
    fontSize: 12,
    fontWeight: FontWeight.w500,
  );

  /// [tileLabel] for the viewer's language: Burmese and Thai a weight up.
  /// Their strokes are thinner than Latin's at 12 sp: over a white film 11
  /// of their ⋮ words read 3.5-4.4:1 by the strict measure (the legibility
  /// test, 26 Nov 2026); a weight up, 5 (Thai none), the rest Burmese's
  /// finest marks (ဖြတ်ရန်, အကြိုက်: 3.8-4.5 at the 10th percentile of
  /// their pixels, over 5 at the strokes). 13 sp made it no better.
  static TextStyle tileLabelIn(BuildContext context) {
    final code = Localizations.localeOf(context).languageCode;
    return code == 'my' || code == 'th'
        ? tileLabel.copyWith(fontWeight: FontWeight.w600)
        : tileLabel;
  }

  /// Side padding of a panel: a little less on the narrowest phones.
  /// 24, as MX Player's panels keep their content about 26 dp in (the
  /// reference lab, 22 Nov 2026, on the owner's 384 dp phone; the owner
  /// chose MX's spacing): it was 20.
  /// On a tablet (short side 600 dp or more) 32, as MX's there (reference
  /// lab 45828625924: its rows 32 dp in, its panel the screen's width).
  static double pad(BuildContext context) {
    final short = MediaQuery.sizeOf(context).shortestSide;
    return short >= 600 ? 32 : (short < 360 ? 20 : 24);
  }

  /// A dialog's surface: the panel's colour and corners.
  static ShapeBorder get dialogShape => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      );
}

/// A menu of the player: a side panel from the right with the phone held
/// sideways, a bottom sheet upright, MX's reach both ways
/// ([PlayerUi.panelExtent]). On the [PlayerShade]: the picture is neither
/// dimmed nor blurred, only darkened behind the words (the owner, 22 Nov
/// 2026); a tap on the picture closes it. Its body scrolls, and fades at
/// an edge that has more. It slides in.
class PlayerPanel extends StatelessWidget {
  const PlayerPanel({
    super.key,
    required this.children,
    required this.onDismiss,
    this.title,
    this.trailing,
    this.onBack,
  });

  final String? title;
  final Widget? trailing;
  final List<Widget> children;
  final VoidCallback onDismiss;

  /// A page inside a panel (⋮'s "More", as MX's): its ← goes back a page,
  /// both ways round. Without it, upright the ← closes the panel.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final portrait = size.height >= size.width;
    final pad = PlayerUi.pad(context);
    final padding = MediaQuery.paddingOf(context);
    final extent = PlayerUi.panelExtent(size);

    final surface = PlayerShade(
      sideways: !portrait,
      child: Padding(
        // Sideways the panel runs under the status bar and the navigation
        // buttons; its content keeps clear of both.
        padding: EdgeInsets.only(
          top: portrait ? 0 : padding.top,
          right: portrait ? 0 : padding.right,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // As MX's (the owner, 26 Nov 2026: "as MX, all of it"): no
            // handle; upright a ← before the title closes the panel; the
            // title as near the top as MX's (its middle 28 dp down).
            if (title != null)
              _PanelHeader(
                title: title!,
                trailing: trailing,
                top: portrait ? 4 : 6,
                onBack: onBack ?? (portrait ? onDismiss : null),
              ),
            Flexible(
              child: _FadingScroll(
                padding: EdgeInsets.fromLTRB(
                  pad,
                  // No title (⋮): the first tiles 34 dp down, as MX's.
                  title == null ? 30 : 2,
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
            // Read as Android reads a dialog's backdrop: "Dismiss". Nothing
            // drawn: the picture is not dimmed (the shade, 22 Nov).
            child: Semantics(
              label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
              child: GestureDetector(
                onTap: onDismiss,
                behavior: HitTestBehavior.opaque,
                child: const SizedBox.expand(),
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
                // The screen's width, as MX's on a tablet held upright
                // (reference lab 45828625924; the owner took it over the
                // 640 dp cap of Google's large-screen guideline, 26 Nov).
                child: Align(
                  alignment: Alignment.bottomCenter,
                  heightFactor: 1,
                  child: SizedBox(
                    // MX's reach, the same for every panel (panelExtent):
                    // what it covers below its words is shade, not glass.
                    width: size.width,
                    height: extent,
                    child: Opacity(opacity: t, child: panel),
                  ),
                ),
              ),
            )
          else
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              // MX's reach; the navigation buttons' strip is added to it,
              // not taken from it.
              width: PlayerUi.sideWidth(size) + padding.right,
              child: FractionalTranslation(
                translation: Offset(1 - t, 0),
                child: Opacity(opacity: t, child: panel),
              ),
            ),
        ],
      ),
      child: surface,
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.title,
    required this.top,
    this.trailing,
    this.onBack,
  });

  final String title;
  final Widget? trailing;
  final double top;

  /// Upright, MX's ← before the title (26 Nov 2026): it closes.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final pad = PlayerUi.pad(context);
    return Padding(
      // With a ←, its 48 dp target starts 12 dp before the edge, so the
      // arrow itself sits on it and the title 60 dp in, as MX's.
      padding: EdgeInsets.fromLTRB(
          onBack != null ? pad - 12 : pad, top, pad - 8, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        // The action at the right edge, as wide as it needs up to half the
        // row; the title takes the rest. (Both flexible, they split the
        // row in two and the action sat in the middle.)
        child: LayoutBuilder(
          builder: (context, c) => Row(
            children: [
              if (onBack != null)
                IconButton(
                  onPressed: onBack,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(Icons.arrow_back_rounded,
                      size: 24, color: PlayerUi.textPrimary),
                ),
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
      child: _mask(
        SingleChildScrollView(
          controller: _ctl,
          padding: widget.padding,
          child: _boundary(Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: widget.children,
          )),
        ),
      ),
    );
  }

  /// THE LIST IN A LAYER OF ITS OWN (27 Nov 2026, the owner on 1.64.89:
  /// "⋮'s menu stutters when scrolled"). Without it each frame of a scroll
  /// painted the whole list again — and Impeller keeps a word's blurred
  /// halo ([PlayerUi.shadeInk]) only while the same recorded word is drawn
  /// again (its TextShadowCache is keyed by the TextFrame, made anew each
  /// time a paragraph is painted; a lone glyph, an icon, by its index), so
  /// every frame blurred every word's three shadows from nothing: ⋮'s 44
  /// paragraphs, 132 blurs a frame. In its own layer the list is recorded
  /// once and only moved; the halos come from the cache.
  Widget _boundary(Widget child) => PlayerUi.ownLayer(child);

  Widget _mask(Widget child) {
    if (!PlayerUi.labMask) return child;
    return ShaderMask(
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
      child: child,
    );
  }
}

/// A sheet's body that fades at an edge with more beyond it, as ⋮'s does:
/// for a sheet whose list always runs on (the gestures help).
class PanelScroll extends StatelessWidget {
  const PanelScroll({super.key, required this.padding, required this.children});

  final EdgeInsets padding;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      _FadingScroll(padding: padding, children: children);
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
    // A choice is marked as MX and Android mark one (the owner, 26 Nov
    // 2026: "as MX, all of it"): a ring, a dot in it when chosen. The
    // title stays white: a blue title over a bright film read 1.3:1 on the
    // see-through shade (the legibility test, 22 Nov).
    const colour = PlayerUi.textPrimary;
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
                    child: Center(child: PanelRadio(selected: selected)),
                  )
                else if (icon != null)
                  Icon(icon,
                      size: 22,
                      color: PlayerUi.textPrimary),
                if (choice || icon != null) const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    style: PlayerUi.rowTitle.copyWith(color: colour),
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: 12),
                  // At the row's end, up to 160 dp: as a Flexible beside
                  // the Expanded title the two split the row and the value
                  // sat in its middle (♪'s "Audio delay  0 ms" on the
                  // emulator, run 45796876490).
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
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
                  Icon(Icons.check_rounded,
                      size: 22,
                      color: PlayerUi.textPrimary,
                      shadows: PlayerUi.ink),
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

/// A choice's mark (the owner, 26 Nov 2026: "as MX, all of it"): a ring,
/// with a dot in it when chosen — the mark MX and Android give one choice
/// of a list. An outline: nothing fills it while it is not chosen.
class PanelRadio extends StatelessWidget {
  const PanelRadio({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
            color: selected ? PlayerUi.textPrimary : PlayerUi.markIdle,
            width: 2),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                    color: PlayerUi.accent, shape: BoxShape.circle),
              ),
            )
          : null,
    );
  }
}

/// A check box's mark: a rounded square, filled with a ✓ when on — as
/// MX draws its subtitle tracks (the owner, 26 Nov 2026).
class PanelCheckMark extends StatelessWidget {
  const PanelCheckMark({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: value ? PlayerUi.accent : null,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
            color: value ? PlayerUi.accent : PlayerUi.markIdle, width: 2),
      ),
      child: value
          ? const Icon(Icons.check_rounded,
              size: 16, color: Colors.white, shadows: <Shadow>[])
          : null,
    );
  }
}

/// One row of a [PanelCheckBox] group.
class PanelCheck {
  const PanelCheck({required this.title, required this.value, required this.onTap});

  final String title;
  final bool value;
  final VoidCallback onTap;
}

/// Check box rows in a box (the owner, 26 Nov 2026: "English, Burmese in a
/// rectangle, as MX"): the film's subtitle tracks, each a check box and its
/// name, inside a thin rectangle. The row takes the tap.
class PanelCheckBox extends StatelessWidget {
  const PanelCheckBox({super.key, required this.rows});

  final List<PanelCheck> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: PlayerUi.boxEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in rows)
            MergeSemantics(
              child: Semantics(
                checked: r.value,
                child: InkWell(
                  onTap: r.onTap,
                  borderRadius: BorderRadius.circular(6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          PanelCheckMark(value: r.value),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(r.title,
                                style: PlayerUi.rowTitle
                                    .copyWith(color: PlayerUi.textPrimary)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A row that opens below itself, as MX's subtitle "Settings ▾" does (the
/// owner, 26 Nov 2026): an icon, a title and a caret; its rows show while
/// it is open. Shut when the panel opens.
class PanelExpandRow extends StatefulWidget {
  const PanelExpandRow({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  State<PanelExpandRow> createState() => _PanelExpandRowState();
}

class _PanelExpandRowState extends State<PanelExpandRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Row(
                  children: [
                    Icon(widget.icon, size: 22, color: PlayerUi.textPrimary),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(widget.title,
                          style: PlayerUi.rowTitle
                              .copyWith(color: PlayerUi.textPrimary)),
                    ),
                    Icon(
                        _open
                            ? Icons.arrow_drop_up_rounded
                            : Icons.arrow_drop_down_rounded,
                        size: 26,
                        color: PlayerUi.textPrimary),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_open) ...widget.children,
      ],
    );
  }
}

/// A value set by steps: its name on the left, − value + on the right
/// (every stepper of a sheet in one column). A tap on the value puts it
/// back. The subtitle's timing, size and position; the audio's delay.
class PanelStepperRow extends StatelessWidget {
  const PanelStepperRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onMinus,
    required this.onPlus,
    required this.onReset,
    required this.minusTooltip,
    required this.plusTooltip,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback onReset;
  final String minusTooltip;
  final String plusTooltip;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          Icon(icon, color: PlayerUi.textSecondary, size: 22),
          const SizedBox(width: 16),
          Expanded(child: Text(label, style: PlayerUi.rowTitle)),
          _StepButton(
            icon: Icons.remove_rounded,
            onPressed: onMinus,
            tooltip: minusTooltip,
          ),
          SizedBox(
            width: 76,
            child: GestureDetector(
              // Tapping the number resets that one row. Cheap to reach, and
              // obvious once found — the value is the thing you are staring at.
              onTap: onReset,
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: PlayerUi.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          _StepButton(
            icon: Icons.add_rounded,
            onPressed: onPlus,
            tooltip: plusTooltip,
          ),
        ],
      ),
    );
  }
}

/// − or + of a stepper: a 40 dp tonal circle.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      style: IconButton.styleFrom(
        backgroundColor: PlayerUi.raised,
        foregroundColor: PlayerUi.textPrimary,
        fixedSize: const Size(40, 40),
        minimumSize: const Size(40, 40),
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
                    // White, as the row's words: grey read 2.5:1 over a
                    // white film (⋮'s Video Display, 26 Nov 2026).
                    Icon(icon, size: 22, color: PlayerUi.textPrimary),
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
          // MX's proportions (26 Nov 2026): a 44 dp disc (MX's 45), rows
          // about 88 dp apart (MX's 83; they were 110).
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      // A dark disc in a thin ring, as MX rings its tiles
                      // (the owner, 26 Nov 2026). Dark: on the see-through
                      // shade a light disc lifted the ground under a white
                      // icon over a bright film to 2.9:1 (22 Nov).
                      color: selected
                          ? PlayerUi.accentContainer
                          : PlayerUi.tileDisc,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: selected ? PlayerUi.accent : PlayerUi.tileRing,
                          width: 1.2),
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
              const SizedBox(height: 6),
              // Three lines at most: two hold every label at the usual
              // sizes; the third keeps a Burmese one whole on a 320 dp
              // phone at the largest font ("ဖွင့်နေသော စ…").
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: PlayerUi.tileLabelIn(context),
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
    // No line under the title, as MX's sheets have none (the owner, 26 Nov
    // 2026: "as MX, all of it").
    this.divider = false,
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
        // As a panel's (26 Nov 2026): no handle — upright the whole sheet
        // still drags down to close — and upright a ← that closes it.
        _PanelHeader(
          title: title,
          trailing: trailing,
          top: upright ? 4 : 6,
          onBack: upright ? () => Navigator.of(context).maybePop() : null,
        ),
        if (divider)
          const Divider(height: 1, thickness: 1, color: PlayerUi.hairline),
      ],
    );
  }
}

/// A sheet of the player. Upright, a bottom sheet on the [PlayerShade], as
/// tall as every panel ([PlayerUi.panelExtent], MX's reach: 22 Nov 2026),
/// the screen's width (MX's, 26 Nov 2026), dragged or flicked down to close. Sideways, the
/// same content in a panel from the right, the whole height — as ⋮ and the
/// subtitle panel are: a bottom sheet on a phone held sideways had some
/// 300 dp and cut the lists, the sliders and the buttons (12 Nov). The
/// picture is not dimmed behind it; [barrierColor] can still set a dim.
///
/// The form follows the WINDOW while the sheet is open (_PlayerSheetFrame):
/// it was chosen once, on opening, so a phone turned under an open sheet —
/// or a tablet's window resized, which Android 16 lets happen whatever the
/// player asks — left a bottom sheet some 300 dp tall sideways. One route
/// for both forms, the content's state kept through the turn.
Future<T?> showPlayerSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  Color? barrierColor,
}) {
  PlayerUi.openSheets.value++;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // The picture is not dimmed behind a sheet (the shade, 22 Nov 2026).
    barrierColor: barrierColor ?? Colors.transparent,
    transitionDuration: PlayerUi.motion,
    pageBuilder: (_, __, ___) => _PlayerSheetFrame(builder: builder),
    transitionBuilder: (context, animation, __, child) {
      final size = MediaQuery.sizeOf(context);
      final sideways = size.width > size.height;
      return SlideTransition(
        position: Tween<Offset>(
          begin: sideways ? const Offset(1, 0) : const Offset(0, 1),
          end: Offset.zero,
        ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      );
    },
  ).whenComplete(() => PlayerUi.openSheets.value--);
}

/// The frame of a player sheet, by the window: a bottom sheet upright, a
/// panel from the right, the whole height, sideways, both on the shade. Every
/// widget above the content is the same in both forms — only their values
/// change — so a turn keeps the content's element and its state (a cut's
/// marks, the subtitle panel's values).
class _PlayerSheetFrame extends StatefulWidget {
  const _PlayerSheetFrame({required this.builder});

  final WidgetBuilder builder;

  @override
  State<_PlayerSheetFrame> createState() => _PlayerSheetFrameState();
}

class _PlayerSheetFrameState extends State<_PlayerSheetFrame>
    with SingleTickerProviderStateMixin {
  /// How far the upright sheet has been dragged down.
  double _drag = 0;
  double _dragFrom = 0;
  final GlobalKey _sheet = GlobalKey();
  late final AnimationController _settle;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this, duration: PlayerUi.motion)
      ..addListener(() {
        setState(() => _drag =
            _dragFrom * (1 - Curves.easeOutCubic.transform(_settle.value)));
      });
  }

  void _dragged(DragUpdateDetails d) {
    _settle.stop();
    setState(() => _drag = (_drag + d.delta.dy).clamp(0.0, double.infinity));
  }

  /// Down past a third of its height, or flicked: closed; else back up.
  void _released(DragEndDetails d) {
    final height = _sheet.currentContext?.size?.height ?? 0;
    if ((d.primaryVelocity ?? 0) > 700 || _drag > height / 3) {
      Navigator.of(context).maybePop();
      return;
    }
    _dragFrom = _drag;
    _settle.forward(from: 0);
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final sideways = size.width > size.height;
    // MX's reach, as every panel's (PlayerUi.panelExtent): upright the
    // screen's short side tall, sideways as wide.
    final width = sideways
        ? PlayerUi.sideWidth(size) + padding.right
        : size.width;
    final extent = PlayerUi.panelExtent(size);
    return Align(
      alignment: sideways ? Alignment.centerRight : Alignment.bottomCenter,
      child: Transform.translate(
        offset: Offset(0, sideways ? 0 : _drag),
        child: GestureDetector(
          // Upright, a drag that starts off the sheet's lists moves the
          // sheet, as a bottom sheet's does; a list takes its own drags.
          onVerticalDragUpdate: sideways ? null : _dragged,
          onVerticalDragEnd: sideways ? null : _released,
          child: ConstrainedBox(
            key: _sheet,
            constraints: sideways
                ? BoxConstraints.tightFor(width: width, height: size.height)
                : BoxConstraints.tightFor(width: width, height: extent),
            child: PlayerShade(
              sideways: sideways,
              child: Padding(
                padding: sideways
                    ? EdgeInsets.only(top: padding.top, right: padding.right)
                    : EdgeInsets.only(bottom: padding.bottom),
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [Flexible(child: Builder(builder: widget.builder))],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The dark ground under the controls' top bar (from the top) or bottom
/// row (from the bottom): black at [edge] at the screen's edge, at least
/// [hold] across the bar, where its words and icons are, then thinning out
/// to nothing over [fade] dp beyond it (drawn outside the bar, taking no
/// taps), so it has no edge. Its words and icons carry [PlayerUi.shadeInk]
/// too (as a panel's).
///
/// Why (26 Nov 2026): the bars' gradients ran from 80 % black at the edge
/// to nothing across the bar itself, as light as MX's (the reference lab,
/// run 45781933354: within a few grey levels of each other), and over a
/// white, busy or colourful frame the title read 2.2:1, ♪ and CC 2.0, the
/// elapsed time 1.5 (test/player_legibility_test.dart; 4.5:1 text, 3:1
/// icons). A halo alone lifted them to 2.0-3.7: two or three pixels off a
/// thin stroke it is too faint. Held at 50 % black across the bar (MX's
/// level where its title sits, but held, not ramped), the lowest word
/// reads 5.8:1 over a white film (45 %: 5.1; 62 %: 7.8); over a dark one
/// nothing changes.
class BarShade extends StatelessWidget {
  const BarShade({super.key, required this.fromTop, required this.child});

  /// The top bar; else the bottom row.
  final bool fromTop;
  final Widget child;

  static const double edge = 0.80;
  static const double hold = 0.50;
  static const double fade = 64;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: fromTop ? 0 : -fade,
          bottom: fromTop ? -fade : 0,
          child: IgnorePointer(
            child: LayoutBuilder(builder: (context, c) {
              final total = c.maxHeight;
              final bar = (total - fade).clamp(0.0, total);
              final at = total > 0 ? bar / total : 1.0;
              final half = total > 0 ? (bar + fade * 0.45) / total : 1.0;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
                    end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: edge),
                      Colors.black.withValues(alpha: hold),
                      Colors.black.withValues(alpha: hold * 0.4),
                      Colors.black.withValues(alpha: 0),
                    ],
                    stops: [0, at, half, 1],
                  ),
                ),
              );
            }),
          ),
        ),
        FilmInk(child: child),
      ],
    );
  }
}

/// Words and icons drawn straight on the film carry [PlayerUi.shadeInk], as
/// a panel's do: the controls' bars (inside [BarShade]) and the shortcut
/// row, whose labels hang on the film under its discs when it is open.
class FilmInk extends StatelessWidget {
  const FilmInk({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle.merge(
      style: TextStyle(shadows: PlayerUi.ink),
      child: IconTheme.merge(
        data: IconThemeData(shadows: PlayerUi.ink),
        child: child,
      ),
    );
  }
}

/// The shade behind a panel or sheet ([PlayerUi.shadeSeeThrough]): within
/// the menu, [PlayerUi.shadeColour] letting 40 % of the film through; before
/// its edge (above it upright, left of it sideways) thinning out over
/// [PlayerUi.shadeFade] dp to nothing. No blur, no edge, no corners: the film
/// stays sharp. The fade before the edge is drawn outside the menu's box and
/// takes no taps (a tap there closes the menu, as anywhere off it). Words
/// and icons on it carry [PlayerUi.shadeInk]. Ink draws on it.
class PlayerShade extends StatelessWidget {
  const PlayerShade({super.key, required this.sideways, required this.child});

  /// The menu rises from the right; else from the bottom.
  final bool sideways;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      const fade = PlayerUi.shadeFade;
      final reach = (sideways ? c.maxWidth : c.maxHeight);
      final length = (reach.isFinite ? reach : 400.0) + fade;
      const full = 1 - PlayerUi.shadeSeeThrough;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: sideways ? -fade : 0,
            top: sideways ? 0 : -fade,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: sideways ? Alignment.centerLeft : Alignment.topCenter,
                    end: sideways ? Alignment.centerRight : Alignment.bottomCenter,
                    colors: [
                      PlayerUi.shadeColour.withValues(alpha: 0),
                      PlayerUi.shadeColour.withValues(alpha: PlayerUi.shadeMid),
                      PlayerUi.shadeColour.withValues(alpha: full),
                      PlayerUi.shadeColour.withValues(alpha: full),
                    ],
                    stops: [
                      0,
                      (fade - PlayerUi.shadeMidAt) / length,
                      fade / length,
                      1,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              // The halo on every word and icon of the menu: the film shows
              // through the shade, so a word may sit on white.
              child: DefaultTextStyle.merge(
                style: TextStyle(shadows: PlayerUi.ink),
                child: IconTheme.merge(
                  data: IconThemeData(shadows: PlayerUi.ink),
                  // Its lists stop at their ends, as MX's do, instead of
                  // stretching (PlayerUi.labStretch says what that cost).
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context)
                        .copyWith(overscroll: PlayerUi.labStretch),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// Frosted glass: the film behind blurred, under [PlayerUi.glassTint], a
/// faint edge; [PlayerUi.surface] where the phone cannot afford the blur.
/// Ink (a row's ripple) draws on it. A dialog's and a card's surface; a
/// panel or sheet has the [PlayerShade] since 22 Nov 2026.
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
          // Its own layer, as a panel's list (_FadingScroll._boundary):
          // a scroll moves the words, it does not paint them again.
          Flexible(
              child: SingleChildScrollView(child: PlayerUi.ownLayer(child))),
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
