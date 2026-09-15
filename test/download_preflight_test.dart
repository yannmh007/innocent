import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/downloader/domain/download_preflight.dart';

/// The two questions asked before a download starts.
///
/// Worth testing because the bug this code fixes was not in the logic — it was
/// that three of the four start paths never asked. So the tests below pin the
/// DECISION, and the fix that matters (who calls it) is pinned by the call
/// sites themselves. What these catch is the decision quietly changing shape
/// underneath those four callers.
void main() {
  const int gb = 1024 * 1024 * 1024;

  group('metered', () {
    test('warns when Wi-Fi only is on and the link is metered', () {
      expect(
        decidePreflight(
          wifiOnly: true,
          online: true,
          unmetered: false,
          freeBytes: 64 * gb,
        ),
        PreflightVerdict.metered,
      );
    });

    test('says nothing when the setting is off', () {
      expect(
        decidePreflight(
          wifiOnly: false,
          online: true,
          unmetered: false,
          freeBytes: 64 * gb,
        ),
        PreflightVerdict.clear,
      );
    });

    test('says nothing on an unmetered link', () {
      expect(
        decidePreflight(
          wifiOnly: true,
          online: true,
          unmetered: true,
          freeBytes: 64 * gb,
        ),
        PreflightVerdict.clear,
      );
    });

    test('says nothing while offline', () {
      // Offline is not "on mobile data". The download will fail for its own
      // reasons and the engine will say so; warning about a data bundle that
      // is not being spent would be a second, wrong explanation.
      expect(
        decidePreflight(
          wifiOnly: true,
          online: false,
          unmetered: false,
          freeBytes: 64 * gb,
        ),
        PreflightVerdict.clear,
      );
    });
  });

  group('free space', () {
    test('warns when the file plus the margin would not fit', () {
      expect(
        decidePreflight(
          wifiOnly: false,
          online: true,
          unmetered: true,
          freeBytes: 1 * gb,
          totalBytes: 900 * 1024 * 1024,
        ),
        PreflightVerdict.lowSpace,
      );
    });

    test('the margin is what makes that case fire', () {
      // 900 MB into 1 GB fits on a bare comparison and is refused here. This
      // asserts the margin exists rather than asserting its exact size, so
      // tuning kPreflightSpaceMargin does not break the test — halving it
      // does, which is the point.
      expect(900 * 1024 * 1024 + kPreflightSpaceMargin, greaterThan(1 * gb));
    });

    test('says nothing when it fits comfortably', () {
      expect(
        decidePreflight(
          wifiOnly: false,
          online: true,
          unmetered: true,
          freeBytes: 64 * gb,
          totalBytes: 2 * gb,
        ),
        PreflightVerdict.clear,
      );
    });

    test('an unknown size is not checked', () {
      // A flat playlist read carries no per-entry size. Refusing on a size
      // nobody knows would block every playlist on a nearly-full phone.
      expect(
        decidePreflight(
          wifiOnly: false,
          online: true,
          unmetered: true,
          freeBytes: 1024,
        ),
        PreflightVerdict.clear,
      );
    });

    test('an unknown free space is not checked either', () {
      // freeBytes <= 0 means the platform could not say. No answer is not a
      // reason to warn.
      expect(
        decidePreflight(
          wifiOnly: false,
          online: true,
          unmetered: true,
          freeBytes: -1,
          totalBytes: 500 * gb,
        ),
        PreflightVerdict.clear,
      );
    });
  });

  test('metered is reported first when both apply', () {
    // Deliberate ordering: a person told "not enough space" who frees some and
    // retries would otherwise meet the data warning second, having already
    // decided twice. The one that costs money goes first.
    expect(
      decidePreflight(
        wifiOnly: true,
        online: true,
        unmetered: false,
        freeBytes: 1 * gb,
        totalBytes: 900 * 1024 * 1024,
      ),
      PreflightVerdict.metered,
    );
  });
}
