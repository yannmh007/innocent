/// The two questions asked before a download starts, and nothing else.
///
/// WHY THIS IS ITS OWN FILE. These checks lived inside `_QualitySheetState`,
/// which meant they only ran for downloads started from the quality sheet.
/// The other three ways to start one — the quick-quality preset, the playlist
/// sheet, and a pick made inside the in-app browser — went straight to the
/// engine. A user who had switched "Wi-Fi only" on could queue a forty-item
/// playlist over mobile data without a word, and the free-space check had the
/// same hole in the same three places. See `docs/audit_downloader.md` F1/F2.
///
/// The decision is deliberately a PURE FUNCTION over plain values: no
/// BuildContext, no provider, no platform channel. That is what lets the
/// browser path — which has no widget tree in front of it — ask the same
/// question the sheets ask, and what makes it testable without a device.
library;

/// What the pre-flight decided. Never a hard refusal: every caller offers a
/// way through, because the person asking has a reason and the check is a
/// warning, not a policy.
enum PreflightVerdict {
  /// Nothing to say. Start the download.
  clear,

  /// "Wi-Fi only" is on and this connection is metered.
  metered,

  /// The download would not comfortably fit.
  lowSpace,
}

/// Headroom demanded on top of the download's own size.
///
/// A margin, not a bare comparison: finishing with nothing left over is its
/// own kind of failure, and the size the extractor reports is often an
/// estimate anyway.
const int kPreflightSpaceMargin = 200 * 1024 * 1024;

/// Decide, from facts alone.
///
/// [totalBytes] is null when nothing knows the size yet — a playlist of
/// entries that have not been probed, most commonly. A size nobody knows
/// cannot be checked against free space, so that arm simply does not fire;
/// the metered question is still worth asking and still is.
///
/// [freeBytes] of zero or less means the platform could not say. Treated the
/// same way: no answer is not a reason to warn.
///
/// Metered is checked FIRST because it is the one that costs money. A person
/// told "not enough space" who then frees some and retries would otherwise
/// meet the data warning second, having already decided twice.
PreflightVerdict decidePreflight({
  required bool wifiOnly,
  required bool online,
  required bool unmetered,
  required int freeBytes,
  int? totalBytes,
}) {
  if (wifiOnly && online && !unmetered) return PreflightVerdict.metered;
  if (totalBytes != null && totalBytes > 0 && freeBytes > 0) {
    if (totalBytes + kPreflightSpaceMargin > freeBytes) {
      return PreflightVerdict.lowSpace;
    }
  }
  return PreflightVerdict.clear;
}
