import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';

/// Screen-capture protection (Android `FLAG_SECURE`) for the Private Folder
/// and every other surface that shows vault content.
///
/// WHY THIS IS NOT A SIMPLE BOOL
/// ─────────────────────────────
/// `FLAG_SECURE` lives on the Activity's Window, and this is a single-Activity
/// Flutter app, so it is one global switch shared by every route. That makes
/// the naive "set true in initState, false in dispose" pattern actively wrong:
/// the vault screen turns it on, the user opens an image from the vault (also
/// protected), closes the image, its dispose turns the flag OFF — and the
/// vault list underneath is suddenly screenshot-able again, with nothing on
/// screen to suggest anything changed.
///
/// So this is a COUNTER, not a flag. Every protected surface acquires on the
/// way in and releases on the way out; the window flag is only cleared when
/// the last holder lets go. The platform call is skipped whenever the desired
/// state already matches, because re-applying FLAG_SECURE re-creates the
/// surface on some devices and that reads as a flicker.
///
/// WHAT IT ACTUALLY BLOCKS (all three matter for a vault):
///   • manual screenshots and screen recording
///   • the thumbnail Android puts in the recents/app-switcher — otherwise the
///     vault's contents are visible to anyone who double-taps the square
///     button, with no PIN in the way at all
///   • mirroring to non-secure external displays (casting)
///
/// Android-only by nature. Everywhere else the calls are silent no-ops, so
/// callers never need a platform check.
class SecureScreenService {
  SecureScreenService._();

  /// Process-wide instance. Deliberately not a Riverpod provider: the counter
  /// must survive provider disposal, and widgets that need it are spread
  /// across features that should not have to depend on each other.
  static final SecureScreenService instance = SecureScreenService._();

  static const MethodChannel _channel =
      MethodChannel('mx_clone/secure_screen');

  int _holders = 0;
  bool _applied = false;

  /// Identifies the most recent deferred drop, so an earlier one that is still
  /// sleeping abandons itself instead of clearing the flag after a newer
  /// decision has been made. See [_sync].
  int _dropToken = 0;

  /// True while at least one surface is asking for protection.
  bool get isSecure => _holders > 0;

  /// Number of live holders — exposed for debugging and tests only.
  @visibleForTesting
  int get holders => _holders;

  /// Ask for screen-capture protection. Pair EVERY call with [release].
  Future<void> acquire() async {
    _holders++;
    await _sync();
  }

  /// Give up one claim. Protection drops only when the count reaches zero.
  /// Guarded against going negative: a double-release from a widget disposed
  /// twice would otherwise leave the counter permanently below zero and the
  /// vault permanently unprotected.
  Future<void> release() async {
    if (_holders > 0) _holders--;
    await _sync();
  }

  /// Force the counter back to zero. Only for a hard reset (e.g. a test, or a
  /// recovery path that knows every holder is gone).
  Future<void> reset() async {
    _holders = 0;
    await _sync();
  }

  Future<void> _sync() async {
    final want = _holders > 0;
    if (want == _applied) return;
    if (!want) {
      // DROPPING IS DEFERRED; TAKING IS NOT.
      //
      // Protection must go up the instant it is asked for, but coming down can
      // wait a moment — and it has to, because a hand-off releases before the
      // successor acquires. Sending a video to the floating window pops the
      // player (release) and the little window claims it a frame later; the
      // counter therefore touches zero even though something protected is on
      // screen the whole time. Applying that literally means clearing
      // FLAG_SECURE and setting it again, and re-applying the flag re-creates
      // the window surface on some devices — a visible flash, for a transition
      // where nothing actually became unprotected.
      //
      // So a drop waits briefly and then re-reads the counter. If anyone has
      // claimed in the meantime, no platform call is made at all.
      final int token = ++_dropToken;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (token != _dropToken) return;
      if (_holders > 0) return;
      if (!_applied) return;
    }
    try {
      await _channel.invokeMethod<bool>('setSecure', {'secure': want});
      _applied = want;
    } catch (e) {
      // A failed window-flag call must never take down the screen that asked
      // for it. Leave _applied alone so the next transition retries.
      if (kDebugMode) debugPrint('SecureScreenService.setSecure: $e');
    }
  }
}

/// Wraps a subtree so screen capture is blocked for as long as it is mounted.
///
/// Preferred over calling the service by hand: it is impossible to forget the
/// release, which is the failure that silently disables the whole protection.
///
/// ```dart
/// return const SecureScreenGuard(child: PrivateFolderScreen());
/// ```
class SecureScreenGuard extends StatefulWidget {
  final Widget child;

  /// When false the guard is inert — lets a caller keep one widget tree and
  /// protect it conditionally (the player uses this: only vault videos).
  final bool enabled;

  const SecureScreenGuard({
    super.key,
    required this.child,
    this.enabled = true,
  });

  @override
  State<SecureScreenGuard> createState() => _SecureScreenGuardState();
}

class _SecureScreenGuardState extends State<SecureScreenGuard> {
  bool _held = false;

  @override
  void initState() {
    super.initState();
    _apply(widget.enabled);
  }

  @override
  void didUpdateWidget(SecureScreenGuard old) {
    super.didUpdateWidget(old);
    if (old.enabled != widget.enabled) _apply(widget.enabled);
  }

  void _apply(bool want) {
    if (want == _held) return;
    _held = want;
    // Fire-and-forget: the platform round-trip must not delay the frame that
    // is already building this subtree.
    if (want) {
      // ignore: discarded_futures
      SecureScreenService.instance.acquire();
    } else {
      // ignore: discarded_futures
      SecureScreenService.instance.release();
    }
  }

  @override
  void dispose() {
    if (_held) {
      _held = false;
      // ignore: discarded_futures
      SecureScreenService.instance.release();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
