# Movies — steps 3, 4, 5 tap by tap

31 Aug 2026, for app **v1.63.5+310**. Phase 1: MP4 in a private bucket,
presigned URLs, no Worker, no domain, no terminal.

`movies_phase1_simple_plan.md` is still the authority on WHAT. This file is
only the HOW, in the order the taps happen, on a phone.

---

## What changed since the plan was written

**Supabase Edge Functions can now be written and deployed from the dashboard.**
Edge Functions → *Deploy a new function* → **Via Editor** gives a browser code
editor with Deno type-checking and a Deploy button. No CLI, no Docker.

That matters more than it sounds: `request-playback` is the one piece of phase 1
that had no phone-only route, and it is the piece that enforces payment. Phase 1
can now be finished end to end from the phone.

**One caveat, stated by Supabase itself:** the dashboard editor has **no version
control and no rollback**. So `docs/edge/request-playback.ts` in this zip is the
MASTER COPY. Edit it there, paste it in. If you edit only in the browser, the
running code is the only copy of it that exists.

---

## Step 3 — Supabase (about 30 minutes)

1. `supabase.com` → **New project**.
2. Region **Singapore**. This cannot be changed later.
3. Save the database password somewhere you will still have in a year.
4. Wait for provisioning (~2 min).
5. **SQL Editor** → *New query* → paste **all** of
   `docs/movies_step3_supabase.sql` → **Run**.
6. Still in SQL Editor, run the four proof lines in the comment near the top:

   ```sql
   set role anon;
   select locator from public.titles limit 1;      -- must ERROR
   select id, title from public.titles limit 1;    -- must WORK
   select * from public.row_catalogue('trending'); -- must WORK, no locator
   reset role;
   ```

   **The first line must fail.** If it returns data, the column grants did not
   apply and every media path in the catalogue is readable by anyone holding
   the anon key — which ships inside the APK and is meant to. A policy you have
   not watched refuse something is not evidence of anything.

7. **Settings → API**. Copy the **Project URL** and the **anon / publishable**
   key. Those are the two `--dart-define` values. The **service_role** key is
   also on that page: it goes into the Edge Function's secrets and **nowhere
   near the app, ever**.

---

## Step 4 — R2 (about 15 minutes)

1. Cloudflare dashboard → **R2** → **Create bucket**.
2. `innocent-media` — leave it **private**. This holds the video.
3. **Create bucket** again: `innocent-public` — this holds posters.
4. Open `innocent-public` → Settings → **Public access** → enable the
   **r2.dev** subdomain. Cloudflare's own docs say r2.dev is for testing and is
   rate-limited and throttled, which is correct for now: posters are small and
   there are no users. A custom domain replaces it at release, and
   `poster_url` is a plain column, so that is an UPDATE, not a rebuild.
5. R2 → **Manage R2 API Tokens** → **Create API token**.
   * Permission: **Object Read only**
   * Scope: **the private bucket only**
   * Copy the **Access Key ID**, **Secret Access Key** and **Account ID** now.
     The secret is shown once.

   Read-only and single-bucket on purpose: this token can be pasted into a
   dashboard, read from function logs, or leak in a screenshot, and the worst
   it can then do is read files that paying users can already read. It cannot
   delete the catalogue.

---

## Step 4b — the playback function (about 15 minutes)

1. Supabase → **Edge Functions** → *Deploy a new function* → **Via Editor**.
2. Name it **exactly** `request-playback`. The app calls
   `/functions/v1/request-playback`; a different name is a 404 that reads as
   "unavailable" on the phone.
3. Paste all of `docs/edge/request-playback.ts`. → **Deploy**.
4. Edge Functions → **Secrets**, add four:

   ```
   R2_ACCOUNT_ID          (the hex string in your Cloudflare dashboard URL)
   R2_ACCESS_KEY_ID
   R2_SECRET_ACCESS_KEY
   R2_BUCKET              innocent-media
   ```

   `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically;
   do not add them by hand.

5. Test it from the dashboard's built-in tester with
   `{"title_id":"<the id of your test row>"}`. A free title must return a `url`
   and an `expires_at`. Paste that URL into a browser: the video must play, and
   **ten minutes later the same URL must be refused**. If it still works, the
   expiry is not being signed and every link is permanent.

---

## Step 5 — one title, end to end (the rule that saves the week)

**Do not upload title two until title one plays in the app.**

1. Pick the smallest real file you have. Check its size first: the R2 dashboard
   refuses single files over **300 MB** and points at the API instead. That
   measurement is the decision — if most of the catalogue is under it, phase 1
   needs no tooling at all.
2. Upload the video to `innocent-media` with key `v/first-test.mp4`.
   Keep keys **plain**: lower case, no spaces, no brackets. The function signs
   awkward characters correctly (verified against an independent implementation
   of the AWS spec, including `(HD)` and apostrophes) — but a plain key is one
   fewer thing to be wrong about at 1 a.m.
3. Upload the poster to `innocent-public` as `p/first-test.jpg`, then copy its
   public r2.dev URL.
4. Supabase → **Table Editor** → `titles` → edit the seeded test row:
   * `poster_url` = the r2.dev URL
   * `locator` = `v/first-test.mp4`
   * `access_tier` = `free` ← **leave it free for this first test**
   * `published` = true
5. Build the app in FlutLab with the two defines:

   ```
   --dart-define=VH_BASE_URL=https://xxxx.supabase.co
   --dart-define=VH_ANON_KEY=eyJhbGciOi...
   ```

   Until both are set the app runs on the bundled demo data and never touches
   the server, so a build without them proves nothing.
6. Open the app → Movies → the title should appear → tap Play.

### If the catalogue is empty

An empty catalogue and a failed request look identical on screen. In order:

* **Column mismatch.** The commonest cause, and the reason the SQL is derived
  from `api_content_repository.dart` and not from the old contract document.
  PostgREST rejects the whole request if one name in `select` is unknown.
  Test in a browser:
  `https://xxxx.supabase.co/rest/v1/titles?select=id,title&apikey=ANON` — a 400
  names the missing column.
* **`published` is false.** The RLS policy hides the row entirely.
* **Defines missing.** The app is on demo data. About → version, then check the
  build command.

### Then, and only then

Six more titles. Check posters, the grid, and the premium lock — set title two
to `access_tier = premium` and confirm it refuses to play with the paywall,
not with an error. Then the remaining ninety-odd at five to ten a day, Wi-Fi
only.

---

## What is still not built

* **Auth, subscriptions, premium_requests, devices.** The function above reads
  `subscriptions` and `devices`; neither table exists yet, so **every premium
  title will refuse**. That is the correct order — free playback proves the
  pipe, and nothing can be sold until `premium_backend_spec.md` is implemented.
* **The open decision is still open**: phone OTP versus email sign-in. It
  changes the schema, so it comes before those tables, not after.
* `docs/premium_backend_spec.md` has the rest of the schema when you get there.
