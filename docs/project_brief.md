# Innocent — project brief

**Read this first.** It exists so a new conversation does not start with the
owner re-explaining the project. Everything below is decided, not proposed.

Companion documents:

| File | What it holds |
|---|---|
| **`docs/handoff_2026_08_31.md`** | **the newest state**: what is done, what is untested, what is next |
| `docs/handoff_2026_08_30.md` | the previous one: signing history, the on-device test table |
| `docs/maintenance.md` | how to verify a change, the honest weakness list, the roadmap |
| `docs/premium_backend_spec.md` | schema, RLS, the playback function, the security model |
| `docs/client_api_contract.md` | every endpoint the app already calls, exactly |
| `tool/README.md` | the structural checks and how to add one |

For the Movies vertical specifically:

| File | What it holds |
|---|---|
| **`docs/movies_execution_plan.md`** | **the plan you work from** — every stage, the SQL, the gates, the client work queue |
| `docs/movies_roadmap.md` | the same order with the reasoning behind each step |
| `docs/movies_gaps.md` | what is still missing, ordered by what stops a launch |
| `docs/movies_access_plan.md` | tiers, stream and offline protection, device binding |
| `docs/movies_platform_plan.md` | which services, and why not the others |
| `docs/movies_capacity_model.md` | the year-one numbers, and where they bind |
| `docs/movies_dataflow.md` | end to end: a file on a phone → a picture on theirs |

---

## 1. What this is

**Innocent** — an MX Player-inspired Android media player, built by one
developer for Myanmar users. Internal Dart package name is `mx_clone`
(historical; the rebrand deliberately left Android identifiers alone).

Stack: Flutter, media_kit/libmpv for playback, Riverpod, GoRouter,
SharedPreferences. Localised **en / my / th** through `AppStrings` runtime maps
— there is no gen-l10n and no build_runner.

**The constraint that shapes everything:** development happens in **FlutLab.io
by copy-paste. There is no local compiler.** Code is verified by structural
analysis and by reading, then built in the browser. This is why `tool/` exists
and why the rules in §6 are non-negotiable.

The app already shipped: local browser, full gesture player, music tab,
file transfer, a private vault, and a yt-dlp downloader.

---

## 2. The current project: the Video Hub

Growing Innocent from a player into a **player + streaming platform**.

Entry point: a **Movies** chip, first in the Local screen's quick-access strip
→ top-level route `Routes.videoHub`, wrapped in the age gate.

**The catalogue is entirely adult** — licensed JAV/AV. This is why there is no
"Adult" category: a tab that matches everything is not a filter. The 18+
decision happens at the door instead.

Shape:

* full-screen **age gate** before anything — two explicit buttons, terms on
  screen, a real refusal path, versioned consent recorded on device and server
* **search field** covering the whole catalogue
* pinned **category bar** — All / Movies / Series / Reels
* "All" shows curated **rows** with See-all on every one; a category shows a
  paged **poster grid** with a filter toolbar and sheet
* **detail** = poster, facts, and a mixed photo/video album
* playback hands off to the **existing player** — this feature deliberately
  gains no second video surface

---

## 3. Monetisation

Freemium **soft paywall**. Three tiers, one ordered value (`ViewerTier`):

| | Anonymous | Registered | Premium |
|---|---|---|---|
| Browse, posters, synopsis | yes | yes | yes |
| Preview stills | 3 | 5 | all |
| Marked preview clip | yes | yes | yes |
| Watchlist + synced history | no | **yes** | yes |
| Full album | no | no | yes |
| **Play a premium title** | no | no | **yes** |
| Offline download | no | no | yes |
| Quality ceiling | 480p | 480p | source |
| Concurrent streams | 1 | 1 | 2 |

Registering buys account-bound features that cost nothing to give away, so
signing up is an offer rather than a toll gate.

**Payment is KPay, outside the app, approved by a human.** The app cannot
verify a transfer and does not pretend to: the user signs in (phone first —
the paying number is usually the signing-in number), submits the transaction id
and sending number, and an operator checks it against the real KPay statement.
The confirmation screen says "submitted, under review" and never "you are
premium".

---

## 4. The seams that must not be broken

**One storage seam.** Everything the screens need is on `ContentRepository`,
and nothing on it names a provider. Widgets hold a provider-agnostic `MediaRef`
and ask the repository to resolve it. Swapping the media backend is one line in
`contentRepositoryProvider` plus an adapter class.

**One access decision.** `ViewerTier` is derived in exactly one place.
`CapabilityMatrix` and `AccessPolicy` decide **whether to draw a lock, never
whether to hand over a file** — an attacker who patches them gets a
nicer-looking free account.

**One playback path.** Only `playback.dart` may open the player or interpret a
`PlaybackGrant`. `tool/security_invariants.py` enforces this.

**The one security rule:** the **server** must never return a playable URL to an
account without an active subscription. Not "the app hides the button" — the
bytes must not be obtainable. This is why `requestPlayback` returns a grant or a
reason, never a boolean the client acts on. Flutter TLS pinning is bypassable
and device attestation does not stop interception; what makes interception
pointless is that the response is a **capability** (a signed, expiring URL only
the server can mint), not a permission.

**One design-token file.** `video_hub_theme.dart` (`VH`) owns type, spacing,
tonal surfaces and the text luminance ramp for the whole feature.

---

## 5. Where things stand

### Status as of v1.63.1+306 (30 Aug 2026) — READ THIS PARAGRAPH FIRST

The app **builds, installs and runs on a real device**. That sentence was not
true before 30 Aug 2026 and it changes how everything below should be read: a
"structurally verified" claim is no longer the strongest thing available.

Settled that day, in order:

1. **Application id is `com.innocent.media`** — `applicationId`, `namespace`,
   all 22 Kotlin files and the AIDL. This is now FROZEN: changing it after a
   single user installs means every one of them loses their data. (The Dart
   package is `innocent`; only the 19 MethodChannel strings are `mx_clone`.)
2. **Release signing is wired but the keystore does not exist yet.**
   `build.gradle.kts` reads `android/key.properties` and FAILS SOFT to the
   debug key with a loud log warning. **The next real task is generating that
   keystore and backing it up in three places** — until then no APK may be
   given to anyone, because a debug-signed build can never be updated.
3. **audio_service was never starting.** `MainActivity` now extends
   `AudioServiceFragmentActivity`. Consequence to remember: the Flutter engine
   is CACHED, so the Dart isolate outlives the Activity.
4. **The app was dying in native code during playback.** Cause: `ref` used
   inside `dispose()`, which throws every time and abandoned the whole
   teardown, leaving libmpv un-destroyed. Fixed, plus `tool/ref_in_dispose.py`
   so it cannot return silently.
5. **Settings → Diagnostics exists and works.** It reads Android's own
   process-exit history and a persistent breadcrumb trail. It found #4 on its
   first use. **When anything goes wrong, ask for that report before
   theorising** — four rounds of reading code did not find what one report
   did.

**Built and structurally verified** (Dart-only): the whole Video Hub surface,
the age gate, the paywall and account screens, the three-tier model, a
per-install anonymous id, and a complete HTTP adapter that switches on by
itself once `BackendConfig` has a URL and anon key.

**Not built:**

* **the backend** — sign-in, entitlement and approval are on-device stubs that
  enforce nothing. Do not take money until `docs/premium_backend_spec.md` is
  implemented.
* Google sign-in (the button exists and says so honestly)
* Bookmarks and Downloads screens (the entries exist)
* disk image caching and offline behaviour (crash reporting is DONE — see
  Settings → Diagnostics)
* an in-app updater — a launch requirement outside Play, and
  `REQUEST_INSTALL_PACKAGES` is already in the manifest

**Two places where the code contradicts the plans**, both small and both
required before device binding means anything:

* `device_identity.dart` stores the device id in `SharedPreferences`, which
  "Clear data" wipes — `movies_access_plan.md` §4 says it must be Keystore-backed
* `AccessDenial` has two values, so a server `wrong_device` refusal renders as
  "unavailable" and the user never learns their new phone needs the slot

**Two decisions are open and block the database schema:**

* **How sign-in works.** Phone OTP needs a paid third-party SMS provider
  (~$0.10 a verification, ~$300-500 in year one against $2/month of
  infrastructure) with unreliable delivery to +95 numbers. Email sign-in costs
  nothing, and a human already verifies the payer's phone against the KPay
  statement at approval time. See `docs/movies_execution_plan.md` §0.1.
* **How far age verification goes.** Declaration, date-of-birth record, or a
  real provider. Play is no longer doing this.

**Next, in order:** decide those two → get a green build → stand up the backend
in the order in `docs/movies_execution_plan.md` (which follows
`docs/client_api_contract.md`) → back it up the day real data exists → the four
unit tests named in `docs/maintenance.md` → disk image caching.

---

## 6. Rules learned the hard way

Each of these cost a broken build or a wrong-looking screen.

* **Verify in this order: FlutLab Analyzer → `python3 tool/check.py` → Build.**
  The Analyzer understands every object in the project and answers in seconds.
  The Python checks read source as TEXT and know nothing about types. Neither
  replaces the other, and skipping the Analyzer is what shipped a broken build.
* **Never edit a signature with a regex across many files.** It has failed
  twice, leaving `getFeatured(())` and eleven references to a deleted
  parameter. Both had balanced parentheses and read perfectly.
* **Every checker must be shown to fail before it is trusted** — and confirm
  the injection actually applied. Twice a fault "passed" because nothing was
  injected.
* **A checker that accuses working code gets switched off.** Several rules have
  been narrowed after flagging code that compiles. Fix the checker first.
* **Fail toward locked.** Unknown access tier reads as premium; unknown request
  status reads as pending. A schema typo should hide content, not unlock it.
* **Absent is not zero.** A missing count draws nothing — a reader cannot tell
  an honest zero from an unfilled column.
* **Match the tree, not the newest docs.** Before using a recent Flutter API,
  grep how the existing code does the same thing.
* **Dart-only changes get a patch bump**; native changes get a minor bump.
  Bump `pubspec.yaml` and `lib/core/app_version.dart` together, add a README
  entry, then diff the whole tree against the previous archive before zipping —
  a file that shrank unexpectedly is the signal.

---

## 7. How the owner works

Burmese is the working language. The app targets Myanmar users on mid-range
Android phones and mobile data, which is why payload size, cold-start cost and
offline behaviour are real concerns rather than theoretical ones.

Deliverables are **complete zip archives**, not patches — there is no git in
the loop. Every archive is extract-verified before it is handed over.

What is wanted is an engineer who researches before deciding, says plainly when
something will not work, and does not describe a stub as if it were finished.
