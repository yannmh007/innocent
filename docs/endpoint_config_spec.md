# Endpoint configuration — buying the domain late, safely

Written 30 Aug 2026. Answers one question: **can the domain wait until release,
and can it then be swapped in without shipping a new build?**

**Yes to both, on one condition:** the indirection is built *now*, not at the
moment of the swap. An app that hardcodes hostnames and plans to "change them
later" changes them by shipping a release. An app that resolves them at runtime
changes them by editing a row.

---

## 1. The decision

| Item | When | Why |
|---|---|---|
| **Release keystore** | **now** | locks at the first public build, and has nothing to do with the domain |
| **Application id** | **now** | same — and it does *not* need to match a domain (see §2) |
| **Endpoint indirection** | **Stage 3**, with the first real backend call | costs almost nothing now, costs a release later |
| **Domain purchase** | **at release** | ~$10.44, and nothing before release needs it |
| **Custom domain on the public bucket** | at release | one row edit afterwards |

**Nothing is permanent until an APK is in a stranger's hands.** During
development every hostname is disposable, so `r2.dev`, `*.supabase.co` and
`*.workers.dev` are all fine — provided the app was never written to believe
they are forever.

One structural fact makes this easier than it looks: **the private bucket never
needs a domain at all.** Encrypted segments are fetched by presigned URL against
`<account-id>.r2.cloudflarestorage.com`, which is the S3 endpoint and is not a
public hostname you choose. The domain matters for **one bucket** — the public
one holding posters, the APK and `version.json`. It is a release-time
concern, not an architecture concern.

---

## 2. The application id does not have to match a domain

Reverse-DNS is a *convention* for uniqueness, not a requirement of ownership.
Nothing verifies that the developer owns the domain in the package name, users
never see it, and Android developer verification registers the package name, not
a domain.

So pick it today, independently:

```
mm.innocent.player      or      app.innocent.media
```

Requirements, all of which these meet: unique, stable forever, not
`com.example.*`, and plausible. Choose the domain later on brand grounds alone,
and if the matching `.com` is gone by then, it changes nothing.

**This removes the only real dependency between the domain and Stage −1.**

---

## 3. The adapter

### 3.1 What is compiled into the APK

Exactly three constants, all via `--dart-define`, all already in the
`BackendConfig` pattern:

```
VH_BASE_URL    the Supabase project URL      — the bootstrap
VH_ANON_KEY    the anon key
VH_BEACON      a recovery URL (see §3.4)     — used only when the bootstrap fails
```

Nothing else. **No poster base, no CDN host, no updater URL, no support link.**

### 3.2 What comes from the server

One table, one RPC, read without auth:

```sql
create table public.app_config (
  key   text primary key,
  value text not null,
  updated_at timestamptz default now()
);

-- cdn_base       https://pub-xxxx.r2.dev        → later https://cdn.<domain>
-- updater_url    https://pub-xxxx.r2.dev/version.json
-- support_url    https://t.me/…
-- min_build      301
-- config_ttl     3600
```

The app fetches this at launch, caches it with its `updated_at`, and re-fetches
when the TTL expires or on a forced refresh.

### 3.3 The database rule that makes the swap free

> **Store keys and paths. Never store URLs.**

`titles.locator` holds `seg/9f2a1c/`, not `https://…/seg/9f2a1c/`. Posters hold
`poster_key`, not `poster_url`. The URL is assembled at read time as
`cdn_base + key`.

Get this wrong and moving the CDN means rewriting every row in `titles`. Get it
right and it means editing one row in `app_config`. The schema already leans
this way — `titles.provider` and `titles.locator` exist precisely so the storage
provider can change; this extends the same idea to the hostname.

### 3.4 Resolution order, and never bricking

```
1. app_config from Supabase        (normal path)
2. the cached copy                 (offline, or Supabase slow)
3. the beacon                      (Supabase unreachable or moved)
4. the compiled-in defaults        (last resort)
```

The **beacon** is a small static JSON at a location independent of both Supabase
and Cloudflare. During development, a file in a public GitHub repo served from
`raw.githubusercontent.com` is free, permanent, and editable from a phone. Its
job is to answer one question when everything else is gone: *where does this app
live now?* It may therefore override `VH_BASE_URL` itself.

```json
{ "supabase_url": "https://xxxx.supabase.co",
  "cdn_base":     "https://cdn.example.com",
  "updater_url":  "https://cdn.example.com/version.json",
  "config_version": 7 }
```

Rules that keep this from becoming a new failure mode:

* **Validate before adopting.** A value that is not an `https://` URL is
  discarded and the previous one kept.
* **Never let a fetch failure block launch.** The config resolves in the
  background; the UI uses the cache.
* **The beacon is read only when the bootstrap fails**, never on the happy path.
* A hostile beacon can misdirect requests but cannot grant entitlement or
  decrypt anything — the key still comes from an authenticated Supabase call and
  segments are AES-encrypted. Signing the beacon with an Ed25519 key whose public
  half is compiled in closes even that gap, and is worth adding once the rest
  works.

---

## 4. The swap, at release

Ten minutes, once:

1. Buy the domain (Cloudflare Registrar, `.com`, ~$10.44/year).
2. R2 → public bucket → **Connect custom domain** → `cdn.<domain>`.
3. Set `Cache-Control: public, max-age=31536000, immutable` on posters and the
   APK; `max-age=60` on `version.json`.
4. `update app_config set value = 'https://cdn.<domain>' where key = 'cdn_base';`
   and the same for `updater_url`.
5. R2 → public bucket → **disable the `r2.dev` development URL**, so the bucket
   has exactly one public entrance.

Every installed app picks the new base up on its next launch. No release, no
reinstall, no user action.

Then bake the domain-based beacon into the first public build, and keep the
GitHub beacon as the second entry in the list. Two independent recovery paths,
both free.

---

## 5. What to watch while testing on free hostnames

* **`r2.dev` is not cached at the edge.** Latency and cost measured there are
  not the production numbers — the custom domain will be faster and will consume
  far fewer Class B operations. Do not tune anything based on `r2.dev` figures.
* **`r2.dev` is rate-limited** and returns 429 in the hundreds of requests per
  second. Irrelevant for a handful of test devices; fatal on launch day. This is
  the whole reason step 5 above exists.
* **Anything in the public bucket is public** during testing, with no auth and no
  WAF. Test posters only. Encrypted segments live in the private bucket and are
  never affected.
* Keep `VH_BASE_URL` pointing at the real production Supabase project from
  Stage 3 onward — the project does not change at release, only the CDN in front
  of the public bucket does.

---

## 6. What this changes in the plan

* `movies_operating_plan.md` §5 gains a fourth item under *what can be deleted*:
  the domain, until release.
* `app_distribution_foundation.md` Stage −1 loses its domain step and keeps the
  keystore and application id, which were never really about the domain.
* Stage 3 gains the `app_config` table, the resolver, and the beacon —
  approximately 200 lines, and the reason the domain can wait.

> **The domain is bought at release. The ability to change it is built now. Those
> are two different tasks, and only the second one has a deadline.**
