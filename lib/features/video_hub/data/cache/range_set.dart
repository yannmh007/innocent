/// Which bytes of a file this phone actually has.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS IS A CLASS OF ITS OWN, WITH TESTS
/// ═══════════════════════════════════════════════════════════════════════
///
/// A cache that streams while it fills does not hold a neat prefix. A viewer
/// opens a film, watches four minutes, drags the bar to the middle, watches
/// two more, then comes back. On disk that is two islands of real data with a
/// hole between them — and the ONE thing this cache must never do is hand a
/// player the hole. Bytes that were never fetched read back as zeros from a
/// sparse file: not an error, not a short read, just silence and a green
/// screen, and the player has no way to tell.
///
/// So every byte served from disk has to be one this says is held, and the
/// arithmetic that decides it is worth testing on its own — without a
/// network, a file or a player. Off-by-one here is a corrupted film.
///
/// HALF-OPEN THROUGHOUT: `[start, end)`. HTTP `Range` is inclusive at both
/// ends and that difference is exactly where an off-by-one lives, so the
/// conversion happens once, at the edge, and never inside this file.
library;

class RangeSet {
  RangeSet([List<List<int>>? ranges]) {
    if (ranges != null) {
      for (final r in ranges) {
        if (r.length == 2) add(r[0], r[1]);
      }
    }
  }

  /// Sorted, non-overlapping, non-touching. Every method below depends on
  /// all three, and [add] is the only thing that may modify it.
  final List<List<int>> _r = <List<int>>[];

  List<List<int>> get ranges =>
      List<List<int>>.unmodifiable(_r.map((e) => List<int>.unmodifiable(e)));

  bool get isEmpty => _r.isEmpty;

  /// Total bytes held. This is what the storage budget is measured in —
  /// NOT the file's length, which for a sparse file counts holes that
  /// occupy no disk at all.
  int get bytes {
    var n = 0;
    for (final r in _r) {
      n += r[1] - r[0];
    }
    return n;
  }

  /// Record that `[start, end)` is now on disk.
  ///
  /// ADJACENT RANGES MERGE, not just overlapping ones. `[0,10)` and `[10,20)`
  /// describe one unbroken run of twenty bytes, and leaving them as two
  /// entries would make [contiguousEndFrom] stop at 10 — the cache would
  /// re-fetch from the network data it already had, forever, at every
  /// boundary between two writes.
  void add(int start, int end) {
    if (end <= start || start < 0) return;
    var lo = start, hi = end;
    var i = 0;
    while (i < _r.length) {
      final r = _r[i];
      if (r[1] < lo) {
        i++;
        continue;
      }
      if (r[0] > hi) break;
      lo = lo < r[0] ? lo : r[0];
      hi = hi > r[1] ? hi : r[1];
      _r.removeAt(i);
    }
    _r.insert(i, <int>[lo, hi]);
  }

  /// How far an unbroken run starting at [from] reaches, or [from] itself
  /// when that byte is not held.
  ///
  /// The single question the server asks: "starting here, how much can I
  /// serve without touching the network?" Returning [from] means "none",
  /// which is the safe answer and the one a caller cannot misread.
  int contiguousEndFrom(int from) {
    for (final r in _r) {
      if (r[0] <= from && from < r[1]) return r[1];
      if (r[0] > from) break;
    }
    return from;
  }

  /// Whether every byte of `[start, end)` is held.
  bool covers(int start, int end) {
    if (end <= start) return true;
    return contiguousEndFrom(start) >= end;
  }

  /// The first byte at or after [from] that is NOT held, or null when the
  /// run reaches [limit].
  ///
  /// Used to decide how much of an upstream fetch is worth writing: past
  /// this point the data is new, before it the write would be redundant.
  int? firstGapFrom(int from, int limit) {
    final end = contiguousEndFrom(from);
    if (end >= limit) return null;
    return end;
  }

  List<List<int>> toJson() => _r.map((r) => <int>[r[0], r[1]]).toList();

  @override
  String toString() => _r.map((r) => '${r[0]}-${r[1]}').join(',');
}
