# innocent-console — the admin console on an origin of its own

docs/security_review_2026_11.md S4/P4.

## Why

The console has always been served by GitHub Pages at
`yannmh007.github.io/innocent/studio/`. Three things are wrong with that
for the one page that holds an admin session:

* **The origin is shared.** `yannmh007.github.io` is the origin of every
  Pages site this GitHub account will ever have. A browser keeps the admin
  session (localStorage) per origin, so any second Pages site of the
  account could read it.
* **Pages sends no headers.** The policy lives in a `<meta>`, which cannot
  say `frame-ancestors`, HSTS or COOP. And its `connect-src` had to allow
  any https host, so a script that got in could send the session anywhere.
* **Pages publishes all of `docs/`**: migrations, the functions' source,
  every plan. The console needs none of it.

Here the console is served by an assets-only Worker at
`https://console.innocentplayer.com`, with real headers (`build.mjs`):

* a CSP whose `connect-src` names only the four hosts the console talks
  to (the Supabase project, `stream.`, `cdn.`, R2 uploads);
* `frame-ancestors 'none'`, HSTS, COOP `same-origin`, `nosniff`, no
  referrer, `noindex`.

The bundle is `docs/studio` plus the four edge modules the console
imports, and nothing else. Static asset requests cost nothing on the Free
plan.

`tool/js/console_build_test.mjs` proves it, in Chromium under the real
header. The bundle holds every import the console makes. The page loads
with no violation, and its Service Worker registers. The four hosts are
allowed, and any other host is refused.

## Turning it on (the owner, once, in Cloudflare — about ten minutes)

Workers Builds deploys from `main`, so this folder must be on `main` first.
It goes there with the next release, or earlier on request.

1. **Create the Worker from the repository.**
   1. Cloudflare dashboard → **Workers & Pages** → **Create application**
      → **Import a repository** → `yannmh007/innocent`.
   2. **Name it exactly `innocent-console`.** The build fails if it
      differs from `name` in `wrangler.toml`, on purpose.
   3. **Root directory: `docs/console`**.
   4. Leave the build command empty (`wrangler.toml` runs `node build.mjs`
      itself). Leave the deploy command as `npx wrangler deploy`.
   5. **Save and Deploy.** The `routes` entry makes the DNS record and the
      certificate for `console.innocentplayer.com`.
2. **Check that the zone's WAF rules do not catch it.** The custom rules
   made for the stream Worker ("only `/v/` and `/health`; only GET, HEAD,
   OPTIONS") must be limited to `stream.innocentplayer.com`.
   1. Go to Security → WAF → Custom rules, and open each rule.
   2. If its expression does not already say
      `http.host eq "stream.innocentplayer.com"`, add that, joined with
      **and**. The rate-limiting rule on `/v/` likewise.
   3. Otherwise the console's pages answer 403.
3. **Let Supabase send the console back after Google sign-in.**
   1. Supabase dashboard → Authentication → URL Configuration →
      **Redirect URLs** → Add `https://console.innocentplayer.com/studio/`.
   2. Keep the GitHub Pages one until the move is proven.
4. **Open `https://console.innocentplayer.com`** and sign in with Google and
   your authenticator code, as on Pages. The session there is new; the
   Pages one is not carried over (different origin, as intended).

The functions already answer this origin with CORS (`console_origins.js`,
deployed 6 Nov). The stream Worker needs `docs/worker/src/index.js` on
`main` to answer it too; until then the speed test and sealed previews
fail on the new console only.

## Afterwards

When the new console has been used for a week without trouble — and an
UPLOAD has worked there: uploads go from the page straight to R2, so both
buckets' CORS policy must name `https://console.innocentplayer.com`
(`docs/studio/README.md`, "CORS, on both buckets"). The 6 Nov steps left
that out; sign-in, the Dashboard, Review, previews and the speed test do
not need it, which is why a week of use without an upload proves nothing
about it (13 Nov).

* Retire the Pages copy. Remove `https://yannmh007.github.io` from
  `console_origins.js` and from the stream Worker's `STUDIO_ORIGINS`, from
  Supabase's Redirect URLs, and from both buckets' CORS policy.
  **Done 13 Nov 2026**: studio v55 answers only the console; Pages
  unpublished, its redirect URL and CORS entries gone, its page a 404 in
  the transport check. The other functions and the Worker drop the origin
  as they next deploy. Unpublishing did not hold: the next push to main
  (19:00 UTC) redeployed Pages, because its source branch was still set.
  Since 14 Nov Pages' Source is **GitHub Actions** with no workflow that
  deploys (`tool/workflow_yaml.py` fails on one), which is what stops it.
* Point studio's `CONSOLE_URL` (the link in review notices) at the new
  origin.
* Settings → Pages: publish nothing, or only what must be public.
