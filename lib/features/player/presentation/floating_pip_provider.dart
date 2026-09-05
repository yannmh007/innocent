import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/secure_screen/secure_screen_service.dart';
import 'player_provider.dart';

/// Phase 15: In-app floating PiP overlay state.
/// When [activeUri] is set, the [FloatingPipOverlay] widget appears
/// over the shell with a small video preview + controls.
class FloatingPipState {
  final String? activeUri;
  final String? activeTitle;
  final Offset position;
  /// When the app is leaving to the background, the floating window briefly
  /// expands to fill the screen so Android's system PiP captures ONLY the
  /// video (not the shell behind it). Restored to the small window on return.
  final bool fullscreenForPip;

  /// This playback is capture-protected (vault item, or paid catalogue
  /// content).
  ///
  /// AUDIT FIX (v1.55.16) — FLAG_SECURE was acquired by the PLAYER SCREEN and
  /// released in its dispose. Sending a video to the floating window pops that
  /// screen, so the claim was dropped while the little window carried on
  /// showing the same protected video: screenshots worked again, and the
  /// recents thumbnail showed it to anyone who tapped the square button. The
  /// window that is showing the picture has to be the thing holding the claim.
  final bool secure;

  /// The URI is a one-off address, not a stable identity — a signed, expiring
  /// stream URL.
  ///
  /// Carried for the same reason as [secure]: expanding the little window back
  /// to the full player rebuilds the player screen from this state, and a flag
  /// that is not carried is a flag that is LOST. Dropping this one would let
  /// the expanded player write a signed URL into resume storage and history —
  /// exactly the leak the flag exists to prevent, reintroduced by the one path
  /// that reconstructs the screen.
  final bool ephemeral;

  const FloatingPipState({
    this.activeUri,
    this.activeTitle,
    this.position = const Offset(20, 80),
    this.fullscreenForPip = false,
    this.secure = false,
    this.ephemeral = false,
  });

  bool get isActive => activeUri != null;

  FloatingPipState copyWith({
    Object? activeUri = _sentinel,
    Object? activeTitle = _sentinel,
    Offset? position,
    bool? fullscreenForPip,
    bool? secure,
    bool? ephemeral,
  }) {
    return FloatingPipState(
      activeUri: activeUri == _sentinel ? this.activeUri : activeUri as String?,
      activeTitle:
          activeTitle == _sentinel ? this.activeTitle : activeTitle as String?,
      position: position ?? this.position,
      fullscreenForPip: fullscreenForPip ?? this.fullscreenForPip,
      secure: secure ?? this.secure,
      ephemeral: ephemeral ?? this.ephemeral,
    );
  }
}

const Object _sentinel = Object();

class FloatingPipNotifier extends StateNotifier<FloatingPipState> {
  final Ref _ref;
  FloatingPipNotifier(this._ref) : super(const FloatingPipState());

  /// Whether this notifier currently holds a screen-capture claim.
  ///
  /// Tracked rather than recomputed, because [SecureScreenService] counts
  /// holders: acquiring twice and releasing once leaves the whole app
  /// capture-blocked until it restarts, and the reverse leaves protected
  /// content exposed. There are four places the state is assigned, so the
  /// pairing lives in ONE method they all go through instead of being repeated
  /// (and eventually missed) in each.
  bool _secureHeld = false;

  void _setState(FloatingPipState next) {
    state = next;
    final want = next.isActive && next.secure;
    if (want == _secureHeld) return;
    _secureHeld = want;
    // ignore: discarded_futures
    want
        ? SecureScreenService.instance.acquire()
        : SecureScreenService.instance.release();
  }

  /// [secure] must mirror the player screen's own claim, so the protection
  /// does not lapse for the moment between the player popping and the little
  /// window appearing. [ephemeral] rides along so an expand can hand it back.
  void activate(
    String uri,
    String? title, {
    bool secure = false,
    bool ephemeral = false,
  }) {
    _setState(state.copyWith(
      activeUri: uri,
      activeTitle: title,
      secure: secure,
      ephemeral: ephemeral,
    ));
  }

  void close() {
    // Tapping × on the floating PiP means "I'm done" — it must FULLY stop
    // playback, not just hide the overlay. Otherwise libmpv's audio thread
    // (and the background foreground-service, if any) would keep running and
    // the user would hear the video in the background after closing it.
    try {
      final notifier = _ref.read(playerControllerProvider.notifier);
      notifier.stopBackgroundPlaybackService();
      // ignore: discarded_futures
      notifier.stopPlayback();
    } catch (_) {/* controller may not exist — best effort */}
    _setState(const FloatingPipState());
  }

  /// Hide the overlay WITHOUT stopping playback — used when expanding back to
  /// the fullscreen player, where playback must continue seamlessly. (Unlike
  /// [close], which is the × button and hard-stops.)
  void hideForExpand() {
    _setState(const FloatingPipState());
  }

  /// The uri this notifier just handed to the fullscreen player, and when.
  ///
  /// AUDIT FIX (v1.51) — the overlay's own comment promised that "the
  /// fullscreen player will adopt the already-running libmpv instance so
  /// playback is seamless", but nothing ever told the player that. Its
  /// initState unconditionally called openVideo(), so expanding the little
  /// window reloaded the file from disk: a black frame, a spinner and a
  /// re-seek, every single time. MX Player expands instantly, because there is
  /// nothing to reload — it is the same playback session.
  ///
  /// A one-shot marker is the smallest thing that carries that fact across the
  /// route push. It is time-boxed so a stale marker can never make a genuine
  /// "open this file again" request silently do nothing.
  String? _handoffUri;
  DateTime? _handoffAt;
  static const Duration _handoffWindow = Duration(seconds: 5);

  /// Hide the overlay AND record that [uri] is being handed to the fullscreen
  /// player. Only the expand button calls this; [hideForExpand] deliberately
  /// does not, so a plain "clear the floating window" can never be mistaken
  /// for a hand-off.
  void handOffForExpand(String uri) {
    _handoffUri = uri;
    _handoffAt = DateTime.now();
    _setState(const FloatingPipState());
  }

  /// True exactly once, for the player screen that this hand-off was meant
  /// for. Consumed on read so a second player screen cannot adopt it too.
  bool consumeHandoff(String uri) {
    final at = _handoffAt;
    final had = _handoffUri;
    _handoffUri = null;
    _handoffAt = null;
    if (had == null || at == null) return false;
    if (had != uri) return false;
    return DateTime.now().difference(at) <= _handoffWindow;
  }

  void updatePosition(Offset position) {
    _setState(state.copyWith(position: position));
  }

  /// Expand the floating window to fill the screen (true) so system PiP
  /// captures only the video, or restore it to the small window (false).
  void setFullscreenForPip(bool value) {
    if (!state.isActive) return;
    _setState(state.copyWith(fullscreenForPip: value));
  }
}

final floatingPipProvider =
    StateNotifierProvider<FloatingPipNotifier, FloatingPipState>((ref) {
  return FloatingPipNotifier(ref);
});
