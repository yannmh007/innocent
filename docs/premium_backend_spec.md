# Premium backend — security specification

Everything the app does about premium access is a **user-interface
affordance**. This document describes the part that actually enforces
anything. Implement it before taking money.

---

## 0. The one thing to internalise first

> If a device can play it, a device can copy it.

There is no configuration that makes video uncopyable. A screen recorder, a
patched build, or a camera pointed at the screen defeats every client-side
measure that exists, including full DRM. The realistic goal is not prevention;
it is to make copying **expensive, inconvenient and traceable**, and to close
the cheap paths that account for almost all real leakage:

| Path | Cost to attacker | Closed by |
|---|---|---|
| Share a permanent media URL | zero | short-lived signed URLs |
| Pull the file with a downloader | minutes | no direct URLs; token-gated proxy |
| Sign in on 40 devices with one account | zero | session binding + concurrency cap |
| Patch the APK's `isPremium` flag | minutes | **server-side authorization** |
| Screen-record playback | minutes | `FLAG_SECURE` (Android), watermark |
| Capture with external hardware | high | nothing. Accept this. |

The row that matters most is the fourth. Everything else is refinement; that
one is the difference between a paywall and a suggestion.

---

## 0b. Why a man-in-the-middle does not get in

The obvious worry is that someone intercepts the app's traffic, edits the
reply, and walks through the paywall. Whether that works depends entirely on
**what the reply contains**.

| The server returns | An attacker on the wire |
|---|---|
| `{"isPremium": true}` — a PERMISSION | flips `false` to `true` and is in |
| a signed, expiring, identity-bound URL — a CAPABILITY | gains nothing |

In the second case there is **no boolean to flip**. What playback needs is a
cryptographic artifact that only the server can mint, because only the server
holds the signing key. A free account's proxy can rewrite every byte of the
response and still not produce a URL the CDN will honour. Intercepting a
premium user's own reply shows them their own URL, which they already had, and
which stops working in minutes.

So the rule is not "make the channel unbreakable". It is:

> **Never send a permission. Send a capability.**

The app must therefore contain no code path where a value received from the
network decides whether playback is allowed. It asks for a URL; it either gets
one or it gets a refusal with a reason. `security_invariants.py` enforces this
structurally: only `playback.dart` may open the player, only it may interpret a
grant, and no data adapter may consult the local capability table.

### Why not simply pin the certificate?

Do pin — it raises effort and stops passive interception on hostile networks.
But do not build on it. TLS pinning in a Flutter app is **known to be
bypassable**: `libflutter.so` handles TLS inside the engine, outside the
Android network stack, and public tooling (reFlutter) patches that binary to
disable verification, after which any proxy can read the traffic. Device
attestation does not close this either — Play Integrity tells you about the
device and the build, and explicitly does not prevent man-in-the-middle.

Both are worth having and neither is load-bearing. The capability design is
what makes their failure survivable.

### Attestation is a hint, never a verdict

If Play Integrity is added, its verdict may **raise friction** — rate-limit,
require re-login, flag for review. It must never be the thing that grants
access, and its absence must never be the thing that denies a paying customer.
Attestation fails for ordinary reasons: a de-Googled phone, a custom ROM, a
sideloaded build, a Play Services outage. A subscriber locked out by a false
positive is a refund and a bad review; an attacker who fails attestation simply
turns it off.

---

## 1. Non-negotiable rule

**The server must never return a playable URL to an account without an active
subscription.**

Not "the app hides the button". Not "the app checks a flag". The bytes must not
be obtainable. Every other measure here is secondary to that sentence.

This is why `ContentRepository.requestPlayback` returns a grant-or-reason
instead of a URL, and why the app never stores a media URL. When the HTTP
adapter replaces the local one, the verdict starts arriving from the server and
**no screen changes**.

---

## 2. Schema (Supabase / Postgres)

```sql
-- ---------------------------------------------------------------- profiles
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  phone       text,
  display_name text,
  created_at  timestamptz not null default now()
);

-- ----------------------------------------------------------- subscriptions
-- One active row per user. Written ONLY by the approval function.
create table public.subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  plan_id     text not null,              -- 'monthly' | 'yearly'
  starts_at   timestamptz not null default now(),
  expires_at  timestamptz,                -- null = lifetime
  created_by  uuid,                       -- the admin who approved
  created_at  timestamptz not null default now()
);
create index on public.subscriptions (user_id, expires_at desc);

-- -------------------------------------------------------- premium_requests
-- A CLAIM that a KPay transfer happened. Grants nothing by itself.
create table public.premium_requests (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  plan_id       text not null,
  reference     text not null,            -- KPay transaction id
  sender_phone  text,
  status        text not null default 'pending',   -- pending|approved|rejected
  note          text,
  submitted_at  timestamptz not null default now(),
  reviewed_at   timestamptz,
  reviewed_by   uuid
);
create index on public.premium_requests (status, submitted_at);

-- ------------------------------------------------------------------ titles
-- access_tier drives BOTH the badge in the app and the server's decision.
create table public.titles (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  access_tier  text not null default 'premium', -- 'free' | 'premium'
  status       text not null default 'live',    -- 'live'|'hidden'|'takedown'
  photo_count  int,                             -- NULL = unknown, never 0
  video_count  int,
  -- ... poster, year, genres, popularity ...
  provider     text not null,                  -- 'telegram' | 'bunny' | ...
  locator      text not null,                  -- NEVER exposed to clients
  content_key  bytea,                          -- 16 bytes. NEVER exposed
  provider_meta jsonb not null default '{}'::jsonb
);

-- ------------------------------------------------------------ play_grants
-- Audit + concurrency. One row per issued playback token.
create table public.play_grants (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  title_id    uuid not null references public.titles(id) on delete cascade,
  device_id   text,
  issued_at   timestamptz not null default now(),
  expires_at  timestamptz not null,
  ip          inet
);
create index on public.play_grants (user_id, issued_at desc);
```

### Three column decisions that look arbitrary and are not

* **`access_tier` defaults to `premium`, not `free`.** Fail toward locked. A row
  inserted by an ingest script that forgot the column is hidden rather than
  given away — visible and recoverable instead of silent and expensive.
* **`status` exists from day one.** It is the kill switch for a licence
  dispute, a mistake or a legal demand, and it must be checked in three places:
  the catalogue policy, the grant path, and the download licence check.
  A takedown that only stops new views leaves every offline copy playing.
* **`photo_count` / `video_count` are nullable and must stay nullable.** Absent
  is not zero: the card draws nothing for null and "0 photos" for zero, and only
  one of those is honest when the column has simply not been filled in yet.

### `active_subscription` helper

```sql
create or replace function public.has_active_subscription(uid uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.subscriptions
    where user_id = uid
      and starts_at <= now()
      and (expires_at is null or expires_at > now())
  );
$$;
```

---

## 3. Row Level Security

**Every table in `public` must have RLS enabled.** A table without RLS is
readable by anyone holding the project URL and the anon key — and both of those
ship inside the APK. There is no such thing as a private table without a
policy.

```sql
alter table public.profiles         enable row level security;
alter table public.subscriptions    enable row level security;
alter table public.premium_requests enable row level security;
alter table public.titles           enable row level security;
alter table public.play_grants      enable row level security;

-- profiles: your own row only
create policy "own profile" on public.profiles
  for select using (auth.uid() = id);
create policy "own profile update" on public.profiles
  for update using (auth.uid() = id);

-- subscriptions: READ ONLY, and only your own.
-- No insert/update policy exists at all, so no client can write one -- the
-- approval function uses the service role and bypasses RLS entirely.
create policy "own subscription" on public.subscriptions
  for select using (auth.uid() = user_id);

-- premium_requests: create your own claim, read your own claims.
-- No UPDATE policy: a user must not be able to set their own status to
-- 'approved'.
create policy "own requests read" on public.premium_requests
  for select using (auth.uid() = user_id);
create policy "own requests insert" on public.premium_requests
  for insert with check (
    auth.uid() = user_id and status = 'pending'
  );

-- titles: catalogue metadata is public to signed-in users...
create policy "catalogue read" on public.titles
  for select using (auth.role() = 'authenticated');

-- play_grants: never client-readable. No policy = no access.
```

### The column that must never be selectable

`titles.locator` is the actual storage address. A `select *` from the client
hands it over and every other measure becomes decoration.

Postgres RLS is **row**-level, not column-level, so a policy cannot hide it.
Two options, in order of preference:

1. Keep media addressing in a **separate table** (`title_sources`) with RLS
   enabled and NO select policy. Only the Edge Function (service role) reads
   it. This is the safer shape and the one to build.
2. Or expose the catalogue through a **view** that omits the column, revoke
   `select` on the base table from `anon`/`authenticated`, and grant it on the
   view only.

Do not rely on the client asking for a narrow column list. The client chooses
its own query.

---

## 4. Playback authorization (Edge Function)

The only endpoint that can produce a media URL.

```
POST /functions/v1/request-playback
Authorization: Bearer <user JWT>          -- keep verify_jwt = true
body: { "title_id": "...", "device_id": "..." }
```

Logic, in order:

1. **Verify the JWT.** Keep `verify_jwt = true` so the platform validates it
   before the handler runs. RLS does **not** cover Edge Functions — the
   function is its own authorization surface and must check for itself.
2. Load the title with the **service role** (this is the only place the
   service key is used; never put it in client code, never in a function that
   is callable without a JWT).
3. `access_tier = 'free'` → skip to 5.
4. `has_active_subscription(uid)` → false → return **403 `needs_premium`**.
   A distinct code, not a generic error: the app renders a paywall for this
   and a "something went wrong" screen for anything else.
5. **Concurrency check** — count `play_grants` for this user in the last
   N minutes with distinct `device_id`. Over the cap → 429 `too_many_devices`.
   This is what stops one subscription serving a group chat.
6. Mint a **short-lived signed URL** (5–10 minutes is plenty; the player only
   needs it to start, and HLS segments are re-signed as they are requested).
7. Insert a `play_grants` row (audit + the concurrency data for step 5).
8. Return `{ url, expires_at }`.

### Signing, per backend

* **Bunny** — token authentication on the pull zone: `SHA256(token_key + path +
  expiry)`. Native, documented, cheap.
* **Storj / any S3** — presigned `GET` with a short expiry.
* **Telegram** — has no concept of signed URLs. The proxy must implement it:
  the Edge Function mints an HMAC over `(title_id, user_id, expiry)`, the proxy
  verifies it before streaming a single byte, and the proxy's own address is
  never a stable, guessable media path.

> This is the concrete cost of Telegram-as-storage: the security layer that
> Bunny and Storj give you as a setting has to be written and operated by you.

---

## 5. Manual KPay approval

The app can never verify a KPay transfer. Do not let it try.

1. User signs in (phone), taps a plan, sees the KPay number and a reference.
2. User pays **outside the app**, then submits `{plan_id, reference,
   sender_phone}` → row in `premium_requests`, status `pending`.
3. Operator opens the admin view, compares `reference` / `sender_phone`
   against the **real KPay statement**, and approves or rejects.
4. Approval runs a `security definer` function that writes `subscriptions` and
   flips the request to `approved` **in one transaction**. A subscription
   without a matching approved request — or the reverse — is a reconciliation
   problem you will not enjoy later.

```sql
create or replace function public.approve_premium_request(
  req_id uuid, months int
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare r public.premium_requests;
begin
  select * into r from public.premium_requests
    where id = req_id and status = 'pending' for update;
  if not found then raise exception 'request not pending'; end if;

  insert into public.subscriptions (user_id, plan_id, expires_at, created_by)
  values (r.user_id, r.plan_id, now() + make_interval(months => months), auth.uid());

  update public.premium_requests
     set status='approved', reviewed_at=now(), reviewed_by=auth.uid()
   where id = req_id;
end; $$;

revoke execute on function public.approve_premium_request(uuid,int) from public, anon, authenticated;
-- grant only to the admin role you create.
```

**Idempotency.** A double-tap on Approve must not create two subscriptions.
The `for update` lock plus the `status = 'pending'` predicate handles it: the
second call finds nothing and raises.

---

## 6. Client-side measures — worth doing, not to be trusted

| Measure | Value | Honest limit |
|---|---|---|
| `FLAG_SECURE` during premium playback | blocks Android screenshots and most screen recorders | root/patched builds skip it; nothing stops a second camera |
| Never persist a media URL | a leaked URL dies in minutes | none — do this |
| Re-request on resume | expired token cannot be reused | none — do this |
| Watermark with the account label | makes a leak traceable to an account | deterrence, not prevention |
| Root/emulator detection | raises effort | trivially bypassed; never gate on it alone |
| TLS certificate pinning | stops passive proxies on hostile networks | reFlutter patches `libflutter.so` and reads everything |
| Play Integrity attestation | flags patched builds and emulators | does not stop MitM; false-positives real customers |
| Device id + concurrency cap | makes casual account sharing visible | a determined user clears it for a fresh slot |

The app already owns `SecureScreenService` for the Private Folder; premium
playback reuses it rather than adding a second mechanism.

---

## 6b. What actually differs between free and premium

The tiers differ in several ways, so the server answers several questions -
not one boolean. `CapabilityMatrix` in the app mirrors this table for drawing
locks; the server re-decides every row.

| Capability | Free | Premium |
|---|---|---|
| Browse catalogue, posters, synopsis, rating | yes | yes |
| Preview stills (first 4 of a premium title) | yes | yes |
| Marked preview clip (one per title) | yes | yes |
| Full album (all stills and clips) | no | yes |
| Play a premium title | **no** | yes |
| Offline download | no | yes |
| Quality ceiling | 480p | source |
| Concurrent streams | 1 | 2 |

Two of these deserve a note.

**The quality ceiling is a ceiling, not a block.** A free viewer watching a
preview at 480p still sees the film, and "your copy is worse" is a better
upgrade argument than "you may not look". It is enforced by which rendition
the server signs, not by a player setting.

**Concurrency is the number that decides whether one subscription serves a
group chat.** It can only be counted server-side, from the `play_grants` log -
a client-side count knows about the streams that are not the problem.

**A premium subscriber's downloads are theirs.** They stay playable, offline,
after the app closes. That is what was bought. The thing that must not happen
is a FREE account obtaining the file at all - which is again a server
question, never a hidden-button one.

---

## 7. Pre-launch checklist

- [ ] RLS enabled on **every** table in `public`
- [ ] `subscriptions` and `premium_requests` have **no** client UPDATE policy
- [ ] Media locator lives in a table with no select policy (or behind a view)
- [ ] `service_role` key exists **only** in Edge Function secrets — never in
      the app, never in a repo, never in a function callable without a JWT
- [ ] `request-playback` runs with `verify_jwt = true`
- [ ] Signed URLs expire in minutes, not hours
- [ ] `needs_premium` is a distinct response code from a generic failure
- [ ] Approval is a `security definer` function, execute revoked from
      `authenticated`
- [ ] No endpoint returns a permission boolean that the client acts on
- [ ] Playback response is a signed URL or a refusal — never `{premium: true}`
- [ ] Quality ceiling enforced by which rendition is signed, not by the player
- [ ] Concurrency counted from `play_grants`, not reported by the client
- [ ] Attestation (if used) can only add friction, never grant or deny
- [ ] Tested by signing in as a **free** account and calling the function
      directly with curl — not through the app. The app is not the attacker.

Added 28 Aug 2026, from the audit in `movies_gaps.md`:

- [ ] `locator` and `content_key` are **revoked** from `anon` and
      `authenticated`, not merely omitted from the app's select list — RLS
      filters rows, not columns, and a client can ask for any column it likes
- [ ] `titles.status` is checked in the **grant path** and in the **download
      licence check**, not only in the catalogue policy
- [ ] `devices` has the partial unique index, and a self-service release with a
      server-side per-account cooldown
- [ ] The device id the constraint guards is **Keystore-backed**, not
      SharedPreferences — otherwise "Clear data" frees the slot
- [ ] The database has a **scheduled backup** that has been **restored once**
- [ ] There is an **operator path** — approvals, rejections, device overrides
      and takedowns — that does not require a laptop
- [ ] The app can be **updated**, and can be **forced** to update

The curl line is the whole security test. If a free account with a valid JWT can curl a
playable URL out of your backend, nothing in the client matters.
