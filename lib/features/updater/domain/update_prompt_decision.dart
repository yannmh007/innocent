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
/// the same version." §3 sets the cadence.
///
/// Step 7 added the two columns that change what a prompt may do:
/// [promptStyleFor] reads `priority` and decides only how loud the prompt is,
/// and [isBlocked] reads `min_supported` and is the ONLY function in the app
/// that can refuse to let someone keep using it.
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
  ///
  /// TWO CLOCKS, AND THEY ARE NOT THE SAME ONE. This takes [lastCheckedAt] —
  /// when the app last got an ANSWER out of the server — while [shouldPrompt]
  /// takes `lastPromptAt`, when it last INTERRUPTED someone. They used to be
  /// the same value, and the bug that hid in that is worth remembering: the
  /// shown-time is only written when a dialog actually appears, so a user with
  /// nothing to update never recorded anything, and re-fetched the manifest on
  /// every single resume. The commonest state in the world — up to date — was
  /// the one that cost the most data.
  static bool mayCheckNow({
    required DateTime? lastCheckedAt,
    required DateTime now,
    required bool busy,
    Duration throttle = throttle,
  }) {
    // §4B: never while something else is using the screen or the network. An
    // update prompt over a running transfer is an interruption of the thing
    // the user is actually doing.
    if (busy) return false;
    return _throttleElapsed(
      lastPromptAt: lastCheckedAt,
      now: now,
      throttle: throttle,
    );
  }

  /// The whole decision, including the release the manifest returned.
  ///
  /// [lastPromptAt] IS NOT [mayCheckNow]'s clock. This one throttles
  /// INTERRUPTIONS — §3's "at most once every 24 hours" as the user
  /// experiences it — and is written only when a dialog actually goes up. The
  /// other throttles REQUESTS. Asking the server costs data; asking the user
  /// costs their patience, and the two are spent at different moments.
  ///
  /// Re-checks `busy` rather than trusting the caller: a fetch takes time, and
  /// the user may have started a download in the meantime.
  static bool shouldPrompt({
    required AppRelease? release,
    required int installedBuild,
    required int? dismissedVersionCode,
    required DateTime? lastPromptAt,
    required DateTime now,
    required bool busy,
    Duration throttle = throttle,
  }) {
    if (busy) return false;
    if (!_throttleElapsed(
      lastPromptAt: lastPromptAt,
      now: now,
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
  /// because [mayCheckNow] gates the manifest fetch on its own 24-hour clock.
  /// This is the floor under that, not a second cadence.
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

  /// THE ONLY THING IN THIS APP THAT CAN LOCK SOMEONE OUT. Step 7, §2's
  /// "emergency brake".
  ///
  /// Read this function assuming it is wrong, because the cost of a false
  /// positive is not a bad prompt — it is a person whose media player has
  /// stopped working, possibly on a metered connection with no way to pay for
  /// the download. §2: "Use it almost never."
  ///
  /// It is therefore written as four ways to say NO and exactly one way to say
  /// yes. Every uncertainty — no manifest, an unparsed column, a zero, a
  /// misconfigured row — resolves to false.
  ///
  ///   1. FAIL-OPEN ON SILENCE. A null [release] is every failure the check
  ///      can have: no network, a timeout, a 500, a malformed row, a build
  ///      whose column list the server rejected. None of those are evidence
  ///      about whether this build may run, and treating them as evidence
  ///      would mean a flaky connection can brick the app.
  ///
  ///   2. FAIL-OPEN ON AN UNSET MINIMUM. Null, zero and negative all mean "no
  ///      minimum". Zero is the column's own default, so the overwhelmingly
  ///      common row says exactly that, and null is what [AppRelease] produces
  ///      for anything it could not read as an integer.
  ///
  ///   3. NOTHING BELOW THE LINE. `installedBuild >= min` is the ordinary
  ///      state of every up-to-date install and is checked before anything
  ///      else can go wrong.
  ///
  ///   4. NEVER BLOCK WITH NOWHERE TO GO. This is the guard that matters most
  ///      and the one that is easiest to leave out. If `min_supported` is
  ///      raised above the release actually published — a typo, or a row
  ///      edited before the APK was uploaded — then blocking would strand the
  ///      user permanently: the screen would demand an update that does not
  ///      exist, and no amount of tapping, waiting or reinstalling would clear
  ///      it. So the manifest must offer a build at or above the minimum, and
  ///      that build must be genuinely downloadable ([AppRelease.canDownload]
  ///      — a real https URL and a well-formed hash). A brake with no exit is
  ///      not a brake; it is a wall.
  ///
  /// Note that [release] being newer than [installedBuild] falls out of 3 and
  /// 4 together and is not checked separately: if `installed < min <=
  /// release.versionCode` then the release is newer by arithmetic.
  static bool isBlocked({
    required AppRelease? release,
    required int installedBuild,
  }) {
    // 1 — silence is not evidence.
    if (release == null) return false;

    // 2 — no minimum set.
    final min = release.minSupported;
    if (min == null || min <= 0) return false;

    // 3 — at or above the line.
    if (installedBuild >= min) return false;

    // 4 — and there has to be somewhere to go.
    if (release.versionCode < min) return false;
    if (!release.canDownload) return false;

    return true;
  }

  /// How loudly the prompt for [release] should speak. Step 7, §2's priority
  /// table.
  ///
  /// PRESENTATION ONLY. Nothing this returns can make a prompt
  /// un-dismissible: every style below keeps "Not now", and the dismissal it
  /// records is the same per-version one step 5 built. §2 puts urgency and
  /// "may this build keep running" in two different columns precisely because
  /// they are two different questions, and only [isBlocked] answers the
  /// second.
  ///
  /// An absent or out-of-range priority falls back to [UpdatePromptStyle.
  /// standard] — the column's own default of 3, and the behaviour every
  /// release before step 7 already had. A server that says something
  /// unexpected must not change how the app behaves.
  static UpdatePromptStyle promptStyleFor(AppRelease? release) {
    final p = release?.priority;
    if (p == null) return UpdatePromptStyle.standard;
    switch (p) {
      case 1:
        return UpdatePromptStyle.silent;
      case 2:
        return UpdatePromptStyle.quiet;
      case 4:
      case 5:
        return UpdatePromptStyle.urgent;
      case 3:
        return UpdatePromptStyle.standard;
      default:
        return UpdatePromptStyle.standard;
    }
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

/// How prominent an update prompt is allowed to be. Step 7, §2's priority
/// table, and nothing more than presentation.
///
/// EVERY ONE OF THESE IS DISMISSIBLE. The ladder changes which surfaces speak
/// and how hard the dialog is to wave away by accident; it never changes
/// whether the user may say no. `min_supported` is the only column that can do
/// that, and it is read by [UpdatePromptDecision.isBlocked] alone.
enum UpdatePromptStyle {
  /// priority 1 — "Settings only, no prompt". Nothing goes to the user; the
  /// App update screen still shows the release, as it always does.
  silent,

  /// priority 2 — "banner only". The shade notice, but no dialog: worth
  /// knowing about, not worth interrupting for.
  quiet,

  /// priority 3 — the default, and what every release before step 7 got: the
  /// notice and a dialog the user can wave away by tapping outside it.
  standard,

  /// priority 4-5 — "important" and "critical". The same dialog with the same
  /// two buttons, except a stray tap on the barrier no longer counts as an
  /// answer: the user has to actually choose. Harder to miss, exactly as
  /// dismissible.
  urgent;

  /// Whether the on-resume dialog may open at all.
  bool get showsDialog => this != silent && this != quiet;

  /// Whether the shade notice may be posted.
  bool get showsNotification => this != silent;

  /// Whether a tap outside the dialog counts as "Not now".
  ///
  /// False only at [urgent], and this is the ONE behavioural difference
  /// priority is allowed to make. The "Not now" button is present at every
  /// level; this decides whether a stray tap is treated as pressing it.
  bool get barrierDismissible => this != urgent;
}
