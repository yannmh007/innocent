import 'dart:async';
import 'dart:collection';
import 'dart:io';

/// A tiny async semaphore that caps how many expensive jobs run at once.
///
/// The media library does two kinds of CPU-heavy work on demand while the
/// user scrolls: generating video thumbnails (a native `MediaMetadataRetriever`
/// decode, one background thread PER request on the Android side) and pulling
/// embedded album art out of audio files (a `compute` isolate per song). With
/// no ceiling, flinging through a large folder fires dozens of these at once —
/// every visible tile asks for its image simultaneously — and the device pegs
/// the CPU, drops frames, and on weaker phones can ANR.
///
/// This limiter keeps a fixed number of jobs in flight and queues the rest, so
/// throughput stays high WITHOUT flooding the machine. Callers wrap the heavy
/// bit in [run]; cache hits should be checked BEFORE calling so they never
/// queue behind a decode.
class ConcurrencyLimiter {
  final int maxConcurrent;
  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  ConcurrencyLimiter(int maxConcurrent)
      : maxConcurrent = maxConcurrent < 1 ? 1 : maxConcurrent;

  /// Run [task] once a slot is free, releasing the slot when it finishes
  /// (whether it succeeds or throws). The task's result/exception is passed
  /// straight through to the caller.
  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // Hand the slot straight to the next waiter — _active stays the same.
      _waiters.removeFirst().complete();
    } else {
      _active--;
    }
  }
}

/// Pick a sensible parallelism for on-demand media decoding based on the
/// device. We use roughly half the CPU cores so the UI thread, audio, and
/// whatever else the phone is doing keep headroom, clamped to a safe 2..4
/// band: below 2 stalls scrolling, above 4 gives diminishing returns while
/// raising the odds of a thermal/CPU spike on mid-range hardware. Reading
/// the core count (rather than a hard-coded number) is the adaptation that
/// matters here — an 8-core flagship gets 4, a 4-core budget phone gets 2 —
/// without the fragility of trying to "learn" a limit at runtime.
int adaptiveMediaConcurrency({int min = 2, int max = 4}) {
  int cores;
  try {
    cores = Platform.numberOfProcessors;
  } catch (_) {
    cores = 4; // conservative default if the platform won't say
  }
  final half = cores ~/ 2;
  if (half < min) return min;
  if (half > max) return max;
  return half;
}
