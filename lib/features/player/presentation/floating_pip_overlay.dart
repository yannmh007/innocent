import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
// v1.61: PipService is named by the teardown snapshot field below.
// Dart imports are not transitive, so core_providers is not enough.
import '../../../core/services/pip/pip_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/routes.dart';
import 'floating_pip_provider.dart';
import 'player_provider.dart';

/// Phase 15: In-app floating PiP overlay.
/// Replaces system PiP. Shown over the shell as a Stack overlay.
/// - Draggable around the screen
/// - Mini controls: prev / play-pause / next / fullscreen / close
/// - Tap on video area → expand back to full player
class FloatingPipOverlay extends ConsumerStatefulWidget {
  const FloatingPipOverlay({super.key});

  @override
  ConsumerState<FloatingPipOverlay> createState() => _FloatingPipOverlayState();
}

class _FloatingPipOverlayState extends ConsumerState<FloatingPipOverlay>
    with WidgetsBindingObserver {
  // Phase 17: MX Player PiP is much larger (~360×210, 16:9.3 ratio).
  static const double _w = 360;
  static const double _h = 210;

  bool _handlersInstalled = false;

  /// Snapshot taken in [deactivate]. Same reason as PlayerScreen: `ref`
  /// is already disposed by the time dispose() runs, so reading it there
  /// throws and skips the rest of the teardown.
  PipService? _pipServiceAtTeardown;

  /// Has this app ever reached the foreground? Guards the `detached` teardown.
  bool _hasBeenResumed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// AUDIT FIX (v1.51) — a detached picture must always have a way back.
  ///
  /// Background audio works by releasing the video track when the screen goes
  /// off. The fullscreen player restores it on `resumed`, but the floating
  /// window is not the player: the player route was popped when the video was
  /// sent here, so nothing was listening to the lifecycle at all. Lock the
  /// phone with the floating window open, unlock it, and the little window
  /// would have kept playing sound over a permanently black rectangle.
  ///
  /// The overlay is mounted for the whole app session, so it is the natural
  /// owner of that restore while it is the thing showing the video.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!mounted) return;
    if (state == AppLifecycleState.resumed) _hasBeenResumed = true;
    if (state == AppLifecycleState.detached) {
      // Only meaningful once the app has actually been alive. Flutter can
      // deliver `detached` before any view is attached — at startup on some
      // platforms — and hard-stopping there would be a teardown for an app
      // that has not started yet. Harmless today because nothing is playing,
      // but it is the kind of assumption that quietly stops being true.
      if (!_hasBeenResumed) return;
      // LAST LINE OF DEFENCE (v1.55) — the engine is being destroyed.
      //
      // `detached` is the only warning Flutter gives that the isolate is about
      // to go, and libmpv does not go with it: its threads belong to the
      // process and stop only when something calls dispose. Anything still
      // playing here would be orphaned — audible, unreachable, and joined by a
      // second voice the next time the app is opened.
      //
      // This overlay is mounted for the whole session, so it is the one widget
      // still listening at this point. Fire-and-forget on purpose: there is no
      // time left to await, and pause() alone silences immediately.
      try {
        final svc = ref.read(videoPlayerServiceProvider);
        // ignore: discarded_futures
        svc.pause();
        // ignore: discarded_futures
        svc.stop();
        // ignore: discarded_futures
        ref.read(backgroundPlaybackServiceProvider).stop();
      } catch (_) {
        // Providers may already be gone; nothing useful left to do.
      }
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    if (!ref.read(floatingPipProvider).isActive) return;
    // ignore: discarded_futures
    ref.read(playerControllerProvider.notifier).setBackgroundAudioMode(false);
  }

  /// Install the system-PiP handlers that make the floating window keep
  /// playing OVER OTHER APPS when the user leaves Innocent — the YouTube
  /// behaviour. We (re)install whenever the floating window becomes active,
  /// which deliberately overwrites the fullscreen player's handlers: once the
  /// player route is popped into this floating window, IT is the thing that
  /// should react to the user leaving the app. The player's own dispose is
  /// guarded to NOT clear these while the floating window is live.
  void _installFloatingHandlers() {
    final pipSvc = ref.read(pipServiceProvider);
    pipSvc.onUserLeaveHint = _onLeaveWhileFloating;
    pipSvc.onPipModeChanged = _onPipModeChangedWhileFloating;
    pipSvc.onPipPlayPause = _onPipPlayPause;
    pipSvc.onPipClosed = _onPipClosedWhileFloating;
    _handlersInstalled = true;
  }

  /// The user dismissed the system PiP window with × while we were floating.
  /// Fully stop playback and remove the floating window — matching MX Player,
  /// where closing the mini window ends the video (it must NOT keep playing in
  /// the background or reappear as a floating window inside the app).
  void _onPipClosedWhileFloating() {
    ref.read(floatingPipProvider.notifier).close();
  }

  /// Arm Android 12+ system auto-enter PiP with the current video's aspect so
  /// that leaving the app hands the floating video off to a system PiP window
  /// OVER OTHER APPS — reliably, without depending on the manual
  /// onUserLeaveHint → enterPip call landing before the activity pauses.
  void _armSystemAutoEnter() {
    final st = ref.read(playerControllerProvider);
    int w = 16;
    int h = 9;
    if (st.videoTracks.isNotEmpty) {
      final v = st.videoTracks.first;
      final vw = v.width ?? 0;
      final vh = v.height ?? 0;
      if (vw > 0 && vh > 0) {
        w = vw;
        h = vh;
      }
    }
    // ignore: discarded_futures
    ref.read(pipServiceProvider).setAutoEnterPip(true, width: w, height: h);
  }

  void _onLeaveWhileFloating() {
    final st = ref.read(playerControllerProvider);
    if (!st.isPlaying) return; // paused → nothing worth floating
    // Expand the little window to fill the screen so Android's system PiP
    // captures ONLY the video, not the app screen behind it.
    ref.read(floatingPipProvider.notifier).setFullscreenForPip(true);
    int w = 16;
    int h = 9;
    if (st.videoTracks.isNotEmpty) {
      final v = st.videoTracks.first;
      final vw = v.width ?? 0;
      final vh = v.height ?? 0;
      if (vw > 0 && vh > 0) {
        w = vw;
        h = vh;
      }
    }
    // Source rect ≈ full screen (the video fills it once expanded).
    Rect? srcRect;
    if (context.mounted) {
      srcRect = Offset.zero & MediaQuery.of(context).size;
    }
    ref.read(pipServiceProvider).enterPip(
          width: w,
          height: h,
          isPlaying: st.isPlaying,
          sourceRect: srcRect,
        );
  }

  void _onPipModeChangedWhileFloating(bool inPip) {
    ref.read(playerControllerProvider.notifier).setInSystemPip(inPip);
    if (!inPip) {
      // Back from the system PiP window → shrink to the in-app floating
      // window again (or the floating state was already closed).
      ref.read(floatingPipProvider.notifier).setFullscreenForPip(false);
    }
  }

  void _onPipPlayPause() {
    final controller = ref.read(playerControllerProvider.notifier);
    final playing = ref.read(playerControllerProvider).isPlaying;
    if (playing) {
      controller.pause();
    } else {
      controller.play();
    }
    // ignore: discarded_futures
    ref.read(pipServiceProvider).setPipPlaying(!playing);
  }

  @override
  void deactivate() {
    try {
      _pipServiceAtTeardown = ref.read(pipServiceProvider);
    } catch (_) {}
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Overlay only unmounts on app teardown; drop the handlers we own.
    // Uses the snapshot, never `ref` — reading a provider here throws.
    try {
      final pipSvc = _pipServiceAtTeardown;
      if (_handlersInstalled && pipSvc != null) {
        pipSvc.onUserLeaveHint = null;
        pipSvc.onPipModeChanged = null;
        pipSvc.onPipPlayPause = null;
        pipSvc.onPipClosed = null;
      }
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // (Re)install our PiP handlers the moment the floating window goes live,
    // so leaving the app from the floating window enters system PiP.
    ref.listen<bool>(
      floatingPipProvider.select((s) => s.isActive),
      (prev, active) {
        if (active) {
          _installFloatingHandlers();
          _armSystemAutoEnter();
        } else {
          // Floating window closed → disarm Android 12+ system auto-enter so
          // the app doesn't PiP itself when there's no floating video left.
          // ignore: discarded_futures
          ref.read(pipServiceProvider).setAutoEnterPip(false);
        }
      },
    );
    final pip = ref.watch(floatingPipProvider);
    if (!pip.isActive) return const SizedBox.shrink();
    // Whether Android has actually moved us into a system PiP window. This is
    // set from onPictureInPictureModeChanged, which fires RELIABLY on entry —
    // unlike fullscreenForPip (set in onUserLeaveHint), which the Android 12+
    // system auto-enter can outrun. We use it below to guarantee the video is
    // rendered fullscreen inside the PiP window (otherwise the small floating
    // window overflows the tiny PiP surface and shows only a cropped corner).
    final inSystemPip =
        ref.watch(playerControllerProvider.select((s) => s.inSystemPip));

    // Belt-and-suspenders: never mount the PiP video surface unless the
    // player is actually initialized. A stale "active" PiP state pointing
    // at an uninitialized controller would otherwise crash the build (this
    // overlay sits on every tab, so that blanks whatever screen is shown).
    if (!ref.read(videoPlayerServiceProvider).isInitialized) {
      return const SizedBox.shrink();
    }

    final svc = ref.read(videoPlayerServiceProvider);
    final size = MediaQuery.of(context).size;

    // Expanded-for-PiP: fill the whole screen so Android's system PiP window
    // captures ONLY the video. Triggered either by fullscreenForPip (set as we
    // leave) OR by actually being in a system PiP window — the latter catches
    // the Android 12+ auto-enter case where the expand hadn't rendered yet, so
    // the PiP window shows the full video instead of a clipped corner.
    if (pip.fullscreenForPip || inSystemPip) {
      return Positioned.fill(
        child: Container(
          color: Colors.black,
          child: svc.buildVideoWidget(fit: BoxFit.contain),
        ),
      );
    }

    final maxX = size.width - _w;
    final maxY = size.height - _h - 100; // leave bottom nav room

    final pos = Offset(
      pip.position.dx.clamp(0.0, maxX < 0 ? 0.0 : maxX),
      pip.position.dy.clamp(0.0, maxY < 0 ? 0.0 : maxY),
    );

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: const _PipBody(width: _w, height: _h),
    );
  }
}

class _PipBody extends ConsumerStatefulWidget {
  final double width;
  final double height;

  const _PipBody({required this.width, required this.height});

  @override
  ConsumerState<_PipBody> createState() => _PipBodyState();
}

class _PipBodyState extends ConsumerState<_PipBody> {
  bool _showControls = false;
  Offset _dragOffset = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final pip = ref.watch(floatingPipProvider);
    final playerState = ref.watch(playerControllerProvider);
    final svc = ref.read(videoPlayerServiceProvider);

    return GestureDetector(
      onTap: () {
        setState(() => _showControls = !_showControls);
      },
      onPanStart: (details) {
        _dragOffset = pip.position - details.globalPosition;
      },
      onPanUpdate: (details) {
        ref
            .read(floatingPipProvider.notifier)
            .updatePosition(details.globalPosition + _dragOffset);
      },
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        color: Colors.black,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: Stack(
            children: [
              // Video
              Positioned.fill(
                child: svc.buildVideoWidget(fit: BoxFit.contain),
              ),
              // Controls overlay (semi-transparent)
              if (_showControls)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Top row: fullscreen + close
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 4),
                          child: Row(
                            children: [
                              _ControlBtn(
                                icon: Icons.fullscreen,
                                tooltip: 'Open fullscreen',
                                onTap: () => _expandToFull(context, pip),
                              ),
                              const Spacer(),
                              _ControlBtn(
                                icon: Icons.close,
                                tooltip: 'Close',
                                onTap: () =>
                                    ref.read(floatingPipProvider.notifier).close(),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        // Middle row: prev / play-pause / next
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _ControlBtn(
                              icon: Icons.skip_previous,
                              size: 28,
                              tooltip: 'Previous',
                              onTap: () => ref
                                  .read(playerControllerProvider.notifier)
                                  .playPreviousInFolder(),
                            ),
                            const SizedBox(width: 8),
                            _ControlBtn(
                              icon: playerState.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              size: 32,
                              tooltip: 'Play/Pause',
                              onTap: () => ref
                                  .read(playerControllerProvider.notifier)
                                  .playOrPause(),
                            ),
                            const SizedBox(width: 8),
                            _ControlBtn(
                              icon: Icons.skip_next,
                              size: 28,
                              tooltip: 'Next',
                              onTap: () => ref
                                  .read(playerControllerProvider.notifier)
                                  .playNextInFolder(),
                            ),
                          ],
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _expandToFull(BuildContext context, FloatingPipState pip) {
    final uri = pip.activeUri;
    final title = pip.activeTitle;
    // Hide the overlay WITHOUT stopping playback — the fullscreen player will
    // adopt the already-running libmpv instance so playback is seamless.
    // (Using close() here would hard-stop the audio, then the reopened player
    // would have to restart from scratch.)
    if (uri == null) {
      ref.read(floatingPipProvider.notifier).hideForExpand();
      return;
    }
    // Records the hand-off so the player screen adopts this playback session
    // instead of reopening the file (see FloatingPipNotifier.handOffForExpand).
    ref.read(floatingPipProvider.notifier).handOffForExpand(uri);
    // Push the player on the root navigator. Use the router provider directly
    // (rather than GoRouter.of(context)) because this overlay now lives at the
    // MaterialApp builder level, above the Navigator, where an inherited
    // lookup isn't guaranteed.
    //
    // EVERY FLAG THE PLAYER WAS OPENED WITH HAS TO COME BACK.
    //
    // This push RECONSTRUCTS the player screen, so anything missing from the
    // map is silently reset to its default. `secure` omitted means paid
    // content plays back screenshot-able; `ephemeral` omitted means the
    // expanded player writes a signed URL into resume storage and history —
    // the leak those flags exist to prevent, reintroduced by the single path
    // that rebuilds the screen from state rather than from the original route.
    ref.read(routerProvider).push(
      Routes.player,
      extra: <String, dynamic>{
        'uri': uri,
        'title': title ?? '',
        'secure': pip.secure,
        'ephemeral': pip.ephemeral,
      },
    );
  }
}

class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final String tooltip;
  final VoidCallback onTap;

  const _ControlBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Tooltip(
          message: tooltip,
          child: Icon(icon, color: Colors.white, size: size),
        ),
      ),
    );
  }
}
