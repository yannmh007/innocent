# From movie card to media album: the mosaic plan

Design note, 2 Sep 2026, against v1.63.7+312.

The brief: the detail screen should look like a Telegram media group - mixed
short clips and photos in a layout that VARIES with what is in it, not a fixed
grid - and a premium title should offer Upgrade instead of Play while still
showing its free photos underneath.

Three things were checked in the code before planning any of it. One is already
done, one is the real work, and one is a constraint that decides the whole
approach.

---

## 1. ALREADY DONE: the premium button

`content_detail_screen.dart` already switches the button by entitlement:

```dart
/// True when this viewer cannot play the title. Changes the button LABEL,
/// never disables it - a dead Play button teaches nothing, while a button
/// that says Upgrade both explains the state and offers the way out.
final bool locked;
```

Locked titles get a lock icon and `vhUpgrade`; unlocked get play and `vhPlay`.
The reasoning for changing the label rather than disabling the button is
already written into the file.

**So this needs no work - it needs a TEST.** The test title is `free`, so the
locked path has never been on screen. Set one title to `premium` and open it:

```sql
update public.titles set access_tier = 'premium' where slug = 'first-test';
```

Expect: **Upgrade**, not Play. Set it back to `free` afterwards.

**Free photos already stay visible**, because the album section is drawn
outside the entitlement check and `title_media` filters only on
`titles.published`. Photos of a premium title are readable. That matches the
brief - but see the open question in §5.

## 2. THE REAL WORK: the grid is fixed, and that is the problem

```dart
sliver: SliverGrid(
  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 3,
    childAspectRatio: 1,
```

Three columns, every tile a square, forever. A 9:16 portrait clip and a 16:9
still get the same square hole. That is a poster grid, and this is not a poster
screen any more.

## 3. THE CONSTRAINT THAT DECIDES THE APPROACH

Telegram's layout is driven by **aspect ratios**. Its own maintainers state the
rule plainly: the layout may crop however it likes, but **the pixel aspect
ratio is sacred and must never be stretched or squeezed**. Rows are formed by
partitioning items so each row's aspect-sum is roughly equal, then scaling the
row so its widths fill the container - the row's height falls out of
`width / sum(aspects)`.

That algorithm needs a ratio per item. **This project does not have one.**

`title_assets` has `width` and `height`, and `title_media` exposes them - but
they are filled by hand, and files are uploaded through the R2 dashboard, which
supplies no dimensions. On day one every ratio is null.

So a pure ratio-driven layout has nothing to work with. Three ways out:

| | how | cost |
|---|---|---|
| **A. Count patterns** | fixed layouts chosen by item COUNT; tiles crop with `BoxFit.cover` | none - works today with no data |
| **B. Measure on decode** | read intrinsic size from the decoded image, cache it, re-lay out | one reflow the first time; needs a ratio cache |
| **C. Backfill dimensions** | an edge function fetches the first ~64 KB of each photo and parses the JPEG/PNG header | server work; permanently correct after |

**Recommended: A now, C later, B never.**

A looks right immediately and needs nothing. Cropping to fill a tile does NOT
violate the sacred rule - cropping is explicitly allowed, only stretching is
not, and `BoxFit.cover` crops. C makes A better later without changing the
widget, because the layout should read ratios when they exist and fall back to
patterns when they do not. B causes visible reflow on a screen people are
looking at, for a result C gets permanently.

---

## 4. THE LAYOUT, SPECIFIED

A new widget, `MediaMosaic`, replacing the `SliverGrid`. Pure layout - it takes
`List<AlbumItem>` and a width, and returns positioned tiles.

**Rules, in order:**

1. **Ratio per item** = `width / height` when both are known, else a default by
   kind: 1.0 for photos, 0.75 for clips (portrait short video is the common
   case; a wrong default costs a crop, not a stretch).
2. **1 item** - full width, capped at 4:3 so a tall image cannot push the rest
   of the screen off.
3. **2 items** - side by side, equal heights, widths proportional to ratio.
   Both portrait: keep them side by side. Both landscape: stack them.
4. **3 items** - one large plus two stacked, unless all three are similar
   ratios, in which case one row of three.
5. **4 items** - two by two, or one large plus a column of three when the first
   is much wider than the rest.
6. **5 or more** - the general row-partition: walk the items accumulating
   ratios, close a row when its accumulated ratio passes a target (about 2.2 on
   a phone), then scale that row to the full width. Row height =
   `width / sum(ratios)`.
7. **Cap at 10 visible**, with a "+N" overlay on the last tile. Telegram's own
   groups cap at 10, and a mosaic of forty tiles is a scroll, not a glance.
8. **Gaps of 2 px**, no rounded corners inside the mosaic, rounded on the
   outer edge only - that is what makes it read as one object rather than a
   grid of cards.

**Videos** get a duration badge (`AlbumItem.durationLabel` already exists) and
a play glyph. **Free items inside a locked title** get no lock; everything else
in a locked title gets a small lock corner.

**Order is not re-sorted.** Telegram reorders to optimise the packing, and it
is the right call for a chat message nobody curated. Here the operator chose
`sort_order` deliberately, and silently reordering their album would be the app
overruling an editorial decision.

---

## 5. THE OPEN QUESTION - decide before building

**In a premium title, which photos are free?**

Today `title_media` returns every photo of every published title with a public
URL, regardless of tier. So all photos of a premium title are already visible
to anyone - including via the raw r2.dev URL, since the public bucket has no
auth.

Two readings of the brief:

* **(a) Photos are the teaser, always free.** Videos are what is paid for. This
  is how most catalogue apps work, needs no change, and gives the paywall
  something to sell against.
* **(b) Only photos marked `is_free` are shown.** Tighter, but it means the
  operator must mark them per title, and the ones not marked are still sitting
  on a public URL - so it is a UI courtesy, not a control.

**Recommended: (a)**, and be honest about what it is. Anything in
`innocent-public` is public; the security boundary is the private bucket and
the ten-minute signed URL, not the photo grid. If some photos must be paid,
they belong in `innocent-media` as `clip`/`photo` behind `request-playback` -
which is a bigger change and probably not worth it.

---

## 6. CLIPS NEED SERVER WORK

`_album()` gives a clip `MediaRef(provider: 'asset', locator: <asset id>)` and
no URL, on purpose: a clip's playable URL must come from `request-playback`
like the main video, or the ten-minute expiry becomes optional.

But `request-playback` today reads `titles.locator` and knows nothing about
assets. **Tapping a clip cannot work until it accepts an `asset_id`.**

The change is small and self-contained:

* accept `{title_id, asset_id?}`;
* when `asset_id` is given, look up that asset, confirm it belongs to the
  title, and sign ITS object_key;
* apply the same tier check - except that `is_free` assets skip it, which is
  what makes the trailer slot work inside a premium title;
* everything else, including the signer, is untouched.

---

## 7. THE PLAN, IN ORDER

| # | what | where | needs |
|---|---|---|---|
| 1 | Test the premium button with a premium title | SQL, 1 min | nothing |
| 2 | Decide §5 | - | a decision |
| 3 | `MediaMosaic` widget + swap the SliverGrid | client | nothing |
| 4 | `request-playback` v3: `asset_id` + `is_free` | edge fn | after 3 |
| 5 | Repository: send `asset_id` when a clip is tapped | client | after 4 |
| 6 | Backfill `width`/`height` (option C) | edge fn | optional, later |

1 and 2 cost minutes and change what 3 should be. **Do them first.**

3 is the visible change and is self-contained - one new widget, one call site,
no server involvement, no contract change.

4 and 5 are what make a clip playable. Until they land, clips draw in the
mosaic and do nothing when tapped, so the mosaic should not show clips at all
until 4 is done - or it teaches people that tapping does nothing.

**Which means 3 and 4 should ship together, not one at a time.**


---

# ADDENDUM, 2 Sep 2026 — Telegram vs Pinterest

Researched on request. The short version: **they solve opposite problems, and
this app has both.** Choosing one for everything would be wrong.

## 8. THE STRUCTURAL DIFFERENCE

They are not two styles of the same thing. They fix opposite dimensions.

| | Telegram grouped media | Pinterest masonry |
|---|---|---|
| Set size | bounded, 2-10, all known before layout | unbounded, infinite scroll |
| What is FIXED | container width; **row height varies** | **column width**; height varies |
| Packing | row-first: fill a row, scale it to the width | column-first: put the next item in the **shortest column** |
| Aspect ratio | preserved by **cropping** to fit the row | preserved **exactly** - never cropped |
| Reading order | kept | **broken** - visual order stops matching source order |
| Needs dimensions upfront | **No** | **Yes, mandatory** |
| Answers | "show this group as ONE object" | "show me as much as possible, forever" |

Masonry's defining move is the one older CSS layout modes could not express:
*find the shortest column and place the next item there.* Everything else about
it follows from that. Telegram's defining move is the opposite: *take these N
items, arrange them into rows, and scale each row until it exactly fills the
width.*

Two consequences worth being explicit about:

**(a) Masonry breaks reading order.** Item 4 can appear above item 3. Good
masonry implementations offer a switch - "horizontal order" for a stable
left-to-right reading flow, or shortest-column for the tightest packing. You
cannot have both. For a curated catalogue where `sort_order` was chosen
deliberately, that is a real cost, not a detail.

**(b) Masonry needs the aspect ratio BEFORE it lays anything out**, because the
tile height IS `column_width / ratio`. Pinterest can do this because it stores
image dimensions server-side. §3 of this document established that this project
does not have them.

So the missing `width`/`height` is not a small gap. **It is the thing that
makes one of these two layouts cheap and the other expensive.**

## 9. WHERE EACH ONE BELONGS IN THIS APP

The mistake would be picking one and using it everywhere. There are three
surfaces and they are not alike.

### Movies / Series tabs — KEEP THE UNIFORM GRID

Posters are all 2:3. **Masonry over items that share one aspect ratio produces
a uniform grid with extra code**, because every tile computes the same height.
There is nothing to stagger.

The current fixed grid is not a limitation here; it is correct. Leave it.

### Detail screen album — TELEGRAM

Bounded (one folder, typically 2-20 items), mixed photos and clips, meant to
read as one object belonging to one title. Every property of Telegram's layout
matches, and it works with no dimensions at all via the count patterns in §4.

**This is what §4 already specifies. Nothing changes.**

### Reels tab — PINTEREST, and this is the new finding

Reels is an unbounded feed of short clips whose ratios genuinely vary - 9:16
portrait, 1:1, the occasional landscape. That is precisely the case masonry
exists for, and precisely the case a uniform square grid handles worst: a 9:16
clip in a square tile loses about 44% of its frame to cropping.

**But it needs dimensions.** Which turns option C from §3 - the edge function
that reads image and video headers to backfill `width`/`height` - from
"optional, later" into **a prerequisite for Reels looking right**.

That is the real conclusion of this research: the layout question and the
metadata question are the same question.

## 10. FLUTTER REALITY CHECK

`SliverGrid` cannot do masonry. Its delegates compute a uniform tile geometry;
variable heights are outside what it models. Three options:

| | cost |
|---|---|
| `flutter_staggered_grid_view` package | a new dependency, in a build that cannot be compiled locally to check - the same risk that ruled out `cached_network_image` |
| Hand-rolled columns: N `Column`s in a `Row`, each item appended to the shortest | ~60 lines, no dependency, **but builds every item at once** |
| Custom `RenderSliverMultiBoxAdaptor` | correct and lazy; days of work |

**Recommended: hand-rolled, per page.** The catalogue is paged at 30 items, so
"builds every item at once" means thirty widgets - which is what a `GridView`
with 30 children does anyway. The lazy-building argument only bites in the
thousands, and this catalogue will not reach thousands.

The Telegram mosaic for the album needs none of this: it is a bounded set laid
out into rows, which is an ordinary `Column` of `Row`s.

## 11. REVISED PLAN

| # | what | surface | needs dimensions |
|---|---|---|---|
| 1 | Test the premium Upgrade button | detail | no |
| 2 | Decide §5 (which photos are free) | - | no |
| 3 | `MediaMosaic` - Telegram rows + count patterns | detail album | **no** |
| 4 | `request-playback` v3: `asset_id` + `is_free` | edge fn | no |
| 5 | Send `asset_id` when a clip is tapped | client | no |
| 6 | Backfill `width`/`height` from file headers | edge fn | - |
| 7 | `MediaMasonry` - shortest-column, per page | **Reels** | **yes, after 6** |

1-5 are unchanged and remain the priority: they need no data that does not
exist.

6 and 7 are the new work this research adds, and they are in the right order.
**Building 7 before 6 would produce a masonry that cannot compute a single tile
height** - every item would fall back to the same default ratio, which is a
uniform grid with extra steps.
