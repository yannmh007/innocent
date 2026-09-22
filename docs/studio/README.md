# Innocent Studio — what it needs outside this repository

The page: <https://yannmh007.github.io/innocent/studio/>
The API:  `docs/edge/studio.ts`, deployed as the `studio` edge function.

Pick files, type a name, tap Publish. The file goes from the phone straight
to R2 — never through the function — so the only size ceiling is R2's own,
5 GiB in a single PUT.

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
