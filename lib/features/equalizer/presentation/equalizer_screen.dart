import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/equalizer/equalizer_service.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
final equalizerServiceProvider = Provider<EqualizerService>((ref) {
  // Reuse the process-wide instance so the UI, the startup audio-session
  // hook, and the playback-start reapply all share one session id + state.
  return sharedEqualizerService;
});

class EqualizerScreen extends ConsumerStatefulWidget {
  const EqualizerScreen({super.key});

  @override
  ConsumerState<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends ConsumerState<EqualizerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  bool _enabled = false;
  bool _supported = false;
  bool _loading = true;
  int _bandCount = 5;
  int _minLevel = -1500;
  int _maxLevel = 1500;
  List<int> _bandLevels = [0, 0, 0, 0, 0];
  List<int> _bandFreqs = [60000, 230000, 910000, 3600000, 14000000];
  List<String> _presets = const [];
  int? _activePreset;

  // Phase 45 (audit): Bass Boost / Virtualizer / Reverb state matching
  // MX Player V3's audio effects panel. Each effect is an independent
  // Android AudioFx instance that can be toggled and tuned.
  bool _bassBoostEnabled = false;
  int _bassBoostStrength = 0; // 0..1000
  bool _virtualizerEnabled = false;
  int _virtualizerStrength = 0; // 0..1000
  int _reverbPreset = 0; // 0..6 (None .. Plate)

  // UX-1 (audit): one-tap curated "sound profiles" shown as cards (like
  // MX Player's Audio Effect tab). The native EQ already supports
  // per-band levels — a profile just writes a band curve, scaled to the
  // device's actual band count and dB range.
  String? _selectedProfile;

  // Last value within an active dial drag (guards the 270° bottom gap).
  double _dialDrag = 0;

  /// 5-point dB curves (low→high frequency) for the curated profiles,
  /// scaled to the device band count/range by [_applyProfile].
  static const List<_SoundProfile> _profiles = [
    _SoundProfile('Original', Icons.graphic_eq, [0.0, 0.0, 0.0, 0.0, 0.0]),
    _SoundProfile('Music', Icons.music_note, [3.0, 1.0, 0.0, 1.0, 3.0]),
    _SoundProfile('Movie', Icons.movie_outlined, [5.0, 2.0, -1.0, 2.0, 5.0]),
    _SoundProfile('Bass Boost', Icons.speaker, [7.0, 4.0, 1.0, 0.0, 0.0]),
    _SoundProfile('Treble Boost', Icons.equalizer, [0.0, 0.0, 1.0, 4.0, 7.0]),
    _SoundProfile('Clarity', Icons.auto_awesome, [-1.0, 0.0, 1.0, 4.0, 5.0]),
  ];

  EqualizerService get _eq => ref.read(equalizerServiceProvider);

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
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
    // Phase 45 (audit refined, build 63): restore the persisted master
    // toggle state. MX Player V3's `audio_effects_enabled` survives
    // across app restarts.
    final masterEnabled = ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.audioEffectsEnabled);
    if (masterEnabled) {
      await _eq.setEnabled(true);
    }
    // Restore the previously-applied state (shared with the video player's
    // panel) and re-apply to the engine, which starts flat after a restart.
    final cached = _eq.bandLevels;
    final levels = <int>[
      for (int i = 0; i < bands; i++)
        (i < cached.length ? cached[i] : 0).clamp(range[0], range[1])
    ];
    final bass = _eq.bassStrength;
    final virt = _eq.virtualizerStrength;
    final reverb = _eq.reverbPreset;
    final effect = _eq.activeEffect;
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
      _selectedProfile = effect.isEmpty ? null : effect;
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  String _fmtFreq(int milliHz) {
    final hz = (milliHz / 1000).round();
    if (hz >= 1000) {
      final k = hz / 1000;
      return k == k.roundToDouble()
          ? '${k.round()}kHz'
          : '${k.toStringAsFixed(1)}kHz';
    }
    return '${hz}Hz';
  }

  String _fmtDb(int millibel) {
    final db = millibel / 100;
    final sign = db > 0 ? '+' : '';
    return '$sign${db.toStringAsFixed(1)} dB';
  }

  Future<void> _toggleEnabled(bool v) async {
    HapticFeedback.selectionClick();
    await _eq.setEnabled(v);
    // Phase 45 (audit refined, build 63): MX Player V3's
    // `audio_effects_enabled` master toggle. Persist so that subsequent
    // sessions remember whether the user wants the audio effects
    // pipeline active.
    await ref
        .read(playerSettingsProvider.notifier)
        .setValue(PlayerSetting.audioEffectsEnabled, v);
    // Code-quality audit: was calling setState without a mounted guard.
    // The user can navigate away while these two awaits are in flight,
    // and calling setState on a disposed State throws a FlutterError.
    if (!mounted) return;
    setState(() => _enabled = v);
  }

  Future<void> _applyPreset(int index) async {
    final levels = await _eq.usePreset(index);
    if (levels != null && mounted) {
      setState(() {
        _bandLevels = levels;
        _activePreset = index;
        _selectedProfile = null;
      });
      _eq.cacheSelection(presetIndex: index, effect: '');
    }
  }

  /// Interpolate a 5-point dB curve (positions 0, .25, .5, .75, 1) to an
  /// arbitrary normalised band position so profiles scale to whatever
  /// band count the device's equalizer reports.
  double _curveAt(List<double> curve, double pos) {
    final seg = (pos * 4).clamp(0.0, 4.0);
    final i = seg.floor().clamp(0, 3);
    final t = seg - i;
    return curve[i] + (curve[i + 1] - curve[i]) * t;
  }

  /// Apply a one-tap sound profile: writes a band curve (scaled to the
  /// device band count + dB range) and turns the audio pipeline on if
  /// it was off, mirroring MX Player's Audio Effect profiles.
  Future<void> _applyProfile(_SoundProfile p) async {
    if (!_enabled) {
      await _toggleEnabled(true);
    }
    final levels = <int>[];
    for (int i = 0; i < _bandCount; i++) {
      final pos = _bandCount <= 1 ? 0.0 : i / (_bandCount - 1);
      final mb =
          (_curveAt(p.curve, pos) * 100).round().clamp(_minLevel, _maxLevel);
      levels.add(mb);
      await _eq.setBandLevel(i, mb);
    }
    if (!mounted) return;
    setState(() {
      _bandLevels = levels;
      _selectedProfile = p.name;
      _activePreset = null;
    });
    _eq.cacheSelection(presetIndex: null, effect: p.name);
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: const TextStyle(
          color: AppColors.accentBlue,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      );

  Future<void> _onBandChange(int band, double value) async {
    final level = value.round();
    await _eq.setBandLevel(band, level);
    // Code-quality audit: was calling setState without a mounted guard.
    // Slider drags fire many onChange events in quick succession; if
    // the screen is disposed mid-drag the trailing event would crash.
    if (!mounted) return;
    setState(() {
      _bandLevels[band] = level;
      _activePreset = null; // custom
      _selectedProfile = null;
    });
    _eq.cacheSelection(presetIndex: null, effect: '');
  }

  @override
  Widget build(BuildContext context) {
    final showTabs = _supported && !_loading;
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: Text(AppStrings.of(context).equalizerTitle),
        bottom: showTabs
            ? TabBar(
                controller: _tab,
                indicatorColor: AppColors.accentBlue,
                labelColor: AppColors.accentBlue,
                unselectedLabelColor: Colors.white70,
                tabs: const [
                  Tab(text: 'Sound Profiles'),
                  Tab(text: 'Equalizer'),
                ],
              )
            : null,
        actions: [
          if (_supported)
            Switch(
              value: _enabled,
              onChanged: _toggleEnabled,
              activeColor: AppColors.accentBlue,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_supported
              ? _buildUnsupported()
              : TabBarView(
                  controller: _tab,
                  children: [
                    _buildProfilesTab(),
                    _buildEqualizerTab(),
                  ],
                ),
    );
  }

  Widget _buildUnsupported() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.tune,
              color: AppColors.darkOnSurfaceMuted,
              size: 64,
            ),
            const SizedBox(height: 16),
            Text(AppStrings.of(context).eqNotAvailable,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            const Text(
              'Your device or OS does not support audio effects, or no audio is currently playing.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.darkOnSurfaceMuted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfilesTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_enabled)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.darkSurface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.white10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      color: AppColors.accentBlue, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(AppStrings.of(context).tapProfileHint,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          _sectionLabel('SOUND PROFILES'),
          const SizedBox(height: 12),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.95,
            children: _profiles.map((p) {
              return _ProfileCard(
                profile: p,
                selected: _selectedProfile == p.name,
                onTap: () {
                  HapticFeedback.selectionClick();
                  _applyProfile(p);
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Text(AppStrings.of(context).profilesFineTuneHint,
            style: TextStyle(
              color: AppColors.darkOnSurfaceMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEqualizerTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Opacity(
        opacity: _enabled ? 1.0 : 0.45,
        child: AbsorbPointer(
          absorbing: !_enabled,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _bandPanel(),
              const SizedBox(height: 20),
              if (_presets.isNotEmpty) ...[
                _sectionLabel('PRESETS'),
                const SizedBox(height: 12),
                _presetChips(),
                const SizedBox(height: 22),
              ],
              _sectionLabel('AUDIO EFFECTS'),
              const SizedBox(height: 16),
              _dialsRow(),
              const SizedBox(height: 14),
              _reverbRow(),
            ],
          ),
        ),
      ),
    );
  }

  /// The 5 band sliders inside a rounded, faintly-bordered panel — the
  /// framed MX look, matching the video player's audio-effect sheet.
  Widget _bandPanel() {
    return Container(
      height: 240,
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: List.generate(_bandCount, (i) {
          return Expanded(
            child: _BandSlider(
              value: _bandLevels[i].toDouble(),
              min: _minLevel.toDouble(),
              max: _maxLevel.toDouble(),
              label: _fmtFreq(_bandFreqs[i]),
              valueLabel: _fmtDb(_bandLevels[i]),
              onChanged: (v) => _onBandChange(i, v),
            ),
          );
        }),
      ),
    );
  }

  Widget _presetChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _presets.asMap().entries.map((e) {
        final i = e.key;
        final isActive = _activePreset == i;
        return ChoiceChip(
          label: Text(e.value),
          selected: isActive,
          onSelected: (_) {
            HapticFeedback.selectionClick();
            _applyPreset(i);
          },
          backgroundColor: AppColors.darkSurface,
          selectedColor: AppColors.accentBlue,
          labelStyle: TextStyle(
            color: isActive ? Colors.white : Colors.white70,
            fontSize: 13,
          ),
          side: BorderSide(
            color: isActive ? AppColors.accentBlue : AppColors.white20,
          ),
        );
      }).toList(),
    );
  }

  // Bass Boost + Virtualizer rotary dials — matches the video player's
  // audio-effect sheet (replaces the old switch + slider tiles).
  Widget _dialsRow() {
    final media = MediaQuery.of(context);
    final dialSize = ((media.size.width - 64) / 2).clamp(120.0, 160.0);
    return SizedBox(
      height: dialSize + 4,
      child: Row(
        children: [
          _dial(
            label: 'Bass Boost',
            strength: _bassBoostStrength,
            size: dialSize,
            onChanged: (v) async {
              setState(() {
                _bassBoostStrength = v;
                _bassBoostEnabled = v > 0;
              });
              await _eq.setBassBoostEnabled(v > 0);
              await _eq.setBassBoostStrength(v);
            },
          ),
          _dial(
            label: 'Virtualizer',
            strength: _virtualizerStrength,
            size: dialSize,
            onChanged: (v) async {
              setState(() {
                _virtualizerStrength = v;
                _virtualizerEnabled = v > 0;
              });
              await _eq.setVirtualizerEnabled(v > 0);
              await _eq.setVirtualizerStrength(v);
            },
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
    final sweep = _DialPainter._sweep;
    var delta = (math.atan2(dy, dx) - _DialPainter._start) % (2 * math.pi);
    if (delta < 0) delta += 2 * math.pi;
    double t = delta <= sweep
        ? delta / sweep
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
                    fill: AppColors.specEqDialFill,
                    track: AppColors.specEqTrack,
                    accent: AppColors.accentBlue,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$pct%',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 4),
                    Text(label,
                        style: const TextStyle(
                            color: AppColors.white55, fontSize: 13)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
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
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.waves, color: AppColors.white55, size: 20),
            const SizedBox(width: 12),
            Text(AppStrings.of(context).reverb,
                style: TextStyle(color: AppColors.white70, fontSize: 16)),
            const Spacer(),
            Text(name,
                style:
                    const TextStyle(color: AppColors.white55, fontSize: 15)),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down,
                color: AppColors.white55, size: 22),
          ],
        ),
      ),
    );
  }

}

class _BandSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final String label;
  final String valueLabel;
  final ValueChanged<double> onChanged;

  const _BandSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.valueLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          valueLabel,
          style: const TextStyle(
            color: AppColors.accentBlue,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppColors.accentBlue,
                inactiveTrackColor: Colors.white24,
                thumbColor: AppColors.accentBlue,
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

/// UX-1 (audit): a curated one-tap sound profile (name + icon + a
/// 5-point dB curve that [_applyProfile] scales to the device's bands).
class _SoundProfile {
  final String name;
  final IconData icon;
  final List<double> curve;
  const _SoundProfile(this.name, this.icon, this.curve);
}

/// UX-1 (audit): tappable profile card for the Sound Profiles tab.
/// Filled accent when selected (mirrors MX Player's highlighted card).
class _ProfileCard extends StatelessWidget {
  final _SoundProfile profile;
  final bool selected;
  final VoidCallback onTap;

  const _ProfileCard({
    required this.profile,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentBlue.withOpacity(0.20)
              : Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? AppColors.accentBlue
                : Colors.white.withOpacity(0.12),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              profile.icon,
              color: selected ? Colors.white : AppColors.white70,
              size: 26,
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                profile.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: TextStyle(
                  color: selected ? Colors.white : AppColors.white70,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rotary gauge: filled circle + a 270 degree arc (gap at the bottom)
/// with a progress sweep and a knob dot at the current value. Mirrors the
/// video player's audio-effect dial so the two screens look identical.
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

  static const double _start = 3 * math.pi / 4; // 135 degrees
  static const double _sweep = 3 * math.pi / 2; // 270 degrees

  @override
  void paint(Canvas c, Size s) {
    final center = s.center(Offset.zero);
    final r = s.width / 2;
    c.drawCircle(center, r, Paint()..color = fill);

    final arcRect = Rect.fromCircle(center: center, radius: r - 7);
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

    final ang = _start + _sweep * t;
    final dot = center + Offset(math.cos(ang), math.sin(ang)) * (r - 7);
    c.drawCircle(dot, 7, Paint()..color = accent);
    c.drawCircle(
      dot,
      7,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_DialPainter o) =>
      o.t != t || o.fill != fill || o.track != track || o.accent != accent;
}
