# The foundation, and whether this survives three years

Written 30 Aug 2026, after auditing build 301's `android/` directory against
Android's 2026–2027 distribution rules and the economics of the free tiers this
plan stands on.

`movies_operating_plan.md` answers *how it is run*. This answers a narrower and
more urgent question: **is the thing being built on solid ground, and what will
it cost when it is no longer free?**

Three findings, ordered by how much more expensive each gets the longer it is
left. The first one is the largest risk in this entire project, and it is one
line in one file.

---

## 1. Release builds are signed with the debug key

`android/app/build.gradle.kts`, inside `buildTypes.release`:

```kotlin
signingConfig = signingConfigs.getByName("debug")
```

This is the untouched Flutter template default. It has three consequences that
compound.

**Android refuses an update signed with a different key.** Not a warning — a
hard refusal (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`). The only remedy is
uninstall and reinstall, which destroys the Private Folder vault, downloads,
history, settings and the login.

**The debug key is not owned.** It is generated automatically per build
environment, in `~/.android/debug.keystore`. It is not backed up, it has a
fixed one-year-ish validity in some toolchains, and there is no guarantee that
a rebuilt FlutLab container produces the same one. **The identity of the app is
currently an accident of whichever machine last built it.**

**The in-app updater is the only distribution channel.** Outside Play there is
no other path (`movies_gaps.md` #7). If the key drifts once, the updater stops
working permanently, for everyone, and the fix is asking every user to reinstall
and lose their data.

### The fix, once, forever

1. **Generate a real release keystore.** RSA 2048, validity 10,000 days. Two
   phone-only ways to run `keytool`:
   * **Termux** (F-Droid) → `pkg install openjdk-17` → `keytool -genkeypair`.
     Best option: the key never leaves the phone.
   * **Google Colab**, which has a JDK, then download the `.jks` and delete the
     runtime. Acceptable.
   * **Never** a website that generates keystores for you. That key is the app's
     identity forever.
2. **Wire it up**: `android/key.properties` (git-ignored) + a `signingConfigs`
   block reading it, and `release { signingConfig = signingConfigs.getByName("release") }`.
3. **Back it up in three independent places**, because losing it ends the app:
   * an encrypted archive in the private Telegram channel,
   * a copy on storage you control,
   * base64 in GitHub Secrets, once release builds move to Actions.
4. **Record the SHA-256 fingerprint** in `docs/` so any future build can be
   checked as the same identity.
5. The updater verifies the downloaded APK's SHA-256 before installing — already
   planned, and now it has a stable signer behind it.

---

## 2. The application id is a placeholder

```kotlin
namespace     = "com.example.mx_clone"
applicationId = "com.example.mx_clone"
```

`com.example.*` is reserved for samples. It is rejected by Play, it is a poor
thing to register under developer verification (§3), and it does not match the
product's name.

**Changing the application id creates a different app as far as Android is
concerned** — a new install, not an update. Same cost as a key change: uninstall,
reinstall, lose everything local.

**Amendment, same day — this is a one-line change, not a refactor.**

`namespace` and `applicationId` are allowed to differ. `namespace` is only the
package used for generated `R` and `BuildConfig` classes; `applicationId` is the
app's identity on the device and the thing developer verification registers.

So the entire change is:

```kotlin
namespace     = "com.innocent.media"     // renamed too, 30 Aug 2026
applicationId = "com.innocent.media"
```

No Kotlin files move. No directory renames. No package declarations edited.
The `com.example` namespace is untidy and invisible; the `applicationId` is what
matters, and it is one line.

The application id also does **not** need to match a domain you own — reverse-DNS
is a uniqueness convention, nothing verifies ownership, and users never see it.

> **The cost of this migration only ever goes up.** It is measured in users, and
> today is the smallest that number will ever be.

If there are already users on debug-signed builds, the honest sequence is: ship
one final build under the old identity that (a) warns clearly, (b) offers an
export for anything worth keeping, and (c) links the new APK. Then never break
identity again.

---

## 3. Android developer verification — a clock with a date on it

Google is requiring apps installed on **certified Android devices** to be
registered by a **verified developer**, whether they come from a store or from
sideloading:

| Date | What happens |
|---|---|
| March 2026 | Verification opened to all developers, including those distributing only outside Play (Android Developer Console) |
| August 2026 | Limited-distribution accounts and the "advanced flow" go global |
| **30 Sept 2026** | Enforcement begins for users in **Brazil, Indonesia, Singapore, Thailand** |
| **2027** | Rolls out **globally**, to all apps on certified devices |

Three details decide what this means here:

* **It verifies identity, not content.** Google has said explicitly that this is
  not an app review. An app that Play's content policy would reject can still be
  registered — the check is who you are, not what you ship.
* **Unregistered apps are not blocked outright.** They can still be installed
  via ADB or a new "advanced flow" with extra security checkpoints. But a
  friction-heavy warning screen between a user and a paid install is a
  conversion problem, and it applies to *updates* as well as first installs.
* **Myanmar is not in the first wave.** The 2027 global rollout is the deadline
  that matters, and its details are not final.

### What to do

**Register early, under a neutral identity, with the final package name.**

The reasoning: the app *is* a general media player — that is what
`project_brief.md` describes and what most of the code does. The Movies vertical
is a server-side catalogue behind an age gate, not the app's identity. That is a
defensible position, it argues for a neutral package name and app name, and it
is worth keeping true as the product grows.

The alternative — staying unregistered — is survivable but expensive: every
install and every update goes through the advanced flow from 2027. Plan for it
as the fallback, and write the install instructions for it before they are
needed, rather than after.

**Re-check this every quarter.** The 2027 rules are announced, not published in
final form.

---

## 4. The free tiers are a bootstrap, not a home

| | Free | Pro |
|---|---|---|
| Price | $0 | **$25/month per organisation** |
| Database | 500 MB | 8 GB |
| Egress | 5 GB/month | **250 GB/month** |
| Backups | **none** | daily, 7-day retention |
| Inactivity | **pauses after ~7 days** | never |
| MAU | 50,000 | 100,000 |

`movies_capacity_model.md` already identifies the 5 GB egress as the binding
limit, and it binds at roughly month 9 — which is also roughly when there is
revenue.

**Two consequences worth deciding now:**

**The first $25/month of revenue goes to Supabase Pro.** Five subscribers pay
for it. Not features, not ads, not a second server — the thing that removes the
pause, adds daily backups, and multiplies the binding resource by fifty.

**On Pro, the Cloudflare Worker may never be needed.** The phase-1 design in
`movies_operating_plan.md` §5.1 spends ~36 KB of egress per view on the
playlist. Against 250 GB that is roughly **seven million views a month**. The
§5.2 trigger stands as written for the free tier, but the honest expectation is
that the upgrade path is *Supabase Pro*, not *a second platform*.

---

## 5. Risk register

Everything that could end this, with what already answers it.

| Risk | Answer that already exists | What is still needed |
|---|---|---|
| **Signing key lost or drifted** | nothing | §1 — the largest gap in the project |
| **KPay account closed** | `payment_instructions` is a table read without auth, so the payment channel is data, not code — a new number is a row edit, not a release | a second channel identified in advance |
| **Telegram account banned** | masters are the only unrecoverable asset; two accounts, and forwarding costs no re-upload | a cold copy outside Telegram, funded by the second $25 of revenue |
| **R2 or Cloudflare suspended** | masters in Telegram; `titles.provider` and `titles.locator` already exist, so moving to B2 or Bunny is a bucket copy and a constant | nothing |
| **Google revokes verification** | the app is a media player, not an adult app; the advanced flow remains | written install instructions for the fallback |
| **Supabase changes the free tier** | Pro at $25 is the answer, and revenue covers it | nothing |
| **A takedown demand** | `titles.status` checked in catalogue, grant path and licence check | per-title licence records (`movies_gaps.md`) |
| **The operator is unavailable** | every command is a checked-in button | the credential map |

Read down the "already exists" column: the architecture answers almost all of
it. The two blanks are §1 and the cold copy — one is a day's work now, the other
is $25 a month later.

---

## 6. Where this goes in the order

```
−1  FOUNDATION — before the next public build                    1 day
    · real release keystore, backed up in three places
    · final application id, from the owned domain
    · both shipped in ONE migration release
    · start developer-verification registration
 0  auth + age decisions        (done — operating plan §1)
0.5 domain + innocent-ops repo + secrets + first workflows
 1  green build
 2  Supabase foundation
 …  as movies_operating_plan.md §9
```

Stage −1 does not depend on anything else and nothing else makes it cheaper to
delay. It is the only stage whose cost is measured in users rather than days.

---

## 7. References

| | Claim | Source |
|---|---|---|
| F1 | Apps must be registered by verified developers to install or update on certified devices — Brazil, Indonesia, Singapore, Thailand from 30 Sept 2026; global in 2027 | `developer.android.com/developer-verification`, and the Android Developers Blog, June 2026 |
| F2 | Verification confirms developer identity and is not an app content review; unregistered apps remain installable via ADB or the advanced flow | same |
| F3 | Developers who distribute only outside Play register through the Android Developer Console | `support.google.com/android-developer-console/answer/16561738` |
| F4 | Supabase Free: 500 MB database, 5 GB egress, no backups, pauses after ~7 days | `supabase.com/pricing` |
| F5 | Supabase Pro: $25/month, 8 GB database, 250 GB egress, daily backups with 7-day retention, no pausing | same |
| F6 | Android will not install an update signed with a different key | Android application-signing documentation |

---

## 8. The one sentence

> **The backend plan is sound and cheap. The app's identity — its signing key
> and its package name — is not yet owned, and everything else in this repo is
> built on top of it.**
