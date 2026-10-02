import 'package:flutter/material.dart';

/// A photo that can be pinched, double-tapped and panned — inside a
/// [PageView] that swipes between photos.
///
/// ─── WHY THE OLD ONE COULD NOT ZOOM ─────────────────────────────────────
///
/// It was an [InteractiveViewer] straight inside the album's PageView. Both
/// want the same fingers: the PageView's horizontal drag claims a gesture as
/// soon as the FIRST finger moves a few pixels sideways, and a pinch never
/// starts with both fingers landing on the same frame. So the page slid a
/// little and the pinch was lost — on a real phone, nearly every time.
///
/// ─── WHAT THIS DOES INSTEAD ─────────────────────────────────────────────
///
/// It tells its parent to stop paging the moment a SECOND finger touches
/// (the parent swaps in [NeverScrollableScrollPhysics], which takes the
/// PageView's drag out of the gesture arena before it can win), and keeps
/// paging off while the photo is zoomed, so a one-finger drag on a zoomed
/// photo moves around the photo instead of flicking to the next one. Back at
/// 100 % with no fingers down, paging comes back. Double-tap zooms to where
/// the finger was and back out, as in Telegram and Google Photos.
class ZoomablePhoto extends StatefulWidget {
  const ZoomablePhoto({
    super.key,
    required this.child,
    required this.onLockPaging,
    this.maxScale = 5,
    this.doubleTapScale = 2.5,
  });

  final Widget child;

  /// True: the parent must stop paging now. False: it may page again.
  final ValueChanged<bool> onLockPaging;
  final double maxScale;
  final double doubleTapScale;

  @override
  State<ZoomablePhoto> createState() => ZoomablePhotoState();
}

class ZoomablePhotoState extends State<ZoomablePhoto>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _zoomTween;
  Offset? _doubleTapAt;
  int _pointers = 0;
  bool _locked = false;

  /// The current zoom, 1.0 when the whole photo is shown.
  double get scale => _transform.value.getMaxScaleOnAxis();

  bool get _zoomed => scale > 1.01;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() {
      final t = _zoomTween;
      if (t != null) _transform.value = t.value;
    });
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.completed) _report();
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _report() {
    final lock = _pointers >= 2 || _zoomed;
    if (lock == _locked) return;
    // setState, because [InteractiveViewer.panEnabled] follows it.
    if (mounted) setState(() => _locked = lock);
    widget.onLockPaging(lock);
  }

  void _toggleZoom() {
    final at = _doubleTapAt;
    final Matrix4 target;
    if (_zoomed) {
      target = Matrix4.identity();
    } else {
      // Zoom INTO the point that was tapped, not the middle of the screen:
      // the reason for a double-tap is a face or a line of text, and it must
      // stay under the finger.
      final p = at ?? Offset.zero;
      final s = widget.doubleTapScale;
      target = Matrix4.identity()
        ..translate(-p.dx * (s - 1), -p.dy * (s - 1))
        ..scale(s);
    }
    _zoomTween = Matrix4Tween(begin: _transform.value, end: target)
        .animate(CurveTween(curve: Curves.easeOutCubic).animate(_anim));
    _anim.forward(from: 0);
    // Lock straight away when zooming in, so a quick swipe during the
    // animation does not page away from what is being looked at.
    if (!_zoomed && !_locked) {
      setState(() => _locked = true);
      widget.onLockPaging(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Counted here, below every gesture recogniser, because this has to
      // know about the second finger BEFORE the arena decides anything.
      onPointerDown: (_) {
        _pointers++;
        _report();
      },
      onPointerUp: (_) {
        if (_pointers > 0) _pointers--;
        _report();
      },
      onPointerCancel: (_) {
        if (_pointers > 0) _pointers--;
        _report();
      },
      child: GestureDetector(
        onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
        onDoubleTap: _toggleZoom,
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          maxScale: widget.maxScale,
          // At 100 % a one-finger drag belongs to the PageView; panning a
          // photo that already fits the screen moves nothing useful.
          panEnabled: _locked,
          clipBehavior: Clip.none,
          onInteractionStart: (_) => _anim.stop(),
          onInteractionUpdate: (_) => _report(),
          onInteractionEnd: (_) {
            _report();
            // Rebuild once so panEnabled follows the new zoom.
            if (mounted) setState(() {});
          },
          child: widget.child,
        ),
      ),
    );
  }
}
