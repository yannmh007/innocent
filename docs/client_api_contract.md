# Client API contract

What the app already calls. Build the backend to match these and it connects
with **no app changes** — only `BackendConfig` needs filling in.

Paths are Supabase-shaped (`/auth/v1`, `/rest/v1`, `/functions/v1`). Any server
that answers these shapes works; nothing in the app is Supabase-specific.

Schema, RLS and the security reasoning live in `premium_backend_spec.md`. This
file is only the wire format.

---

## Configuration

```
--dart-define=VH_BASE_URL=https://xxxx.supabase.co
--dart-define=VH_ANON_KEY=<anon key>
```

Until both are set, every repository falls back to the bundled on-device stub,
which **grants nothing** — a misconfigured build shows an empty catalogue
rather than quietly handing out content.

Every request carries `apikey: <anon key>`; authenticated ones also carry
`Authorization: Bearer <user access token>`.

---

## Viewer tiers and identity

Three tiers, and the app sends what it knows about each. The SERVER decides
which one applies - the app reports, it does not claim.

| Tier | Has account | Subscription | Identified by |
|---|---|---|---|
| `anonymous` | no | - | `x-install-id` header |
| `registered` | yes | none / expired | JWT `sub` |
| `premium` | yes | active | JWT `sub` |

### `x-install-id`

Sent on **every** request, signed in or not. A random 128-bit value generated
once per install and kept in app-private storage - which is exactly what
Android's own guidance calls for: a privately stored GUID or Firebase
Installation ID for signed-out analytics. Never IMEI or serial (a
`SecurityException` since Android 10), never `ANDROID_ID` (app-scoped and
regenerated on reinstall anyway), never the advertising id.

Two roles, one value: before sign-in it identifies the VIEWER, so anonymous
activity has somewhere to attribute; after sign-in it identifies the DEVICE,
for the concurrency cap.

### Claiming anonymous history

```
POST /rest/v1/rpc/claim_anonymous_history
{anon_id}
```

Called once, immediately after a successful sign-in, with the install id that
anonymous activity was recorded under. Re-key those rows to the new
`auth.uid()`.

**This is not optional polish.** Without it, registering is the moment a
person's history disappears - the worst possible first impression for an
account, and entirely avoidable. Make it idempotent: it will be retried.

### Age consent

```
POST /rest/v1/rpc/record_age_consent
{terms_version, accepted_at}
```

Recorded for ANONYMOUS viewers too - attribute to `auth.uid()` when signed in,
otherwise to `x-install-id`. The device already remembers it; this is the copy
that can still be produced in a year, which is the only kind worth anything if
a consent is ever questioned.

Store the version. A consent recorded against terms that have since changed is
not consent to the current terms, and bumping `AgeConsentStore.currentVersion`
in the app re-prompts everyone.

### Media counts

`titles.photo_count` and `titles.video_count` are SERVER-SUPPLIED per title.
The app never derives them from the album, for two reasons: a grid card has no
album loaded, and the album GROWS - stills and short clips get added to a title
long after publishing - so a client-side count would differ per screen.

Null means unknown, and the card then draws nothing. Do not send `0` for "not
counted yet": a reader cannot tell an honest zero from an unfilled column, and
only one of them is true.

### Recording a view

```
POST /rest/v1/rpc/record_view
{title_id, viewer_tier?}
```

`viewer_tier` is a HINT for the anonymous case, where there is no JWT to read
one from. When a JWT is present the server must prefer what the JWT and the
subscription table say, never the field. Attribute to `auth.uid()` when signed
in, otherwise to `x-install-id`.

De-dupe per viewer per title per day. The app already de-dupes per session;
that only stops it inflating its own numbers, not a user reopening the app.

---

## Auth

> **OPEN DECISION — this section may change before the backend is built.**
> The table below is the phone-OTP shape the app implements today. Supabase does
> not send SMS itself: phone login requires a paid third-party provider at
> roughly **$0.10 a verification**, which at the month-9 projection is
> **$300-500 in year one against $2/month of infrastructure**, with unreliable
> delivery to Myanmar (+95) numbers. Since a human already verifies the payer's
> number against the KPay statement at approval, an email + password sign-in
> (`/auth/v1/signup` and `/auth/v1/token?grant_type=password`) buys the same
> assurance for nothing. **Decide before building the schema** —
> `movies_execution_plan.md` §0.1. If email wins, only the two OTP rows below
> and `sign_in_sheet.dart` change; everything else in this contract stands.

| Call | Method | Path | Body |
|---|---|---|---|
| Send OTP | POST | `/auth/v1/otp` | `{phone}` |
| Verify OTP | POST | `/auth/v1/verify` | `{type:"sms", phone, token}` |
| Current user | GET | `/auth/v1/user` | — |
| Refresh | POST | `/auth/v1/token?grant_type=refresh_token` | `{refresh_token}` |
| Sign out | POST | `/auth/v1/logout` | — |

Verify must return `access_token`, `refresh_token`, `expires_in`, and ideally
`user`. If `user` is absent the app follows up with `/auth/v1/user`.

`/auth/v1/user` is read as `{id, phone, email, user_metadata:{full_name}}`.

**Session handling already implemented in the app:** a 401 triggers exactly ONE
refresh, then the original request is retried once. Concurrent refreshes are
serialised — six requests failing on a stale token produce one refresh, not
six. A refresh that fails on the NETWORK does not sign the user out (offline is
not logged out); a refresh the server rejects clears the session.

---

## Entitlement

```
GET /rest/v1/subscriptions
    ?select=plan_id,starts_at,expires_at
    &order=expires_at.desc.nullsfirst
    &limit=1
```

RLS scopes this to the caller. No user id is sent — the server must take it
from the JWT and ignore anything the client claims.

`expires_at: null` = lifetime. The app **also** compares the expiry locally and
treats a past date as free, so it behaves identically whether or not RLS hides
expired rows.

---

## Payment instructions

```
GET /rest/v1/payment_instructions
    ?select=payee_name,payee_number,prices,note&limit=1
```

`prices` is `{"yearly":"MMK 34,000","monthly":"MMK 3,500"}`. Readable without
auth so the price is visible before sign-in. If this call fails the app shows
bundled defaults rather than an error — the payment screen is the last place to
show a failure.

---

## Premium requests (manual KPay)

```
POST /rest/v1/premium_requests
Prefer: return=representation
{plan_id, reference, sender_phone?}
```

The app **never sends `status`**. The insert policy must accept only
`status='pending'`; letting a client name a status is the hole that lets
somebody submit an approved one.

```
GET /rest/v1/premium_requests
    ?select=id,plan_id,reference,sender_phone,status,note,submitted_at
    &order=submitted_at.desc&limit=20
```

`status` ∈ `pending | approved | rejected`. **An unrecognised value is read as
`pending`** — a new server-side state must never make an old build claim access.

---

## Catalogue

> **CORRECTED 31 Aug 2026.** This list was wrong, and wrongly in the expensive
> direction: it said `popularity` where the code asks for `view_count`, and it
> omitted `photo_count`, `video_count` and `is_featured` entirely. A `titles`
> table built from the old list answers every catalogue request with **HTTP 400
> — `column titles.view_count does not exist`**, and the app renders an empty
> catalogue with no explanation, because a failed fetch and an empty one look
> the same on screen. The authority is
> `data/api/api_content_repository.dart`; this file follows it.

```
GET /rest/v1/titles?select=id,title,title_mm,synopsis,category,poster_url,
    year,rating,quality_label,genres,episode_count,view_count,access_tier,
    photo_count,video_count
```

The column list is explicit and **never `*`**. The storage locator is not in it
and must not be selectable at all.

Every one of these columns must EXIST, even if it is null for every row —
PostgREST rejects the whole request if a single name in `select` is unknown.

* `category` ∈ `movies | series | reels | adult`
* `access_tier` ∈ `free | premium` — **anything else is read as `premium`**.
  A schema typo then locks the catalogue (visible, recoverable) instead of
  unlocking it (silent, expensive).
* `genres` is a text array; filtered with `genres=ov.{Action,Drama}`
* Adult is excluded with `category=neq.adult` unless the gate is unlocked
* `is_featured` is **filtered but never selected** — `getFeatured()` asks for
  `is_featured=eq.true&limit=1`. It still has to be a real column.
* `view_count` is what "Most watched" orders by
  (`order=view_count.desc.nullslast`). There is no `popularity` column.
* `photo_count` / `video_count` are server-supplied and **nullable on purpose**.
  Null draws nothing; `0` claims an honest zero. Do not default them.

### One paging caveat, deliberately left alone

`_page()` does not send `limit` or `offset` — it fetches the matching rows and
slices client-side. At a hundred titles that is a few tens of kilobytes and it
makes `totalCount` exact for free. It becomes wrong somewhere in the low
thousands, and fixing it then means `Range` headers plus `Prefer: count=exact`
in `ApiClient`. Noted rather than fixed, because it is not yet the bottleneck.

### RPCs

| RPC | Args | Returns |
|---|---|---|
| `landing_rows` | `{include_restricted}` | `[{key,title,default_sort,ranked,items:[title...]}]` |
| `row_catalogue` | `{row_key,include_restricted,...filters}` | `[title...]` |
| `catalogue_facets` | `{row_key?,category_filter?,include_restricted?}` | `{genres:[],years:[],qualities:[]}` |

`landing_rows` exists so a cold start is one round trip instead of five on a
mobile network. `row_catalogue` exists because a row's scope may span
categories — Trending covers films, series and clips — which no column filter
can express.

Sort maps to `order=`: `popularity.desc.nullslast`, `year.desc.nullslast`,
`rating.desc.nullslast`, `title.asc`.

---

## Playback — the only endpoint that matters

```
POST /functions/v1/request-playback
Authorization: Bearer <user JWT>          (verify_jwt = true)
{title_id, media_key?, device_id?}
```

**Success**

```json
{ "url": "https://…signed…", "expires_at": "2026-08-23T12:34:56Z" }
```

**Refusal**

| Status | Body | App behaviour |
|---|---|---|
| 403 | `{"code":"needs_premium"}` | opens the **paywall** |
| 401 | — | treated as needs_premium (session gone) |
| 409 | `{"code":"wrong_device"}` | **currently shows "unavailable"** — see below |
| 403 other, 404, 429, 5xx, offline | any | "unavailable" message |

**Known client gap.** `AccessDenial` has only `needsPremium` and `unavailable`,
so a `wrong_device` refusal is indistinguishable from a server outage. A paying
customer on a replacement phone therefore sees an unexplained error with no
route to the self-service device release. Adding `AccessDenial.wrongDevice` and
the screen behind it is a prerequisite for the `devices` table meaning anything
to a user. Tracked as `movies_gaps.md` #4.

`needs_premium` **must** be that exact string. It is the single value that
separates a paywall from an error screen, and getting it wrong loses the sale
AND looks like a bug.

`device_id` is a random per-install value (no IMEI, no MAC, no ad id). Use it
to bind the grant and enforce the concurrency cap. It is information, not a
claim of rights.

### Already guaranteed by the app

* the client sends **no assertion about its own entitlement** — there is no
  field for one
* it **never stores** a returned URL, and requests a fresh one every play
* it holds **no media locator**; playback is asked for by `title_id` and the
  server resolves the address
* every play goes through one function, enforced by `security_invariants.py`

---

## Build order

1. `titles` + RLS + the anon read policy → catalogue appears
2. phone auth → sign-in works
3. `subscriptions` + `premium_requests` + RLS → paywall and payment flow work
4. `request-playback` → video plays

Steps 1-3 are ordinary tables. **Step 4 is the security boundary.** Test it by
signing in as a free account and calling it with curl — not through the app.
The app is not the attacker.
