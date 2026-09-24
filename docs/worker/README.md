# innocent-stream

The only public door to the private video bucket, and the reason playback
starts quickly.

## What problem this solves

Playback URLs used to point at `<account-id>.r2.cloudflarestorage.com` —
R2's **S3 API endpoint**. That endpoint works from anywhere, but it is not a
CDN. Nothing it serves is cached at the edge, so:

* every byte of every play, for every viewer, comes from the bucket's region;
* every seek is a fresh round trip to that region;
* an MP4 whose index sits at the end costs two such round trips before the
  first frame;
* two people watching the same film ten minutes apart share nothing.

And the URL itself named the account, named the private bucket, spelled out
the folder scheme, and carried the access key id in its credential scope.

With this Worker the app plays `https://<worker>/v/<token>`, where the token
is AES-GCM ciphertext that says nothing to anyone holding the URL. The first
viewer of a film in a given region pulls it from the bucket; everyone after
them is served from the Cloudflare edge beside them.

## The one design decision worth understanding

Workers Caching keys on the **request path**. A token is different on every
play — new expiry, new IV — so caching on the public path would miss every
single time.

So there are two entrypoints:

| entrypoint | caching | path | runs |
|---|---|---|---|
| `default` | **off** | `/v/<token>` | every request |
| `Media` | **on** | `/o/<object key>` | only on a cache miss |

The gateway decrypts the token and forwards to the inner entrypoint at a
**stable** path derived from the object key. Two viewers with completely
different URLs land on the same cache entry.

Range requests are the platform's job. Cloudflare strips `Range` before
invoking a cached entrypoint, asks for the full body, stores it, and slices
every later range out of storage without running any code. `Media`
therefore always returns `200` with the whole object and never reads
`Range` — a Worker that returns its own `206` is treated as uncacheable,
which would silently turn this back into an expensive proxy.

## Deploying it — from a phone, with no terminal

`npx wrangler deploy` assumes a laptop. There is another way that is entirely
dashboard-driven: **Workers Builds**, Cloudflare's own CI, which connects to
this GitHub repository and deploys using the `wrangler.toml` beside this
file.

That matters beyond convenience. Workers Caching — the whole reason this
Worker exists — **cannot be switched on from the dashboard**; Cloudflare's
own docs list a dashboard UI for it under "coming soon". It is a Wrangler
config key. So a Worker pasted into the dashboard editor would deploy, run,
serve video correctly, and cache nothing at all. Workers Builds runs the
real Wrangler against the real config, which is why it is the route here
rather than the editor.

`package.json` beside this file pins Wrangler for the same reason: `[cache]`
needs 4.69.0 and the per-entrypoint map needs 4.107.0, and an older Wrangler
does not warn — it drops the settings.

### 1. Make the secret (in the console you already use)

Open the operator console on your phone, go to **Health**, and under
**Stream secret** tap **Generate**, then **Copy**.

It is generated in the browser and stored nowhere — not on the page, not on
a server, not in this repository. Keep the tab open until step 4; you need
to paste the same value twice.

### 2. Create the Worker from the repository

In the Cloudflare dashboard:

1. **Workers & Pages** → **Create application**
2. **Import a repository** → connect GitHub if it asks, and pick
   `yannmh007/innocent`
3. **Name the Worker exactly `innocent-stream`.** The build fails if the
   dashboard name and the `name` in `wrangler.toml` disagree — Cloudflare
   checks it on purpose, so a repository cannot deploy over a Worker it was
   not meant to.
4. **Root directory**: `docs/worker` — this is a monorepo, and that is where
   the Worker's config lives.
5. Leave the deploy command at `npx wrangler deploy`.
6. **Save and Deploy.**

The R2 binding is in `wrangler.toml`, so it is created for you. There is
nothing to attach by hand.

### 3. Give the Worker the secret

Open the deployed Worker → **Settings** → **Variables and Secrets** → **Add**:

| | |
|---|---|
| Type | **Secret** (not Text — a plaintext variable is readable from the dashboard afterwards) |
| Name | `TOKEN_SECRET` |
| Value | the string from step 1 |

Deploy again from **Deployments** so the running version picks it up.

Check it is alive by opening this in the phone's browser:

```
https://innocent-stream.<your-subdomain>.workers.dev/health
```

It should answer `{"ok":true,"service":"innocent-stream"}`. Anything else
means the Worker is not running yet; the `/health` path is deliberately the
only one that answers without a token.

### 4. Give Supabase the same secret and the address

Supabase dashboard → **Edge Functions** → **Secrets** → add two:

| Name | Value |
|---|---|
| `STREAM_TOKEN_SECRET` | the same string from step 1 |
| `STREAM_BASE` | `https://innocent-stream.<your-subdomain>.workers.dev` |

`request-playback` starts minting Worker tokens the moment **both** exist.
Until then it presigns exactly as it does today, so a half-finished
deployment degrades to current behaviour rather than breaking playback. No
app release is involved either way — the client plays whichever URL it is
handed.

Now close the console tab from step 1.

### If a build fails

The build log is in the Worker's **Settings → Builds**. The two failures
worth naming:

* **"Worker name mismatch"** — the dashboard name is not `innocent-stream`.
* **An error mentioning `cache` or `exports`** — Wrangler is older than
  `package.json` asks for. Check the build log's install step actually ran.

## Checking it actually worked — without a terminal

Three things to look at, in order, all from a phone.

**Is it on at all?** The console's **Signals** tab reads the same numbers
`request-playback` writes. In the Supabase dashboard, Edge Functions →
`request-playback` → Logs, each successful call now carries
`"via":"edge"` once the two secrets exist and `"via":"s3"` before that. That
one field answers "did the change take effect" without reading a URL back.

**Is the cache filling?** Play a film, wait a minute, play it again — ideally
from a second phone. Cloudflare's Worker page shows requests and, once the
cache is warm, a subscription-free **Cf-Cache-Status** breakdown under the
Worker's metrics. A first play is a `MISS`; every later one on the same
object should be a `HIT`.

**Did viewers feel it?** This is the measurement that matters and the only
one that is not a proxy for it. The console's **Signals** tab shows
time-to-first-frame as p50/p95/p99, measured on real devices, by day. Compare
the days either side of the deployment. p95 is the number to watch: an
average is dragged around by one viewer on a dying connection and hides
exactly the tail that makes people stop opening the app.

If `Cf-Cache-Status` is `MISS` every time, the two causes are a `206`
escaping from `Media` — it must return the full `200` and let the platform
slice — or the inner path not being stable, which would mean the token had
leaked into it. Both are covered above.

## What this does and does not protect

**Does.** The URL no longer names the account, the bucket, the folder scheme
or the key, and carries no credential scope. A token cannot be edited or
extended: AES-GCM is authenticated, so a single changed bit fails to decrypt
rather than decrypting to something else. Expiry is checked on every
request, by the gateway, whose caching is off precisely so that it is.

**Does not.** A token that is still valid is a link that works, exactly as a
presigned URL was. Entitlement, the device binding and the concurrency cap
are decided by `request-playback` when the token is minted, not here. This
Worker is a door with a short-lived key, not a second opinion on who the
viewer is — and a short-lived key handed to someone else opens the door for
them until it expires.

Rejections deliberately say nothing. "Expired", "bad signature" and "no such
object" are three different facts, and answering with which one is which
turns this into an oracle for learning how tokens are built.
