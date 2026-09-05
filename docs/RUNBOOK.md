# RUNBOOK — everything to run, in order

Written 2 Sep 2026, current as of app **v1.64.1+314**.

One document, because the instructions were spread across a dozen chat
messages and a folder of SQL files. Run top to bottom. Every step says what it
should produce, so a wrong result stops you at the step that caused it rather
than three steps later.

**Every SQL file is safe to run twice.** Each checks whether it has already
been applied and skips. If you lose your place, re-run from the top.

---

## PART 0 — WHAT ALREADY EXISTS

| | |
|---|---|
| Supabase project | `yqonvmuiezqvyqmexrft`, region `ap-southeast-1` |
| R2 buckets | `innocent-media` (private), `innocent-public` (public) |
| Edge functions | `request-playback` (v3), `self-test`, `backfill-dimensions` |
| Migrations applied | 001–009 |
| App | v1.64.1+314, backend baked into `BackendConfig` |

---

## PART 1 — SQL, IN THIS ORDER

Each goes in a **NEW query tab** in the SQL Editor. Never paste over an old
one - re-running an old tab by accident is how the wrong migration gets
applied twice.

| # | file | what it does | should produce |
|---|---|---|---|
| 001 | `step1_supabase_v2.sql` | titles, RLS, column grants, 4 RPCs | `Success. No rows returned` |
| 002 | *(inside 001's follow-up)* | `service_role` grants | — |
| 003+004 | `003_004_tracking_and_lifecycle.sql` | migration tracking, `extra`, `status` | 4 rows: 001–004 |
| 005 | `005_schema_migrations_grant.sql` | let the server read its own table | `005` |
| 006 | `006_title_assets.sql` | assets, primary poster, `title_media` view | `photo_count`=1, `video_count`=1 |
| 007 | `007_slug_and_add_title.sql` | `slug`, `add_title()` | slug filled in |
| 008 | `008_operator_ergonomics.sql` | metadata params, `publish_title`, health view | `catalogue_health` |
| 009 | `009_album_order_and_clip_thumbs.sql` | album order, clip thumbnails | photos at 1001+ |
| **010** | **`010_premium_backend.sql`** | **subscriptions, devices, requests, prices** | **`010`** |
| 011 | `011_sort_order_collisions.sql` | album order continues instead of restarting | every `distinct_orders` equals `assets` |
| **012** | **`012_app_releases.sql`** | **in-app updater manifest, one row** | **`012`, and `anon` can read it** |

> **012 does not depend on 003-011.** It has no foreign key, no RPC and creates
> `schema_migrations` itself, so it can be run before the others are finished.
> `select version from schema_migrations` will show a gap until they are, and
> the gap is the table reporting the truth rather than a fault.

**After the whole run:**

```sql
select version, note from public.schema_migrations order by version;
-- 001 through 010, ten rows.
```

### The one check that must FAIL

```sql
set role anon;
select locator from public.titles limit 1;        -- must ERROR
select object_key from public.title_assets limit 1; -- must ERROR
reset role;
```

Both must be refused. If either returns data, every media path in the
catalogue is readable by anyone holding the key that ships inside the APK.
**Stop and fix before anything else.**

---

## PART 2 — EDGE FUNCTIONS

All three: **Deploy → Settings → turn `Verify JWT with legacy secret` OFF.**

> That toggle has been observed switching itself back on after a redeploy.
> Check it EVERY time. Left on, the function 401s before your code runs, and
> the app reads a 401 as `needsPremium` - a paywall on a free title.

| function | file | notes |
|---|---|---|
| `request-playback` | `request-playback-v3.ts` | the security boundary |
| `self-test` | `self-test.ts` | your one-tap health check |
| `backfill-dimensions` | `backfill-dimensions.ts` | run after each upload session |

### Secrets (Edge Functions → Secrets)

```
R2_ACCOUNT_ID          048680c1bbdd81dfc33d5cab9f9acfb8
R2_ACCESS_KEY_ID       8ac9c57d7fe41c20ca1eaa4c01e51d86
R2_SECRET_ACCESS_KEY   2f60015610f48f306d36135b0ed9fa7839b61bb77c0fc5d3707219cdd3f681fa
R2_BUCKET              innocent-media
SB_SERVICE_KEY         <the legacy service_role JWT, 219 chars>
SB_ANON_KEY            sb_publishable_vTiAxBAhnZL_BqFcZD4m9A_Rb8Q8PHj
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically -
do not add them.

> `SB_SERVICE_KEY` exists because `SUPABASE_SERVICE_ROLE_KEY` now holds the
> NEW `sb_secret_` key, which is 41 characters and not a JWT. supabase-js puts
> the key in `Authorization: Bearer`, the platform cannot validate a non-JWT
> there, the connection silently drops to `anon`, and the `locator` read is
> refused by the very grants that exist to refuse it. The symptom was a flat
> `not_found`. **This cost two wrong guesses to find.**

### Then

**Run `self-test`. Ten checks, all PASS.** That is the gate for everything
below.

---

## PART 3 — ADDING A TITLE

```
1.  VPN OFF                       ← a VPN silently breaks R2 uploads
2.  R2: innocent-media/<slug>/    video1.mp4, video2.mp4 …
    R2: innocent-public/<slug>/   photo1.jpg, photo2.jpg …
                                  ← folder names must MATCH
3.  SQL:  select public.add_title(
              'spiderman', 'Spider-Man',
              array['video1.mp4'], array['photo1.jpg','photo2.jpg'],
              p_title_mm := 'ပင့်ကူလူသား', p_year := 2026,
              p_genres := array['Action'], p_quality := 'HD',
              p_tier := 'free');
4.  Function: backfill-dimensions → Send Request
5.  SQL:  select * from public.catalogue_health;   ← verdict must be 'ok'
6.  SQL:  select public.publish_title('spiderman');
7.  App:  pull to refresh
```

**Five titles at a time, then test all five, then the next five.** Not a
hundred at once: `add_title` cannot check that the file exists in R2, so a
mistyped filename produces a title that looks perfect in the catalogue and
dies on Play. The health view catches missing rows; only opening the app
catches a wrong name.

### Changing the card image

```sql
select a.id, a.object_key, a.is_primary
from public.title_assets a join public.titles t on t.id = a.title_id
where t.slug = 'spiderman' and a.kind = 'photo' order by a.sort_order;

select public.set_primary_asset('<the id you want>');
```

---

## PART 4 — WEEKLY

**Back up.** The free tier has NO backups - no daily, no downloadable, no PITR.
R2 holds `spiderman/video1.mp4`; only this database knows that is a film.

```sql
select json_build_object(
  'titles', (select json_agg(t) from (select * from public.titles order by created_at) t),
  'assets', (select json_agg(a) from (select * from public.title_assets order by added_at) a),
  'subs',   (select json_agg(s) from (select * from public.subscriptions order by created_at) s)
);
```

Export it. Keep the last few.

**Keep the project awake.** A free project pauses after **7 days without a
database query**, and the app then shows an empty catalogue with no
explanation. Running `self-test` counts as activity. A free uptime pinger
hitting the REST endpoint every few minutes removes the problem entirely.

---

## PART 5 — PREMIUM (after 010)

### Set the price - this is what the paywall shows

```sql
update public.payment_instructions set
  payee_name   = 'Yann Min Htan',
  payee_number = '09xxxxxxxxx',
  prices       = '{"monthly":"5000 MMK","yearly":"45000 MMK"}'::jsonb,
  note         = 'KPay ပို့ပြီး reference ကို app ထဲ ထည့်ပါ'
where id = 1;
```

Readable **without a session**, on purpose: the paywall has to show a price
before anyone has a reason to sign in.

### The daily loop

```sql
select * from public.pending_requests;              -- the inbox
select public.approve_request('<id>', 30);          -- 30 days
select public.reject_request('<id>', 'ငွေမရောက်ပါ');
```

`approve_request` EXTENDS an existing subscription rather than replacing it,
so an early renewal never loses days already paid for.

### ⚠️ Premium cannot work until auth is switched on. See Part 6.

---

## PART 6 — THE AUTH DECISION (still open, and now clearer)

**The client has already chosen.** `api_account_repository.dart` calls
`/auth/v1/otp` with a phone number and `/auth/v1/verify` with `type: 'sms'`.
It is built for native phone OTP.

| | Phone OTP | Phone-as-email + password |
|---|---|---|
| Client work | **none** | sign-in sheet, sign-up, password field, repository - a real rewrite |
| Cost | **per SMS, forever** | zero |
| Myanmar delivery | international SMS routes, unreliable | n/a |
| Recycled SIM | **whoever holds the number gets in** | they would also need the password |
| Password recovery | n/a | **operator only** - no real inbox to send to |

Two things worth knowing before deciding:

* Supabase's own documentation discourages phone-as-identifier because
  **networks recycle numbers**, and recommends MFA to compensate. With OTP the
  SIM IS the credential, so a recycled number is a handed-over account. With a
  password it is not.
* Storing or confirming a phone number in Supabase generally requires an SMS
  provider to be configured **even when you do not want confirmation** -
  developers report `Unable to get SMS provider` for unrelated calls. So "phone
  auth without SMS" is not a supported middle path.

**Nothing in migration 010 depends on this.** It keys off `auth.users(id)` and
`auth.uid()`, which are identical either way. The decision changes the sign-in
screen and the monthly bill, not the schema - so it can be made late without
rework.

**It is also not urgent.** Free titles need no account at all. Premium refuses
until auth exists, which is the correct order: prove the catalogue, then sell
it.

---

## PART 7 — STILL OPEN

| | why it matters |
|---|---|
| **Shrink the posters** | 3.31 MB each. A free viewer downloads every LOCKED photo in full to see a blur of it - at a hundred titles that is real money on Myanmar mobile data. ~500 px wide, JPEG, gets it to ~80 KB |
| **Event log** | algorithms can be written later; events cannot be recreated later. Every day without it is a day of data that will never exist |
| **Admin panel** | passcode + HMAC session + rate limit + audit log. Would replace most of Part 3 with taps |
| **Reels masonry** | needs `backfill-dimensions` to have run over real clips first. A masonry with no ratios IS a uniform grid |
| **Android verification** | Sep 30 2026 affects **Brazil, Indonesia, Singapore, Thailand only** - NOT Myanmar. Global in 2027. Your own Singapore device is affected; ADB and the advanced flow still work |

---

## APPENDIX — WHEN SOMETHING BREAKS

| symptom | look here first |
|---|---|
| Movies tab empty | `self-test`. Then: is the project paused? |
| Title shows, Play fails | filename mismatch - compare `titles.locator` with R2 |
| Paywall on a FREE title | `Verify JWT` switched itself back on |
| `not_found` from playback | function **Logs** tab - v3 writes the real reason there |
| Poster missing | `backfill-dimensions` failures list, or `catalogue_health` |
| Album reshuffles itself | migration 009 not applied |
| Upload fails in R2 | **VPN** |

Edge function logs are kept **one day** on the free tier. Copy anything
interesting out immediately.
