// Tests for the one thing in this app that can lock a user out.
// Step 7 of docs/updater_plan.md, §2's "emergency brake".
//
// WHY THESE ARE THE MOST IMPORTANT TESTS IN THE UPDATER. Every other failure
// in this feature costs someone a wasted tap or a missed release. This one
// costs them their media player, possibly on a metered connection with no way
// to pay for the download that would fix it. §2: "Use it almost never."
//
// UpdatePromptDecision.isBlocked is therefore written as four ways to say no
// and one way to say yes, and there is a test here for each of them —
// including the guard that is easiest to leave out and worst to get wrong:
// never block when the manifest offers nothing to update TO.
//
// Priority is tested alongside because the two columns are constantly confused
// and the whole point of step 7 is that they are not the same: priority
// changes how loud a prompt is and can never make one un-dismissible.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/updater/domain/app_release.dart';
import 'package:innocent/features/updater/domain/update_prompt_decision.dart';

/// The installed build every test compares against.
const int installed = 320;

/// A well-formed, genuinely downloadable release. `canDownload` is part of the
/// fourth guard, so the happy-path fixture has to satisfy it or the tests
/// would pass for the wrong reason.
const String goodSha =
    'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2';

AppRelease release({
  int versionCode = 330,
  int? minSupported,
  int? priority,
  String? apkUrl = 'https://example.com/innocent.apk',
  String? apkSha256 = goodSha,
}) =>
    AppRelease(
      versionName: '1.65.0',
      versionCode: versionCode,
      apkUrl: apkUrl,
      apkSha256: apkSha256,
      apkBytes: 88000000,
      minSupported: minSupported,
      priority: priority,
    );

bool blocked(AppRelease? r) =>
    UpdatePromptDecision.isBlocked(release: r, installedBuild: installed);

void main() {
  group('guard 1 — a manifest that did not arrive never blocks', () {
    test('no release at all', () {
      // Every failure the check can have arrives here as null: no network, a
      // timeout, a 500, a malformed row, a column the server rejected. None of
      // them is evidence about whether this build may run.
      expect(blocked(null), isFalse);
    });

    test('a malformed row parses to null, and null does not block', () {
      // The parse is the first guard: a row the client cannot read is a row it
      // must not act on. A version_code that is not an int is exactly the
      // typo a hand-edited SQL row produces.
      expect(AppRelease.fromJson(<String, dynamic>{}), isNull);
      expect(
        AppRelease.fromJson(<String, dynamic>{
          'version_name': '1.65.0',
          'version_code': '330', // a string, not an int
          'min_supported': 999,
        }),
        isNull,
      );
      expect(blocked(AppRelease.fromJson(<String, dynamic>{})), isFalse);
    });

    test('min_supported that is not an integer is dropped, not coerced', () {
      // '999' must NOT become 999. Coercing a string here would let a typo in
      // the SQL editor lock every install out of the app.
      for (final bad in <Object?>['999', 999.0, true, null, <int>[999]]) {
        final r = AppRelease.fromJson(<String, dynamic>{
          'version_name': '1.65.0',
          'version_code': 330,
          'apk_url': 'https://example.com/innocent.apk',
          'apk_sha256': goodSha,
          'min_supported': bad,
        });
        expect(r, isNotNull, reason: 'the row itself is still readable');
        expect(r!.minSupported, isNull, reason: 'min_supported was $bad');
        expect(blocked(r), isFalse, reason: 'min_supported was $bad');
      }
    });

    test('an absent min_supported column does not block', () {
      // What an older schema, or a build reading a row it did not ask for,
      // actually looks like: the key simply is not there.
      final r = AppRelease.fromJson(<String, dynamic>{
        'version_name': '1.65.0',
        'version_code': 330,
        'apk_url': 'https://example.com/innocent.apk',
        'apk_sha256': goodSha,
      });
      expect(r!.minSupported, isNull);
      expect(blocked(r), isFalse);
    });
  });

  group('guard 2 — an unset minimum never blocks', () {
    test('null does not block', () {
      expect(blocked(release(minSupported: null)), isFalse);
    });

    test('zero does not block, and zero is the column default', () {
      // migration 012: `min_supported int not null default 0`. The
      // overwhelmingly common row says exactly this, so it is the case that
      // must never block.
      expect(blocked(release(minSupported: 0)), isFalse);
    });

    test('a negative does not block', () {
      expect(blocked(release(minSupported: -1)), isFalse);
      expect(blocked(release(minSupported: -999)), isFalse);
    });

    test('"unset" is checked in its own right, not left to guard 3', () {
      // FOUND BY MUTATION TESTING. Deleting `min <= 0` from guard 2 broke
      // nothing above, because guard 3 (installed >= min) masks it for every
      // real build number — 320 is above 0 and above any negative, so the row
      // never reaches the blocking branch anyway.
      //
      // The check is kept in the code regardless: "0 means no minimum" is the
      // column's documented meaning (migration 012 defaults it to 0), not an
      // accident of arithmetic. So it is pinned here at the only inputs that
      // can tell the two readings apart, and a future reordering of the
      // guards that would turn "unset" into "block everyone" now fails.
      expect(
        UpdatePromptDecision.isBlocked(
          release: release(versionCode: 330, minSupported: 0),
          installedBuild: -1,
        ),
        isFalse,
        reason: '0 means unset, whatever it is compared against',
      );
      expect(
        UpdatePromptDecision.isBlocked(
          release: release(versionCode: 330, minSupported: -5),
          installedBuild: -10,
        ),
        isFalse,
        reason: 'a negative minimum is not a minimum',
      );
    });
  });

  group('guard 3 — at or above the line never blocks', () {
    test('installed exactly at the minimum', () {
      // The boundary, and the direction that matters: `>=` not `>`. Blocking
      // someone who is precisely at the minimum would be off by one release.
      expect(blocked(release(minSupported: installed)), isFalse);
    });

    test('installed above the minimum', () {
      expect(blocked(release(minSupported: installed - 1)), isFalse);
      expect(blocked(release(minSupported: 1)), isFalse);
    });
  });

  group('guard 4 — never block with nowhere to go', () {
    test('a minimum above the published release does NOT block', () {
      // THE GUARD THAT MATTERS MOST. A typo raising min_supported past the
      // release actually published would otherwise demand an update that does
      // not exist — permanently, with no tap, wait or reinstall that clears
      // it.
      expect(
        blocked(release(versionCode: 330, minSupported: 400)),
        isFalse,
        reason: 'nothing to update to: 330 is below the demanded 400',
      );
    });

    test('the release exactly at the minimum DOES block', () {
      // The other side of the same boundary: 330 satisfies a minimum of 330,
      // so there is somewhere to go and the brake may apply.
      expect(blocked(release(versionCode: 330, minSupported: 330)), isTrue);
    });

    test('no apk_url does not block', () {
      // The row was edited before the APK was uploaded. Real, and the first
      // way a well-meant brake strands people.
      expect(
        blocked(release(minSupported: 325, apkUrl: null)),
        isFalse,
      );
    });

    test('no apk_sha256 does not block', () {
      // An unverifiable APK is one this app will never install, so demanding
      // it would be demanding the impossible.
      expect(
        blocked(release(minSupported: 325, apkSha256: null)),
        isFalse,
      );
    });

    test('a malformed hash does not block', () {
      expect(blocked(release(minSupported: 325, apkSha256: 'deadbeef')), isFalse);
      expect(
        blocked(release(minSupported: 325, apkSha256: goodSha.toUpperCase())),
        isFalse,
      );
    });

    test('a non-https url does not block', () {
      expect(
        blocked(release(
          minSupported: 325,
          apkUrl: 'http://example.com/innocent.apk',
        )),
        isFalse,
      );
    });
  });

  group('the one way to say yes', () {
    test('below the minimum with a downloadable target DOES block', () {
      expect(
        blocked(release(versionCode: 330, minSupported: 325)),
        isTrue,
      );
    });

    test('one build below the minimum is still below it', () {
      expect(
        blocked(release(versionCode: 330, minSupported: installed + 1)),
        isTrue,
      );
    });

    test('a whole real row, end to end', () {
      final r = AppRelease.fromJson(<String, dynamic>{
        'version_name': '1.65.0',
        'version_code': 330,
        'apk_url': 'https://example.com/innocent.apk',
        'apk_sha256': goodSha,
        'apk_bytes': 88000000,
        'min_supported': 325,
        'priority': 5,
      });
      expect(r, isNotNull);
      expect(r!.minSupported, 325);
      expect(blocked(r), isTrue);
    });
  });

  group('priority changes how loud, never whether', () {
    test('every level keeps the dialog dismissible', () {
      // The rule the whole step turns on: priority is presentation. There is
      // no level at which the user loses the ability to say no.
      for (var p = 1; p <= 5; p++) {
        expect(
          blocked(release(priority: p)),
          isFalse,
          reason: 'priority $p must not block on its own',
        );
      }
    });

    test('even priority 5 with no min_supported does not block', () {
      // §2's own table calls 5 "critical", and it still may not lock anyone
      // out: that is what the separate column is for.
      expect(blocked(release(priority: 5, minSupported: 0)), isFalse);
      expect(blocked(release(priority: 5, minSupported: null)), isFalse);
    });

    test('1 is silent — no dialog, no notice', () {
      final style = UpdatePromptDecision.promptStyleFor(release(priority: 1));
      expect(style, UpdatePromptStyle.silent);
      expect(style.showsDialog, isFalse);
      expect(style.showsNotification, isFalse);
    });

    test('2 is the notice only', () {
      final style = UpdatePromptDecision.promptStyleFor(release(priority: 2));
      expect(style, UpdatePromptStyle.quiet);
      expect(style.showsDialog, isFalse);
      expect(style.showsNotification, isTrue);
    });

    test('3 is the behaviour every release before step 7 had', () {
      final style = UpdatePromptDecision.promptStyleFor(release(priority: 3));
      expect(style, UpdatePromptStyle.standard);
      expect(style.showsDialog, isTrue);
      expect(style.showsNotification, isTrue);
      expect(style.barrierDismissible, isTrue);
    });

    test('4 and 5 are harder to miss, not harder to refuse', () {
      for (final p in [4, 5]) {
        final style = UpdatePromptDecision.promptStyleFor(release(priority: p));
        expect(style, UpdatePromptStyle.urgent);
        expect(style.showsDialog, isTrue);
        expect(style.showsNotification, isTrue);
        // A stray tap outside no longer counts as an answer...
        expect(style.barrierDismissible, isFalse);
      }
    });

    test('an absent or out-of-range priority falls back to standard', () {
      // A server saying something unexpected must not change how the app
      // behaves.
      expect(UpdatePromptDecision.promptStyleFor(release(priority: null)),
          UpdatePromptStyle.standard);
      expect(UpdatePromptDecision.promptStyleFor(null),
          UpdatePromptStyle.standard);
      for (final p in [0, -1, 6, 99]) {
        expect(
          UpdatePromptDecision.promptStyleFor(release(priority: p)),
          UpdatePromptStyle.standard,
          reason: 'priority $p is not in 1..5',
        );
      }
    });

    test('priority does not leak into the step 5 dismissal rules', () {
      // shouldPrompt takes no priority at all, and must keep honouring a
      // dismissal at every level. If urgency could override a dismissal, the
      // server could nag from SQL — which is exactly what §3 forbids.
      for (var p = 1; p <= 5; p++) {
        expect(
          UpdatePromptDecision.shouldPrompt(
            release: release(versionCode: 330, priority: p),
            installedBuild: installed,
            dismissedVersionCode: 330,
            lastPromptAt: null,
            now: DateTime(2026, 9, 7),
            busy: false,
          ),
          isFalse,
          reason: 'priority $p must not resurrect a dismissed version',
        );
      }
    });
  });
}
