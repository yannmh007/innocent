# Handoff, 27 Nov 2026: the player's smoothness (⋮ scroll stutters)

> **DONE the same day (smoothness session)** — the cause, the fixes and
> the phones' numbers are in BACKLOG §0 ("THE PLAYER'S SMOOTHNESS — FOUND,
> FIXED, MEASURED"); the rule in .claude/rules/flutter-app.md. Not
> released. What follows is the plan as it was written before.

Written at the end of the session that shipped 1.64.89 (the player as MX
Player's). The owner's report, the same day, on 1.64.89: **tap ⋮, scroll
its menu: it stutters and lags** ("ထစ်ပြီး ကြာနေပါတယ်"). The owner wants
it fixed properly next session, every similar case found and fixed, and
the player's smoothness, function and CPU checked as people really use it,
on real phones, with numbers. The prompt to paste is at the end (§6).

Read first: CLAUDE.md, BACKLOG §0 (the 1.64.89 record, "27 Nov"),
`.claude/rules/flutter-app.md`, skills `ui-design`, `device-labs`,
`release`. The player's MX work is in docs/handoff_2026_11_26_mx_parity.md.

## 1. What is live

1.64.89+402 (main 6ee04134; app_releases id 1 since 05:47 UTC 27 Nov).
The work branch `claude/extract-github-release-oteqr5` carries it plus
unreleased work (library cache, the seek-bar pack's header read, lab
hooks) — releases are a tree of chosen files on main, never a merge
(skill `release`).

## 2. Suspects for the ⋮ stutter (read in code, NOT yet measured)

Prove each with a number before changing it; fix the ones that count.

1. **Every glyph and icon on the shade carries three shadows, one blurred
   10 px.** `PlayerShade` gives all text `PlayerUi.shadeInk` through
   `DefaultTextStyle.merge` and icons through `IconTheme` (player_ui.dart
   ~77-83 and ~1412-1416). A blurred text shadow is a mask-filter per
   glyph, drawn again whenever its layer repaints.
2. **The scroll repaints all of it every frame, inside a saveLayer.**
   `PlayerPanel` → `_FadingScroll` (player_ui.dart ~425-500): a
   `ShaderMask` (an offscreen layer the size of the panel) around a
   `SingleChildScrollView` of a `Column` — no `RepaintBoundary`, no lazy
   list. ⋮ holds 10-12 tiles, two switch rows and 14 check boxes; every
   scroll frame re-rasterises them all, with their shadows, through the
   mask.
3. **The whole player screen rebuilds on every state change, the playing
   position too.** `player_screen.dart` build: `final state =
   ref.watch(playerControllerProvider)` (~3190); the position is written
   to that state several times a second (player_provider.dart
   `_livePosition()` ~409/648/664). Each rebuild also rebuilds ⋮'s items
   (`_buildMoreMenuItems`, `_buildMorePage`, a `ref.watch` inside
   `_topBarItems()`) and the top bar's TextPainter measures — a hitch every
   tick while the finger scrolls.
4. The panel's entry animation wraps the panel in `Opacity` (~315, ~330);
   at t = 1 it should cost nothing — check it is not left in a layer.
5. The film keeps decoding under it (libmpv / ExoPlayer) — the real
   phone's budget is shared; measure with the film playing and paused.

Likely the same in: the CC panel (track list + "Settings ▾"), ♪ (tracks +
Audio delay), ⋮'s More page, Display Settings, the Audio Effect /
Equalizer sheet, the Sleep panel, the Playing Queue and Bookmarks sheets,
every `showPlayerSheet` body (player_ui.dart ~510 `_FadingScroll` again,
~1627 a plain `SingleChildScrollView`), the shortcut row's horizontal
scroll, and the controls while a film plays (BarShade, the clock, the
seek bar's position).

## 3. How to measure (numbers, before and after)

- **On the phone, in the app**: `CpuProbe` (lib/core/services/diagnostics/
  cpu_probe.dart) already logs per-thread CPU and frames drawn per 10 s
  (`LAB cpu app 74% · 28.6fps · …` in lab traces) and has a
  `SchedulerBinding.addTimingsCallback`. Extend it (or a lab-only probe)
  to log, per window, FrameTiming build and raster p50/p90/p99 and the
  frames over 16.7 ms (and 8.3 ms on a 120 Hz phone), so a scroll gives a
  `LAB frames …` line. Lab-only code stays behind INNOCENT_LAB.
- **Device lab** (emulator, `test_device/config.env`, skill
  `device-labs`): add a flow that opens a film, opens ⋮, scrolls it
  down and up N times (Maestro swipes), the same for CC, ♪, the More page,
  a sheet; collect `dumpsys gfxinfo <pkg> framestats` (gfxinfo.txt exists
  in results) and the `LAB frames` lines. The emulator's GPU is not a
  phone's: use it for before/after, not for absolute numbers.
- **Test Lab** (realme RE58C2 API 35, OPPO OP573DL1 API 34 — real
  phones, `test_device/cloud.env`; five tests a day, reset 08:00 UTC):
  the lab build's game loop can open ⋮ and scroll it (a lab hook, as the
  other checks there) and write the same `LAB frames` line, for the
  numbers that count. The owner's phone is 384x823 dp at 2.8125, 120 Hz
  capable — a diagnostics report from the owner after the fix is the
  last proof (Settings → Report a problem carries CpuProbe's lines).
- **Locally**: `flutter test` cannot time a GPU, but a widget test can
  count rebuilds (a build counter in ⋮'s tiles while the position ticks)
  and prove a repaint boundary isolates the scroll
  (`debugRepaintRainbowEnabled`-style checks via `RenderObject.debugLayer`
  or counting paints). Keep the layout matrix green
  (`PLAYER_PHONES=all LANGS=my,en,th SCALES=1.0,1.3`), the legibility
  test (`LEGIBILITY_OUT=…`) — a cheaper shadow must still read over a
  white film (≥ 4.5:1 text, ≥ 3:1 icons; the shade's ink exists because
  halos alone failed).

## 4. Fix directions to weigh (decide by the numbers)

- Draw the ink once: cheaper shadows (no 10 px blur; a 1-2 px outline or
  a single shadow), or the halo only where the film can show through.
- Keep the scroll's repaint to the scroll: a `RepaintBoundary` round the
  scrolled content / each tile; the fade without a full-panel saveLayer
  (a gradient overlay at the edges instead of `ShaderMask`), or a lazy
  `ListView`/`SliverGrid` where the list is long.
- Stop rebuilding menus on position ticks: `select` the fields a widget
  needs (`ref.watch(provider.select(...))`), move the position into its own
  listenable for the seek bar and times, build ⋮'s item list once per open.
- Check `const` and keys so a rebuild does not re-lay out the tiles.

## 5. Rules that still hold

CLAUDE.md: work on the session's branch, check.py gating every push,
`git checkout pubspec.lock`, no pull request, never rewrite pushed
history, secrets never printed, open films only in labs. **Release only
when the owner says "release"** (skill `release`: a tree of chosen files
on main, the reviewer agent on its diff, device lab gate + Test Lab
realme/OPPO, Build, app_releases with a rolled-back dry run first).
The owner's MX rules (handoff 26 Nov) for any look change: MX's layout,
Innocent's colours, legibility tested on film. Reply to the owner in
Burmese; numbered steps for anything the owner must do.

## 6. The prompt to paste (next session)

```
Innocent player — smoothness session (27 Nov 2026 handoff).

ပြဿနာ: 1.64.89 မှာ player ရဲ့ ⋮ (အစက်သုံးစက်) ကို နှိပ်ပြီး ပေါ်လာတဲ့ menu ကို
scroll လုပ်ရင် ထစ်ပြီး ကြာနေပါတယ်။ ဒီ bug ကို အရင်းအမြစ်ကနေ သေချာ ပြင်ပါ။

လုပ်စေချင်တာ:
1. CLAUDE.md, docs/handoff_2026_11_27_player_smoothness.md (ဒီဖိုင် အပြည့်),
   BACKLOG §0, .claude/rules/flutter-app.md, skill ui-design, device-labs ကို
   အရင်ဖတ်ပါ။ Work branch: claude/extract-github-release-oteqr5 (session
   branch က main ကနေ စရင် BACKLOG §0 အတိုင်း work branch ကို fast-forward push).
2. မပြင်ခင် တိုင်းပါ: ⋮ scroll လုပ်စဉ် frame build/raster ms (p50/p90/p99),
   16.7 ms ကျော်တဲ့ frame အရေအတွက်၊ CPU (thread အလိုက်) ကို lab build ထဲမှာ
   `LAB frames` line နဲ့ ထုတ်ပါ (CpuProbe ကို တိုးချဲ့၊ lab-only code ကို
   INNOCENT_LAB နောက်မှာထား)။ Device lab (emulator) မှာ ⋮/CC/♪/More page/sheet
   တွေကို scroll လုပ်တဲ့ flow အသစ်နဲ့ dumpsys gfxinfo framestats ယူပါ။
   Test Lab (realme, OPPO — ဖုန်းအစစ်) မှာလည်း တူတဲ့ check ကို run ပါ
   (တစ်ရက် ၅ test၊ 08:00 UTC reset — cloud.env comment တွေနဲ့ ရေတွက်ပါ)။
   Film ဖွင့်ထား/pause ထားနှစ်မျိုးလုံး။
3. Handoff §2 ထဲက သံသယ ၅ ချက် (text/icon shadow blur 10, ShaderMask +
   SingleChildScrollView + RepaintBoundary မရှိ, position tick တိုင်း player
   screen တစ်ခုလုံး rebuild, Opacity, decode) ကို တစ်ခုချင်း နံပါတ်နဲ့
   သက်သေပြပြီး အရေးကြီးတာတွေကို ပြင်ပါ။ ပြင်ပြီးရင် အတူတူ ပြန်တိုင်း
   (before/after ဇယား)။
4. အလားတူ ဖြစ်နိုင်တာ အကုန်စစ်ပြင်ပါ: player ရဲ့ panel/sheet အားလုံး (CC,
   ♪, More page, Display Settings, Audio Effect/EQ, Sleep, Playing Queue,
   Bookmarks, showPlayerSheet အားလုံး), shortcut row scroll, controls ပေါ်နေစဉ်
   film ဖွင့်ထားတာ (BarShade, clock, seek bar), app ရဲ့ list/grid screen တွေ
   (Home, Library, Search, poster grid)။ Scroll/animation တိုင်း 60 fps (120 Hz
   ဖုန်းမှာ 120) နီးပါး ရရမယ်၊ ရပ်နေတဲ့ screen က frame မဆွဲရဘူး။
5. Function တွေ တကယ် အလုပ်လုပ်/မလုပ် စစ်ပါ: ⋮ tile ၁၀ ခု + More page row
   တိုင်း၊ shortcut ၁၄ ခု၊ Customise Items၊ speed card၊ A-B၊ Sleep၊ CC/♪၊
   PiP၊ lock၊ gesture တွေ — device lab player_audit flow တွေကို တိုးချဲ့ပြီး
   တစ်ခုချင်း နှိပ်/စစ်ပါ။ ပျက်တာတွေ့ရင် ပြင်ပါ။
6. CPU/battery: film ဖွင့်ထားစဉ်၊ controls ပေါ်နေစဉ်၊ menu ဖွင့်ထားစဉ်၊
   app ရပ်နေစဉ် CPU ကို CpuProbe နဲ့ တိုင်းပြီး အလဟဿ သုံးနေတာ (မလိုတဲ့
   rebuild, timer, repaint) ကို ဖြတ်ပါ။
7. Legibility (ဖြူတဲ့ film ပေါ် စာ ≥4.5:1၊ icon ≥3:1)၊ layout matrix
   (PLAYER_PHONES=all LANGS=my,en,th SCALES=1.0,1.3)၊ whole suite၊
   flutter analyze (path မပါ)၊ check.py — အကုန် green ဖြစ်ရမယ်။ Shadow ကို
   လျှော့ရင် legibility test နဲ့ ပြန်စစ်ပါ။
8. တွေ့သမျှ အားနည်းချက် (UI/UX, function, performance) ကို ပြင်ပြီး
   အဆင့်မြှင့်ပါ — ဘာကြောင့်ပြင်တယ်ဆိုတာ နံပါတ်နဲ့ ပြပါ။
9. Release ကို ကျွန်တော် "release" လို့ ပြောမှ လုပ်ပါ။ အဆုံးမှာ before/after
   နံပါတ်ဇယား (fps, jank %, CPU %) နဲ့ မြန်မာလို report၊ ကျွန်တော်
   ဖုန်းမှာ စမ်းရမယ့် အဆင့်တွေ ပေးပါ။
```
