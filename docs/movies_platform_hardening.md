# The things not asked for yet

Design note, 2 Sep 2026, v1.63.6+311. Written in answer to "think further ahead
than I can, and make sure what I forget can still be added later."

Three sections: **limits that will bite** (researched, with numbers), **the
mechanism for adding what was forgotten** (which is the real answer), and **a
correction to my own event-log design from yesterday**, which does not survive
contact with those limits.

---

## PART 1 - THREE LIMITS THAT WILL BITE, AND WHEN

### 1.1 A free Supabase project PAUSES after 7 days of inactivity

This is the one that will cause the first mysterious outage.

If no queries reach the database for seven days, the compute instance shuts
down. Resuming takes roughly 30-60 seconds and, depending on the state, a
manual click in the dashboard. Dashboard visits do not count as activity -
**only real database queries do.**

What it looks like from the outside: the Movies tab is empty, or hangs, and
nothing in the app explains why. Exactly the failure mode this project has
already been bitten by twice.

It is realistic here. There are no users yet, and a week can pass while
attention is on the app side.

**Mitigations, cheapest first:**
* an uptime pinger (free tier of any monitor) hitting the REST endpoint every
  few minutes - five minutes to set up, keeps the project warm forever;
* `pg_cron` running a trivial `select 1` daily - no third party, but a paused
  project cannot run its own cron, so this only prevents drift, not a pause
  that already happened;
* Pro at $25/month removes it entirely, and is the honest answer the day real
  users exist.

**Before anything is sold, this must be solved.** A paying customer meeting a
paused project is a refund.

### 1.2 There are NO BACKUPS on the free tier. None.

No daily backups, no downloadable backups, no point-in-time recovery. If the
database is lost, corrupted, or a bad `delete` runs, **there is nothing to
restore from.**

This is worse than it sounds, because the database is now the only place that
knows what any file in R2 actually is. R2 holds `v/index-v1-a1.mp4`; only
Postgres knows that is a film, its poster, its tier and its genres. Lose the
database and 40 GB of objects become 40 GB of anonymous blobs.

**The mitigation is a weekly export, and it is small.** A hundred titles is
tens of kilobytes of JSON - it fits in a phone's notes app. The SQL Editor's
result panel has an **Export** button, which is the phone-only route:

```sql
-- Run weekly. Export the result. This IS the backup.
select json_agg(t) from (
  select * from public.titles order by created_at
) t;
```

Keep the last few. A backup that has never been restored is a guess, so at
least once, paste one back into a scratch project and confirm it reloads.

### 1.3 The 500 MB database cap, and why my event design breaks it

Free tier: 500 MB, counting data **and indexes**. Yesterday's design proposed
an `events` table recording `impression` - one row every time a card is drawn
on screen.

Arithmetic:

| | |
|---|---|
| One event row + its three indexes | ~350-400 bytes |
| 500 MB ÷ 400 B | ~1.3 million rows total, for the whole database |
| 100 viewers × ~100 impressions/day | 10,000 rows/day |
| Time to fill the entire free tier | **~4 months** |

And that is before titles, comments, or watch progress take their share. **The
design I gave yesterday would fill this project's database and stop all writes
within a few months of getting users.** Filling it does not degrade gracefully
- the database goes read-only.

**Corrected design, three changes:**

1. **Do not store impressions as rows.** Count them on the client and send one
   summary per session: `{"impressions": {"<title_id>": 14, ...}}`. One row per
   session instead of hundreds. The click-through ratio survives; the volume
   does not.
2. **Roll up daily, keep raw for 30 days.** A `daily_title_stats` table
   (title_id, day, plays, completes, clicks, impressions) is a few hundred rows
   a month forever. Every algorithm in yesterday's note reads perfectly well
   from it. Raw events are only needed while a question is still being asked.
3. **`play_progress` every 30s is too often.** Every 60s, plus one on pause and
   one on exit, answers "where did they stop" at a fifth of the rows.

The principle underneath: **keep the questions, drop the rows.** An aggregate
that answers the question is worth more than raw data that cannot be stored.

### 1.4 The smaller ones, for the record

* **Egress 5 GB/month.** `_page()` fetches every matching row and slices
  client-side. At a hundred titles that is tens of kilobytes and harmless; it
  becomes an egress problem in the low thousands. Already noted in the contract.
* **Edge Function logs are kept ONE DAY.** The `reason`/`detail` diagnostics
  are only visible for 24 hours. Copy anything interesting out immediately.
* **500,000 function invocations/month.** One per playback. Not a concern.
* **50,000 monthly active users.** Generous; not a concern.
* **Two active free projects**, which is exactly enough for one production and
  one scratch project to test a restore into.

---

## PART 2 - HOW TO ADD WHAT WAS FORGOTTEN

This is the actual question. The answer is not a bigger schema - it is three
disciplines that make a small schema safe to extend forever.

### 2.1 Numbered, idempotent migrations

Right now, schema changes are SQL pasted into an editor. There is no record of
what was applied, no way to rebuild the database, and no way to tell whether a
project matches the code. Today already proved the cost: grants had to be
patched after the fact, and the only reason it was diagnosable was a
hand-added `reason` field.

The fix is small and works from a phone:

```sql
create table if not exists public.schema_migrations (
  version    text primary key,
  applied_at timestamptz not null default now(),
  note       text
);
```

Then every change lives in a numbered file in `docs/migrations/`, and every
file starts and ends the same way:

```sql
-- 003_title_assets.sql
do $$
begin
  if exists (select 1 from public.schema_migrations where version = '003') then
    raise notice 'migration 003 already applied, skipping';
    return;
  end if;

  -- ... the actual change ...

  insert into public.schema_migrations (version, note)
  values ('003', 'title_assets + primary poster trigger');
end $$;
```

Three things this buys, all of which are the answer to "what if I forget
something":

* **running it twice is safe** - the second run does nothing, so there is never
  a question of whether it was applied;
* **the project can be rebuilt** - run 001, 002, 003 in order against an empty
  project and get an identical database. That is also how a restore works;
* **the files are the history** - six months from now, "why does this column
  exist" has a written answer next to the change.

**Every schema change from here should be a numbered file.** The SQL already
written becomes `001_titles.sql` and `002_service_role_grants.sql`
retroactively, with the migrations table seeded to match.

### 2.2 Additive-only: the rule that protects the client

The whole "finish the client, then work only on the backend" plan rests on one
promise: **the server never breaks what the client already reads.**

So the rule, without exceptions:

| Allowed | Never |
|---|---|
| ADD a column | RENAME a column the client selects |
| ADD an RPC | DROP a column the client selects |
| ADD a value the client tolerates | CHANGE a column's type |
| Stop writing a column | REMOVE an RPC |

To retire a field, stop writing it and leave it in place. A dead column costs
nothing. A renamed one costs a rebuild - and PostgREST rejects the ENTIRE
request when one name in `select` is unknown, so the symptom is a blank
catalogue, not a helpful error. That failure has already happened once on this
project.

### 2.3 `extra jsonb` - the escape hatch for unknown unknowns

```sql
alter table public.titles add column if not exists extra jsonb not null default '{}';
```

Anything not thought of yet goes in here with no migration and no client
change: an award, a content warning, a festival, a sponsor, a note to self.

With discipline, or it becomes a swamp:

* jsonb is for **experiments and rarities**. When a key is used by most rows,
  or needs an index, or the client must read it - **promote it to a real
  column** in a numbered migration.
* the client never reads `extra`. It is operator-side only. Anything the app
  must display is a real column, because the app selects columns by name.

### 2.4 Never hard-delete: status, not DELETE

```sql
alter table public.titles
  add column if not exists status text not null default 'draft'
  check (status in ('draft','published','hidden','removed'));
```

`published` (boolean) answers one question. A status column answers the ones
that come later: taken down after a complaint, hidden while the file is
re-encoded, retired but keep the watch history.

`delete from titles` cascades into events, bookmarks and progress and destroys
history that can never be rebuilt. **`status = 'removed'` is reversible;
DELETE is not.** Keep `published` as the client contract, maintained from
`status` by a trigger - the app changes nothing.

### 2.5 Idempotency, before money is involved

When KPay activation is built, this becomes urgent: a user double-taps, the
network retries, the same payment is credited twice.

Every operation that changes money or entitlement takes a client-generated
`request_id`, unique-indexed. Second attempt hits the constraint and returns
the first result. **Cheap to build now, expensive to retrofit after the first
double-credit.**

`record_view` already has this shape - its primary key of
`(title_id, viewer_key, viewed_on)` makes a repeat a no-op. The same pattern,
applied where it matters more.

---

## PART 3 - THE SELF-TEST, AND WHY IT MATTERS MOST

Everything above is prevention. This is detection, and for a one-person
operation working from a phone it is worth more.

**One endpoint that checks the server still satisfies the client contract**,
and one screen in the app that calls it:

```
CONTRACT SELF-TEST                                   2 Sep 2026 21:04
  titles: all 16 granted columns present             PASS
  anon CANNOT read locator                           PASS   ← the important one
  anon CAN read the catalogue                        PASS
  landing_rows() returns rows                        PASS
  catalogue_facets() responds                        PASS
  request-playback returns a signed URL              PASS
  signed URL expires within 15 minutes               PASS
  schema_migrations latest = 004                     PASS
```

Every line is a thing that has broken, or nearly broken, in the last two days.

This turns the loop from *change the server, open the app, guess* into *change
the server, tap once, read the answer* - which is exactly what was asked for,
and it is one screen plus one function.

**Build the self-test before building more schema.** Every table added after it
gets a line in it; every table added before it is a thing nobody is checking.

---

## THE ORDER I WOULD ACTUALLY DO THIS IN

1. **Weekly export** of `titles`. Two minutes, and the free tier has no
   backups at all. (1.2)
2. **Keep-alive** so the project cannot pause. (1.1)
3. **`schema_migrations`**, seeded with what already exists. Everything after
   this is a numbered file. (2.1)
4. **Self-test function + app screen.** (Part 3)
5. **`extra jsonb`, `status`** - two columns, both additive, both impossible to
   add cleanly once a hundred titles exist. (2.3, 2.4)
6. **`title_assets`** with the movable primary poster. (yesterday's A1)
7. **The event log, corrected** - session summaries and daily rollups, not raw
   impressions. (1.3)

1 through 5 are cheap, and all five are things that get harder every day they
are not done. 6 and 7 are the features; they should come after the machinery
that makes them safe to change.
