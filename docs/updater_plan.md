# The in-app updater — plan

Written 2 Sep 2026, against v1.64.5+318.

**STATUS, 4 Sep 2026 — steps 1 and 2 are BUILT, in v1.64.6+319.**
`docs/migrations/012_app_releases.sql` is the server half;
`lib/features/updater/` is the client half. Everything from step 3 down is
still unbuilt. Two deliberate deviations from what is written below, both
explained where they occur: `apk_url` and `apk_sha256` are nullable until an
APK actually exists, and 012 depends on no earlier migration so it can be run
out of order.

The requirement, in your words: a notification and a dialog on an old version;
the user can dismiss it; they can still update whenever they want; and if they
dismissed it, Settings has a way to download the update.

That is exactly the right shape, and it matches what the established practice
calls a **flexible** update. Below is that practice, the one place your
situation differs from every article about it, and the order to build in.

---

## 0. THE DIFFERENCE THAT CHANGES EVERYTHING

Every guide on this subject describes **Google Play's In-App Updates**
(`AppUpdateManager`), where Play downloads and installs and the app only asks.
Two flows: **flexible** (a prompt, background download, app stays usable) and
**immediate** (a full-screen flow that blocks until updated).

**You have no Play Store.** Your own distribution note says it plainly:

> *"The in-app updater is the only distribution channel. Outside Play there is
> no other path."*

So the **UX patterns transfer and the mechanism does not**. You build:
check a manifest → download an APK → verify it → hand it to the system
installer via `REQUEST_INSTALL_PACKAGES`, which the app already holds (today
only for installing an APK someone sent over Transfer).

Everything below is written for that.

---

## 1. THE SAFETY FACT THE WHOLE FEATURE RESTS ON

**Android refuses to install an APK signed with a different key than the one
already installed.** That is not a nicety - it is the only thing standing
between your updater and someone substituting an APK.

Consequences:

* **The signing identity can never change.** `docs/signing_identity.md` records
  the SHA-256 of `innocent.jks`. If that key is ever lost, **every existing
  install is stranded forever** - they cannot update, and the replacement is a
  different app that cannot see their vault.
* **Verify the SHA-256 before installing anyway.** The signature check catches
  substitution; the hash catches a truncated or corrupted download, which on a
  Myanmar mobile connection is the far likelier failure. Installing a truncated
  APK fails confusingly; refusing it and re-downloading does not.
* Ship the expected hash **in the manifest**, not alongside the APK, so a
  tampered file cannot bring its own matching hash.

---

## 2. THE SERVER SIDE — one row

Supabase, one table, edited by hand. No new infrastructure.

```sql
create table public.app_releases (
  id            int primary key default 1 check (id = 1),
  version_name  text not null,      -- '1.65.0'
  version_code  int  not null,      -- 319   ← the client compares THIS
  apk_url       text not null,      -- R2 public bucket
  apk_sha256    text not null,
  apk_bytes     bigint not null,    -- so the client can say "42 MB" first
  min_supported int  not null default 0,  -- below this, force
  priority      int  not null default 3,  -- 1..5, see below
  notes_en      text,
  notes_mm      text,
  released_at   timestamptz not null default now()
);
```

Readable by `anon` - the check has to work before anyone signs in.

### `version_code`, never `version_name`

The client compares the integer. `1.64.5` vs `1.9.0` as strings is a trap that
every project falls into once: `"1.9" > "1.64"` lexically. You already have the
integer - `AppVersion.build` - and it already increments every release.

### `priority` — the server decides urgency, the client decides pixels

Google Play's own model, adapted. **PRIORITY IS PRESENTATION ONLY.** It decides
which surfaces speak and how hard the dialog is to wave away by accident. It
never decides whether the user may say no.

| priority | meaning | this app's behaviour |
|---|---|---|
| 5 | critical | notification + dialog, marked; the barrier is not an answer |
| 4 | important | notification + dialog, marked; the barrier is not an answer |
| 3 | normal | notification + dialog, dismissible by tapping outside (the default) |
| 2 | minor | notification only, no dialog |
| 1 | silent | Settings only; no dialog, and a notification already posted is withdrawn |

**Every level keeps "Not now"**, and the dismissal it records is the per-version
one from step 5 — priority cannot revive a version the user has already
declined. At 4 and 5 the only difference is that a stray tap on the barrier no
longer counts as an answer: harder to MISS, exactly as easy to refuse.

An absent priority, or one outside 1..5, is treated as 3. A server saying
something unexpected must not change how the app behaves.

**The whole point: you change urgency from SQL, with no rebuild.** Ship a build
at priority 2, discover a bad bug, raise it to 5 — everyone still on the old
version gets the loud prompt on their next check.

#### Why priority cannot block, and `min_supported` alone can

An earlier draft of this plan had priority 5 mean "blocking dialog, no dismiss"
and priority 4 mean "blocking after 3 days". **That was wrong, and the code
deliberately does not do it.**

ONE COLUMN, ONE JOB. `priority` is the dial you reach for often — every release
sets it, it is edited by hand in the SQL editor, and a wrong value there is a
typo, not an emergency. `min_supported` is the one you touch almost never, and
touching it is a deliberate act with a deliberate consequence. If urgency could
also block, then a slipped keystroke in the field that gets edited every single
release would lock every install out of the app. Keeping the two apart means the
dangerous power lives only on the column nobody edits casually — and that
column carries four separate guards before it will refuse anyone (see below).

The cost is that a critical release cannot forbid use by itself. That is the
right trade: `min_supported` is right there when a build genuinely must stop
running, and it is one number away.

### `min_supported` — the emergency brake

Separate from priority because it answers a different question: not *how
urgently should they update*, but *may this version keep running at all*. Set
it when a release breaks the API contract or ships something dangerous.
Below it, the app shows an unskippable screen.

**Use it almost never.** A forced update on a metered connection with no Wi-Fi
is an app that simply stops working for that person.

#### The four guards, and why each one exists

The client is written as four ways to say no and one way to say yes. It blocks
ONLY when all four are satisfied; every uncertainty resolves to "not blocked".

1. **The manifest arrived and parsed.** No network, a timeout, a 500, a
   malformed row, a column the server rejected — none of those is evidence
   about whether this build may run, and treating them as evidence would let a
   flaky connection brick the app. A `min_supported` that is not an integer is
   dropped rather than coerced: `'999'` must never become `999`, or a typo
   becomes a lockout.
2. **A minimum is actually set.** Null, `0` and negatives all mean "no
   minimum". `0` is this column's default, so the overwhelmingly common row
   says exactly that.
3. **The installed build is below it.** `installed >= min_supported` is every
   healthy install, and the boundary is inclusive.
4. **There is somewhere to go.** The published `version_code` must be at or
   above the minimum AND that release must be genuinely downloadable — a real
   `https` `apk_url` and a well-formed `apk_sha256`. Raise `min_supported` past
   the release you have actually published and the app would otherwise demand
   an update that does not exist, permanently. A brake with no exit is not a
   brake; it is a wall.

And the screen lets go by itself: it re-reads the manifest on resume and on a
Check now button, and releases on any answer that is not a clear current block
— **a failed fetch included**. Being wrong in that direction costs one
unenforced update. Being wrong in the other costs someone their app, with no
way to reach the thing that would fix it.

Two consequences worth knowing before you use it:

* **It engages within 24h, not instantly.** The block is read from the same
  once-a-day manifest check everything else uses; fetching on every resume
  would cost every user data for a thing that almost never happens. Raise
  `priority` to 5 at the same time for the immediate loud prompt.
* **Turning off the network releases the screen**, by design — see the failed
  fetch above. It re-blocks on the next successful check.

---

## 3. THE CADENCE — what the research actually says

The failure mode is not "too few prompts". It is nagging. Bad prompts raise
churn and support tickets; users conclude the app is broken or their data is at
risk.

**Rules, in order of importance:**

1. **Check at most once every 24 hours**, on resume, never on every launch. A
   version check is a network call; doing it on every cold start costs a
   Myanmar user data for nothing.
2. **Never prompt during playback, a download or a transfer.** A dialog over a
   film is the single most resented thing an app can do. Queue it for the next
   time the user is on a list screen.
3. **Dismissal is remembered PER VERSION.** Dismissing 1.65.0 must not dismiss
   1.66.0. Store `dismissed_version_code`, not a boolean.
4. **Re-prompt at most once per priority step**, and only after a real interval
   (3 days at priority 4, never again at 2-3). One reminder is a reminder; the
   third is nagging.
5. **Name the deadline or the impact, never "Later".** The research is
   unambiguous: vague buttons mean people forget what they postponed. Write
   *"Playback fixes - update by Friday"*, not *"A new version is available"*.
6. **Wi-Fi by default.** Show the size before downloading, and on mobile data
   require a second confirmation naming the megabytes. This is a Myanmar app;
   a 45 MB surprise is real money.

---

## 4. THE THREE SURFACES

### A. Notification — quiet
Only at priority ≥ 2, only once per version (and at most once per 24h for the
same version), low importance channel so it does not buzz. Never for a version
the user has dismissed. Tapping opens the update screen. This is the one your
users will actually see, because they are not in the app when you release.

### B. Dialog — on resume, on a list screen
Title, one line of what changed (`notes_mm` from the server), the size, two
buttons: **Update** and **Not now** — at every priority. Below `min_supported`
there is no dialog at all: that case is the blocking screen, which has only
**Update** and cannot be left.

Never over the player. Never twice for the same version: a dismissal is an
answer about that build, and no priority overrides it.

### C. Settings → App update — always available
The answer to *"what if they dismissed it?"* Shows current version, latest
version, notes, and a **Check now** button. **Never hidden**, even when up to
date - "You're on the latest version (1.64.5)" is a useful thing to be able to
confirm, and it is where someone goes when they suspect the app is stale.

---

## 5. THE DOWNLOAD — where this actually gets hard

The prompt is the easy half. This is the half that fails on a real phone.

* **Resumable.** 45 MB on a flaky connection will be interrupted. HTTP `Range`
  to a `.part` file, rename on completion - **the same pattern already used by
  `PosterCache` and the Transfer receiver.** Reuse it; a half-written APK that
  is renamed only on success can never be installed.
* **Free space first.** `PrivateFolderService.freeSpaceBytes()` exists now
  (v1.64.5). The APK needs its own size plus the installer's working room.
  Refuse up front, as the vault and the receiver both do.
* **Verify SHA-256 before the install intent, always**, including after a
  resume. A resumed download is exactly where a corrupt file comes from.
* **Foreground service or a progress notification.** Android will kill a
  background download of that size.
* **On failure, delete the partial file.** A stale `.part` that a later resume
  appends to produces a hash mismatch that looks like tampering.

---

## 6. FAILURE MODES, AND WHAT THE USER SHOULD SEE

| what happens | what they see |
|---|---|
| No network | nothing. Silence is correct; check again tomorrow |
| Manifest unreachable | nothing. A version check is not worth an error |
| Download interrupted | resumes on its own; a notification only if it fails twice |
| Hash mismatch | *"Download was damaged. Try again."* - never "verification failed", which reads as an accusation |
| Install refused (signature) | *"This update could not be installed. Contact support."* This means the signing key drifted and is a genuine emergency |
| "Install unknown apps" is off | send them straight to that Settings page, and say why |
| Not enough space | the size needed and the size free, as the vault now does |

---

## 7. WHAT NOT TO BUILD

* **No silent auto-install.** It is not possible without device-owner
  privileges, and an app that tried would be indistinguishable from malware.
* **No staged rollout / percentages.** One row, one version. Complexity for a
  user base that does not exist yet.
* **No delta updates.** Full APK each time. Deltas need Play's infrastructure.
* **No "what's new" carousel.** One line from `notes_mm` is enough.

---

## 8. BUILD ORDER

1. `app_releases` table + `anon` read grant + one row for the current build.
2. **Settings → App update, check-only.** Shows current and latest, no
   download. Proves the manifest end to end with nothing that can break an
   install.
3. Download + resume + SHA-256 + free space. Still no install - stop at
   *"Downloaded"*.
4. The install intent, and the "install unknown apps" path.
5. The dialog, with per-version dismissal.
6. The notification.
7. `priority` handling, then `min_supported` last - the forced path is the one
   that can lock people out, so it goes in when everything under it is proven.

**Steps 1-2 are testable today, alone, on your own phone.** Steps 5-7 cannot be
meaningfully tested until someone other than you is running an older build -
the same trigger crash reporting waits on.

---

## 9. ONE THING TO SETTLE FIRST

**Where does the APK live?** `innocent-public` on R2 is the obvious answer -
it is already public and egress is free.

But it means **anyone with the URL can download your APK**, which is fine and
in fact what you want for sharing. Just know that publishing there makes the
build public even before you tell anyone about it. If that matters, a signed
short-lived URL from an edge function is the alternative - the machinery is
already there in `request-playback`.

---

## APPENDIX — the other question

**Adding more videos and photos to an existing title later: already built.**

`add_title` is deliberately re-runnable. Upload three more clips to the same R2
folder next month, run the same call with the fuller list, and only the new
files are added - `unique (bucket, object_key)` skips the ones already there,
and since migration 011 the sort order continues from what is stored instead of
restarting and colliding.

It also never overrides a poster you chose by hand: the first photo becomes
primary only when nothing is primary yet.

So there is nothing to build for that. Series/episodes remain unbuilt and, per
your note, unneeded.
