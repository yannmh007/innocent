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

## Deploying it

Four steps. Nothing here can be done from the repository, because three of
them involve secrets.

**1. Make the shared secret.** 32 random bytes, base64url, no padding:

```
openssl rand 32 | base64 | tr '+/' '-_' | tr -d '='
```

Keep the output. It goes in two places and nowhere else.

**2. Give it to the Worker.**

```
cd docs/worker
npx wrangler secret put TOKEN_SECRET
```

**3. Deploy.**

```
npx wrangler deploy
```

Note the URL it prints — `https://innocent-stream.<your-subdomain>.workers.dev`.
Check it is alive: `curl https://innocent-stream.<sub>.workers.dev/health`
should answer `{"ok":true,"service":"innocent-stream"}`.

**4. Give the same secret to Supabase**, along with the Worker's base URL,
as Edge Function secrets:

```
STREAM_TOKEN_SECRET = <the same base64url string>
STREAM_BASE         = https://innocent-stream.<your-subdomain>.workers.dev
```

`request-playback` mints Worker tokens as soon as **both** are present. If
either is missing it goes on returning presigned S3 URLs exactly as before —
so a half-finished deployment degrades to the old behaviour rather than
breaking playback. No app release is involved either way: the client plays
whatever URL it is handed.

## Checking it actually caches

Play a film, then play it again from another device on the same network.

```
curl -sI "https://innocent-stream.<sub>.workers.dev/v/<token>" | grep -i cf-cache-status
```

`MISS` on the first request for an object, `HIT` afterwards. If it says
`MISS` every time, the usual cause is a `206` escaping from `Media` or the
inner path not being stable — both are covered above.

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
