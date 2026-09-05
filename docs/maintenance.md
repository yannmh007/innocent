# Maintaining Innocent

Written for whoever picks this up next, including you in six months.

---

## 1. How to verify a change

There is no local compiler in this workflow, so verification is three steps and
**the order matters**:

| # | Step | Catches | Cost |
|---|---|---|---|
| 1 | FlutLab → **Analyzer** tab | types, missing overrides, wrong arity, null misuse | seconds |
| 2 | `python3 tool/check.py` | structure, imports, collisions, architecture | seconds |
| 3 | FlutLab → **Build** | the truth | minutes |

**Step 1 is the one people skip, and it is the one that matters most.**
FlutLab's Analyzer 2.0 runs a real language server that understands every
object in this project and every imported library — it reports the same errors
the compiler will, without the wait. A build was shipped broken because that
tab was not opened first.

`tool/check.py` is not a compiler and never will be. It reads source as text.
It catches whole classes of error a build takes minutes to find, and it knows
**nothing about types**. Both steps are needed; neither replaces the other.

### What each checker protects

| Script | Guards against |
|---|---|
| `verify.py` | invisible characters, brace balance, **malformed signatures** (`f(())`, empty named lists), duplicate declarations, string-table parity across en/my/th, design-token typos, undefined private helpers, version consistency |
| `compile_risk.py` | a type or provider used without importing it |
| `contract_conformance.py` | an implementation drifting from its interface; constructor calls with the wrong argument count |
| `collision.py` | a new top-level name that already exists elsewhere in the tree |
| `check_args.py` | a named argument the constructor does not declare |
| `security_invariants.py` | the paywall architecture quietly coming apart |

### The rule that keeps them honest

**Every checker must be shown to fail before it is trusted.** Break something
on purpose, confirm the checker reports it, put it back. A check that has never
failed is not evidence of anything — and twice now a fault "passed" only
because the injection never applied, so also confirm the edit actually landed.

Equally: **a checker that accuses working code gets switched off.** Three rules
have been narrowed after they flagged correct code. If a checker fires on
something that compiles, fix the checker first.

### Two things these checkers do NOT cover

**`contract_conformance.py` was blind until 25 Aug 2026.** Its member pattern
let the return-type group match pure whitespace, so the continuation line of an
expression body —

```dart
Future<String?> resolveImageUrl(MediaRef ref) async =>
    resolveImageUrlSync(ref);
```

— read as a declaration of `resolveImageUrlSync`. Any adapter that DELEGATED to
a member therefore appeared to declare it, and the `implements` completeness
check was satisfied by the call site rather than by an implementation. Found
only because a deliberately injected fault refused to fire. Fixed by anchoring
the group on a non-space first character. The general shape is familiar here:
an instrument must not break what it measures.

### Verified, and one thing that is not

The backup exclusion the session tokens now rely on was checked against the
package rather than assumed: `flutter_secure_storage` writes its data to a
SharedPreferences file named `FlutterSecureStorage`, and
`<exclude domain="sharedpref" path="FlutterSecureStorage"/>` is the documented
remedy. Both rule files already carry it, for the vault — so moving the tokens
there put them behind an exclusion that already existed, with no manifest
change.

NOT verified, and worth a look next time someone touches this: an upstream
issue reports a SECOND file, `FlutterSecureKeyStorage.xml`, being created when
`encryptedSharedPreferences: true` is set. It is not excluded here. The
exposure looks nil — it holds the encrypted keyset, and the Keystore key that
opens it is hardware-bound and never leaves the device — so it was deliberately
NOT added, rather than added blind: this release is Dart-only, and an XML
resource change for a file that may not even exist in the pinned version would
have cost that property for no measured benefit. Confirm the filename against
the version in `pubspec.yaml` before adding it.

**No checker sees an UNDEFINED identifier.** A negative test on 27 Aug 2026
replaced `recycleBinProvider` with `recycleBinProviderTYPO` in `local_screen`
and all six passed. `compile_risk.py` only asks whether a KNOWN project type is
used without its import; a name that matches nothing in the project matches no
rule either. So a mistyped provider, method or constant is invisible here and
appears for the first time in the Analyzer. Same practical conclusion as the
`check_args` gap below: step 1 is step 1, and anything this session could not
verify structurally was verified by reading the declaration.

**`check_args.py` deliberately skips `obj.method(...)`.** The receiver may
belong to any package, and a `authenticate` or an `open` on somebody else's
class is not ours to check. Only unqualified calls and constructors are safely
ours. So a wrong named argument passed to one of our own methods THROUGH A
VARIABLE — `controller.openVideo(uri, ephemerall: true)` — is caught by nothing
in `tool/`. The Analyzer catches it instantly, which is one more reason step 1
is step 1.

---

## 2. Where the project actually stands

### Solid

* One design-token file drives the whole feature's type, spacing and colour.
* One `ContentRepository` seam — swapping the media backend is one line plus an
  adapter, and `security_invariants.py` enforces that nothing bypasses it.
* Three viewer tiers derived in one place; no screen re-derives access.
* Full HTTP adapter written against a documented wire contract, switching on by
  itself once `BackendConfig` has a URL.
* Six structural checkers, all negative-tested, now living **in the repo**
  rather than on one machine.

### Honest weaknesses, worst first

**1. The Dart side is still never compiled before a build.**
Structural checks pass; that is not the same as compiling. The NATIVE side is
now better off — Kotlin sources are parse-checked and `Diagnostics.kt` is
stub-compiled against signature-accurate Android stubs (see the v1.61 notes) —
but nothing type-checks Dart outside FlutLab's Analyzer. Run the Analyzer
first, every time; it is the only thing in the loop that understands types.

**2. There is no backend, and two client pieces contradict the plans.**
Sign-in, entitlement and approval are on-device stubs that enforce nothing.
The two client contradictions named here were fixed in v1.63.5:
`device_identity.dart` is now keystore-backed and excluded from Auto Backup and
device transfer (the real defect — not "Clear data", which is supposed to mint
a new id), and `AccessDenial.wrongDevice` exists with a 409 mapping and its own
message. `docs/movies_gaps.md` #4 and #5 are closed on the client side; the
server halves do not exist yet. Do not take money until
`docs/premium_backend_spec.md` is implemented — in particular the one rule that
the **server** must refuse a playable URL to an unentitled account.

**3. ~~No tests for the new feature.~~ PARTLY SOLVED — the entry was stale.**
All four named targets have been covered since 25 Aug 2026 in
`test/video_hub_logic_test.dart`: `AccessPolicy` decisions, `ViewCount.compact`
boundaries (999,999 reads `999K`, truncated not rounded),
`ContentFilters.signature` stability, and `CapabilityMatrix` tiers. v1.63.5
added the `PlaybackGrant` refusal reasons.

What is still uncovered is everything with a device or a network behind it: the
player, the downloader, the transfer and the vault — which remain the four
things most likely to break. Those need fakes rather than pure functions, so
they are a larger job than these were.

**4. ~~Images have no disk cache.~~ SOLVED in v1.63.5.** `PosterCache` writes
artwork to the app cache directory under SHA-1 names, prunes oldest-first at
48 MB, and falls back to plain `Image.network` on any failure — so the worst
case is the behaviour that existed before it. Written by hand rather than
adding `cached_network_image`, which pulls in `sqflite`: a native plugin is not
worth a minor release and a platform library that cannot be compiled locally to
check, for something this small.

Still true, and worth knowing: nothing caches the CATALOGUE itself, only its
pictures. See weakness 5.

**5. No offline story.** Once the API is wired, a dead connection means an empty
catalogue and no explanation. The repository seam is the right place for a
cache-then-network layer; the UI already renders error states.

**6. ~~No crash reporting.~~ SOLVED in v1.61-1.63, and it immediately paid.**
Settings → Diagnostics reads Android's own process-exit history
(`ApplicationExitInfo`, API 30+, with the native tombstone on API 31+) and
pairs it with a breadcrumb trail that is fsync'd to disk after every entry, so
it survives the process. On its first use it named a crash that four rounds of
reading code had not found: `ref` used inside `dispose()`.

What still is NOT covered: nothing reports automatically. The user has to open
the screen and tap **Copy report**. That is the right trade for now — there is
no server to send to — but it means a crash on someone else's phone is still
invisible unless they say so.

**7. `app_strings.dart` is 4,000+ lines** and every feature adds to it. It has
not broken anything, and one file makes locale parity trivially checkable — but
it will need splitting by feature before it doubles again.

**8. Google sign-in is a button that says "not yet".** Honest, but a dead end
on the screen most likely to be the first thing a new user sees.

**9. 295 places catch an error that nobody can ever see.** 88 are `catch (_) {}`
and 207 report only through `debugPrint` behind `kDebugMode`, which is false in
the release build that is the only build anyone runs. This is not a style
complaint: the v1.62 crash WAS one of these, and it cost four rounds of
guessing. The playback path and libmpv's own error stream now feed
`PlaybackLog`, which persists; the downloader, transfer and vault paths do not
yet.

**10. Against MX Player, one real gap is left: network protocols.** MX opens
SMB, FTP and UPnP shares; this app does HTTP/HLS only, and libmpv has no SMB
built in, so closing it means a client plus a local proxy. Everything else on
MX's feature list — subtitle formats and styling, seek preview, aspect ratio,
shuffle/repeat, resume, sleep timer, A-B repeat, subtitle and audio delay,
speed, PiP, background play, equalizer, screen lock, track switching,
frame-stepping — is present as of v1.63. Chromecast and cloud storage are also
absent and are each larger than SMB.

---

## 3. What to do next, in order

**A0. Decide how sign-in works, and how far age verification goes.** Both change
the schema, so neither can come after B. The auth one is the largest cost
decision in the project: phone OTP needs a paid SMS provider at ~$0.10 a
verification against $2/month of infrastructure. See
`docs/movies_execution_plan.md` §0.

**A. Get a green build.** Nothing else can be trusted until this is true once.
Analyzer → `tool/check.py` → Build.

**B. Stand up the backend, in the order in `docs/movies_execution_plan.md`**
(which follows `docs/client_api_contract.md`): titles + RLS → auth →
subscriptions and payment requests → the playback function. Step four is the
security boundary. Test it with `curl` as a free account, not through the app:
**the app is not the attacker.**

**B2. Back it up the day real data exists.** The free tier has no backups, and
losing `subscriptions` means asking a thousand people to prove they paid. A
weekly `pg_dump` to Telegram is twenty lines — and restore it once, because a
backup that has never been restored is a file.

**C. Add the four pure unit tests above.** They are twenty lines each and they
cover the logic most likely to be quietly wrong.

**D. Add disk image caching.** One file, immediate user-visible benefit.

**E. Then, and only then, widen the lint rules** —
`prefer_const_constructors` and friends, one at a time with a cleanup pass.
Enabling them as a batch today would put six hundred style notes in front of
the four real errors the Analyzer tab exists to show.

---

## 4. Conventions worth keeping

* **Dart-only changes get a patch bump**; native changes get a minor bump.
* **Never edit a signature with a regex across many files.** It has failed
  twice: once leaving `getFeatured(())`, once leaving eleven references to a
  deleted parameter. Both had balanced parentheses and read perfectly.
  `contract_conformance.py` now catches the second kind; the first kind is
  cheaper to avoid than to detect.
* **Advisory tables are advisory.** `CapabilityMatrix` and `AccessPolicy` decide
  whether to draw a lock, never whether to hand over a file. An attacker who
  patches them gets a nicer-looking free account.
* **Fail toward locked.** Unknown access tier reads as premium; unknown request
  status reads as pending. A schema typo should hide content, not unlock it.
* **Absent is not zero.** A missing count draws nothing. A reader cannot tell an
  honest zero from an unfilled column, and only one of them is true.
