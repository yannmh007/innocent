// Tests for when the quiet "an update is available" notice may go out.
// Step 6 of docs/updater_plan.md, §4A.
//
// THE TWO RULES THAT NEEDED PROVING, both named in the brief:
//
//   1. A DISMISSED VERSION MUST NOT NOTIFY. "Not now" in the step 5 dialog is
//      an answer, and an answer the user then has to swipe out of their shade
//      is not an answer at all — it is the same prompt wearing a different
//      coat. This is the rule that makes the notification trustworthy enough
//      to leave switched on.
//
//   2. THE 24-HOUR THROTTLE, and here it is PER VERSION. A notice about 321
//      that has sat in the shade since yesterday must not be re-posted; 322 is
//      news and must not be silenced by 321 having been announced.
//
// The logic under test is the same pure function step 5 uses, with every input
// passed in and the clock among them, so both are checked exactly rather than
// by waiting a day.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/updater/data/update_prompt_store.dart';
import 'package:innocent/features/updater/domain/app_release.dart';
import 'package:innocent/features/updater/domain/update_prompt_decision.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The installed build every test compares against.
const int installed = 320;

AppRelease release(int versionCode, {int? bytes}) => AppRelease(
      versionName: '1.64.$versionCode',
      versionCode: versionCode,
      apkBytes: bytes,
      notesEn: 'Something changed.',
    );

final DateTime now = DateTime(2026, 9, 7, 12);

bool shouldNotify({
  AppRelease? forRelease,
  int? dismissed,
  int? notifiedVersion,
  DateTime? lastNotifiedAt,
  bool busy = false,
}) {
  return UpdatePromptDecision.shouldNotify(
    release: forRelease ?? release(321),
    installedBuild: installed,
    dismissedVersionCode: dismissed,
    notifiedVersionCode: notifiedVersion,
    lastNotifiedAt: lastNotifiedAt,
    now: now,
    busy: busy,
  );
}

void main() {
  group('a dismissed version does not notify', () {
    test('nothing dismissed, nothing notified yet — it goes out', () {
      expect(shouldNotify(), isTrue);
    });

    test('dismissing 321 silences the notice for 321', () {
      // The rule the whole step turns on: the dialog and the shade must not
      // disagree about an answer the user already gave.
      expect(shouldNotify(forRelease: release(321), dismissed: 321), isFalse);
    });

    test('dismissing 320 does NOT silence 321', () {
      expect(shouldNotify(forRelease: release(321), dismissed: 320), isTrue);
    });

    test('dismissing 321 does not silence 322, 400 or anything above', () {
      for (final code in [322, 330, 400, 999]) {
        expect(
          shouldNotify(forRelease: release(code), dismissed: 321),
          isTrue,
          reason: 'version $code should still notify after dismissing 321',
        );
      }
    });

    test('a rollback below the dismissed build stays silent', () {
      expect(shouldNotify(forRelease: release(321), dismissed: 322), isFalse);
    });

    test('a dismissal outranks a clear throttle', () {
      // Every other condition says "post it"; the dismissal alone must not be
      // enough to be overridden by an elapsed clock.
      expect(
        shouldNotify(
          forRelease: release(321),
          dismissed: 321,
          notifiedVersion: null,
          lastNotifiedAt: null,
        ),
        isFalse,
      );
    });
  });

  group('the 24-hour throttle, per version', () {
    test('never notified before — it goes out', () {
      expect(shouldNotify(notifiedVersion: null, lastNotifiedAt: null), isTrue);
    });

    test('the same version one minute ago is too soon', () {
      expect(
        shouldNotify(
          notifiedVersion: 321,
          lastNotifiedAt: now.subtract(const Duration(minutes: 1)),
        ),
        isFalse,
      );
    });

    test('the same version 23h59m ago is still too soon', () {
      expect(
        shouldNotify(
          notifiedVersion: 321,
          lastNotifiedAt: now.subtract(const Duration(hours: 23, minutes: 59)),
        ),
        isFalse,
      );
    });

    test('exactly 24h is enough', () {
      expect(
        shouldNotify(
          notifiedVersion: 321,
          lastNotifiedAt: now.subtract(const Duration(hours: 24)),
        ),
        isTrue,
      );
    });

    test('a NEWER version notifies inside the window', () {
      // The per-version half. 321 was announced ten minutes ago; 322 is a
      // different build the user has never been told about, and the clock from
      // the previous one says nothing about it.
      expect(
        shouldNotify(
          forRelease: release(322),
          notifiedVersion: 321,
          lastNotifiedAt: now.subtract(const Duration(minutes: 10)),
        ),
        isTrue,
      );
    });

    test('a timestamp in the future does not mute the notice forever', () {
      // Only a clock that moved backwards produces one. Treating it as recent
      // would silence updates until real time caught up.
      expect(
        shouldNotify(
          notifiedVersion: 321,
          lastNotifiedAt: now.add(const Duration(days: 365)),
        ),
        isTrue,
      );
    });
  });

  group('nothing worth saying', () {
    test('no release published', () {
      expect(
        UpdatePromptDecision.shouldNotify(
          release: null,
          installedBuild: installed,
          dismissedVersionCode: null,
          notifiedVersionCode: null,
          lastNotifiedAt: null,
          now: now,
          busy: false,
        ),
        isFalse,
      );
    });

    test('the server build equals the installed one', () {
      expect(shouldNotify(forRelease: release(installed)), isFalse);
    });

    test('the server build is older than the installed one', () {
      expect(shouldNotify(forRelease: release(installed - 1)), isFalse);
    });
  });

  group('busy', () {
    test('never notifies during playback, a download or a transfer', () {
      expect(shouldNotify(busy: true), isFalse);
    });

    test('busy wins even when everything else says post it', () {
      expect(
        shouldNotify(
          forRelease: release(999),
          dismissed: null,
          notifiedVersion: null,
          lastNotifiedAt: null,
          busy: true,
        ),
        isFalse,
      );
    });
  });

  group('the shade line', () {
    test('carries the version and the size', () {
      expect(release(321, bytes: 88000000).headline, '1.64.321 (321)  ·  88 MB');
    });

    test('drops the size when none is published', () {
      expect(release(321).headline, '1.64.321 (321)');
    });
  });

  group('the store', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    const store = UpdatePromptStore();

    test('remembers no notice before one is posted', () async {
      expect(await store.notifiedVersionCode(), isNull);
      expect(await store.lastNotifiedAt(), isNull);
    });

    test('a posted notice round-trips', () async {
      final at = DateTime(2026, 9, 7, 8, 30, 15);
      await store.recordNotified(321, at);
      expect(await store.notifiedVersionCode(), 321);
      expect(await store.lastNotifiedAt(), at);
    });

    test('a later version replaces the recorded one', () async {
      await store.recordNotified(321, now.subtract(const Duration(hours: 1)));
      await store.recordNotified(322, now);
      expect(await store.notifiedVersionCode(), 322);
      expect(await store.lastNotifiedAt(), now);
    });

    test('a stored notice drives the throttle end to end', () async {
      await store.recordNotified(321, now.subtract(const Duration(hours: 3)));
      final version = await store.notifiedVersionCode();
      final at = await store.lastNotifiedAt();

      // Same version, inside the window: silent.
      expect(
        shouldNotify(
          forRelease: release(321),
          notifiedVersion: version,
          lastNotifiedAt: at,
        ),
        isFalse,
      );
      // A newer one, same window: news.
      expect(
        shouldNotify(
          forRelease: release(322),
          notifiedVersion: version,
          lastNotifiedAt: at,
        ),
        isTrue,
      );
    });

    test('a stored dismissal silences the notice end to end', () async {
      await store.recordDismissed(321);
      final dismissed = await store.dismissedVersionCode();

      expect(
        shouldNotify(forRelease: release(321), dismissed: dismissed),
        isFalse,
      );
      expect(
        shouldNotify(forRelease: release(322), dismissed: dismissed),
        isTrue,
      );
    });

    test('the permission is only ever asked for once', () async {
      expect(await store.notificationPermissionAsked(), isFalse);
      await store.recordNotificationPermissionAsked();
      expect(await store.notificationPermissionAsked(), isTrue);
    });
  });
}
