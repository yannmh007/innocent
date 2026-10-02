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

> ⚠️ **THE R2 KEYS WERE WRITTEN OUT HERE IN FULL, AND THIS REPOSITORY IS
> PUBLIC.** They were committed on 2026-09-?? in "Extract Innocent v1.64.7
> GitHub-ready release into repo root" and were readable by anyone until they
> were taken out. **Deleting them from this file does not undo that** — they are
> still in this repository's history, in every clone and fork, and in whatever
> cached the page. A pair of R2 keys can read, overwrite and delete every object
> in the media bucket.
>
> **They have to be rolled in the Cloudflare dashboard**: R2 → Account Details →
> **Manage** next to API Tokens → **Create Account API token** → **Object Read &
> Write**, scoped to `innocent-media` and `innocent-public` (every R2 call this
> project makes is object-level, so Admin is more than it needs) → then paste the
> new Access Key ID and Secret Access Key into the two secrets below and **revoke
> the old token**. Nothing else makes them safe again.
>
> **ONE PLACE, NOT FOUR.** Supabase Edge Function secrets are per PROJECT, so
> `request-playback`, `studio`, `probe-media` and `transcode` all read the same
> two values and all four are fixed by editing them once. Nothing in GitHub
> Actions holds them — the transcode runner is handed presigned URLs and never
> sees a credential — and neither does the console page or the Worker, which
> reaches the bucket through a binding.
>
> **THE WORKER IS UNAFFECTED**, which is what makes this safe to do in the
> daytime: playback through the edge uses that binding, not these keys, so it
> keeps working throughout. What briefly stops if the values are wrong is
> uploading, probing, and the presigned fallback.
>
> `tool/security_invariants.py` now fails the build if a 64-character hex string
> that looks like an R2 secret appears anywhere in the tree, so this cannot come
> back by being pasted into a document again.

```
R2_ACCOUNT_ID          <from Cloudflare → R2 → Overview, the Account ID>
R2_ACCESS_KEY_ID       <from the R2 API token>
R2_SECRET_ACCESS_KEY   <from the R2 API token — shown ONCE, at creation>
R2_BUCKET              innocent-media
SB_SERVICE_KEY         <the legacy service_role JWT, 219 chars>
SB_ANON_KEY            <the sb_publishable_... key; this one is meant to be public>
```

The values live in the Supabase dashboard and nowhere else. **Never in this
repository**, not even in a comment saying what they used to be: `docs/` is
published as the operator console and everything in it is world-readable.

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically -
do not add them.

> `SB_SERVICE_KEY` exists because `SUPABASE_SERVICE_ROLE_KEY` now holds the
> NEW `sb_secret_` key, which is 41 characters and not a JWT. supabase-js puts
> the key in `Authorization: Bearer`, the platform cannot validate a non-JWT
> there, the connection silently drops to `anon`, and the `locator` read is
> refused by the very grants that exist to refuse it. The symptom was a flat
> `not_found`. **This cost two wrong guesses to find.**

### Forwarding a film to the bot (F1)

The shortest path for a gigabyte is not through the phone. The film is usually
already on Telegram, on a server with a fast link to everywhere: forward it to
the bot and a GitHub Actions runner moves the bytes into R2, creates the
catalogue row and queues the ladder. The operator's part is one tap.

**Once, to set it up:**

1. **A bot.** Message `@BotFather` → `/newbot` → keep the token. Then
   `/setprivacy` → **Disable** is *not* needed (a private chat always reaches
   the bot); leave the defaults.
2. **An application.** <https://my.telegram.org> → API development tools →
   note `api_id` and `api_hash`. These identify an APPLICATION, not a person.
   **Never create a user session string for this** — a session string is the
   whole Telegram account, and nothing here needs one.
3. **Your chat id.** Message `@userinfobot`, or send anything to your own bot
   and read `message.chat.id` from
   `https://api.telegram.org/bot<TOKEN>/getUpdates`.
4. **Repository secrets** (Settings → Secrets and variables → Actions):

   ```
   INGEST_SECRET        a long random string you invent; also a Supabase secret
   TELEGRAM_API_ID      from step 2
   TELEGRAM_API_HASH    from step 2
   TELEGRAM_BOT_TOKEN   from step 1
   ```

5. **Supabase Edge Function secrets** (the same project, one place for all
   functions):

   ```
   INGEST_SECRET             the SAME string as above
   TELEGRAM_BOT_TOKEN        the same token (used only to reply to you)
   TELEGRAM_WEBHOOK_SECRET   another long random string you invent
   TELEGRAM_CHAT_IDS         your chat id from step 3, comma separated
   ```

6. **Deploy `ingest`** (see the section below) with **Verify JWT OFF** —
   Telegram cannot present a JWT.
7. **Point Telegram at it**, once:

   ```
   curl "https://api.telegram.org/bot<TOKEN>/setWebhook" \
     -d "url=https://<project>.supabase.co/functions/v1/ingest" \
     -d "secret_token=<TELEGRAM_WEBHOOK_SECRET>"
   ```

8. **Check it took.** `https://api.telegram.org/bot<TOKEN>/getWebhookInfo`
   should show your function's URL, `pending_update_count: 0` and no
   `last_error_message`. An error here means Telegram is being refused and no
   forwarded film will ever arrive.

**The two halves can be tested separately, and the first one needs nothing from
`my.telegram.org`.** Forward a small file to the bot: if it answers "Queued",
the webhook, the chat allow-list and the database are all working, and the
film sits in the queue waiting for a runner. Only the second half — the runner
fetching it — needs `TELEGRAM_API_ID` and `TELEGRAM_API_HASH`, and if they are
missing the panel says so in words: `attempt 1 of 3 failed: Telegram
credentials are not set on this repository`.

**Then, for every film:** forward it to the bot **as a file/document**, with
the folder name as the caption. The bot replies "Queued". When it says done,
make a title from it in the console (Review or Telegram → *New title from
this*), then send it for review; it reaches the app when an editor or the
owner taps **Approve** — see **The review queue** below.

**Where that panel is**, because it is not called Ingest anywhere on screen
and looking for that word finds nothing:

> Console → **Telegram** in the menu (the sidebar on a computer, the bottom
> bar on a phone) → the section headed **From Telegram**. It has its own page
> since the control-room menu; it used to be the third section of Health. The badge on the menu counts files that
> failed or are waiting to be put in a title.

**The panel is grouped by folder, not by file.** One album is one card,
showing the caption you typed in Telegram and every file in it. Two buttons:

> **New title from this** — makes the title, in that folder, with the
> caption's first line as its name and the rest as its description, and
> attaches every finished file to it. It opens the editor on the new title,
> which is where the category, year, Burmese title, tags and cover go. It is
> created as a DRAFT and cannot be approved until it has files — the database
> refuses, not just the page.
>
> **Attach all to an existing title** — the same, onto a title that already
> exists.

Do NOT make a title for forwarded files from the **Upload** page. That page is the
uploader: it takes files off the phone and insists on at least one, and these
files are already in the bucket. It will tell you so.

`inbox` is the exception and keeps a picker per file. It is not an album — it
is where everything forwarded without a caption lands, and its contents have
nothing to do with each other.

**Send a whole album at once and caption ONE of them.** Telegram delivers an
album as one message per file and puts the caption on a single one of them;
the folder is agreed across the group in the database, so the other files
follow it into the same folder whichever order they arrive in. Before
2026-09-29 they did not, and three photos of a four-photo album went to
`inbox` with nothing anywhere saying why.

### Bot commands: choose the folder in the chat (migration 033)

**A forwarded album's caption cannot be edited**, and a channel's caption is
a Burmese sentence or a hashtag far more often than a folder name — so four
albums of one title used to land in four folders, or in `inbox`. Name the
folder first instead:

```
/folder solo-girl-collection      ← everything from now on goes here
(forward the albums — any caption, any number)
/done                             ← closes it, says how many, says what next
```

| Command | What it does |
|---|---|
| `/folder name` | open a folder; files go there whatever their caption says. The name is slugified (`Solo Girl` → `solo-girl`); Burmese alone is refused, not turned into `inbox`. A name that already has files **continues** it — that is how more is added to a title later |
| `/folder` | which folder is open now, and what is in it |
| `/done` | close it; how many this session added, and the next step in the console |
| `/folders` | the ten most recent folders, with counts — to pick a name to continue |
| `/info name` | files sent, in R2, waiting, failed, not yet in a title; which title owns the folder |
| `/status` | queue, MB waiting, files in no title, archive copies left, when the runner last came by |
| `/retry name` | every failed file of that folder back in the queue (the same rule as the console's retry) |
| `/help` | all of this, and puts the commands in Telegram's `/` menu |

* **A folder closes by itself after three hours with no file**, so a
  forgotten `/done` cannot put tomorrow's film in today's folder. The next file
  after the gap goes by its caption, and the bot says so.
* Inside a session each file gets **one line** back (`✓ name (MB) → folder`)
  instead of the paragraph, because four albums of ten is forty replies.
* The caption is still kept: the console fills the description from it.
* `inbox`, `apk`, `v`, `p`, `thumb(s)`, `backup`, `previews` are refused as
  names — something else lives there.
* **More for a title that already exists:** `/folder <its folder>`, forward,
  `/done`. In Console → Telegram that folder's card then offers **Add N to
  “title”** instead of *New title from this* (which could only be refused —
  a title's folder is its slug). If the title is live, the files are in the
  app as soon as they are added.

`tool/sql/bot_folders_test.sql` is the database test (`BOT FOLDERS TEST PASSED`).

**How long it takes.** `*/5` in the workflow is what GitHub accepts, not what
it runs — a schedule on a free public repository fires when it gets to it,
measured at fourteen to twenty minutes apart. A run now drains the WHOLE queue
rather than taking one file, so ten photos are ten minutes of transfers after
one wait, not ten waits. To skip the wait entirely, run the **Ingest**
workflow by hand from the Actions tab.

**`waiting: Telegram asked for …s` is not a failure.** The run signs in to
Telegram once and moves every file in that one session. If Telegram still
asks the bot to slow down (FLOOD_WAIT), a wait of up to five minutes is sat
through inside the run; a longer one hands the file back WITHOUT spending one
of its three attempts, shows that note in the panel, and the next run takes
it. Nothing to do.

> The first version of the queue-draining run signed in once PER FILE. On
> 2026-09-29 that was fifteen sign-ins in two minutes; Telegram answered
> FLOOD_WAIT on `auth.ImportBotAuthorization`, every throttled file was
> claimed again a second later and throttled again, and seven good files were
> marked `gave up after 3 attempts` in under a minute. If you ever see that
> note again with `ImportBotAuthorization` in it, the runner is signing in more
> than once per run, and `python3 tool/ingest_runner_test.py` should be
> failing.

> **Send it as a FILE, not as a video.** Telegram's clients re-encode anything
> sent as a video; a document is byte-for-byte the master. A video is accepted
> rather than refused, because rejecting one after an hour of uploading would
> be cruel, but it is not the original.

> **`TELEGRAM_CHAT_IDS` is not optional.** A bot anyone can find can be
> messaged by anyone, and without that list a stranger could make this project
> download their file into your bucket at your expense.

> **No `logOut`, and do not run a local Bot API server.** The obvious way to
> beat the cloud Bot API's 20 MB download limit is a self-hosted
> `telegram-bot-api`, and it does not work here: moving a bot to a local server
> requires `logOut` on the cloud API first, after which the cloud API stops
> delivering the updates that put films in the queue. The runner uses MTProto
> as the bot instead — a separate session, no size limit, webhook untouched.

> **Telegram caps a file at 2 GB.** Anything larger has to go through the
> console's own uploader, which since C1 uploads in parts.

> **A failed fetch tries itself twice more, then offers you Try again.**
> A transient failure — Telegram rate limiting, an R2 hiccup, a runner that
> lost its network — costs nothing and fixes itself; the panel shows
> `attempt 1 of 3 failed: …` in the meantime. After the third the row says
> `gave up after 3 attempts: …` and grows a **Try again** button, which puts
> it back in the queue with its attempts reset. Forwarding the same film again
> also starts a new job.
>
> Use **Try again** when the reason was the environment rather than the file,
> which so far is every failure this pipeline has had: the first two jobs died
> three times each on `Telegram credentials are not set on this repository`
> while the chat, the message and the file id in the row were all still good.
> It refuses when that file has since been forwarded again, because retrying
> would fetch the same gigabyte twice.
>
> Until 2026-09-26 a failure was terminal and re-forwarding answered "Already
> queued" for ever, so a film sent before `TELEGRAM_API_ID` existed could not
> be recovered by any means the operator had. Until 2026-09-29 recovering one
> still meant finding the message in Telegram and forwarding it again.

### Redeploying an edge function

**Since 2026-10-01 `studio`, `ingest`, `transcode` and `probe-media` are
deployed as one line**, an `index.ts` that imports the file from this
repository pinned to a commit:

```ts
import 'https://raw.githubusercontent.com/yannmh007/innocent/<commit>/docs/edge/studio.ts';
```

Supabase fetches and bundles it at deploy time, so what runs is byte for byte
that file at that commit — and the dashboard's Code tab shows which commit is
live. To deploy a newer version: push, put the new commit hash in that line,
Deploy. A commit hash and not a branch name, so the live code can never change
underneath anyone, and Verify JWT stays OFF.

The older way still works and is what to fall back on if GitHub is
unreachable: Supabase dashboard → **Edge Functions** → the function → the
**Code** tab → select everything in the editor and replace it with the whole of
`docs/edge/<name>.ts` from this repository → **Deploy** → check
**Settings → Verify JWT is OFF**.

> The dashboard moved this. There is no longer a "Deploy a new version"
> button on the function's overview; editing and deploying both live in the
> **Code** tab. A NEW function is still created from the Edge Functions list
> page, not from inside an existing one.

Verify JWT stays off for all of them because each one does its own checking and
does it differently: `request-playback` reads the viewer's JWT itself; `studio`,
`ingest`, `transcode` and `probe-media` run the admin gate (the caller's role
from the `admins` table, and the 2-step code once it is required — see
**Admins and two-step sign-in** below); the runner ops of `ingest` and
`transcode` check a shared runner secret; and `backfill-dimensions` is called
with no identity at all. `OPERATOR_IDS` is no longer read by anything and can be
deleted from the function secrets. Turning the platform's check on would refuse the runner and the console
before either got to say who it was.

> **Both are deployed and both were read back.** `probe-media` is at version
> 12 with the unused-file report in it, `ingest` at version 5, Verify JWT off
> on both.
>
> The pasted `probe-media` came back with its indentation mangled — the
> dashboard editor adds to the leading whitespace on every paste, and 298 of
> its lines arrived with more than a thousand spaces in front of them. It is
> cosmetic and nothing needs redoing: the deployed copy is 749 lines, the
> repository file is 749 lines, comparing them with the indentation stripped
> gives an exact match, and the file contains no template literal spanning
> more than one line, which is the only place whitespace could have meant
> anything.
>
> What has still never run end to end is the runner: the workflow and
> `tool/ingest.py`. The claim half is proven — a dispatched **Ingest** run
> answered `queue is empty`, which is only reachable through an HTTP 200 from
> the deployed function, so `INGEST_SECRET` matches on both sides and
> `SUPABASE_URL` is right. What is missing is `TELEGRAM_API_ID` and
> `TELEGRAM_API_HASH`.

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

## PART 3b — RELEASING A NEW VERSION OF THE APP

The Build workflow does everything except the last step, which is yours: the
`app_releases` row. It prints the exact `update` to run in the run's summary.

> **`apk_url` and `apk_sha256` must describe the SAME file, and the file must
> never change afterwards.** The updater downloads the whole APK, hashes it,
> and refuses to install anything whose fingerprint does not match the row. A
> row pointing at a file that has since been replaced is not a small problem:
> every phone downloads ninety megabytes, fails the check, is told to try
> again, and downloads it again. There is no way out of that loop from the
> phone.
>
> This is not hypothetical. On 26 Sep, v1.64.36-349 was released at 09:16 and
> its hash went into the row. At 13:38 a commit touching only `tool/` and
> `.github/` — neither covered by the workflow's `paths-ignore` — rebuilt the
> SAME version and `gh release upload --clobber` replaced the asset with a
> byte-different APK of identical size, because APK signing is not
> reproducible. Every update failed from then on.
>
> The workflow no longer does this: a version that is already published keeps
> its APK, and the run says so in its summary instead of uploading. **Getting a
> different binary to users needs a version bump**, which is one line in
> `pubspec.yaml`.

**To check a release is sound, at any time, without downloading it:** open
`https://api.github.com/repos/yannmh007/innocent/releases/tags/v<name>-<code>`
and compare `assets[0].digest` with `apk_sha256` in the row. GitHub computes
that digest itself, so agreement means the two really do describe one file.

## The Files page

`docs/studio/files.js`, *Files* in the console menu (editor and owner). It works
from the console's own copy of the bucket listing (`r2_inventory`, migration
028), taken by **Scan again** and dated on the page — reading R2 on every visit
would be slow on a phone. Scan after doing anything in the Cloudflare dashboard.

| What | Who | What it does |
|---|---|---|
| folders, sizes, cost, "unused" | editor, owner | unused = no title, cover, streaming copy or Telegram file points at it |
| look at a file | editor, owner | ten-minute link, like the preview |
| display name | editor, owner | a label on the page only; nothing in R2 moves |
| **Move to bin** | owner, fresh 2-step code, typed `DELETE` | the file waits **7 days**, restorable; a file a title uses is refused, by the database |
| **Rename / move folder…** | owner, fresh code, new name typed twice | copy inside R2 → check sizes → switch every reference in one transaction → old files to the bin for 7 days |
| **gather into its own folder** | owner | for the early flat `v/…` `p/…` uploads: one title's files are moved to a folder of their own, the same way |

**The bin is emptied by the Telegram runner** (`ingest.yml`, last step, every
run): it asks for files whose seven days are up, deletes each from R2, and
marks it done. A file a title started using again in the meantime is put back
instead of deleted. Nothing else ever deletes from R2.

A file changed in the last day is never offered for deleting: until an upload's
title row is written it looks exactly like an unused file.

**A move that stopped** (page closed, phone lost signal) shows under *Moves not
finished* with **Continue** and **Cancel**. Nothing is switched until every copy
is checked, so the title keeps working from the old folder until then. Cancel
puts the copies made so far in the bin. Files above 5 GB copy in 1 GB
parts; R2 drops an abandoned part-copy by itself after seven days.

**The direct check** under the folders is the older page: it asks R2 directly
and also finds unfinished multipart uploads, which no listing shows.

## Storage: Telegram is the archive, R2 the working set

Migration 029, `docs/studio/storage.js` (*Storage* in the console menu, editor
and owner). Viewers only ever stream from R2 through Cloudflare. What R2 does
not have to hold is a second copy of a film Telegram already has.

**Which films have a Telegram copy.** Only one that arrived by being forwarded
to the bot: the runner can fetch that message again. A film uploaded from the
console never touched Telegram and always stays in R2. The page says which.

| Action | Who | What happens |
|---|---|---|
| **Pin** | owner | everything of the title stays in R2, whatever the policy says |
| **Keep only in Telegram** (one film) | owner, fresh code | the original goes to the bin; its streaming copies stay, so the app plays exactly as before. Downloads get the best streaming copy instead of the original |
| **Bring the original back** | editor | out of the bin at once if it is still there, otherwise fetched from Telegram by the runner |
| **Archive…** | owner, fresh code, typed `ARCHIVE` | the title leaves the app (still approved — not sent back to review); every file of its films goes to the bin; photos stay |
| **Restore** | editor | at once while the files are in the bin; after that the runner fetches the films from Telegram, the streaming copies are made again, and the title goes back in the app **by itself** when they are ready (a draft stays a draft) |
| **Finish restore** | owner | when the encoder failed: back in the app on the originals |
| **Check Telegram copy** | editor | the next runner tick looks at the message |
| **Policy** | owner, fresh code | *automatic*: originals leave R2 a day after their streaming copies are ready (off by default); and the GB at which the bot tells you |

**What keeps this safe.**

1. Nothing leaves R2 at once — the seven-day bin (Files page).
2. The bin **does not delete** the R2 copy of anything whose other copy is in
   Telegram unless the runner has looked at that Telegram message in the last
   **three days** and found the same file (same `file_unique_id`, or the same
   size). Until then the delete simply waits, and the check is asked for.
3. If a check finds the message **gone or a different file**, everything of that
   film still in the bin comes back out at once, the title is put back if it was
   archived, and the page and the bot say so.
4. Every film that is only in Telegram is looked at again every week. If its
   copy is gone then, the bot says so in its daily notice: re-forward the film
   to the bot, or pin the title and upload it from the console.

**The runner does it all.** Checks and restores are handed out by the same
`claim` as forwarded films and done in the same Telegram sign-in; the bin and
the housekeeping run in the workflow's last step (`Empty the R2 bin`), whose log
prints `storage: {...}` with what it did.

**Infrequent Access is not used**, and the page shows the sum: R2's free 10 GB
applies only to Standard storage, Infrequent Access has a 30-day minimum and
charges for every byte read. Below 10 GB it can only cost money. Archiving is
the cheaper way to keep a cold title.

**A title that cannot be archived** says why: a console upload (no Telegram
copy), a copy not checked in three days (a check is queued — try again after the
next runner tick), pinned, or still restoring.

## The archive channel (migration 032)

A private Telegram channel that keeps a copy of EVERY film — forwarded ones
and console uploads alike. It is what a restore fetches from, and what lets R2
free a film's original (Storage page).

**Setting it up — once, two minutes, from the phone:**

1. Telegram → New Channel → name it (e.g. *Innocent archive*) → **Private**.
2. Channel → Administrators → Add Admin → the bot → keep **Post messages** on.
3. The bot says in your chat: *Archive channel connected*. Done.

It must be YOU (an account in `TELEGRAM_CHAT_IDS`) who adds the bot: a channel
anybody else adds it to is ignored. If nothing is said, open the console →
**Status** → *Archive channel* and connect it by name (`@channel`) or id
(`-100…`); and if *Telegram* there says it does not hear channel changes,
press **Repair webhook**.

**What happens then:** on each runner tick up to five films are copied — a
forwarded film in a second (Telegram copies it), a console upload one at a
time (fetched from R2 and sent; over 2000 MB cannot go through Telegram and
stays in R2). The Status page counts *N of M films* in the channel. From then
on every check and restore uses the channel copy.

**Removing the bot from the channel** disconnects it, and the bot says so.
Copies already there stay recorded; nothing new is sent until a channel is
connected again.

**One thing to know before the next release:** the archive copying needs the
runner from this release's branch. Until it is merged, the scheduled runner
does not ask for archive work, so nothing is sent (and nothing breaks).

## Status page (migration 032)

Console → **Status**: the bot and its webhook as Telegram sees them now (and
**Repair webhook**), when the runner last came by and which of its GitHub
secrets were set, every queue, the backups, the archive channel, and which
project secrets are set — yes or no, never a value.

## PART 4 — BACKUPS, AND KEEPING THE PROJECT AWAKE

**The database is backed up every day, by itself** (migration 032). The free
tier has NO backups of its own; R2 holds `spiderman/video1.mp4` and only this
database knows that is a film. So on the first runner tick each day the ingest
function writes every table (and the account list) gzipped to the PRIVATE
bucket, `innocent-media/_backup/db/<year>/<month>/<time>-daily.json.gz`.
Fourteen days are kept, and the first of each month for a year. The Files page
lists them as "database backup" and will not put them in the bin.

**See them, make one, download one:** console → **Status** → *Database
backups*. "Back up now" and "Download" are the owner's; a download needs a
fresh 2-step code, because the file holds every account's email.

**Restore** (owner, from a laptop):

```
python3 tool/restore_backup.py 20261002T112909-daily.json.gz --list    # what is in it
python3 tool/restore_backup.py 20261002T112909-daily.json.gz > restore.sql
python3 tool/restore_backup.py 20261002T112909-daily.json.gz --tables titles,title_assets > some.sql
```

Paste the SQL into the SQL editor. It inserts parents before children and
`on conflict do nothing` — rows still in the database are left as they are. To
put a table back exactly, empty that table yourself first. Accounts are not
written back (auth.users is Supabase's): into the same project nothing is
needed; into a new one people sign in again, and the backup's account list
says who had which subscription.

**If backups stop:** the Status page shows "Last backup" in amber after a day
and red after three. The usual cause is the runner not running — see
*Runners* on the same page.

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

---

## Admins and two-step sign-in

Migration 026. Who may use the console is a table, not a secret: **Admins**
in the console menu (owners only) adds a Google email with a role, changes a
role, or removes someone — effective on their next click, no deploy.

| Role | May |
|---|---|
| owner | everything, including Admins and the console rules |
| editor | publish, approve/reject requests, categories, Files, Activity |
| uploader | upload and edit **their own unpublished drafts**; file Telegram albums into them; cannot publish |
| viewer | look; change nothing |

The last active owner cannot be demoted or removed — by anyone, themselves
included. Every change anyone makes, and every refusal, is a line in
**Activity**; the database refuses to edit or delete those lines.

**A sign-in is announced** to the owner in Telegram (the bot, the chats in
`TELEGRAM_CHAT_IDS`) once per session, with the email, role and Myanmar time.
A sign-in you did not make: remove that admin on the Admins page.

**Two-step sign-in, switched on in this order:**

1. Each admin: **Security** → *Set it up*. On a phone, tap *open it with this
   link* (opens the authenticator app) or copy the setup key into the app;
   type the 6-digit code. From then on the console asks for a code at each
   sign-in.
2. When **every** admin on the Admins page shows *2-step on*, an owner ticks
   *Every admin must give a two-step code* on Security → Console rules. The
   server refuses this while any active admin has none, because an account
   with no authenticator can have one added by whoever holds its Google
   session.
3. From then on, deleting a title and changing admins or the rules also need
   a code from the last few minutes (*Fresh code for deletes*, default 10).

**Emergency switch** (lost phone, locked out): in the Supabase SQL editor,
`update public.admin_settings set require_mfa = false;` — then remove the old
authenticator on Security and set up a new one, then switch it back on.
The console also signs out after *Sign out after (minutes idle)* without a
touch (default 30) — never while an upload is running.

---

## The review queue

Migration 027. **Nothing reaches the app without one approval** — not a
Telegram album, not a console upload. Console → **Review**.

```
draft  →  Send for review  →  waiting  →  Approve  →  live (in the app)
                                 ↓ Send back (with a note) → draft again
                                 ↓ Reject → out of the queue (Reopen brings it back)
live   →  Take down  →  draft
```

* **Upload** always saves a draft now; the "Published" checkbox is gone from
  Upload and from the editor. The bar at the top of the editor shows where a
  title stands and holds the buttons.
* **Uploaders** send their own drafts for review and see what was sent back to
  them (the Review badge counts those). **Editors and owners** approve, send
  back (a note is required), reject, and take down. Approve is one tap.
* **Watch before approving:** the ▶ on a video tile plays it inside the
  console — the 720p streaming copy when there is one, through the same
  Worker viewers use, on a link that lasts ten minutes.
* **Telegram files in no title** are listed on Review too, with *New title
  from this* and (editors) *Discard* for something forwarded by mistake.
  Discard removes the rows only; the files stay in R2, appear on Files as
  unused after a day, and the same file can be forwarded again.
* **Sending for review messages the owner** in Telegram with the title, who
  sent it, how many are waiting, and a link to the Review page.
* **Two-person rule** (Security → Console rules, owner): whoever made a title
  cannot approve it. Off by default; the server refuses to switch it on until
  there are at least two editors or owners.

Every decision is checked again in the database (`review_decide`: role,
state, files, two-person rule) and written to the title's history — the
editor's *History* — which, like the audit log, cannot be edited or deleted.
A title published straight from the Table Editor still gets the same
treatment: its review state follows, and it is refused if it has no files.
`tool/sql/review_test.sql` is the database test (`REVIEW TEST PASSED`).

---

## Uploading from a phone: when the connection goes

`docs/studio/upload.js`. A file over 32 MB goes up in 16 MB parts, and each
accepted part is recorded in the phone (IndexedDB) as it lands.

| What happens | What the console does |
|---|---|
| a blip | retries the part (fresh link each time) |
| minutes with no connection | the file's line says *Waiting for the connection* and it carries on by itself when it is back — no time limit |
| a part stops moving | after a minute with no progress it is treated as a dropped connection and sent again |
| the screen would turn off | kept on while uploading (Screen Wake Lock), where the browser supports it |
| the tab is closed, the phone restarts, Android kills the browser | **Upload → Interrupted uploads → Resume**, pick the same file(s) again; only the missing parts are sent, then the title is made with the details typed the first time. The Dashboard says when there is one |
| R2 says "finished" | the size R2 holds is checked against the file before the title row is written |
| the bucket refuses everything (CORS rule, token) | reported within seconds with "Check bucket access", not waited on |

Picking the file again is a browser rule — a page may not reopen a file by
itself. The console checks it is the same file (name, size and a fingerprint
of its bytes); a different file under the same name is sent from the start
rather than spliced into the old upload.

**Discard** on an interrupted upload deletes its parts from R2 at once. Left
alone, R2 deletes unfinished uploads by itself after **7 days** (Cloudflare's
default); resuming after that sends the unfinished files from the start and
keeps the finished ones. The record is per phone and per browser: an upload
started on one phone can only be resumed on that phone.

The heavy videos are queued for smaller streaming copies once the title row is
written. (Until 2026-10-01 this was attempted before the row existed and could
never find the file, so every heavy upload ended with "could not be queued"
and was queued from Health by hand.)

