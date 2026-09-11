import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/equalizer/equalizer_service.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'equalizer_screen.dart' show equalizerServiceProvider;

import '../../../core/localization/app_strings.dart';

// ── MX Player-sampled palette (v0.49.2 visual parity pass). Values were
// measured from reference screenshots at density 3.0, so this sheet
// matches MX pixel-for-pixel without disturbing the app-wide tokens. ──
const Color _mxActive = Color(0xFF66BAFF);      // thumb, active track, dial dot
const Color _mxTrackMuted = Color(0xFF335777);  // inactive (upper) track
const Color _mxCardBorder = Color(0xFF35455F);  // band panel + card borders
const Color _mxSelTop = Color(0xFF20356A);      // selected card gradient top
const Color _mxSelBottom = Color(0xFF233D78);   // selected card gradient bottom
const Color _mxSelBorder = Color(0xFF4388CB);   // selected card border
const Color _mxDialCenter = Color(0xFF3871C2);  // dial radial gradient centre
const Color _mxDialEdge = Color(0xFF184588);    // dial radial gradient edge
/// Present the MX Player–style Audio Effect / Equalizer panel. In portrait
/// it slides up as a bottom panel over the (still-visible) video; in
/// landscape it slides in from the right as a side drawer, leaving the
/// video visible on the left — matching MX Player. [initialTab] 0 = Audio
/// Effect, 1 = Equalizer.
Future<void> showAudioEffectSheet(BuildContext context, {int initialTab = 1}) {
  final size = MediaQuery.of(context).size;
  final landscape = size.width > size.height;
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Audio Effect',
    barrierColor: Colors.black.withOpacity(0.18),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (ctx, _, __) {
      final land = MediaQuery.of(ctx).size.width >
          MediaQuery.of(ctx).size.height;
      return Align(
        alignment:
            land ? Alignment.centerRight : Alignment.bottomCenter,
        child: AudioEffectSheet(initialTab: initialTab),
      );
    },
    transitionBuilder: (_, anim, __, child) {
      final curved =
          CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      final begin = landscape ? const Offset(1, 0) : const Offset(0, 1);
      return SlideTransition(
        position:
            Tween<Offset>(begin: begin, end: Offset.zero).animate(curved),
        child: child,
      );
    },
  );
}

class AudioEffectSheet extends ConsumerStatefulWidget {
  final int initialTab;

  const AudioEffectSheet({super.key, this.initialTab = 1});

  @override
  ConsumerState<AudioEffectSheet> createState() => _AudioEffectSheetState();
}

class _AudioEffectSheetState extends ConsumerState<AudioEffectSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  bool _supported = false;
  bool _loading = true;
  bool _enabled = false;

  int _bandCount = 5;
  int _minLevel = -1500;
  int _maxLevel = 1500;
  List<int> _bandLevels = [0, 0, 0, 0, 0];
  List<int> _bandFreqs = [60000, 230000, 910000, 3600000, 14000000];
  List<String> _presets = const [];
  int? _activePreset; // null = "Custom"

  bool _bassBoostEnabled = false;
  int _bassBoostStrength = 0; // 0..1000
  bool _virtualizerEnabled = false;
  int _virtualizerStrength = 0; // 0..1000
  int _reverbPreset = 0; // 0..6

  // Selected Audio Effect preset card (MX Player's Audio Effect tab).
  String _activeEffect = 'Original';

  // Scrolls the active preset chip into view in the horizontal strip.
  final GlobalKey _activeChipKey = GlobalKey();
  // Last value within an active dial drag (guards the 270° bottom gap).
  double _dialDrag = 0;

  EqualizerService get _eq => ref.read(equalizerServiceProvider);

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this, initialIndex: widget.initialTab)
      ..addListener(() => setState(() {})); // repaint the underline on swipe
    _init();
  }

  Future<void> _init() async {
    final ok = await _eq.initialize();
    if (!ok || !mounted) {
      setState(() {
        _supported = false;
        _loading = false;
      });
      return;
    }
    final range = await _eq.getBandLevelRange();
    final bands = await _eq.getNumberOfBands();
    final freqs = <int>[];
    for (int i = 0; i < bands; i++) {
      freqs.add(await _eq.getCenterFreq(i));
    }
    final presets = await _eq.getPresets();
    await _eq.loadState();
    if (!mounted) return;
    final masterEnabled = ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.audioEffectsEnabled);
    if (masterEnabled) {
      await _eq.setEnabled(true);
    }
    // Restore the previously-applied state so the panel reopens showing
    // exactly what's active (and re-apply to the engine, which starts flat
    // after an app restart).
    final cached = _eq.bandLevels;
    final levels = <int>[
      for (int i = 0; i < bands; i++)
        (i < cached.length ? cached[i] : 0).clamp(range[0], range[1])
    ];
    final bass = _eq.bassStrength;
    final virt = _eq.virtualizerStrength;
    final reverb = _eq.reverbPreset;
    for (int i = 0; i < levels.length; i++) {
      await _eq.setBandLevel(i, levels[i]);
    }
    await _eq.setBassBoostEnabled(bass > 0);
    await _eq.setBassBoostStrength(bass);
    await _eq.setVirtualizerEnabled(virt > 0);
    await _eq.setVirtualizerStrength(virt);
    await _eq.setReverbPreset(reverb);
    if (!mounted) return;
    setState(() {
      _supported = true;
      _loading = false;
      _minLevel = range[0];
      _maxLevel = range[1];
      _bandCount = bands;
      _bandFreqs = freqs;
      _bandLevels = levels;
      _presets = presets;
      _enabled = masterEnabled;
      _bassBoostStrength = bass;
      _bassBoostEnabled = bass > 0;
      _virtualizerStrength = virt;
      _virtualizerEnabled = virt > 0;
      _reverbPreset = reverb;
      _activePreset = _eq.activePresetIndex;
      _activeEffect = _eq.activeEffect;
    });
    _scrollActiveChipIntoView();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  String _fmtDb(int millibel) => '${(millibel / 100).round()} dB';

  // MX prints the full centre frequency with a space: "60 Hz" … "14000 Hz".
  String _fmtFreq(int milliHz) => '${(milliHz / 1000).round()} Hz';

  Future<void> _toggleEnabled(bool v) async {
    HapticFeedback.selectionClick();
    await _eq.setEnabled(v);
    await ref
        .read(playerSettingsProvider.notifier)
        .setValue(PlayerSetting.audioEffectsEnabled, v);
    if (!mounted) return;
    setState(() => _enabled = v);
  }

  Future<void> _applyPreset(int? index) async {
    if (index == null) {
      // "Custom" — leave levels as-is, just clear the active flag.
      setState(() => _activePreset = null);
      _eq.cacheSelection(presetIndex: null, effect: _activeEffect);
      _scrollActiveChipIntoView();
      return;
    }
    final levels = await _eq.usePreset(index);
    if (levels != null && mounted) {
      setState(() {
        _bandLevels = levels;
        _activePreset = index;
        _activeEffect = ''; // native preset → no effect card is active
      });
      _eq.cacheSelection(presetIndex: index, effect: '');
      _scrollActiveChipIntoView();
    }
  }

  Future<void> _onBandChange(int band, double value) async {
    final level = value.round();
    await _eq.setBandLevel(band, level);
    if (!mounted) return;
    setState(() {
      _bandLevels[band] = level;
      _activePreset = null; // manual edit → Custom
      _activeEffect = ''; // …and no effect card is active anymore
    });
    _eq.cacheSelection(presetIndex: null, effect: '');
  }

  Future<void> _setBassBoost(int strength) async {
    final s = strength.clamp(0, 1000);
    setState(() {
      _bassBoostStrength = s;
      _bassBoostEnabled = s > 0;
    });
    await _eq.setBassBoostEnabled(s > 0);
    await _eq.setBassBoostStrength(s);
  }

  Future<void> _setVirtualizer(int strength) async {
    final s = strength.clamp(0, 1000);
    setState(() {
      _virtualizerStrength = s;
      _virtualizerEnabled = s > 0;
    });
    await _eq.setVirtualizerEnabled(s > 0);
    await _eq.setVirtualizerStrength(s);
  }

  /// Apply an Audio Effect preset card: pushes its 5-band curve plus its
  /// bass-boost / virtualizer amounts to the engine, and mirrors them into
  /// the Equalizer tab's sliders + dials (the two tabs share state, so the
  /// chosen effect is visible there too). Every preset except "Original"
  /// turns the EQ on so it's audible; "Original" resets to flat.
  Future<void> _applyEffect(String name) async {
    final preset = _effectPresets[name];
    if (preset == null) return;
    final levels = <int>[
      for (int i = 0; i < _bandCount; i++)
        (i < preset.bands.length ? preset.bands[i] : 0)
            .clamp(_minLevel, _maxLevel)
    ];
    setState(() {
      _activeEffect = name;
      _bandLevels = levels;
      _bassBoostStrength = preset.bass;
      _bassBoostEnabled = preset.bass > 0;
      _virtualizerStrength = preset.virt;
      _virtualizerEnabled = preset.virt > 0;
      _activePreset = null; // not a native EQ preset → Custom
    });
    if (name != 'Original' && !_enabled) {
      await _toggleEnabled(true);
    }
    for (int i = 0; i < levels.length; i++) {
      await _eq.setBandLevel(i, levels[i]);
    }
    await _eq.setBassBoostEnabled(preset.bass > 0);
    await _eq.setBassBoostStrength(preset.bass);
    await _eq.setVirtualizerEnabled(preset.virt > 0);
    await _eq.setVirtualizerStrength(preset.virt);
    _eq.cacheSelection(presetIndex: null, effect: name);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isLandscape = media.size.width > media.size.height;

    final content = Column(
      children: [
        _tabBar(),
        Expanded(
          child: !_supported && !_loading
              ? _unsupported()
              : _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : TabBarView(
                      controller: _tab,
                      children: [
                        _audioEffectTab(),
                        _equalizerTab(),
                      ],
                    ),
        ),
      ],
    );

    if (isLandscape) {
      // MX Player landscape: a right-side drawer over the dimmed video
      // (the video stays visible on the left), full height. Soft fade on
      // the left edge, rounded left corners.
      final panelW = (media.size.width * 0.48).clamp(340.0, 420.0);
      return Container(
        width: panelW,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.black.withOpacity(0.72),
              Colors.black.withOpacity(0.93),
              Colors.black.withOpacity(0.97),
            ],
            stops: const [0.0, 0.16, 1.0],
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            bottomLeft: Radius.circular(20),
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(left: false, child: content),
        ),
      );
    }

    // Portrait: a bottom panel over the lower ~64%, video crisp above it.
    // Transparent at the top so the video shows through the tab bar,
    // fading to near-opaque dark for the controls — the MX look.
    final sheetH = (media.size.height * 0.60).clamp(400.0, 580.0);
    return Container(
      height: sheetH,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withOpacity(0.0),
            Colors.black.withOpacity(0.60),
            Colors.black.withOpacity(0.95),
            Colors.black.withOpacity(0.97),
          ],
          stops: const [0.0, 0.05, 0.17, 1.0],
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(top: false, child: content),
      ),
    );
  }

  Widget _unsupported() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(AppStrings.of(context).audioFxNotAvailable,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.white55, fontSize: 14),
          ),
        ),
      );

  // ── Tab bar: Audio Effect | Equalizer, blue underline under the active ──
  Widget _tabBar() {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          _tabItem('Audio Effect', 0),
          _tabItem('Equalizer', 1),
        ],
      ),
    );
  }

  Widget _tabItem(String label, int index) {
    final active = _tab.index == index;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _tab.animateTo(index)),
        child: Stack(
          children: [
            Center(
              child: Text(
                label,
                style: TextStyle(
                  color: active ? Colors.white : AppColors.white40,
                  fontSize: 16.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                height: 2,
                color: active ? AppColors.accentBlue : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Equalizer tab: On/Off → presets → bands (panel) → Reverb → dials ──
  Widget _equalizerTab() {
    final land =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    return SingleChildScrollView(
      // MX: 24dp sides in portrait; in landscape the panel hugs the right
      // edge, so the outer margin shrinks to ~14dp there.
      padding: land
          ? const EdgeInsets.fromLTRB(18, 8, 14, 16)
          : const EdgeInsets.fromLTRB(24, 12, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _eqHeader(),
          const SizedBox(height: 12),
          // Controls below the master toggle dim + lock when the EQ is off,
          // so it's clear they're inactive (the toggle itself stays live).
          Opacity(
            opacity: _enabled ? 1.0 : 0.4,
            child: IgnorePointer(
              ignoring: !_enabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _presetChips(),
                  const SizedBox(height: 12),
                  _bandPanel(),
                  const SizedBox(height: 10),
                  _reverbRow(),
                  const SizedBox(height: 12),
                  _dialsRow(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The 5 band sliders inside a rounded, faintly-bordered panel — the
  /// framed look from MX Player that keeps the bands visually grouped
  /// instead of floating loose over the video.
  Widget _bandPanel() {
    // MX: the framed band card measures ~164dp tall in BOTH orientations,
    // with a clearly visible steel-blue 1.2dp border (#35455F).
    return Container(
      height: 164,
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.035),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _mxCardBorder, width: 1.2),
      ),
      child: _bandRow(),
    );
  }

  Widget _eqHeader() {
    return Row(
      children: [
        // MX header glyph = three vertical slider stems.
        const RotatedBox(
          quarterTurns: 1,
          child: Icon(Icons.tune, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 10),
        Text(AppStrings.of(context).equalizerTitle,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 16.5,
                fontWeight: FontWeight.w600)),
        const Spacer(),
        Text(_enabled ? 'On' : 'Off',
            style: const TextStyle(color: AppColors.white55, fontSize: 14)),
        const SizedBox(width: 6),
        Transform.scale(
          scale: 0.9,
          child: Switch(
            value: _enabled,
            onChanged: _toggleEnabled,
            activeColor: Colors.white,
            activeTrackColor: AppColors.accentBlue,
          ),
        ),
      ],
    );
  }

  Widget _presetChips() {
    // "Custom" + the device's native presets, as a horizontal text strip.
    final items = <_Preset>[
      const _Preset('Custom', null),
      ..._presets.asMap().entries.map((e) => _Preset(e.value, e.key)),
    ];
    return SizedBox(
      height: 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 26),
        itemBuilder: (_, i) {
          final p = items[i];
          final active = _activePreset == p.index;
          return GestureDetector(
            key: active ? _activeChipKey : null,
            onTap: () {
              HapticFeedback.selectionClick();
              _applyPreset(p.index);
            },
            behavior: HitTestBehavior.opaque,
            child: Center(
              child: Text(
                p.label,
                style: TextStyle(
                  color: active ? _mxActive : AppColors.white50,
                  fontSize: 15,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// After the active chip changes, scroll the horizontal strip so it's
  /// centred and visible (MX keeps the selected preset on screen).
  void _scrollActiveChipIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _activeChipKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _bandRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: List.generate(_bandCount, (i) {
        return Expanded(child: _bandSlider(i));
      }),
    );
  }

  Widget _bandSlider(int i) {
    final lvl = _bandLevels[i]
        .toDouble()
        .clamp(_minLevel.toDouble(), _maxLevel.toDouble());
    return Column(
      children: [
        Text(_fmtDb(_bandLevels[i]),
            style: const TextStyle(color: AppColors.white60, fontSize: 12)),
        const SizedBox(height: 6),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              // MX slider (measured): 3dp track, ø16 thumb, bright #66BAFF
              // below the thumb, muted #335777 above it.
              trackHeight: 3,
              activeTrackColor: _mxActive,
              inactiveTrackColor: _mxTrackMuted,
              thumbColor: _mxActive,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 16),
              overlayColor: _mxActive.withOpacity(0.15),
              trackShape: const RectangularSliderTrackShape(),
            ),
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                min: _minLevel.toDouble(),
                max: _maxLevel.toDouble(),
                value: lvl,
                onChanged: (v) => _onBandChange(i, v),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // "14000 Hz" must fit a 1/5 column — scale down instead of wrapping.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(_fmtFreq(_bandFreqs[i]),
              style: const TextStyle(color: AppColors.white60, fontSize: 11.5)),
        ),
      ],
    );
  }

  Widget _reverbRow() {
    final presets = _eq.getReverbPresets();
    final name = presets[_reverbPreset];
    return PopupMenuButton<int>(
      initialValue: _reverbPreset,
      color: AppColors.darkSurface,
      position: PopupMenuPosition.under,
      onSelected: (i) async {
        HapticFeedback.selectionClick();
        setState(() => _reverbPreset = i);
        await _eq.setReverbPreset(i);
      },
      itemBuilder: (_) => [
        for (int i = 0; i < presets.length; i++)
          PopupMenuItem<int>(
            value: i,
            height: 44,
            child: Row(
              children: [
                Icon(
                  i == _reverbPreset
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  size: 18,
                  color: i == _reverbPreset
                      ? AppColors.accentBlue
                      : AppColors.white40,
                ),
                const SizedBox(width: 10),
                Text(presets[i],
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.waves, color: AppColors.white60, size: 18),
            const SizedBox(width: 12),
            Text(AppStrings.of(context).reverb,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(name,
                style: const TextStyle(
                    color: AppColors.white50, fontSize: 14)),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down,
                color: AppColors.white50, size: 20),
          ],
        ),
      ),
    );
  }

  // ── Audio Effect tab: a 2×3 grid of preset cards (MX Player style). ──
  Widget _audioEffectTab() {
    final names = _effectPresets.keys.toList();
    final media = MediaQuery.of(context);
    final landscape = media.size.width > media.size.height;
    // Fixed card height keeps the MX "wider-than-tall" proportion instead
    // of stretching to fill the sheet; the grid is centred in the space.
    // Measured on MX: cards are 92×57dp in portrait (h≈66dp landscape),
    // 16dp gaps, 24dp side margins — and the grid is pinned to the TOP in
    // portrait (right under the tabs), only centred in landscape.
    final rowH = landscape ? 66.0 : 58.0;
    return Align(
      alignment: landscape ? Alignment.center : Alignment.topCenter,
      child: SingleChildScrollView(
        padding: landscape
            ? const EdgeInsets.fromLTRB(18, 14, 14, 18)
            : const EdgeInsets.fromLTRB(24, 16, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: rowH,
              child: Row(
                children: [
                  _effectCard(names[0]),
                  const SizedBox(width: 16),
                  _effectCard(names[1]),
                  const SizedBox(width: 16),
                  _effectCard(names[2]),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: rowH,
              child: Row(
                children: [
                  _effectCard(names[3]),
                  const SizedBox(width: 16),
                  _effectCard(names[4]),
                  const SizedBox(width: 16),
                  _effectCard(names[5]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _effectCard(String name) {
    final preset = _effectPresets[name]!;
    final active = _activeEffect == name;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          _applyEffect(name);
        },
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            // MX selected card: a deep-blue vertical gradient with a
            // brighter #4388CB frame; unselected: near-black with the same
            // steel border as the band panel.
            gradient: active
                ? const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_mxSelTop, _mxSelBottom],
                  )
                : null,
            color: active ? null : Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? _mxSelBorder : _mxCardBorder,
              width: active ? 1.6 : 1.2,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(preset.icon,
                  color: active ? Colors.white : AppColors.white70, size: 22),
              const SizedBox(height: 6),
              Text(
                name,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: active ? Colors.white : AppColors.white70,
                  fontSize: 13.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Bass Boost + Virtualizer rotary dials (shown on the Equalizer tab). ──
  Widget _dialsRow() {
    final media = MediaQuery.of(context);
    final landscape = media.size.width > media.size.height;
    // MX dial measures ~101dp in landscape; portrait sits a touch larger.
    final dialSize = landscape ? 100.0 : 108.0;
    return SizedBox(
      height: dialSize + 4,
      child: Row(
        children: [
          _dial(
            label: 'Bass Boost',
            strength: _bassBoostStrength,
            size: dialSize,
            onChanged: _setBassBoost,
          ),
          _dial(
            label: 'Virtualizer',
            strength: _virtualizerStrength,
            size: dialSize,
            onChanged: _setVirtualizer,
          ),
        ],
      ),
    );
  }

  /// Map a touch point inside a dial to a 0..1000 strength by its angle on
  /// the 270° arc (matching [_DialPainter]): lower-left = 0, top = 50%,
  /// lower-right = max. Direct manipulation, like turning a real knob.
  int _dialStrengthFromOffset(Offset local, double size, {bool guard = true}) {
    final c = size / 2;
    final dx = local.dx - c;
    final dy = local.dy - c;
    const sweep = _DialPainter._sweep;
    var delta = (math.atan2(dy, dx) - _DialPainter._start) % (2 * math.pi);
    if (delta < 0) delta += 2 * math.pi;
    double t = delta <= sweep
        ? delta / sweep
        // In the bottom gap → snap to whichever end is nearer.
        : ((delta - sweep) < (2 * math.pi - delta) ? 1.0 : 0.0);
    t = t.clamp(0.0, 1.0);
    // During a continuous drag, don't let the value teleport across the
    // bottom gap (100% ↔ 0%); hold the end we're nearest instead.
    if (guard && (t - _dialDrag).abs() > 0.5) {
      t = _dialDrag >= 0.5 ? 1.0 : 0.0;
    }
    _dialDrag = t;
    return (t * 1000).round();
  }

  Widget _dial({
    required String label,
    required int strength,
    required double size,
    required ValueChanged<int> onChanged,
  }) {
    final t = (strength / 1000).clamp(0.0, 1.0);
    final pct = (t * 100).round();
    return Expanded(
      child: Center(
        child: GestureDetector(
          // Turn the knob directly: the touch's angle on the arc sets the
          // value (lower-left = 0 … top = 50% … lower-right = max).
          onPanStart: (d) {
            HapticFeedback.selectionClick();
            onChanged(
                _dialStrengthFromOffset(d.localPosition, size, guard: false));
          },
          onPanUpdate: (d) =>
              onChanged(_dialStrengthFromOffset(d.localPosition, size)),
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: Size(size, size),
                  painter: _DialPainter(
                    t: t,
                    fill: _mxDialCenter,
                    track: _mxTrackMuted,
                    accent: _mxActive,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$pct%',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(label,
                        style: const TextStyle(
                            color: AppColors.white60, fontSize: 11.5)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Preset {
  final String label;
  final int? index;
  const _Preset(this.label, this.index);
}

/// One Audio Effect preset card: an icon, a 5-band curve (in millibel,
/// for the 60 / 230 / 910 / 3600 / 14000 Hz bands), and bass-boost /
/// virtualizer amounts (0..1000). Values are clamped to the device's
/// real band range when applied.
class _EffectPreset {
  final IconData icon;
  final List<int> bands;
  final int bass;
  final int virt;
  const _EffectPreset(this.icon, this.bands, {this.bass = 0, this.virt = 0});
}

/// MX Player's Audio Effect presets, in display order (2×3 grid).
const Map<String, _EffectPreset> _effectPresets = {
  // Icons picked to sit as close as Material allows to MX's custom glyphs
  // (waveform / mic-with-arcs / rippling speaker / loud speaker /
  //  camcorder / note).
  'Original': _EffectPreset(Icons.graphic_eq, [0, 0, 0, 0, 0]),
  'Clarity': _EffectPreset(Icons.settings_voice_outlined,
      [-100, -200, 200, 450, 350]),
  'Bass Boost': _EffectPreset(Icons.speaker_outlined, [600, 400, 0, 0, 0],
      bass: 600),
  'Treble Boost': _EffectPreset(Icons.volume_up_outlined, [0, 0, 0, 450, 650]),
  'Movie': _EffectPreset(Icons.videocam_outlined, [400, 200, 0, 200, 450],
      bass: 250, virt: 600),
  'Music': _EffectPreset(Icons.music_note_outlined, [450, 150, -100, 200, 450],
      bass: 150),
};

/// Rotary gauge: filled circle + a 270° arc (gap at the bottom) with a
/// progress sweep and a knob dot at the current value.
class _DialPainter extends CustomPainter {
  final double t; // 0..1
  final Color fill;
  final Color track;
  final Color accent;

  _DialPainter({
    required this.t,
    required this.fill,
    required this.track,
    required this.accent,
  });

  static const double _start = 3 * math.pi / 4; // 135°
  static const double _sweep = 3 * math.pi / 2; // 270°

  @override
  void paint(Canvas c, Size s) {
    final center = s.center(Offset.zero);
    final r = s.width / 2;
    // MX knob body: radial blue — #3871C2 in the centre falling off to
    // #184588 at the rim (sampled from the reference shots).
    c.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [fill, _mxDialEdge],
          stops: const [0.25, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    final arcRect = Rect.fromCircle(center: center, radius: r - 8);
    final bg = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    c.drawArc(arcRect, _start, _sweep, false, bg);

    final fg = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    c.drawArc(arcRect, _start, _sweep * t, false, fg);

    // Short tick marks at the two ends of the 270° arc (MX detail).
    final tick = Paint()
      ..color = Colors.white38
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final a in [_start, _start + _sweep]) {
      final dir = Offset(math.cos(a), math.sin(a));
      c.drawLine(center + dir * (r - 4), center + dir * (r - 12), tick);
    }

    final ang = _start + _sweep * t;
    final dot = center + Offset(math.cos(ang), math.sin(ang)) * (r - 8);
    c.drawCircle(dot, 6, Paint()..color = accent);
    c.drawCircle(
      dot,
      6,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_DialPainter o) =>
      o.t != t || o.fill != fill || o.track != track || o.accent != accent;
}
