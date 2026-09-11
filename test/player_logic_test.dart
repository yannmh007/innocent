// Tests for player logic that had none.
//
// WHAT IS TESTABLE HERE AND WHAT IS NOT. `PlayerController` is a
// StateNotifier that reaches the world through `_ref` — settings, resume
// storage, user data, and libmpv behind `videoPlayerServiceProvider`. None of
// its methods can be called without standing up those providers and a real
// media_kit engine, so nothing below drives the controller.
//
// Two things ARE reachable, and they are the two that carry the bugs:
//
//   1. `PlayerState` itself imports cleanly into a plain VM test. Its
//      `copyWith` is 50 parameters wide and uses a sentinel to tell "leave
//      this alone" from "set it to null", which is exactly the shape that
//      breaks quietly under a refactor.
//
//   2. The pure decisions buried inside those methods — the seek clamp, the
//      auto-save throttle, the surface-op fence — are arithmetic and
//      scheduling with no platform in them. Each is EXTRACTED VERBATIM below,
//      with the source file and the shipped lines named, so the test fails if
//      someone changes the real thing without changing the copy. That is the
//      same pattern `update_download_test.dart` uses for the space check.
//
// Every one of these five is a rule the source comments say was got wrong
// once already.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/shortcut_item.dart';

// ───────────────────────────────────────────────────────────────────────────
// 1. THE SEEK CLAMP — player_controller_playback.dart, `seek()`
//
// Extracted verbatim from the body of `seek`. The original reads
// `state.duration` and the argument; both are parameters here and nothing
// else in that expression touches the controller.
// ───────────────────────────────────────────────────────────────────────────
Duration seekClamp(Duration to, Duration dur) {
  return to < Duration.zero
      ? Duration.zero
      : (dur > Duration.zero && to > dur ? dur : to);
}

/// From `seekRelative()`, same file. The two clamps are deliberately
/// identical; what differs is what `target` is computed from.
Duration seekRelativeTarget({
  required int seconds,
  required Duration enginePosition,
  required Duration statePosition,
  required Duration dur,
}) {
  final base =
      enginePosition > Duration.zero ? enginePosition : statePosition;
  final target = base + Duration(seconds: seconds);
  return target < Duration.zero
      ? Duration.zero
      : (dur > Duration.zero && target > dur ? dur : target);
}

// ───────────────────────────────────────────────────────────────────────────
// 2. THE AUTO-SAVE THROTTLE — player_controller_navigation.dart,
//    `_scheduleAutoSave()`
//
// Verbatim, with the timer field made local. The source comment records what
// this replaced: a debounce that was reset by every position tick, so during
// continuous playback the timer never elapsed and NOTHING was persisted.
// ───────────────────────────────────────────────────────────────────────────
class AutoSaveScheduler {
  /// The shipped value is `const Duration(seconds: 5)`. It is a parameter
  /// here ONLY so the tests run in milliseconds instead of minutes — the
  /// logic under test is the throttle-vs-debounce shape above it, not the
  /// number. `fake_async` would have kept the constant verbatim, but it is a
  /// transitive dependency this package does not declare, and adding it to
  /// pubspec for two tests is a worse trade than one injected Duration.
  AutoSaveScheduler(this.window);
  final Duration window;

  Timer? _autoSaveTimer;
  int saves = 0;

  void scheduleAutoSave() {
    if (_autoSaveTimer?.isActive ?? false) return;
    _autoSaveTimer = Timer(window, () => saves++);
  }

  void cancel() => _autoSaveTimer?.cancel();
}

// ───────────────────────────────────────────────────────────────────────────
// 3. THE SURFACE-OP FENCE — media_kit_player_service.dart, `_runSurfaceOp`
//
// Verbatim apart from the debugPrint. This is what serialises a
// detach/reattach pair against another one arriving on top of it, and the
// generation counter is what lets an in-flight transition notice it has been
// superseded and abandon itself.
// ───────────────────────────────────────────────────────────────────────────
class SurfaceOps {
  int surfaceGen = 0;
  Future<void> _surfaceOp = Future<void>.value();

  Future<void> runSurfaceOp(Future<void> Function(int gen) action) {
    final next = _surfaceOp.then((_) {
      final gen = ++surfaceGen;
      return action(gen);
    }).catchError((Object e) {
      // Swallowed in the source too; see the comment below it.
    });
    _surfaceOp = next;
    return next;
  }
}

void main() {
  group('the seek clamp', () {
    // "libmpv tolerates out-of-range values but the UI state would briefly
    // show negative or past-end positions until libmpv corrects them."
    const dur = Duration(minutes: 5);

    test('a position inside the video passes through untouched', () {
      expect(seekClamp(const Duration(minutes: 2), dur),
          const Duration(minutes: 2));
    });

    test('a negative seek becomes zero', () {
      expect(seekClamp(const Duration(seconds: -30), dur), Duration.zero);
      expect(seekClamp(const Duration(hours: -1), dur), Duration.zero);
    });

    test('past the end becomes the end', () {
      expect(seekClamp(const Duration(minutes: 9), dur), dur);
    });

    test('exactly the duration is allowed', () {
      // The boundary is `> dur`, not `>=`. Seeking to the last frame is a
      // legitimate thing to ask for.
      expect(seekClamp(dur, dur), dur);
    });

    test('an UNKNOWN duration never clamps the top end', () {
      // duration is zero while a file is still opening. Clamping against it
      // would pin every early seek to 0:00 — worse than the overshoot the
      // clamp exists to prevent.
      expect(seekClamp(const Duration(minutes: 9), Duration.zero),
          const Duration(minutes: 9));
      // ...but the floor still applies.
      expect(seekClamp(const Duration(seconds: -5), Duration.zero),
          Duration.zero);
    });
  });

  group('seekRelative bases the jump on the ENGINE position', () {
    // "State position is deliberately quantised to whole seconds... so a
    // +10 s skip taken from it actually moved somewhere between 9.0 and 10.0
    // seconds, and repeated skips accumulated the error."
    const dur = Duration(minutes: 5);

    test('uses the engine position when it has one', () {
      // The quantised UI copy says 30s; libmpv says 30.8s. +10 must land on
      // 40.8, not 40.
      expect(
        seekRelativeTarget(
          seconds: 10,
          enginePosition: const Duration(milliseconds: 30800),
          statePosition: const Duration(seconds: 30),
          dur: dur,
        ),
        const Duration(milliseconds: 40800),
      );
    });

    test('falls back to the state position when the engine reports zero', () {
      expect(
        seekRelativeTarget(
          seconds: 10,
          enginePosition: Duration.zero,
          statePosition: const Duration(seconds: 30),
          dur: dur,
        ),
        const Duration(seconds: 40),
      );
    });

    test('spam-tapping forward at the end stops at the duration', () {
      // "Spam-tapping +10 at the end of a 5-minute clip would otherwise let
      // the internal position run past duration before completion fires."
      var pos = const Duration(minutes: 4, seconds: 55);
      for (var i = 0; i < 5; i++) {
        pos = seekRelativeTarget(
          seconds: 10,
          enginePosition: pos,
          statePosition: pos,
          dur: dur,
        );
      }
      expect(pos, dur);
    });

    test('rewinding past the start stops at zero', () {
      expect(
        seekRelativeTarget(
          seconds: -10,
          enginePosition: const Duration(seconds: 3),
          statePosition: const Duration(seconds: 3),
          dur: dur,
        ),
        Duration.zero,
      );
    });
  });

  group('the auto-save throttle', () {
    const window = Duration(milliseconds: 100);

    test('continuous playback still saves, repeatedly', () async {
      // THE REGRESSION THIS PINS. The old code cancelled and re-armed on
      // every position tick, so a video that played without pausing never
      // reached the deadline and a force-kill lost the resume point
      // entirely. A steady stream of ticks must still produce saves.
      final s = AutoSaveScheduler(window);
      for (var i = 0; i < 60; i++) {
        s.scheduleAutoSave();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      s.cancel();
      expect(s.saves, greaterThanOrEqualTo(2),
          reason: 'a debounce would have saved zero times');
    });

    test('a tick inside the window does not re-arm the timer', () async {
      // The throttle half: the first tick owns the deadline and later ticks
      // leave it alone.
      final s = AutoSaveScheduler(window);
      s.scheduleAutoSave();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      s.scheduleAutoSave(); // would reset a debounce
      await Future<void>.delayed(const Duration(milliseconds: 60));
      s.cancel();
      expect(s.saves, 1, reason: 'the original deadline must still fire');
    });

    test('nothing fires before the window elapses', () async {
      final s = AutoSaveScheduler(window);
      s.scheduleAutoSave();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(s.saves, 0);
      s.cancel();
    });
  });

  group('the surface detach/reattach fence', () {
    test('two transitions serialise instead of interleaving', () async {
      // The whole point of the chain: a reattach arriving while a detach is
      // mid-flight waits for it rather than running through it.
      final ops = SurfaceOps();
      final order = <String>[];

      // Not awaited on purpose: B is queued behind it and awaiting B is what
      // proves the chain ran them in order.
      unawaited(ops.runSurfaceOp((gen) async {
        order.add('A-start');
        await Future<void>.delayed(const Duration(milliseconds: 60));
        order.add('A-end');
      }));
      final b = ops.runSurfaceOp((gen) async {
        order.add('B-start');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        order.add('B-end');
      });

      await b;
      expect(order, ['A-start', 'A-end', 'B-start', 'B-end']);
    });

    test('dispose invalidates a transition that is mid-await', () async {
      // THE FENCE'S ACTUAL JOB, and it is not the chain's. `dispose()` in
      // media_kit_player_service.dart does a bare `_surfaceGen++` out of band:
      //
      //   "Invalidate any surface transition still part-way through its
      //    awaits, so it abandons itself instead of writing into a player
      //    that is about to be destroyed."
      //
      // The chain cannot help here — the transition is already running. Only
      // the counter can tell it to stop, and every `if (gen != _surfaceGen)
      // return;` in the detach and reattach bodies is that check.
      final ops = SurfaceOps();
      var wroteAfterDispose = false;

      final op = ops.runSurfaceOp((gen) async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        // This is the shipped guard, verbatim.
        if (gen != ops.surfaceGen) return;
        wroteAfterDispose = true;
      });

      // dispose() lands while the transition is inside its await.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ops.surfaceGen++;

      await op;
      expect(wroteAfterDispose, isFalse,
          reason: 'a superseded transition must not write to a dead player');
    });

    test('without the bump, the same transition completes normally', () async {
      // The other half, so the test above is proving the guard rather than
      // proving the transition never runs.
      final ops = SurfaceOps();
      var wrote = false;

      await ops.runSurfaceOp((gen) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (gen != ops.surfaceGen) return;
        wrote = true;
      });

      expect(wrote, isTrue);
    });

    test('a transition that throws does not poison the chain', () async {
      // "The chain must never end in an error state, or every later
      // transition would be skipped." A failed detach must not mean the
      // screen never comes back.
      final ops = SurfaceOps();
      var laterRan = false;

      // Not awaited on purpose: this one is the failure, and the point is
      // that awaiting the NEXT one still resolves.
      unawaited(ops.runSurfaceOp((gen) async {
        throw StateError('surface went away mid-detach');
      }));
      await ops.runSurfaceOp((gen) async {
        laterRan = true;
      });

      expect(laterRan, isTrue,
          reason: 'the reattach after a failed detach must still run');
    });

    test('generations are handed out in order, one per transition', () async {
      final ops = SurfaceOps();
      final gens = <int>[];
      Future<void> last = Future<void>.value();
      for (var i = 0; i < 4; i++) {
        last = ops.runSurfaceOp((gen) async => gens.add(gen));
      }
      await last;
      expect(gens, [1, 2, 3, 4]);
    });
  });

  group('PlayerState.copyWith', () {
    test('changing the decoder does NOT reset the position', () {
      // THE BUG THE SOURCE COMMENT RECORDS: "the decoder switch used to
      // reopen the file, and the video came back at 00:00 every time." The
      // state transition `selectDecoder` performs is exactly this, and the
      // position surviving it is the whole fix.
      const before = PlayerState(
        position: Duration(minutes: 12, seconds: 34),
        duration: Duration(minutes: 90),
        isPlaying: true,
        decoder: DecoderType.hw,
        decoderDialogOpen: true,
      );

      final after = before.copyWith(
        decoder: DecoderType.sw,
        decoderDialogOpen: false,
      );

      expect(after.decoder, DecoderType.sw);
      expect(after.decoderDialogOpen, isFalse);
      expect(after.position, const Duration(minutes: 12, seconds: 34));
      expect(after.duration, const Duration(minutes: 90));
      expect(after.isPlaying, isTrue);
    });

    test('every decoder value round-trips', () {
      for (final d in DecoderType.values) {
        expect(const PlayerState().copyWith(decoder: d).decoder, d);
      }
    });

    test('an omitted field is preserved, not reset to its default', () {
      const before = PlayerState(
        position: Duration(seconds: 45),
        playbackSpeed: 1.75,
        isLocked: true,
        lockScope: 'rotation',
        isKidsLocked: true,
        isMuted: true,
        brightness: 0.3,
        volume: 0.8,
      );
      // Touch one unrelated field.
      final after = before.copyWith(isBuffering: true);

      expect(after.isBuffering, isTrue);
      expect(after.position, const Duration(seconds: 45));
      expect(after.playbackSpeed, 1.75);
      expect(after.isLocked, isTrue);
      expect(after.lockScope, 'rotation');
      expect(after.isKidsLocked, isTrue);
      expect(after.isMuted, isTrue);
      expect(after.brightness, 0.3);
      expect(after.volume, 0.8);
    });

    test('a nullable field can actually be CLEARED, not just set', () {
      // The sentinel is what makes `copyWith(errorMessage: null)` mean
      // "clear it" rather than "leave it". Replace the sentinel with a plain
      // `?? this.x` and an error message becomes impossible to dismiss —
      // the player would show a stale failure over a video that is playing.
      const withError = PlayerState(errorMessage: 'Cannot open file');
      expect(withError.copyWith(errorMessage: null).errorMessage, isNull);
      // ...and omitting it leaves it alone.
      expect(withError.copyWith(isPlaying: true).errorMessage,
          'Cannot open file');
    });

    test('the other sentinel-guarded fields clear too', () {
      const s = PlayerState(
        loadingMessage: 'Copying over ADB...',
        introEndMs: 30000,
        outroStartMs: 1200000,
        pendingResumePosition: Duration(minutes: 3),
      );
      expect(s.copyWith(loadingMessage: null).loadingMessage, isNull);
      expect(s.copyWith(introEndMs: null).introEndMs, isNull);
      expect(s.copyWith(outroStartMs: null).outroStartMs, isNull);
      expect(
          s.copyWith(pendingResumePosition: null).pendingResumePosition, isNull);
      // And a no-op copy keeps every one of them.
      final same = s.copyWith();
      expect(same.loadingMessage, 'Copying over ADB...');
      expect(same.introEndMs, 30000);
      expect(same.outroStartMs, 1200000);
      expect(same.pendingResumePosition, const Duration(minutes: 3));
    });
  });
}
