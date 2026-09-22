# Innocent Studio — what it needs outside this repository

The page: <https://yannmh007.github.io/innocent/studio/>
The API:  `docs/edge/studio.ts`, deployed as the `studio` edge function.

Pick files, type a name, tap Publish. The file goes from the phone straight
to R2 — never through the function — so the only size ceiling is R2's own,
5 GiB in a single PUT. Above that the function refuses before the first byte
rather than letting an hour of uploading end in a CORS error: multipart is
not built. See `docs/movies_v3_plan.md` §3.3.

---

## What the console can do

Four tabs, all behind the operator check in `studio.ts`.

**Catalogue** — every title including drafts, which no other surface can see.
Search, filter by status, tap through to the editor.

**Title editor** — the whole row: names in both languages, description,
category, tags/genres, year, rating, quality, episodes, tier, featured,
published. Plus the media list: reorder, choose the primary photo (the card
image) and the primary video (what the Play path resolves to), mark a clip a
free preview, delete, and add more files to a title that already exists.

**Requests** — the premium approval queue. `docs/movies_gaps.md` §2 called
this launch-blocking; `approve_request()` and `reject_request()` had existed
in the database for weeks with nothing calling them. **An approval here is
what writes the subscription. Nothing else does.**

**Signals** — proof the event log is filling. The whole design of that log is
that nothing on screen changes whether it works or not, which is correct for
the app and useless for an operator: without this tab there would be no way
to tell a working log from a dead one until the day the data was needed and
three months of it did not exist. The row to watch is **Geography** —
`vpn_suspect` means the phone said Myanmar and the connection said somewhere
else; everything reading `unknown` means no country header is reaching this
project at all.

**Health** — the `catalogue_health` view: which titles have no video, no
poster, or no assets.

### One folder per title, in both buckets

```
innocent-media/<slug>/video/20260922-solar-a1b2c3d4.mp4
innocent-public/<slug>/photo/20260922-poster-e5f6a7b8.jpg
innocent-public/<slug>/thumb/20260922-clip-01-c9d0e1f2.jpg
```

The folder is shown in the editor so it can be pasted into the R2 console.

**It is frozen at creation and a rename does not move it.** Every object key
and the title's `locator` name the prefix; a rename that rewrote R2 would have
to copy every object and leave the catalogue broken in between. The folder is
an address — the title is the label.

A title created before foldering gets one the first time it is opened in the
console. Its existing files stay where they are: `v/…` and `p/…` are still
valid keys and everything resolves them in full.

### The uploader measures every file before it sends it

Duration, width and height were null on every asset in the catalogue, and two
things downstream need them — the app's media mosaic sizes each row of tiles
from the aspect ratios in it, and a video tile's duration badge cannot draw
without a duration. The browser has all three for free. It also takes a poster
frame from each video with a `<canvas>` and uploads it under `t/`, which is
what stops six clips in one title from all showing the same picture.

Three files upload at a time. Not twelve: one slow pipe divided twelve ways
finishes nothing inside the presigned URL's one-hour life.

---

## The R2 API token must be **Object Read & Write**

This is the one that cost an afternoon, so it goes first.

`request-playback` only ever SIGNS GET URLS. A token with `Object Read only`
is enough for it, and was what the project had — for three weeks, with
nothing to reveal it, because nothing had ever tried to write.

The first upload did, and both buckets answered:

```
403  <Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
```

**The browser cannot tell you this.** R2 does not attach CORS headers to its
error responses, so a 403 and a missing CORS policy both reach JavaScript as
the same empty `xhr.onerror`. That is what `op: 'selftest'` is for: it runs
the same signed PUT from the server, where CORS does not exist, and prints
the status per bucket. A 200 there with a failure in the page means CORS. A
403 there means the token.

### Fixing it

1. Cloudflare dashboard → **R2 object storage**
2. **Account Details** → **Manage** next to **API Tokens**
3. **Create Account API token**
4. Permissions: **Object Read & Write**
5. Scope it to `innocent-media` and `innocent-public` — both, or the poster
   upload fails on its own later
6. Copy the **Access Key ID** and **Secret Access Key**
7. Supabase → Edge Functions → Secrets: replace `R2_ACCESS_KEY_ID` and
   `R2_SECRET_ACCESS_KEY`

Those two secrets are shared with `request-playback`, so re-test playback
afterwards. A read-write token still reads, so it should be unaffected —
but "should be" is not "was checked".

---

## CORS, on both buckets

A browser PUT to a presigned URL is a cross-origin request. Without a policy
R2 refuses it, whatever the token says.

R2 → bucket → **Settings** → **CORS Policy**, for `innocent-media` **and**
`innocent-public`:

```json
[
  {
    "AllowedOrigins": ["https://yannmh007.github.io"],
    "AllowedMethods": ["PUT"],
    "AllowedHeaders": ["Content-Type"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3600
  }
]
```

The origin is where the PAGE is served from, not where the file is going.
It changed once already, when the page moved off supabase.co.

---

## The rest

- **GitHub Pages**: Settings → Pages → `main` / `/docs`. The page is a
  static file; there is no build step.
- **Supabase redirect allow-list**: Authentication → URL Configuration must
  contain `https://yannmh007.github.io/innocent/studio/`, or Google sends
  the round trip somewhere else.
- **Google web client**: the Supabase callback
  `https://<ref>.supabase.co/auth/v1/callback` must be an authorised
  redirect URI.
- **Who may publish**: `OPERATOR_IDS`, defaulting to one `auth.users.id`.
  Signing in is not the same as being allowed to publish.

---

## Why the page is not served by the function

Supabase: *"Serving of HTML content is only supported with custom domains
(Otherwise GET requests that return text/html will be rewritten to
text/plain)."* The first version did exactly that and Chrome printed the
source. A custom domain is a paid add-on; Pages is free and the repository
is already public.
