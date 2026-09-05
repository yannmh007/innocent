# START HERE — Innocent Movies, handoff for a new chat

Last updated 30 Aug 2026. Read this file first; it says what is decided, what to
do next, and what the other files are for.

---

## Who and what

* **Operator:** Yann Min Htan — independent Flutter developer, Myanmar users.
* **Machine:** a **mobile phone only**. No desktop, no terminal. Flutter builds
  happen in FlutLab in a browser, edited by copy-paste.
* **App:** Innocent, an MX-Player-style Android media player, **v1.59.2+301, not
  yet released — no users at all.**
* **Project:** a Movies vertical inside it — a paid catalogue with a KPay-based
  premium tier.
* **Preference:** plain explanations, the simplest thing that works first.
  Answers in Burmese.

---

## The one-paragraph state of play

The client half of the Movies feature is built and runs against demo data. No
backend exists yet: `BackendConfig` is empty, so the app has never spoken to a
real server. The immediate goal is **one hundred titles live on a real backend,
and a first signed public release** — not the full system the older planning
documents describe.

---

## Decisions, settled

| Decision | Detail |
|---|---|
| **Auth** | option **C′** — phone number as identity, stored as a synthetic email, password set by the user, **email confirmation off**, no SMS, no mail ever sent. Password reset by the operator via the admin bot, proof = the KPay transaction id. |
| **Anonymous users** | keep the existing `x-install-id` + `claimAnonymousHistory()`. Do **not** use Supabase anonymous sign-ins. |
| **Age gate** | date of birth + a stored consent record, plus geo-gating where the grant is minted. |
| **Content format** | **MP4 in a private bucket, presigned URLs.** HLS + AES deferred. |
| **Delivery** | presigned URLs direct from R2. **No Cloudflare Worker** in phase 1. Never proxy-stream video through a Worker. |
| **Upload** | by hand through the Cloudflare dashboard while files are under 300 MB. |
| **Domain** | **not bought yet.** Buy at release. Build the endpoint indirection now so it can be swapped without a release. |
| **Application id** | **`com.innocent.media`**, DONE in v1.60.0+302 — `applicationId`, `namespace`, all 22 Kotlin files and the AIDL renamed together. Does not need to match a domain. |
| **Signing** | WIRED in v1.60.0+302: `build.gradle.kts` reads `android/key.properties`, fails soft to the debug key with a loud warning. Still TO DO: generate the keystore in Colab, back it up ×3, record the SHA-256 in `docs/signing_identity.md`. |
| **Admin tooling** | none yet. If needed later, an operator-only build behind `--dart-define=ADMIN=true`, never a hidden screen in the shipped app. |
| **Supabase region** | Singapore. Cannot be changed later. |
| **CI** | GitHub Actions for build / migrations / gates only. Never for media. |

---

## Next actions, in order

```
1  applicationId — DONE (v1.60.0+302, full rename)
2  release keystore: generate, back up ×3            <- NEXT, 1 hr
3  Supabase project (Singapore) + titles table + RLS                2 hr
4  R2: private bucket + public bucket                              15 min
5  ONE title uploaded by hand, row added, played in the app         1 day
6  five more, then the remaining ninety-odd at 5–10/day
```

Steps 1–2 and 3–5 do not depend on each other.

**Decided 30 Aug 2026:** the application id is `com.innocent.media`.

---

## The files

| File | What it is |
|---|---|
| **`START_HERE.md`** | this file — decisions and next actions |
| **`phase1_simple_plan.md`** | **authoritative for now.** The simple path to 100 titles and a release |
| `app_distribution_foundation.md` | keystore, application id, Android developer verification (2026–27), the risk register, free-tier economics |
| `endpoint_config_spec.md` | how to buy the domain late and swap it in without a release |
| `movies_operating_plan.md` | the finished system — phone-first operations, the full workflow set, references. Background, not yet the plan |

Where they disagree, **`phase1_simple_plan.md` wins** until the first hundred
titles are live.

---

## Paste this into the new chat

> Innocent Movies. Attached: START_HERE.md and the other planning docs, plus the
> latest project zip.
>
> Read START_HERE.md first — it has the settled decisions. `phase1_simple_plan.md`
> is authoritative; the other docs describe a later phase.
>
> Constraints: **I work from a phone only — no terminal, no desktop.** Flutter
> builds happen in FlutLab by copy-paste. I am not deeply technical, so explain
> plainly and give me the simplest thing that works first. Answer in Burmese.
>
> The app has **no users yet**, so nothing is locked in.
>
> Today I want: `<one deliverable>`.

Good single deliverables to ask for, one per session:

* the `build.gradle.kts` patch and `key.properties` for release signing
* the `titles` table SQL plus RLS, ready to paste into the Supabase SQL editor
* the tap-by-tap for creating the Supabase project and the two R2 buckets
* the client patches C2 / C3 / C6 as one zip, following `docs/maintenance.md`

---

## Rules that keep this from going wrong

* **A stage is done when it works end to end, not when the code is written.**
* **Do not upload title two until title one plays in the app.**
* **Store paths in the database, never URLs.** `seg/9f2a1c/`, not `https://…`.
* **Nothing in a shipped APK is secret.** APKs decompile.
* **Wi-Fi only for uploads.** 40 GB of mobile data costs more than a year of the
  whole platform.
* **Add no tool that is not yet the bottleneck.**
