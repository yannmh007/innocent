import 'dart:async';
import 'dart:typed_data';

/// Previews for a film on the ladder engine (MediaKitPlayerService
/// .ladderPreview): one request in flight, the newest moment next — and the
/// LAST position always asked for, so the picture is never one a step
/// behind where the drag ended.
class LadderPreviewLoader {
  LadderPreviewLoader(this.fetch, {this.maxInFlight = 1, this.nearest});

  /// A picture already taken near a moment, and the moment it is of — shown
  /// at once while that moment's own is fetched (19 Nov 2026): a finger
  /// that stops where nothing was taken sees the nearest picture there is
  /// within a few seconds (as YouTube's storyboard, a picture every few
  /// seconds), not the last one fetched wherever it was.
  final ({Uint8List bytes, int at})? Function(int seconds)? nearest;

  /// The moment (s) of the picture last handed out, provisional or not.
  int? shownFor;

  /// How many fetches may be on their way at once. Two (19 Nov 2026): when
  /// the finger stops, the picture of where it stopped starts as soon as
  /// one slot is free rather than after the one fetch ahead of it — that
  /// wait was 0.27 s of the median 1.49 s from the finger's stop to its
  /// picture in device lab S1 (44534768953). The newest moment still
  /// replaces any that waited.
  final int maxInFlight;

  /// The picture nearest a moment, or null.
  final Future<Uint8List?> Function(Duration at) fetch;

  /// The two-second fragment last asked for, and its picture once it came.
  int _bucket = -1;
  Uint8List? _last;

  /// Asked for while one was on its way: only the newest is kept.
  int? _next;
  void Function(Uint8List bytes)? _onPicture;
  int _inFlight = 0;
  bool _gone = false;

  /// A picture for [seconds], to [onPicture].
  ///
  /// ONE ON ITS WAY AT A TIME, THE NEWEST NEXT. A request every 150 ms
  /// queued on a fast swipe — seven fetches, each behind the last, the
  /// final picture 1.3-1.5 s late on both real phones (Test Lab run
  /// 40118247783). Now a moment asked for meanwhile replaces the one
  /// before it, and is fetched the moment the line is free: the picture
  /// trails the finger by at most one fetch, and the moments skipped over
  /// cost nothing.
  void request(int seconds, void Function(Uint8List bytes) onPicture) {
    if (_gone) return;
    _onPicture = onPicture;
    if (_inFlight >= maxInFlight) {
      _next = seconds;
      return;
    }
    // One picture per two-second fragment: that is what the ladder holds.
    // Asked again — a new drag where the last one ended — it is given
    // again, not fetched.
    if (seconds ~/ 2 == _bucket) {
      final last = _last;
      if (last != null) {
        scheduleMicrotask(() {
          if (_gone) return;
          shownFor = seconds;
          onPicture(last);
        });
      }
      return;
    }
    final near = nearest?.call(seconds);
    if (near != null && near.at != shownFor) {
      scheduleMicrotask(() {
        if (_gone) return;
        shownFor = near.at;
        onPicture(near.bytes);
      });
    }
    _fetch(seconds);
  }

  void _fetch(int seconds) {
    _inFlight++;
    _bucket = seconds ~/ 2;
    _last = null;
    final bucket = _bucket;
    fetch(Duration(seconds: seconds)).then((bytes) {
      if (_gone || bytes == null) return;
      if (bucket == _bucket) _last = bytes;
      // Shown even when the finger has moved on: the nearest picture there
      // is, until the newer one arrives.
      shownFor = seconds;
      _onPicture?.call(bytes);
    }, onError: (Object _) {}).whenComplete(() {
      _inFlight--;
      if (_gone) return;
      final next = _next;
      _next = null;
      if (next != null && next ~/ 2 != _bucket) _fetch(next);
    });
  }

  void dispose() => _gone = true;
}
