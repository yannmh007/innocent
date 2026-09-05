# The Movies build — the plan you actually work from

Written 28 Aug 2026. This is the **execution** document. The others explain
*why*; this one says *what to do next, in what order, and how to know it
worked*.

| Read this when | Read instead |
|---|---|
| You are about to do the work | this file |
| You need the reasoning behind a decision | `movies_roadmap.md` |
| You need the security rules | `premium_backend_spec.md` |
| You need the wire format | `client_api_contract.md` |
| You need the numbers | `movies_capacity_model.md` |

**The rule for every stage below:** a stage is not done when the code is
written. It is done when its **gate** passes. A gate is something you can run
and watch fail if you break it.

---

## The shape of the whole thing

```
STAGE 0   Decide two things            ← no code. Blocks the schema
STAGE 1   Green build                  ← nothing else is trustworthy first
STAGE 2   Supabase foundation          ← titles + RLS, proven with curl
STAGE 3   Connect the app              ← the moment paper becomes real
STAGE 4   Backup, immediately          ← real data now exists
──────────── the platform is real from here ────────────
STAGE 5   Take money                   ← subs, requests, devices, admin bot
STAGE 6   Survive                      ← updater, kill switch
STAGE 7   Deliver video                ← R2, HLS, Worker
STAGE 8   Offline downloads            ← the feature people pay for
STAGE 9   Automate ingest              ← only after 3-4 done by hand
STAGE 10  Launch gates                 ← age, support, second archive
```

Stages 0-4 are about **eight days** and they are the ones that convert an
architecture into a system. Everything after them builds on something that has
already been proven to work.

---

# STAGE 0 — Two decisions, before any table exists

No code. One day. Both of these change the schema, so deciding them after
Stage 2 means rewriting Stage 2.

## 0.1 The auth question — and it is a money question

**The problem, stated plainly.** Every plan in this repo assumes phone-first
sign-in with an SMS OTP. Supabase does not send SMS itself — it requires a
third-party provider (Twilio, MessageBird, Vonage, TextLocal), and Twilio
Verify runs about **$0.10 per successful verification**.

At the month-9 projection of 2,500 registered users, allowing for re-logins and
undelivered codes, that is **$300-500** — against an infrastructure budget of
$2/month. **Auth would be 99% of the cost of running this platform**, and it is
in none of the estimates.

There is a second problem that money cannot fix: international A2P SMS delivery
to Myanmar (+95) numbers is unreliable. An OTP that does not arrive is a sign-up
that does not happen, and there is nothing in the app that can fix it.

**The observation that resolves it.** In this business model a **human already
verifies the payer against the KPay statement**. The phone number is checked by
a person, at approval time, against a real bank record. An SMS OTP at sign-in
verifies the same fact, worse, earlier, and for money.

**Three options. Pick one and write it down.**

| Option | Cost at month 9 | Delivery risk | What it buys |
|---|---|---|---|
| **A. Twilio/Vonage OTP** | $300-500 | high in MM | matches the current docs; nothing else |
| **B. Supabase Send SMS hook → a Myanmar SMS gateway** | local rates | medium | phone verification at a sane price; needs a gateway account |
| **C. Email + password; phone recorded, not verified** | **$0** | none | sign-up always works; verification happens where it already happens — at KPay approval |

**Recommendation: C**, with the phone number collected as a required field on
the premium request (it already is) rather than as the login identity. B is the
right answer if phone-as-identity turns out to matter to users; A is not worth
its price for this specific business.

**What each option changes**

* **C** — `profiles.phone` becomes informational. `client_api_contract.md`
  §Auth changes from `/auth/v1/otp` + `/auth/v1/verify` to
  `/auth/v1/signup` + `/auth/v1/token?grant_type=password`. Client work:
  `api_account_repository.dart` (two methods), `sign_in_sheet.dart` (email
  field instead of phone + OTP). Roughly a day.
* **B** — no client change at all. The hook is server-side configuration.
* **A** — no change to anything. Just the bill.

> **Do not skip this by defaulting to A.** Defaulting is choosing, and this is
> the single largest line item in the whole project.

## 0.2 How far age verification goes

Play is not doing this any more, so it is your responsibility and it is a legal
question before it is a technical one. The existing versioned-consent gate is a
**declaration**, not verification.

| Option | Cost | Conversion | Defensibility |
|---|---|---|---|
| Declaration only (what exists) | $0 | best | weakest |
| Date-of-birth entry + stored consent record | $0 | good | moderate |
| A verification provider | real money | poor | strong |

**Write down which you chose and why, in this file, with the date.** If a
consent is ever questioned, the record of a deliberate decision is worth more
than the mechanism itself.

The server-side half already has a home: `record_age_consent` in
`client_api_contract.md`, attributed to `auth.uid()` or `x-install-id`.

**Decision (fill in):**
`_______________________________________________ on ____________`

---

# STAGE 1 — A green build

**One day. Nothing after this can be trusted until it is true once.**

`maintenance.md` is honest about it: nothing in the video hub has been verified
by a compiler in this workflow. Structural checks pass, and structural checks
prove shape, never meaning.

**Steps**

1. FlutLab **Analyzer** tab. It runs a per-project language server that knows
   every object in the project and answers in seconds.
2. `python3 tool/check.py` — the eight structural checkers.
3. Build.

**Gate:** an APK installs, the Movies chip opens the age gate, and the demo
catalogue renders. Not "it compiled" — it runs.

**If it fails,** read the error against `build-workflow` habits: a missing
import surfaced by a new type annotation, a class member shadowing an extension
member, a named argument passed through a variable (which no checker sees). The
Analyzer names these in seconds; the Python checks never will.

---

# STAGE 2 — The Supabase foundation

**Two to three days. This is the most important stage in the document.**

`movies_gaps.md` #3 is the reason: `ApiContentRepository` conforms to the
interface and compiles, and **has never met a real server**. Every timestamp
format, null column, array shape and error body in it is an assumption. The
demo repository has hidden this by returning exactly what the app wanted.

## 2.1 Create the project

One Supabase project, free tier, **no card required**. Name it for production;
staging can wait (free tier allows two, and a staging project will be paused by
the 7-day inactivity rule exactly when you need it).

Record the project URL and the anon key. The anon key is **not a secret** — it
ships in the APK by design. The service-role key **is**, and must never appear
in the app, the repo, or any string the app can reach.

## 2.2 The `titles` table — columns exactly as the app asks for them

The app sends an explicit column list and never `*`. Match it or the adapter
returns nulls where the UI expects values.

```sql
create table public.titles (
  id             uuid primary key default gen_random_uuid(),
  title          text not null,
  title_mm       text,
  synopsis       text,
  category       text not null,             -- movies | series | reels | adult
  poster_url     text,
  year           int,
  rating         numeric,
  quality_label  text,
  genres         text[] not null default '{}',
  episode_count  int,
  popularity     int,
  access_tier    text not null default 'premium',   -- free | premium
  photo_count    int,                       -- NULL = unknown. Never 0 for "not counted"
  video_count    int,
  status         text not null default 'live',      -- live | hidden | takedown
  provider       text not null default 'r2',
  locator        text,                      -- NEVER selectable by a client
  provider_meta  jsonb not null default '{}'::jsonb,
  content_key    bytea,                     -- 16 bytes. NEVER selectable
  segment_count  int,
  duration_secs  int,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index on public.titles (category, popularity desc nulls last);
create index on public.titles (updated_at desc);
```

Three details that are deliberate:

* **`access_tier` defaults to `premium`, not `free`.** Fail toward locked. A
  row inserted by a script that forgot the column is hidden, not given away.
* **`status` exists from day one** (`movies_gaps.md` #8). Adding a kill switch
  after you need one is a week you do not have.
* **`photo_count` / `video_count` are nullable and must stay nullable.** Absent
  is not zero — the card draws nothing for null and "0 photos" for zero, and
  only one of those is honest.

## 2.3 RLS on every table, before any data goes in

```sql
alter table public.titles enable row level security;

-- Anonymous and registered may read the catalogue, but never the locator,
-- the key, or a hidden title.
create policy titles_read_public on public.titles
  for select to anon, authenticated
  using (status = 'live');
```

**The locator problem, and why a policy is not enough.** RLS filters *rows*,
not *columns*. A client that asks for `select=locator` gets it. Two ways to
close that, and you want the second:

```sql
-- Revoke the columns outright from the API roles.
revoke select (locator, content_key, provider_meta)
  on public.titles from anon, authenticated;
```

**Gate for this section — run it before writing another line:**

```bash
# 1. A live free title comes back.
curl "$URL/rest/v1/titles?select=id,title,access_tier" -H "apikey: $ANON"

# 2. The locator does NOT.  Expect an error, not a value.
curl "$URL/rest/v1/titles?select=id,locator" -H "apikey: $ANON"

# 3. A hidden title does not appear at all.
curl "$URL/rest/v1/titles?select=id,title&status=eq.hidden" -H "apikey: $ANON"
```

> Most paywalls do not fail at the cryptography. They fail because a table was
> readable from the start. **Test with curl, not the app. The app is not the
> attacker.**

## 2.4 Three rows, deliberately chosen

Insert exactly three titles: one `free`, one `premium`, one with
`status='hidden'`. Not ten — three, each proving one thing. A catalogue of
sample data hides the case you did not think about.

## 2.5 The three RPCs

The app calls `landing_rows`, `row_catalogue` and `catalogue_facets`. They exist
for reasons worth preserving:

* **`landing_rows`** — a cold start is one round trip instead of five. On a
  Myanmar mobile connection that is the difference between "fast" and "broken".
* **`row_catalogue`** — a row's scope can span categories (Trending covers
  films, series and clips), which no column filter can express.
* **`catalogue_facets`** — the filter sheet needs the available genres, years
  and qualities without downloading the catalogue to derive them.

Each takes `include_restricted` and must apply the same tier rule as the table
policy. Write them `security definer` with `set search_path = public`.

## 2.6 Measure the response size

```bash
curl -s "$URL/rest/v1/rpc/landing_rows" -H "apikey: $ANON" \
     -H "Content-Type: application/json" -d '{"include_restricted":false}' \
  | wc -c
```

**Gate: a page of 20 titles must be under 10 KB.** This is the limit the
capacity model identified as binding: 5,000 users browsing at 50 KB a session
is 5 GB — the entire free monthly egress, before a single video plays. It is
cheap to fix now and impossible to retrofit once people depend on it.

---

# STAGE 3 — Connect the app

**One to two days, most of it small mismatches. That is the point.**

```bash
flutter build apk --release \
  --dart-define=VH_BASE_URL=https://xxxx.supabase.co \
  --dart-define=VH_ANON_KEY=eyJhbGciOi...
```

`BackendConfig.isConfigured` flips, every repository switches from the demo
stubs to `ApiContentRepository`, and nothing else in the app changes.

**Gate:** the three titles appear in the app, with posters, and the premium one
shows a lock.

**Expect a day of tedious mismatches** — timestamp parsing, a `numeric` arriving
as a string, an empty array where null was expected, a genre filter that does
not match PostgREST's `ov.{}` syntax. Every one of them is cheap here and
expensive later, because right now there is only one layer that can be lying.

**Keep a list as you go.** Each mismatch is either a server fix or an adapter
fix, and the ones that turn out to be adapter fixes belong in
`client_api_contract.md` so the next person does not rediscover them.

---

# STAGE 4 — Backup, the same day real data exists

**Half a day. Do not defer this.**

Supabase's free tier has **no backups**. Every video survives a Supabase loss
because Telegram holds the masters — **the catalogue does not**. Titles, tiers,
subscriptions, device slots, who paid: all of it in one free-tier database with
nothing behind it.

```yaml
# .github/workflows/backup.yml
name: backup
on:
  schedule: [{ cron: '0 3 * * 0' }]     # weekly, Sunday 03:00 UTC
  workflow_dispatch:
jobs:
  dump:
    runs-on: ubuntu-latest
    steps:
      - run: pg_dump "${{ secrets.SUPABASE_DB_URL }}" --no-owner -Fc -f dump.pgc
      - run: |
          curl -F document=@dump.pgc \
            "https://api.telegram.org/bot${{ secrets.TG_TOKEN }}/sendDocument?chat_id=${{ secrets.TG_BACKUP_CHAT }}"
```

**Gate:** run it manually once, then **restore it into a scratch project**. A
backup that has never been restored is a file, not a backup.

Losing the `subscriptions` table means asking a thousand people to prove they
paid. This is twenty lines against that.

---

# STAGE 5 — Take money

**Three to four days.** `movies_gaps.md` groups the approval bot and device
recovery together for a good reason: they are the same bot and the same
operator, and building them apart builds the bot twice.

## 5.1 Subscriptions, requests, payment instructions

Schema is in `premium_backend_spec.md` §2. Three policies matter more than the
tables:

```sql
-- A client may insert a CLAIM, and may not name its status.
create policy pr_insert on public.premium_requests
  for insert to authenticated
  with check (user_id = auth.uid() and status = 'pending');

-- A client may read only its own claims.
create policy pr_read on public.premium_requests
  for select to authenticated using (user_id = auth.uid());

-- NOBODY writes subscriptions from the client. No insert/update policy at all.
-- Only the approval function, which runs as service_role.
```

**The hole this closes:** letting a client name a status is how somebody submits
an already-approved one. The app never sends `status` — the policy is what makes
that guarantee real rather than polite.

`payment_instructions` is readable **without auth**, so the price is visible
before sign-in.

## 5.2 The device slot

```sql
create table public.devices (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  device_id     text not null,
  label         text,                    -- "Samsung A15" — so the user knows which
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  released_at   timestamptz
);

create unique index devices_one_active
  on public.devices (user_id) where released_at is null;

create table public.device_switches (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  last_switch timestamptz not null default now()
);
```

The partial unique index is the whole enforcement: **the database physically
cannot hold two active devices for one user.** Not a check in a function
somebody forgets to call — a constraint.

`device_switches` is **per account, not per device**, or the cooldown resets by
reinstalling.

## 5.3 Device recovery — the part that is not optional

`movies_gaps.md` #2 is right and understated. Over nine months and 1,000
subscribers, phones break weekly. Without a recovery path, **every broken phone
is a paying customer locked out by a mechanism you built on purpose**.

```sql
create or replace function public.release_device_slot(new_device_id text,
                                                      new_label text)
returns json language plpgsql security definer set search_path = public as $$
declare last_at timestamptz; cooldown interval := interval '14 days';
begin
  select last_switch into last_at from device_switches where user_id = auth.uid();

  if last_at is not null and last_at + cooldown > now() then
    return json_build_object('ok', false,
                             'retry_after', last_at + cooldown);
  end if;

  update devices set released_at = now()
   where user_id = auth.uid() and released_at is null;

  insert into devices (user_id, device_id, label)
       values (auth.uid(), new_device_id, new_label);

  insert into device_switches (user_id, last_switch) values (auth.uid(), now())
    on conflict (user_id) do update set last_switch = now();

  return json_build_object('ok', true);
end $$;
```

Three properties, each load-bearing:

* **Self-service, once, with a cooldown.** The honest case never reaches a
  human. The cooldown is what stops it becoming account sharing: a shared
  account with a 14-day switch cost is useless to a group and barely noticeable
  to a person who changed phones.
* **A visible date.** "You can switch devices again on 12 September." A refusal
  the user cannot predict reads as a bug.
* **An operator override** through the admin bot, for the genuine edge cases.

## 5.4 The admin Telegram bot

The same private channel as ingest. No dashboard, no laptop — the phone is
enough.

| Command | Does |
|---|---|
| `/pending` | lists unreviewed claims: id, plan, KPay reference, sender number |
| `/approve <id> <months>` | **one transaction**: mark approved, insert the subscription, notify the user |
| `/reject <id> <reason>` | mark rejected with a note the user can read |
| `/device <user>` | show the active slot; force-release it |
| `/takedown <title>` | set `status='takedown'` |

Runs as a **Supabase Edge Function used as the Telegram webhook** — free, no
server. It is the only thing besides the approval path that may hold the
service-role key.

**Notify on arrival**, so approvals are minutes rather than hours. At 1,000
premium users over nine months this is about **four approvals a day**, a few
seconds each. Manual is fine at that size — but only with the bot. Four a day
in a SQL console is not fine.

**Gate:** submit a claim from the app, approve it from your phone, and watch the
app move to premium without anyone touching a browser.

## 5.5 Client-side work this stage requires

Two real gaps where the code does not match the plan:

**(a) `DeviceIdentity` must move to Keystore-backed storage.**
`movies_access_plan.md` §4 says an id in SharedPreferences is cleared by "Clear
data", freeing the slot — so the binding enforces nothing.
`lib/features/video_hub/data/device_identity.dart` still uses
`SharedPreferences`. Move it to the Keystore-backed secure storage the Private
Folder vault already uses, and exclude it from backup so it survives an app-data
clear but does not travel to a new phone.

**(b) `AccessDenial` needs a third value.** It has exactly two —
`needsPremium` and `unavailable`. A server 409 `wrong_device` arrives as
`ApiErrorKind.forbidden` and renders as **"unavailable"**: a paying customer
with a new phone sees an unexplained error and no route to the self-service
release that Stage 5.3 just built.

```
enum AccessDenial { needsPremium, wrongDevice, unavailable }
```

Then a screen: which device holds the slot, a "use this device instead" button,
and the cooldown date when it is refused. Without this, 5.3 exists and nobody
can reach it.

---

# STAGE 6 — Survive

**Three days. Neither of these can be added under pressure**, which is the only
time you will want them.

## 6.1 The in-app updater

Outside Play there is no other way to ship a fix, and **the first urgent update
will be a security fix** — by definition, urgent.

* A **version endpoint**: a JSON file in R2. No server, no cost.
  ```json
  { "latest_build": 312, "min_supported_build": 305,
    "url": "https://cdn.../innocent-1.6.0.apk",
    "sha256": "...", "notes_my": "...", "notes_en": "..." }
  ```
* **Check on launch**, a "what changed" sheet, a download with progress.
* **`REQUEST_INSTALL_PACKAGES` is already in the manifest** (the downloader
  needed it) — half the native work is done. The Android 8+ install-source
  consent flow is the remaining part, and it makes this a **minor** version
  bump.
* **Verify the SHA-256 before installing.** An updater that installs whatever it
  downloaded is a backdoor with a progress bar.
* **`min_supported_build`**: below it the app refuses to run and offers only the
  update. **Design this now** — retrofitting it means the users who most need a
  fix are running the version that cannot be told about it.

## 6.2 The kill switch

`titles.status` already exists from Stage 2.2. Wire it:

* the catalogue policy already filters `status = 'live'`
* the **grant path** must check it too — takedown stops new playback immediately
* the **download licence check** must check it — the next revalidation kills
  existing offline copies

**Gate:** set a title to `takedown`, confirm it vanishes from the catalogue,
that playback is refused, and that a downloaded copy stops working at its next
licence check.

---

# STAGE 7 — Deliver the video

**Four to five days.** Do every step by hand before automating any of it.

## 7.1 Two buckets, not one

The docs have said both "the bucket must never be public" and "posters go to a
public path". Both are right, and they need **two buckets**:

| Bucket | Access | Holds |
|---|---|---|
| `innocent-media` | **private**, presigned URLs only | encrypted HLS segments |
| `innocent-public` | public custom domain | posters, thumbnails, the updater JSON and APK |

A poster is not a secret and gating it costs a Worker call per card. A segment
is, and there is no reason for it to have a permanent URL.

## 7.2 Cloudflare account — the billing facts, checked

* R2 requires a **payment method on file even inside the free allowance**.
* Cloudflare accepts **Visa, Mastercard, Amex, Discover, PayPal, Apple Pay,
  Google Pay, Stripe Link and UnionPay**, and allows **two payment methods per
  account** — so the PayPal you are opening works, and roadmap 6.4's backup
  method is a real feature rather than a hope.
* There are user reports of a **$5 charge at activation**. Read the confirmation
  screen before agreeing.
* If a payment fails, **R2 access is suspended and requests error while the data
  stays intact; after 30 days it may be deleted.** This is exactly why every
  master lives in Telegram — a lost R2 is a re-package, not a loss.

**Add the backup payment method on day one, not after the first decline.**

## 7.3 Package one clip by hand

```bash
openssl rand 16 > key.bin
printf 'https://cdn.example.com/k/PLACEHOLDER\nkey.bin\n' > key_info

ffmpeg -i master.mp4 \
  -c:v libx264 -crf 23 -preset veryfast -c:a aac -b:a 128k \
  -hls_time 6 -hls_key_info_file key_info -hls_playlist_type vod \
  -hls_segment_filename 'seg_%03d.ts' out.m3u8

ffmpeg -i master.mp4 -ss 5 -vframes 1 poster.jpg
```

CRF 23 at 720p puts a 15-minute clip around 200 MB, which is what makes the
capacity model's storage numbers true.

**The rule, and it is the whole point:** the key goes to **Supabase**, never to
the bucket. A key stored next to the segments it decrypts is not encryption; it
is a filing convention.

```sql
update titles set content_key = decode('<hex>', 'hex'), segment_count = 150
 where id = '...';
```

## 7.4 The Worker

Two endpoints. That is all.

```
GET /p/<title_id>?t=<signed>   → verifies, then GENERATES the .m3u8 with
                                 R2 presigned segment URLs already in it
GET /k/<title_id>?t=<signed>   → verifies, reads content_key, returns 16 bytes
```

* The **key URI in the playlist points at the Worker**, not at a file. The
  playlist is useless without the key, and the key is a live authorization
  decision rather than an object sitting in storage.
* The playlist is **generated per request**, so there is no static manifest to
  share either.
* Segments are fetched **straight from R2**, with no Worker in the path: 2
  Worker calls per view instead of 152, and one less network hop.
* The Worker holds **no entitlement logic of its own**. It verifies a token
  minted by Supabase and asks Supabase for the key. If it starts deciding
  things, the design has broken.

**Gate:**
1. an unsigned segment request is refused
2. a signed one works
3. `/k/` with no token returns 403
4. a **free account's** token is refused by `/k/` — tested with curl, not the app

## 7.5 Wire `request-playback` to the subscription

Edge Function, in order, stopping at the first failure:

1. JWT valid? → 401
2. `titles.status = 'live'`? → 404
3. this device holds the account's active slot? → **409 `wrong_device`**
4. `titles.access_tier = 'premium'`? → `has_active_subscription()` → **403
   `needs_premium`**
5. over the concurrent-stream cap? → 429
6. insert `play_grants`
7. mint the signed token; return `{url, expires_at}`

`needs_premium` **must be that exact string.** It is the one value that
separates a paywall from an error screen, and getting it wrong loses the sale
*and* looks like a bug.

There is **no `isPremium: true` anywhere in the response.** A proxy that
rewrites every byte still cannot produce a token the Worker accepts, because
only the server holds the signing key. That is the difference between sending a
permission and sending a capability, and it is why TLS pinning being bypassable
does not matter here.

**Gate — the one that matters most in this document:** sign in as a free
account, get its JWT, and call `request-playback` for a premium title **with
curl**. It must return 403 `needs_premium`. Then do it for a free title and
watch it play.

---

# STAGE 8 — Offline downloads

**Four days.** This is the feature people actually pay for on Myanmar mobile
data — and it has one unsolved design problem that must be settled first.

## 8.1 The problem the plans have not addressed

`movies_access_plan.md` §3 says: download the encrypted segments as they are,
wrap the key with an Android Keystore key, store only the wrapped blob. All
correct. **It never says how libmpv gets the key at playback time.**

HLS players read the key from the URI in the playlist. Writing the key to disk
as a file destroys the entire point of wrapping it.

## 8.2 The solution is already in this codebase

`lib/core/services/downloader/stream_proxy.dart` is a loopback HTTP server
bound to 127.0.0.1, protected by random per-item tokens, already forwarding
range requests for the player. It was built so TikTok headers could travel with
a request; it is exactly the shape this needs.

```
player  →  127.0.0.1:PORT/p/<token>   → a rewritten local playlist
                                         key URI → 127.0.0.1:PORT/k/<token>
                                         segments → file:// paths
player  →  127.0.0.1:PORT/k/<token>   → Keystore unwrap, 16 bytes FROM MEMORY
player  →  file:///.../seg_000.ts     → encrypted bytes straight off disk
```

The key exists in plaintext only inside the process, only while a download is
playing. Nothing writes it anywhere.

**Design it before writing the downloader**, or the download lands and there is
no way to play it.

## 8.3 The four properties

| Property | Mechanism | Stops |
|---|---|---|
| Bytes already encrypted | store the segments as downloaded | there is never a plaintext file to find |
| Key never in the clear | Keystore-wrapped, `setUnlockedDeviceRequired(true)` | copying app data to another phone yields an unopenable blob |
| App-private storage | `getFilesDir()`, not `/sdcard` | other apps, USB, MTP |
| Licence expires | `expires_at` + revalidate within 30 days | "subscribe one month, download everything, cancel" |

```sql
create table public.download_licenses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title_id uuid not null references public.titles(id) on delete cascade,
  device_id text not null,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  last_verified_at timestamptz not null default now()
);
```

The app refuses to play a download not revalidated online within 30 days, and
deletes it when the subscription ends or the title is taken down.

**Stated honestly:** a rooted phone running a patched build can hook the app
after it unwraps the key. That is true of every non-DRM scheme and of Widevine
L3 as well. The defence is that it takes a rooted phone, a patched APK and real
skill — a different population from people who right-click and save.

**Gate:** download a title, put the phone in airplane mode, play it. Then copy
the app's data directory to another device and confirm it yields nothing.

---

# STAGE 9 — Automate ingest

**Two days, and only after three or four titles have gone through by hand.**
Automating a process you have not yet performed correctly automates the mistake.

## 9.1 Verify the load-bearing assumption first

**The Telegram Bot API cannot download the masters — the cap is 20 MB**, and a
master is 200 MB to 2 GB. The way out is an **MTProto client (Telethon or
gramjs) signed in as the bot**: same bot, same channel, different protocol, no
20 MB limit. It needs an `api_id`/`api_hash` from `my.telegram.org` — free, one
form.

**Test this with one 500 MB file before building anything around it.** It is the
single assumption the whole ingest path rests on.

## 9.2 The pipeline

```
Telegram private channel  ← you upload the master with a caption
        ↓  bot writes ONE row to ingest_queue (it downloads nothing)
GitHub Actions (2,000 min/month private, unlimited public)
        1. Telethon pulls the master
        2. openssl rand 16 > key.bin
        3. ffmpeg → encrypted HLS, ~150 segments
        4. ffmpeg → poster.jpg
        5. aws-cli → segments to the private bucket, poster to the public one
        6. Supabase → insert the title row + the key; mark the job done
```

Caption carries the metadata, so the archive is self-describing:

```
#new
title: Example Title
tier: premium
tags: tag-a, tag-b
```

Two rules, both the whole point:

* **The content key goes to the database, never to storage and never to git.**
* **Repository secrets only, and the workflow must never echo them.** A leaked
  R2 token is a leaked catalogue.

---

# STAGE 10 — Launch gates

**Cannot open without these.** None is more than a day.

| # | Gate | Why |
|---|---|---|
| 10.1 | **A second Telegram archive** | Telegram is the backstop for R2, for Cloudflare and for the payment method. **It has no backstop of its own.** A second channel, a second account, or a cold copy on a drive. Every other failure in the runbook is recoverable *because* the masters exist; this is the one row that says unrecoverable |
| 10.2 | **Age verification as decided in 0.2** | Play is not doing it. It is a legal exposure, and the decision matters more than the mechanism |
| 10.3 | **A support route** | A user whose payment was approved but who still sees a paywall currently has no way to reach you. A Telegram support link in the Me tab is enough |
| 10.4 | **`play_failures` telemetry** | Title, error kind, app version. **No personal data.** Ten rows a day is noise; two hundred means something broke this morning — and without it, the first signal is a user complaining loudly |
| 10.5 | **A pricing screen** | The plans exist in the database and nothing in the app says what VIP costs or what it unlocks |
| 10.6 | **Licence records per title** | The content is licensed; keep the proof per title where it can be produced. Some jurisdictions require record-keeping for this category specifically |

---

# The client-side work queue

Code changes this plan requires, in the order they are needed. All are Dart
unless marked.

| # | Change | Needed by | Size |
|---|---|---|---|
| C1 | Auth flow, if Stage 0.1 picks option C — `api_account_repository`, `sign_in_sheet` | Stage 5 | 1 day |
| C2 | `DeviceIdentity` → Keystore-backed, excluded from backup | Stage 5.2 | half a day |
| C3 | `AccessDenial.wrongDevice` + a device-switch screen | Stage 5.3 | 1 day |
| C4 | In-app updater + install-source consent (**native — minor bump**) | Stage 6.1 | 2 days |
| C5 | Offline download: local key-serving proxy, Keystore wrap, licence check | Stage 8 | 3 days |
| C6 | Disk image caching (`cached_network_image` in `PosterImage`) | any time | 2 hours |
| C7 | The four unit tests in `maintenance.md` §3C | any time | 2 hours |
| C8 | Pricing screen, support link, `play_failures` reporting | Stage 10 | 1 day |

C6 and C7 are cheap and independent — good filler while waiting on a backend
step.

---

# The order, on one screen

```
0  decide auth + age                     1 day    ← blocks the schema
1  green build                           1 day    ← blocks everything
2  Supabase: titles, RLS, RPCs, curl     3 days   ← the important one
3  point the app at it                   2 days   ← finds the real mismatches
4  pg_dump → Telegram, weekly            ½ day    ← the day data exists
5  subs, requests, devices, admin bot    4 days   } same bot,
   + C1, C2, C3                          2 days   } same operator
6  updater (C4) + kill switch            3 days   ← cannot be added in a hurry
7  R2 ×2, hand-packaged clip, Worker     5 days   ← money model proven
8  offline downloads (C5)                4 days   ← what people pay for
9  Actions ingest pipeline               2 days   ← after 3-4 by hand
10 launch gates                          3 days
```

Roughly **six weeks** of working days, and the first eight days are the ones
that turn every other estimate from a guess into a schedule.

---

# The five sentences worth remembering

> **Supabase decides. R2 stores. The Worker enforces. Telegram archives.
> Nothing does two of those jobs.**

> **Never send a permission. Send a capability.**

> **Test the paywall with curl, as a free account. The app is not the
> attacker.**

> **The video is the cheap part. The catalogue is the expensive part — and
> until Stage 0.1 is decided, so is the login.**

> **A stage is done when its gate passes, not when the code is written.**
