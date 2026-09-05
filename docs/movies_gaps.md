# What is still missing

Written 28 Aug 2026, after the architecture was settled; **revised the same day**
after auditing the plans against the code that exists. The other documents
describe a system that works. This one lists what stands between that
description and a real service with paying users.

Ordered by what stops a launch, not by what is interesting to build.

**For what to actually do about these, in order, see
`movies_execution_plan.md`.** This file is the list; that one is the schedule.

---

## Blocking — the service cannot open without these

### 1. Sign-in costs more than everything else combined, and nobody costed it

Every plan here assumes phone-first sign-in with an SMS OTP. **Supabase does not
send SMS.** It requires a third-party provider — Twilio, MessageBird, Vonage or
TextLocal — and Twilio Verify runs about **$0.10 per successful verification**.

At the month-9 projection of 2,500 registered users, allowing for re-logins and
undelivered codes, that is **$300-500**. The infrastructure budget in
`movies_capacity_model.md` is **$2/month**. Auth would be roughly **99% of the
cost of running this platform**, and it appears in none of the estimates.

Money is the smaller half. International A2P SMS delivery to Myanmar (+95)
numbers is unreliable, and an OTP that does not arrive is a sign-up that does
not happen — with nothing the app can do about it.

**The observation that resolves it:** a human already verifies the payer against
the KPay statement, by phone number, against a real bank record. An SMS OTP at
sign-in verifies the same fact, worse, earlier, and for money.

**What is needed:** decide between (A) Twilio/Vonage OTP, (B) Supabase's Send
SMS hook pointed at a Myanmar SMS gateway, or (C) email + password with the
phone recorded but not SMS-verified. **C costs nothing and never fails to
deliver.**

**This is blocking because it decides the schema.** Deciding it after the tables
exist means rewriting them. Full comparison in `movies_execution_plan.md` §0.1.

### 2. The payment-to-VIP loop has no operator side

`premium_backend_spec.md` says a claim is recorded and an operator approves it
against the real KPay statement. That is the correct design. **The operator
side does not exist.**

What actually happens today: a user pays, the app records a request, and
nothing on earth turns that into a subscription — the only approval path is a
button that was just removed from release builds because anyone could press it.

**What is needed**

* An admin Telegram bot with `/pending`, `/approve <id> <months>`, `/reject <id>`.
  The same private channel as ingest. No dashboard, no laptop.
* A notification the moment a request arrives, so approvals are minutes rather
  than hours.
* The approval writes the subscription row and nothing else does.

**Scale check:** 1,000 premium users over nine months is roughly **four
approvals a day**, each a few seconds. Manual is fine at this size — but only
with the bot. Doing it by hand in a SQL console is not fine at four a day.

**Until this exists, the product cannot take money.**

### 3. Device binding has no recovery path — and it will lock people out

One account, one device. Now: a user's phone is stolen, or wiped, or dies.

They install on a new phone, sign in, and the database refuses — correctly,
because the old device still holds the slot, and that device is gone.

**They are now a paying customer who cannot use what they paid for, and the
mechanism that blocks them is the one you built on purpose.**

This is not hypothetical. Over nine months and 1,000 subscribers, phones will
break. Expect this weekly.

**What is needed**

* **Self-service release**, once, with a cooldown: "Use on this device instead"
  → the old slot is released, the new one claims it, and the next switch is
  refused for 14 days. This handles the honest case without a human.
* **A visible counter**: "You can switch devices again on 12 September." A
  refusal the user cannot predict feels like a bug.
* **An operator override** for the genuine edge cases, through the same admin
  bot.

The cooldown is what keeps this from becoming account sharing. Without the
self-service path, every broken phone becomes a support ticket and a refund
demand.

**And it has a client half nobody has written — see #4.**

### 4. The app cannot express "wrong device", so recovery is unreachable

`AccessDenial` has exactly two values: `needsPremium` and `unavailable`.

A server 409 `wrong_device` arrives as `ApiErrorKind.forbidden` and renders as
**"unavailable"**. So a paying customer holding a new phone sees an unexplained
error, with no mention of the device slot and no route to the self-service
release that #3 describes.

**What is needed:** a third value (`AccessDenial.wrongDevice`), and a screen
naming the device that holds the slot, offering "use this device instead", and
showing the cooldown date when it refuses.

Without this, #3 can be built perfectly and no user will ever reach it.

### 5. The device id lives where "Clear data" can delete it

`movies_access_plan.md` §4 is explicit: an id in SharedPreferences is cleared by
"Clear data", the slot frees itself, and the whole mechanism enforces nothing.

`lib/features/video_hub/data/device_identity.dart` **still uses
`SharedPreferences`.** The plan and the code disagree, and the code is what
ships.

**What is needed:** move it to the Keystore-backed secure storage the Private
Folder vault already uses, and exclude it from backup — so it survives an
app-data clear but does not travel to a new phone in a device transfer, which is
exactly the behaviour wanted.

Small change. Until it is made, the device slot is decorative.

### 6. The API adapter has never met a real backend

`ApiContentRepository` is written, conforms to the interface and compiles. **It
has never run against a live Supabase project.** Every catalogue shape,
timestamp format, error body and null column in it is an assumption.

The demo repository has hidden this: the app works beautifully against data
that was written to satisfy it.

**What is needed:** one real Supabase project, one real title, and the app
pointed at it — before any of the security work. Expect a day of small,
tedious mismatches. Finding them now costs a day; finding them after the
Worker and the packaging pipeline exist costs a week of not knowing which
layer is lying.

### 7. There is no way to ship a fix

Outside Google Play, an app with no updater is one bug away from being
unrecoverable. **The first urgent update will be a security fix**, and by
definition it will be urgent.

**What is needed**

* A version endpoint (a JSON file in R2 — no server, no cost).
* An in-app check on launch, a "what changed" sheet, and a download.
* `REQUEST_INSTALL_PACKAGES` — **already in the manifest**, added for the
  downloader — plus the Android 8+ install-source consent flow, which is a
  native change and therefore a minor version bump.
* **SHA-256 verification before install.** An updater that installs whatever it
  downloaded is a backdoor with a progress bar.
* A **forced** update path for the security case: a `min_supported_build` in
  that same JSON, below which the app refuses to run.

Design the forced path now. Retrofitting it means the users who most need the
fix are running the version that cannot be told about it.

---

## Serious — the service opens, then hurts

### 8. Offline downloads have no way to hand the key to the player

`movies_access_plan.md` §3 gets the storage right: keep the segments encrypted,
wrap the content key with an Android Keystore key, store only the blob. **It
never says how libmpv obtains that key at playback time.**

HLS players read the key from the URI in the playlist. Writing it to disk as a
file destroys the entire point of wrapping it.

**What is needed — and it already exists in this codebase.**
`lib/core/services/downloader/stream_proxy.dart` is a loopback HTTP server on
127.0.0.1, protected by random per-item tokens, already forwarding range
requests for the player. Serve a rewritten local playlist from it whose key URI
points back at itself, unwrap from Keystore on that request, and return the 16
bytes **from memory**. Segments stay `file://`, encrypted, untouched.

Design this before writing the downloader, or the download lands and there is
no way to play it.

### 9. Posters and segments cannot share one bucket

The documents have said both "the R2 bucket must never be public" and "posters
go to a public-ish path". Both are correct and they need **two buckets**: a
private one for encrypted segments, presigned only, and a public one on a custom
domain for posters, thumbnails, the updater JSON and the APK.

A poster is not a secret, and gating it would cost a Worker call per card. A
segment is, and has no reason to own a permanent URL.

Cheap to set up now, tedious to split later once locators are stored.

### 10. Age verification is undesigned

Play is not doing it any more. The existing versioned-consent gate is a
declaration, not verification, and several jurisdictions now require more than
a declaration for this content.

**Decide deliberately**, and write down which you chose and why: declaration
only (cheapest, weakest), a date-of-birth entry with a stored consent record,
or a real verification provider (costs money, kills conversion). This is a
legal question more than a technical one, and it should be answered before
launch rather than after a complaint.

### 11. Supabase has no backups on the free tier

Every video survives a Supabase loss, because Telegram holds the masters. **The
catalogue does not.** Titles, tiers, subscriptions, device slots, who paid —
all of it lives in one free-tier database with no backup.

**What is needed:** a scheduled GitHub Action, weekly, running `pg_dump` and
posting the file to the private Telegram channel. Twenty lines. Losing the
`subscriptions` table means asking a thousand people to prove they paid.

**And restore it once into a scratch project.** A backup that has never been
restored is a file, not a backup.

### 12. No support channel, and no way to see failures

A user whose payment was approved but who still sees a paywall has no route to
you, and you have no way to know playback is failing until someone complains
loudly.

**Minimum viable version:** a Telegram support link in the app's Me tab, and a
`play_failures` table the app writes to on a playback error (title, error kind,
app version — **no personal data**). Ten rows a day is noise; two hundred means
something broke this morning.

### 13. There is no kill switch

If a title has to come down — a licence dispute, a mistake, a legal demand —
the only current answer is deleting rows and hoping nothing cached it.

**What is needed:** a `titles.status` column (`live` / `hidden` / `takedown`)
checked in the catalogue policy, **in the grant path, and in the download
licence check** — otherwise a takedown stops new views while every existing
offline copy keeps playing. One column, and it needs to exist before it is
needed.

---

## Worth having, not blocking

* **Licence records per title.** Content is described as licensed; keep the
  proof, per title, where it can be produced on request. Some jurisdictions
  require record-keeping for this category of content specifically.
* **A pricing screen.** The tiers exist in the database; nothing in the app
  explains what VIP costs or what it unlocks.
* **Basic analytics.** Which titles are watched, where playback drops. Enough
  to decide what to add next, not enough to identify a person.
* **The Telegram ingest bot needs somewhere to run.** A Supabase Edge Function
  as the Telegram webhook is free and sufficient — but it is a piece nobody has
  written yet.
* **Disk image caching.** `Image.network` caches in memory only, so every cold
  start re-downloads every poster. On Myanmar mobile data that is a real cost to
  a real user, and `PosterImage` is the only place a ref becomes pixels.

---

## Resolved since this list was first written

* **Does Cloudflare accept PayPal?** Yes — Visa, Mastercard, Amex, Discover,
  **PayPal**, Apple Pay, Google Pay, Stripe Link and UnionPay, with **two
  payment methods per account**. So the PayPal being opened works, and the
  backup-payment-method launch gate is a real feature rather than a hope.
* **Does R2 need a card even on the free tier?** Yes, billing information is
  required to activate R2 regardless of usage. There are user reports of a **$5
  charge at activation** — read the confirmation screen.
* **What happens if payment fails?** R2 access is suspended and requests error
  while the data itself stays intact; after **30 days it may be deleted**. This
  is exactly why every master lives in Telegram: a lost R2 is a re-package, not
  a loss.

---

## The order to build them

Grouped so each group is testable end to end before the next begins. Full
step-by-step in `movies_execution_plan.md`.

| Group | Items | Why together |
|---|---|---|
| **0. Decide** | 1 (auth), 10 (age) | Both change the schema. Deciding them later means rewriting it |
| **A. Prove the plumbing** | 6 (real backend), 11 (DB backup) | Nothing else is trustworthy until the app has talked to real Supabase — and the moment there is real data, it needs a backup |
| **B. Take money** | 2 (approval bot), 3 (device recovery), 4 (`wrongDevice`), 5 (Keystore id) | The same admin bot and the same operator. Building them apart builds the bot twice — and 3 is unreachable without 4, unenforceable without 5 |
| **C. Survive** | 7 (updater), 13 (kill switch) | Both are "something went wrong and I need to act now". Neither can be added under pressure |
| **D. Deliver** | 9 (two buckets), 8 (offline key path) | Both are storage-shape decisions that are cheap before locators exist and tedious after |
| **E. Open the doors** | 10 (age, built), 12 (support + failures) | The last things before real users, and both are about what happens when something goes wrong for them |

Then the security work from `movies_roadmap.md` — because a paywall protecting
a catalogue nobody can pay for, on an app that cannot be updated, is protecting
nothing.

---

## The honest summary

The architecture is sound and the numbers work — **with one correction: the
numbers left out the login.** What is otherwise missing is **not technical
difficulty; it is the operational layer**: approving payments, recovering an
account, shipping a fix, taking something down, answering a user.

That layer is unglamorous, it is where the days actually go, and every item in
the Blocking list is a way for a working system to fail a real person on their
first day.
