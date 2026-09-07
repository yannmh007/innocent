import 'app_release.dart';

/// Whether the update prompt may appear right now. Step 5 of
/// `docs/updater_plan.md`.
///
/// PURE ON PURPOSE. Every input is passed in — the clock included — so the
/// rules that decide whether to interrupt someone can be tested exactly,
/// without a widget tree, a network, or a twenty-four hour wait. The parts
/// that touch the world (preferences, the manifest, the dialog) live
/// elsewhere and do no deciding.
///
/// §4B: "on resume, on a list screen... Never over the player. Never twice for
/// the same version." §3 sets the cadence. Nothing here forces anything: at
/// this step every prompt is dismissible, and `priority` / `min_supported` are
/// step 7's job.
class UpdatePromptDecision {
  const UpdatePromptDecision._();

  /// §3's cadence. One prompt a day at most, however many times the app is
  /// resumed — and an app is resumed a lot.
  static const Duration throttle = Duration(hours: 24);

  /// The cheap half, answerable without touching the network.
  ///
  /// Called BEFORE the manifest is fetched so a resume inside the quiet window
  /// costs nothing at all: no request, no battery, no data. On a phone that is
  /// opened thirty times a day this is the difference between one fetch and
  /// thirty.
  static bool mayCheckNow({
    required DateTime? lastPromptAt,
    required DateTime now,
    required bool busy,
    Duration throttle = throttle,
  }) {
    // §4B: never while something else is using the screen or the network. An
    // update prompt over a running transfer is an interruption of the thing
    // the user is actually doing.
    if (busy) return false;
    return _throttleElapsed(lastPromptAt: lastPromptAt, now: now, throttle: throttle);
  }

  /// The whole decision, including the release the manifest returned.
  ///
  /// Re-applies [mayCheckNow]'s conditions rather than trusting the caller to
  /// have checked: a fetch takes time, and the user may have started a
  /// download in the meantime.
  static bool shouldPrompt({
    required AppRelease? release,
    required int installedBuild,
    required int? dismissedVersionCode,
    required DateTime? lastPromptAt,
    required DateTime now,
    required bool busy,
    Duration throttle = throttle,
  }) {
    if (!mayCheckNow(
      lastPromptAt: lastPromptAt,
      now: now,
      busy: busy,
      throttle: throttle,
    )) {
      return false;
    }

    if (release == null) return false;
    // Nothing to offer. The screen says "You're on the latest version"; a
    // dialog saying it would be an interruption with no content.
    if (!release.isNewerThan(installedBuild)) return false;

    // PER-VERSION DISMISSAL, the point of this step. "Not now" on 320 silences
    // 320 for good — but 321 is a different build with different notes, and
    // the user has not been asked about it. `<=` rather than `==` so a
    // manifest that rolls BACK to an older build stays silent too; the user
    // already declined something at least that new.
    if (dismissedVersionCode != null &&
        release.versionCode <= dismissedVersionCode) {
      return false;
    }

    return true;
  }

  /// Whether the quiet "an update is available" notice may go out. Step 6.
  ///
  /// SHARES STEP 5's RULES BY CONSTRUCTION, not by being kept in step with
  /// them: the release check and the per-version dismissal below are the same
  /// two lines [shouldPrompt] runs, and [busy] is the same flag from the same
  /// reader. A version the user declined never notifies, which is the point.
  ///
  /// The one difference is the clock. The dialog's throttle is global — one
  /// interruption a day, whatever it is about. The notification's is PER
  /// VERSION: a notice about 321 that has been sitting in the shade for two
  /// days should not be re-posted, but 322 is news and is not made less so by
  /// 321 having been announced yesterday.
  ///
  /// In practice a new version cannot even be discovered inside the window,
  /// because [mayCheckNow] gates the manifest fetch on the dialog's global
  /// throttle. This is the floor under that, not a second cadence.
  static bool shouldNotify({
    required AppRelease? release,
    required int installedBuild,
    required int? dismissedVersionCode,
    required int? notifiedVersionCode,
    required DateTime? lastNotifiedAt,
    required DateTime now,
    required bool busy,
    Duration throttle = throttle,
  }) {
    // §4B and §3.2: a notice arriving mid-film is the same interruption a
    // dialog would be, one row further from the user's thumb.
    if (busy) return false;

    if (release == null) return false;
    if (!release.isNewerThan(installedBuild)) return false;

    if (dismissedVersionCode != null &&
        release.versionCode <= dismissedVersionCode) {
      return false;
    }

    // A different version than the one last announced is always news.
    if (notifiedVersionCode != release.versionCode) return true;

    return _throttleElapsed(
      lastPromptAt: lastNotifiedAt,
      now: now,
      throttle: throttle,
    );
  }

  /// True when enough time has passed since the last prompt.
  ///
  /// A timestamp in the FUTURE counts as elapsed. It can only come from a
  /// clock that moved backwards — a manual change, a timezone fix, a reboot
  /// with a dead RTC — and treating it as "recent" would silence the prompt
  /// until real time caught up, which could be years. The throttle exists to
  /// stop nagging, not to become a permanent mute.
  static bool _throttleElapsed({
    required DateTime? lastPromptAt,
    required DateTime now,
    required Duration throttle,
  }) {
    if (lastPromptAt == null) return true;
    final elapsed = now.difference(lastPromptAt);
    if (elapsed.isNegative) return true;
    return elapsed >= throttle;
  }
}
