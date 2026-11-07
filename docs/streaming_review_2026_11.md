# Streaming without stutter: what the evidence says (7 Nov 2026)

The owner asked for playback with no stutter and nothing that annoys a
viewer, thought through end to end. This is what was checked, what it
showed, what is fixed already, and the order of the rest — each with the
measurement that will say whether it worked. Background: the ladder on
ExoPlayer (`docs/streaming_pro_plan.md`), the cache proxy
(`lib/features/video_hub/data/cache/stream_cache_server.dart`), the labs
(skill `device-labs`).

## 1. What we could see, and what we could not

From the live `events` table (7 Nov): almost all playback is the labs
(Test Lab phones show as US/DE, the emulator as SG); real viewers are one
or two. So real-user numbers cannot rank anything yet, and three blind
spots meant they could not have:

| Blind spot | Why | Fixed (on the branch, ships with the next release) |
|---|---|---|
| Stalls on the ladder were never sent | `_measureStall` returns early on the ladder: libmpv's diagnosis reads an idle player there. `play_stall` stopped after 24 Oct, which looked like smoothness | A ladder stall is now sent when it ends: frozen ms, the rung, the line speed the proxy last measured |
| Tap-to-picture was not measured whole | `play_open` starts its clock when the player gets the address, after the grant | `play_start` carries `grant_ms` (and `ahead` when the grant was fetched while the viewer read the title) |
| Failures were never reported | the `error` kind existed and nothing sent it | `error` with a fixed code (`would_not_start`, `stalled`, `engine_stuck`, `damaged_stretch`, `offline`, `link_expired`, `player_error`), never the message |

And one new row per playback, `play_summary` (migration 080,
`lib/features/player/domain/playback_qoe.dart`): open_ms, played_s,
stalls, frozen_ms, longest_ms, jumps, jump_ms, rung_low/high/changes,
error codes. From it: **frozen seconds per minute played** (the rebuffer
ratio), stalls per hour, jump wait, by app version, network type and
phone. That is the number every change below is judged by.

## 2. What the labs show (1.64.78, six newest runs; lab-reader 7 Nov)

- **Start-up is fine**: first picture 136–240 ms after the player has the
  address on the Test Lab phones (OPPO A79, realme C53); 0.3–1.2 s on the
  shaped emulator line.
- **A quality change no longer freezes**: about 0.2 s (it was 4.2 s on
  libmpv at 1.64.71).
- **Many short stalls on a weak line**: on the emulator's 2–4 Mbit/s line,
  13 stalls in a 240 s run (each up to 2 s), the rung going 720 → 480 →
  360 → 240 → back to 720.
- **Long stalls when a real line collapses**: OPPO on its own line dipping
  to ~1 Mbit/s: 13.4 s (run 42008905511) and 4.4 s (42218427497).
- **A seek on a slow line is slow**: OPPO 5.9 s frozen — a 537 KB segment
  of the current rung took 5.6 s, the Worker's answer 1.6 s of it.
- **The Original (818p, ~10 Mbit/s) froze 5.4–5.8 s** when chosen by hand
  on the OPPO.

What the labs do not test: a long film, minutes on a weak line, a low-end
or 32-bit phone (`DEVICES32` is empty), a link expiring mid-film, and the
spread of one phone on one build (one run per commit).

## 3. What to change, in order

Each is a hypothesis until a lab A/B on the same line says so; each is
judged by the frozen seconds per minute, stall count and jump wait.

1. **Ship the telemetry** (done on the branch) in the next release, so
   real phones answer section 2's questions.
2. **Fewer, not more, stalls after a stall.** `ExoStreamEngine` resumes
   after a stall with 2 s buffered (`setBufferDurationsMs(…, 2_000)`);
   ExoPlayer's own default is 5 s. On a line slower than the rung, 2 s
   drains in seconds and the film stops again: the emulator's 13 stalls.
   QoE studies rate frequent short stalls worse than fewer longer ones.
   Try 4–5 s, and on a mid-film stall push the bandwidth estimate down to
   what actually arrived so the next segment is a lower rung, not the
   same one. Lab: emulator jumps flow, Sintel, 2–4 Mbit/s, before/after.
3. **Do not climb back too eagerly.** The rung returned to 720p on the
   same 2–4 Mbit/s line and stalled again: require the slow average (not
   the fast one) to clear the higher rung's peak with margin, or hold a
   rung for a while after a stall. Same lab.
4. **A jump on a slow line answers from a smaller rung first.** After a
   seek, when the line estimate is under about twice the rung's peak, take
   the first segment from the rung below, then let Auto climb: a picture in
   one second instead of five. Lab: the far-jump checks on a 1–2 Mbit/s
   line.
5. **A dead connection is noticed sooner.** The proxy waits 8 s of no
   bytes before it gives up on a segment read (`segmentStall`); on a
   mobile line that stalls outright, 3–4 s of nothing is already a dead
   read. Lab: a line that drops to zero for 6 s mid-film.
6. **The Original is chosen only when the line can carry it.** Already
   skipped when the line is measured below it; also hold it back when the
   line swings around it (BACKLOG: OPPO on a 4–14 Mbit/s line).
7. **Seal costs (BACKLOG O1–O3)**: sealed copies froze longer on seeks on
   one phone; the like-for-like run is still owed before sealed copies are
   asked for.

## 4. The labs to add

- **Weak line for ten minutes** on the emulator (1–2 Mbit/s, 150 ms, 1 %
  loss), Sintel or Cosmos Laundromat (12 min): stalls per minute.
- **A link expiring mid-film**: a grant made short-lived in the lab build,
  played past it.
- **A low-end and a 32-bit phone** in Test Lab (`DEVICES`, `DEVICES32`).
- **Twice per build** on the Test Lab phones, so a difference is not one
  hour's line.

Test Lab allows 5 physical runs a day (reset 07:00 UTC); the emulator lab
has no such limit and comes first for every A/B above.
