# Albums the way Telegram does them

Owner request (2026-10-05): the album on a Movies card should behave like a
Telegram media group — most viewers already know Telegram — researched from
Telegram's own code and developer material, with bugs fixed on the way.

## 1. How Telegram lays out a media group

Sources: Telegram Desktop `Telegram/SourceFiles/ui/grouped_layout.cpp`
(`Layouter`, `ComplexLayouter`), Telegram Android
`MessageObject.GroupedMessages.calculate()` (same rules, 800-unit space),
Bot API `sendMediaGroup` (2–10 items per group).

* **Group size**: at most 10 items per media group. A longer post is several
  groups, one after another.
* **Shape classes**: each item's ratio `w/h` is `w` if > 1.2, `n` if < 0.8,
  else `q`. The average ratio starts its sum at 1 (leans square).
* **Box**: square (`maxHeight = maxWidth`) for 2–4 items; `4/3 × maxWidth`
  tall for the "complex" case. Android adds `minWidth` ≈ 120 dp scaled.
* **Two**: `ww` with a high average and similar ratios → stacked top/bottom;
  `ww`/`qq` → side by side, equal; otherwise side by side with widths by
  shape (second ≥ 40 %).
* **Three**: first `n` → tall left column, two stacked on the right; else
  first on top (≤ 66 % of the height), two below.
* **Four**: first `w` → banner on top, three below; else tall left, three
  stacked on the right.
* **Five to ten, or any ratio > 2**: ratios clamped to [1, 2.75] (wide
  average) or [0.667, 1] (narrow); every split into 2, 3 or 4 rows of at
  most 3 items (4 in a narrow middle row) is scored by
  `|totalHeight − 4/3·width|`, × 1.5 if a row is thinner than `minWidth`,
  × 1.5 if a row holds more items than the one below; lowest score wins.
  Rows fill the width exactly; the last cell takes the remainder.
* **Never reordered, never stretched**: pictures are cropped to their cells.
* **Corners**: only the group's outer corners are rounded (the cell's sides
  touching the group edge decide which); inner edges square; a hairline gap.
* **Video cells**: round dark play button, duration pill top-left.
* **Viewer**: black, picture flies from the cell; "N of M"; tap hides the
  chrome; drag down dismisses with the background fading; a strip of the
  group's thumbnails along the bottom (current one wider); neighbours
  preloaded; pinch / double-tap zoom.

## 2. Innocent before

* A justified-rows mosaic (`MediaMosaic`): rows of ~2.2 aspect, any number of
  items in one block, no grouping, no outer-corner rounding, 3 dp gaps. Its
  comment said Telegram reorders items to pack them — it does not.
* Video cells: small play glyph, duration bottom-right.
* Viewer: an opaque page with an app bar "1 / 9"; no drag-to-dismiss, no
  chrome toggle, no thumbnail strip, no hero transition; neighbours built
  only when swiped to. **Bug:** `initialIndex.clamp(0, items.length − 1)`
  throws on an empty album.
* Album cells had no accessibility label (unlabelled buttons for TalkBack).

## 3. What changed

* `telegram_album_layout.dart`: a line-by-line port of Telegram Desktop's
  `Layouter`/`ComplexLayouter` (two, three, four, complex), plus a single
  item capped at 4:3. Groups of ≤ 10 split evenly (23 → 8 + 8 + 7, so no
  group ends in a lone banner). 3 000 random mixes of shapes, 1–10 items,
  four widths: no overlap, nothing outside the width, nothing thinner than
  8 dp.
* `TelegramAlbum`: the groups, outer corners rounded (12 dp), 2 dp
  hairlines, 8 dp between groups, capped at 560 dp wide and centred (as
  Telegram caps the bubble).
* Cells: Telegram's play disc and duration pill; labelled "N of M".
* Viewer: hero flight from the cell, non-opaque route so the album shows
  through the fade, tap to hide/show the bars, drag down to dismiss,
  "3 of 10", thumbnail strip with the current one wider and tap-to-jump,
  neighbours built ahead; empty album safe.
* The detail page uses `TelegramAlbum`; Downloads opens the same viewer.

## 4. Verification

* `test/telegram_album_layout_test.dart` (layout rules and the random
  sweep); `test_screens/album_screens_test.dart` (2, 3, 4, 7, 10, 23 items).
* Device lab `album.yaml` (Android 14 phone, live catalogue): the album
  drawn in Telegram's groups, the viewer opened from a cell ("1 of 6"),
  swiped to "2 of 6" with the strip following, dragged down back to the
  album. Screenshots are kept encrypted (catalogue content).
