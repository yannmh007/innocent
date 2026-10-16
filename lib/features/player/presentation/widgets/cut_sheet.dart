import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/core_providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/ui/app_snackbar.dart';
import '../player_provider.dart';

import '../../../../core/localization/app_strings.dart';
import 'package:path/path.dart' as p;
import '../../../../core/services/video_cut/video_cut_service.dart';
import '../../../../core/ui/share_media.dart';
import '../../../../core/ui/app_sheet.dart';
/// Phase 40: Video Cut/Trim editor (MX Player parity, Function PDF page 5).
///
/// Lets the user mark a start (A) and end (B) point on the video timeline;
/// "Export" copies that stretch into Innocent/Cuts (VideoCutService): at
/// once and without re-encoding, from the key frame at or before A (the
/// sheet says where that is), or with "Exact start" from A itself, which has
/// to re-encode and shows its progress here, with Cancel. It used to say an
/// FFmpeg add-on was needed and cut nothing.
///
/// The A/B points are kept in widget-local state (not shared with the player
/// A-B repeat feature) so that opening Cut doesn't disturb playback.
class CutSheet extends ConsumerStatefulWidget {
  const CutSheet({super.key});

  /// Audit fix (B1): pause playback while the cut sheet is open and
  /// resume only if the playback WAS playing before. Frame-accurate
  /// trim points are unusable when the timeline keeps moving under
  /// the user's finger. We do not resume if the user had paused
  /// before opening (respects their explicit pause).
  static Future<void> show(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(playerControllerProvider.notifier);
    final wasPlaying = ref.read(playerControllerProvider).isPlaying;
    if (wasPlaying) {
      await controller.pause();
    }
    // Same guard, and the same decision, as `BookmarksSheet.show`: if the
    // player screen went away across the `pause()` await, skip the sheet and
    // leave playback paused rather than resuming into a screen the user has
    // already left. See the longer note there.
    if (!context.mounted) return;
    await showAppModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const CutSheet(),
    );
    // Resume only if WE paused. If the user paused before opening we
    // leave them in their chosen state.
    if (wasPlaying) {
      try {
        await controller.play();
      } catch (e) { if (kDebugMode) debugPrint('cut_sheet.best-effort: $e'); }
    }
  }

  @override
  ConsumerState<CutSheet> createState() => _CutSheetState();
}

class _CutSheetState extends ConsumerState<CutSheet> {
  Duration? _startPoint;
  Duration? _endPoint;

  /// "Exact start", remembered while the app runs.
  static bool _lastExact = false;
  bool _exact = _lastExact;

  /// Where the default cut from A really starts: the key frame at or before
  /// it. Null until read, or when it is A itself.
  Duration? _keyStart;

  /// An exact cut is running in this sheet; [_progress] is its percent.
  bool _exporting = false;
  int? _progress;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    // Closed while an exact cut runs: it carries on, and says so; its
    // result replaces this.
    if (_exporting) {
      AppSnackbar.global(AppStrings.current.cutWorking,
          duration: const Duration(minutes: 30));
    }
    super.dispose();
  }

  String? _localPath() {
    final uri = ref.read(playerControllerProvider.notifier).currentUri;
    return uri == null ? null : localPathOf(uri);
  }

  /// Reads where the lossless cut from [a] would start.
  Future<void> _readKeyStart(Duration a) async {
    final path = _localPath();
    if (path == null) return;
    final k = await VideoCutService.keyFrameBefore(path, a);
    if (!mounted || _startPoint != a) return;
    setState(() => _keyStart =
        k != null && a - k > const Duration(milliseconds: 40) ? k : null);
  }

  /// Where the scrubber's thumb is while a finger drags it; null otherwise.
  double? _scrubMs;

  /// Where the scrubber was let go, until the engine's position gets there.
  /// A seek takes a moment: without this the thumb jumped back to the old
  /// spot and a quick Set took the old position.
  Duration? _seekTarget;
  DateTime _seekTargetAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastScrubSeek = DateTime.fromMillisecondsSinceEpoch(0);

  /// Move the paused video while dragging, a few times a second — enough to
  /// see the frame under the thumb without flooding the engine with seeks.
  void _scrub(double ms) {
    setState(() => _scrubMs = ms);
    final now = DateTime.now();
    if (now.difference(_lastScrubSeek) < const Duration(milliseconds: 150)) {
      return;
    }
    _lastScrubSeek = now;
    _seekTo(Duration(milliseconds: ms.round()));
  }

  void _scrubEnd(double ms) {
    final target = Duration(milliseconds: ms.round());
    _seekTo(target);
    setState(() {
      _scrubMs = null;
      _seekTarget = target;
      _seekTargetAt = DateTime.now();
    });
  }

  /// [_seekTarget] while the engine has not reached it (and for at most two
  /// seconds, so a seek that lands elsewhere cannot hold it forever).
  Duration? _pendingSeek(Duration live) {
    final t = _seekTarget;
    if (t == null) return null;
    if ((live - t).abs() < const Duration(milliseconds: 600) ||
        DateTime.now().difference(_seekTargetAt) > const Duration(seconds: 2)) {
      _seekTarget = null;
      return null;
    }
    return t;
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _setStart() {
    final pos = _enginePosition();
    setState(() {
      _startPoint = pos;
      _keyStart = null;
      // If end is now before start, clear it.
      if (_endPoint != null && _endPoint! <= pos) _endPoint = null;
    });
    _readKeyStart(pos);
  }

  /// Where the video actually is, to the millisecond.
  Duration _enginePosition() {
    final engine = ref.read(videoPlayerServiceProvider).position;
    final live = engine > Duration.zero
        ? engine
        : ref.read(playerControllerProvider).position;
    return _pendingSeek(live) ?? live;
  }

  void _setEnd() {
    final pos = _enginePosition();
    if (_startPoint == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).setStartFirst),
          duration: const Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    if (pos <= _startPoint!) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).endAfterStart),
          duration: const Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    setState(() => _endPoint = pos);
  }

  void _clear() {
    setState(() {
      _startPoint = null;
      _endPoint = null;
      _keyStart = null;
    });
  }

  void _seekTo(Duration target) {
    ref.read(playerControllerProvider.notifier).seek(target);
  }

  Future<void> _export() async {
    if (_startPoint == null || _endPoint == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).setBothPoints),
          duration: const Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    final s = AppStrings.of(context);
    final controller = ref.read(playerControllerProvider.notifier);
    final path = _localPath();
    final start = _startPoint!;
    final end = _endPoint!;
    final exact = _exact;
    if (controller.isPrivate || path == null) {
      Navigator.pop(context);
      AppSnackbar.global(
          controller.isPrivate ? s.cutPrivate : s.cutLocalOnly);
      return;
    }
    if (!exact) {
      // A moment: close the sheet; the rest is reported through the root
      // messenger, which needs no context from the popped route.
      Navigator.pop(context);
      AppSnackbar.global(s.cutWorking, duration: const Duration(minutes: 5));
      _report(s, await VideoCutService.cut(
          sourcePath: path, start: start, end: end));
      return;
    }
    // Exact: it can take as long as the clip, so it runs here, with its
    // progress and Cancel.
    setState(() {
      _exporting = true;
      _progress = null;
    });
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final p = await VideoCutService.progress();
      if (mounted && _exporting && p != null) setState(() => _progress = p);
    });
    final result = await VideoCutService.cut(
        sourcePath: path, start: start, end: end, exact: true);
    _poll?.cancel();
    _poll = null;
    if (result.error == 'cancelled') {
      AppSnackbar.global(s.cutCancelled);
      if (mounted) setState(() => _exporting = false);
      return;
    }
    if (mounted) {
      _exporting = false;
      Navigator.pop(context);
    }
    _report(s, result, askedExact: true);
  }

  void _report(AppStrings s, VideoCutResult result, {bool askedExact = false}) {
    final saved = result.path;
    if (saved == null) {
      AppSnackbar.globalError(s.cutFailed(result.error ?? '?'));
      return;
    }
    final name = p.basename(saved);
    // The key-frame note only where an exact start was asked for and not
    // possible: without it the sheet already said where the cut starts.
    final fellBack = askedExact && !result.exact;
    AppSnackbar.global(
        result.silent
            ? s.cutSavedSilent(name)
            : fellBack
                ? s.cutSavedKeyFrame(name)
                : s.cutSaved(name),
        duration: Duration(seconds: result.silent || fellBack ? 7 : 4));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(playerControllerProvider);
    final duration = state.duration;
    // Live engine position. The player state only carries the position while
    // something in the player itself is displaying it — this sheet is a modal
    // route on top, which the controller cannot see. Watching the scoped
    // position stream rebuilds just this sheet, and only while it is open.
    final live = ref.watch(videoPositionProvider).value ?? state.position;
    final position = _pendingSeek(live) ?? live;
    final clipDuration = (_startPoint != null && _endPoint != null)
        ? _endPoint! - _startPoint!
        : null;

    // Scrolls when the screen is short: in landscape the sheet has about
    // 360 dp, less than it needs.
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                const Icon(Icons.content_cut,
                    color: AppColors.accentBlue, size: 22),
                const SizedBox(width: 10),
                Text(AppStrings.of(context).cut,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(AppStrings.of(context).markClipHint,
              style: const TextStyle(
                color: AppColors.white60,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            Text(AppStrings.of(context).cutHint,
              style: const TextStyle(
                color: AppColors.white50,
                fontSize: 11.5,
              ),
            ),
            const SizedBox(height: 20),
            _PointRow(
              label: AppStrings.of(context).pwStartA,
              value: _startPoint,
              fmt: _fmt,
              onSet: _setStart,
              onSeek: _startPoint != null ? () => _seekTo(_startPoint!) : null,
            ),
            // Where the lossless cut will really start, before it is made.
            if (!_exact && _keyStart != null)
              Padding(
                padding: const EdgeInsets.only(left: 80, top: 6),
                child: Text(
                  AppStrings.of(context).cutKeyStartAt(_fmt(_keyStart!)),
                  style:
                      const TextStyle(color: AppColors.white60, fontSize: 11.5),
                ),
              ),
            const SizedBox(height: 12),
            _PointRow(
              label: AppStrings.of(context).pwEndB,
              value: _endPoint,
              fmt: _fmt,
              onSet: _setEnd,
              onSeek: _endPoint != null ? () => _seekTo(_endPoint!) : null,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey('cut-exact'),
              contentPadding: EdgeInsets.zero,
              value: _exact,
              activeColor: AppColors.accentBlue,
              onChanged: _exporting
                  ? null
                  : (v) => setState(() => _exact = _lastExact = v),
              title: Text(AppStrings.of(context).cutExact,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(AppStrings.of(context).cutExactSub,
                  style:
                      const TextStyle(color: AppColors.white60, fontSize: 11.5)),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.white05,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.timer_outlined,
                      color: Colors.white54, size: 16),
                  const SizedBox(width: 8),
                  Text('${AppStrings.of(context).currentLabel}: ${_fmt(position)} / ${_fmt(duration)}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const Spacer(),
                  if (clipDuration != null)
                    Text('${AppStrings.of(context).clipLabel}: ${_fmt(clipDuration)}',
                      style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),
            // The playhead, here: the video is paused under this sheet and
            // the player's own seek bar is behind it, so without this there
            // was no way to move from A to a later B.
            // container: its own node, or the id lands on the whole sheet.
            Semantics(
              container: true,
              identifier: 'cut-scrubber',
              child: Slider(
              value: (_scrubMs ??
                      position.inMilliseconds
                          .clamp(0, duration.inMilliseconds)
                          .toDouble())
                  .clamp(0, duration.inMilliseconds.toDouble()),
              max: duration.inMilliseconds > 0
                  ? duration.inMilliseconds.toDouble()
                  : 1,
              activeColor: AppColors.accentBlue,
              inactiveColor: Colors.white24,
              semanticFormatterCallback: (v) =>
                  _fmt(Duration(milliseconds: v.round())),
              onChanged: duration > Duration.zero ? _scrub : null,
              onChangeEnd: duration > Duration.zero ? _scrubEnd : null,
            ),
            ),
            const SizedBox(height: 8),
            if (_exporting)
              _ExactProgress(
                progress: _progress,
                label: AppStrings.of(context).cutProgress(_progress ?? 0),
                cancel: AppStrings.of(context).cancel,
                onCancel: VideoCutService.cancel,
              )
            else
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: (_startPoint == null && _endPoint == null)
                        ? null
                        : _clear,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(AppStrings.of(context).clear,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _export,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(AppStrings.of(context).export,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// An exact cut at work: how far it is, and Cancel.
class _ExactProgress extends StatelessWidget {
  final int? progress;
  final String label;
  final String cancel;
  final VoidCallback onCancel;

  const _ExactProgress({
    required this.progress,
    required this.label,
    required this.cancel,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress == null ? null : progress! / 100,
            minHeight: 6,
            color: AppColors.accentBlue,
            backgroundColor: Colors.white12,
          ),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ),
            TextButton(
              key: const ValueKey('cut-cancel'),
              onPressed: onCancel,
              child: Text(cancel),
            ),
          ],
        ),
      ],
    );
  }
}

class _PointRow extends StatelessWidget {
  final String label;
  final Duration? value;
  final String Function(Duration) fmt;
  final VoidCallback onSet;
  final VoidCallback? onSeek;

  const _PointRow({
    required this.label,
    required this.value,
    required this.fmt,
    required this.onSet,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: onSeek,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.white05,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: value != null
                      ? AppColors.accentBlue40
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    value != null ? Icons.check_circle : Icons.circle_outlined,
                    color: value != null
                        ? AppColors.accentBlue
                        : Colors.white38,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    value != null ? fmt(value!) : AppStrings.of(context).pwNotSet,
                    style: TextStyle(
                      color: value != null ? Colors.white : Colors.white54,
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (onSeek != null) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.gps_fixed,
                        color: Colors.white38, size: 12),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: onSet,
          style: TextButton.styleFrom(
            backgroundColor: AppColors.white08,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(AppStrings.of(context).setWord,
            style: const TextStyle(
              color: AppColors.accentBlue,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
