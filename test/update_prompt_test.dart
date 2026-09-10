// Tests for when the update prompt may interrupt someone.
// Step 5 of docs/updater_plan.md, §4B.
//
// THE TWO RULES THAT NEEDED PROVING:
//
//   1. PER-VERSION DISMISSAL. "Not now" on 320 must silence 320 and nothing
//      else. If it silenced everything after it, the one prompt the user
//      declined would quietly turn into a permanent opt-out of every future
//      release — which is indistinguishable, from the outside, from an
//      updater that stopped working.
//
//   2. THE 24-HOUR THROTTLE. An app is resumed dozens of times a day. Without
//      the throttle §4B's "on resume" would mean "on every resume", which is
//      the behaviour §3 exists to prevent.
//
// Both are pure functions of explicit inputs, clock included, so they are
// tested exactly rather than by waiting a day.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/updater/data/update_prompt_store.dart';
import 'package:innocent/features/updater/domain/app_release.dart';
import 'package:innocent/features/updater/domain/update_prompt_decision.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The installed build every test compares against.
const int installed = 320;

AppRelease release(int versionCode) => AppRelease(
      versionName: '1.64.$versionCode',
      versionCode: versionCode,
      notesEn: 'Something changed.',
    );

final DateTime now = DateTime(2026, 9, 6, 12);

bool shouldPrompt({
  AppRelease? forRelease,
  int? dismissed,
  DateTime? lastPromptAt,
  bool busy = false,
  DateTime? at,
}) {
  return UpdatePromptDecision.shouldPrompt(
    release: forRelease ?? release(321),
    installedBuild: installed,
    dismissedVersionCode: dismissed,
    lastPromptAt: lastPromptAt,
    now: at ?? now,
    busy: busy,
  );
}

void main() {
  group('per-version dismissal', () {
    test('a newer build prompts when nothing was dismissed', () {
      expect(shouldPrompt(), isTrue);
    });

    test('dismissing 321 silences 321', () {
      expect(shouldPrompt(forRelease: release(321), dismissed: 321), isFalse);
    });

    test('dismissing 320 does NOT silence 321', () {
      // The rule this whole step turns on. A declined prompt is an answer
      // about one build, not a standing instruction.
      expect(shouldPrompt(forRelease: release(321), dismissed: 320), isTrue);
    });

    test('dismissing 321 does not silence 322, 400 or anything above', () {
      for (final code in [322, 330, 400, 999]) {
        expect(
          shouldPrompt(forRelease: release(code), dismissed: 321),
          isTrue,
          reason: 'version $code should still prompt after dismissing 321',
        );
      }
    });

    test('a manifest that rolls back below the dismissed build stays silent',
        () {
      // 322 was declined; the server then re-advertises 321. The user has
      // already said no to something at least that new.
      expect(shouldPrompt(forRelease: release(321), dismissed: 322), isFalse);
    });
  });

  group('the 24-hour throttle', () {
    test('no previous prompt means it may show', () {
      expect(shouldPrompt(lastPromptAt: null), isTrue);
    });

    test('one minute ago is too soon', () {
      expect(
        shouldPrompt(lastPromptAt: now.subtract(const Duration(minutes: 1))),
        isFalse,
      );
    });

    test('23h59m is still too soon', () {
      expect(
        shouldPrompt(
          lastPromptAt: now.subtract(const Duration(hours: 23, minutes: 59)),
        ),
        isFalse,
      );
    });

    test('exactly 24h is enough', () {
      expect(
        shouldPrompt(lastPromptAt: now.subtract(const Duration(hours: 24))),
        isTrue,
      );
    });

    test('a week later certainly is', () {
      expect(
        shouldPrompt(lastPromptAt: now.subtract(const Duration(days: 7))),
        isTrue,
      );
    });

    test('a timestamp in the future does not mute the prompt forever', () {
      // Only a clock that moved backwards can produce this. Treating it as
      // "recent" would silence updates until real time caught up.
      expect(
        shouldPrompt(lastPromptAt: now.add(const Duration(days: 365))),
        isTrue,
      );
    });

    test('the throttle applies even to a version never dismissed', () {
      expect(
        shouldPrompt(
          dismissed: null,
          lastPromptAt: now.subtract(const Duration(hours: 2)),
        ),
        isFalse,
      );
    });
  });

  group('nothing to say', () {
    test('no release published', () {
      // Called directly, not through the helper: the helper defaults a missing
      // release to 321, so passing null there would silently test 321 instead
      // of the empty-table case. It did, until this comment existed.
      expect(
        UpdatePromptDecision.shouldPrompt(
          release: null,
          installedBuild: installed,
          dismissedVersionCode: null,
          lastPromptAt: null,
          now: now,
          busy: false,
        ),
        isFalse,
      );
    });

    test('the server build equals the installed one', () {
      expect(shouldPrompt(forRelease: release(installed)), isFalse);
    });

    test('the server build is older than the installed one', () {
      expect(shouldPrompt(forRelease: release(installed - 1)), isFalse);
    });
  });

  group('busy', () {
    test('never interrupts a download, transfer or playback', () {
      expect(shouldPrompt(busy: true), isFalse);
    });

    test('busy wins even when everything else says show', () {
      expect(
        shouldPrompt(
          forRelease: release(999),
          dismissed: null,
          lastPromptAt: null,
          busy: true,
        ),
        isFalse,
      );
    });
  });

  group('mayCheckNow — the pre-network gate', () {
    test('lets a first check through', () {
      expect(
        UpdatePromptDecision.mayCheckNow(
          lastCheckedAt: null,
          now: now,
          busy: false,
        ),
        isTrue,
      );
    });

    test('blocks inside the window, so no manifest is fetched at all', () {
      // The point of the split: thirty resumes a day must not be thirty
      // requests.
      expect(
        UpdatePromptDecision.mayCheckNow(
          lastCheckedAt: now.subtract(const Duration(hours: 1)),
          now: now,
          busy: false,
        ),
        isFalse,
      );
    });

    test('blocks while busy', () {
      expect(
        UpdatePromptDecision.mayCheckNow(
          lastCheckedAt: null,
          now: now,
          busy: true,
        ),
        isFalse,
      );
    });
  });

  group('two clocks: requests and interruptions', () {
    // THE BUG THIS GROUP EXISTS FOR. mayCheckNow and shouldPrompt used to read
    // the same stored value — the time a dialog was last SHOWN. That value is
    // written only when a dialog actually appears, so the one state almost
    // every user is in almost all of the time (up to date, nothing to show)
    // never wrote anything, and the app re-fetched the manifest on every
    // single resume. §3's first rule, broken by the state it most applies to.

    test('a recent CHECK stops the fetch even though no dialog ever showed',
        () {
      // The regression, stated directly: nothing shown, so lastShownAt is
      // null; but the server answered an hour ago, so there is nothing to ask.
      expect(
        UpdatePromptDecision.mayCheckNow(
          lastCheckedAt: now.subtract(const Duration(hours: 1)),
          now: now,
          busy: false,
        ),
        isFalse,
        reason: 'an answer an hour old is still an answer',
      );
    });

    test('a recent PROMPT does not stop the fetch', () {
      // The other direction, and it is not symmetric. Having interrupted
      // someone yesterday says nothing about whether the manifest is stale.
      expect(
        UpdatePromptDecision.mayCheckNow(
          lastCheckedAt: null,
          now: now,
          busy: false,
        ),
        isTrue,
      );
    });

    test('a recent CHECK does not suppress a dialog that is due', () {
      // Reading the manifest is not interrupting anyone. A check that just
      // happened must still be allowed to produce the day's one prompt.
      expect(
        UpdatePromptDecision.shouldPrompt(
          release: release(321),
          installedBuild: installed,
          dismissedVersionCode: null,
          lastPromptAt: null,
          now: now,
          busy: false,
        ),
        isTrue,
      );
    });

    test('a recent PROMPT still suppresses the next one', () {
      // §3's cadence as the user feels it, unchanged by the split.
      expect(
        UpdatePromptDecision.shouldPrompt(
          release: release(321),
          installedBuild: installed,
          dismissedVersionCode: null,
          lastPromptAt: now.subtract(const Duration(hours: 2)),
          now: now,
          busy: false,
        ),
        isFalse,
      );
    });
  });

  group('the store', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    const store = UpdatePromptStore();

    test('remembers nothing before anything happens', () async {
      expect(await store.dismissedVersionCode(), isNull);
      expect(await store.lastShownAt(), isNull);
    });

    test('a dismissal round-trips', () async {
      await store.recordDismissed(321);
      expect(await store.dismissedVersionCode(), 321);
    });

    test('the shown time round-trips to the second', () async {
      final at = DateTime(2026, 9, 6, 12, 34, 56);
      await store.recordShown(at);
      expect(await store.lastShownAt(), at);
    });

    test('dismissing an OLDER build never un-silences a newer one', () async {
      await store.recordDismissed(330);
      await store.recordDismissed(321);
      // 321 must not overwrite 330: the decision compares with `<=`, so
      // lowering the stored value would bring back a prompt already declined.
      expect(await store.dismissedVersionCode(), 330);
    });

    test('dismissing a newer build raises the watermark', () async {
      await store.recordDismissed(321);
      await store.recordDismissed(330);
      expect(await store.dismissedVersionCode(), 330);
    });

    test('a stored dismissal drives the decision end to end', () async {
      await store.recordDismissed(321);
      final dismissed = await store.dismissedVersionCode();

      expect(shouldPrompt(forRelease: release(321), dismissed: dismissed),
          isFalse);
      expect(shouldPrompt(forRelease: release(322), dismissed: dismissed),
          isTrue);
    });

    test('the check clock round-trips and is separate from the shown one',
        () async {
      final checked = DateTime(2026, 9, 10, 7, 15, 30);
      await store.recordChecked(checked);
      expect(await store.lastCheckedAt(), checked);
      // Recording a check must not invent a prompt that never happened.
      expect(await store.lastShownAt(), isNull);

      await store.recordShown(now);
      expect(await store.lastCheckedAt(), checked,
          reason: 'showing a dialog must not move the check clock');
    });

    test('a stored check clock gates the fetch end to end', () async {
      // Nothing checked yet: ask.
      expect(
        UpdatePromptDecision.mayCheckNow(
          lastCheckedAt: await store.lastCheckedAt(),
          now: now,
          busy: false,
        ),
        isTrue,
      );

      await store.recordChecked(now.subtract(const Duration(hours: 3)));
      expect(
        UpdatePromptDecision.mayCheckNow(
          lastCheckedAt: await store.lastCheckedAt(),
          now: now,
          busy: false,
        ),
        isFalse,
        reason: 'checked three hours ago — nothing to ask',
      );

      await store.recordChecked(now.subtract(const Duration(hours: 30)));
      expect(
        UpdatePromptDecision.mayCheckNow(
          lastCheckedAt: await store.lastCheckedAt(),
          now: now,
          busy: false,
        ),
        isTrue,
        reason: 'a day and a bit old — ask again',
      );
    });

    test('a stored timestamp drives the throttle end to end', () async {
      await store.recordShown(now.subtract(const Duration(hours: 3)));
      expect(shouldPrompt(lastPromptAt: await store.lastShownAt()), isFalse);

      await store.recordShown(now.subtract(const Duration(hours: 30)));
      expect(shouldPrompt(lastPromptAt: await store.lastShownAt()), isTrue);
    });
  });
}
