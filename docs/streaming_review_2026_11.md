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
   **Tried and undone (§5):** 5 s turned blips after a stall into a
   visible 1.26 s stop. The second half (read the line during a read)
   is fix 1 below in §5, and stays.
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

## 5. What the A/B found (7 Nov 2026, afternoon)

**The lab's weak line had never been weak.** The ifb redirect of eth0's
incoming packets was accepted and fed nothing: GitHub's runners carry a
bpf filter at pref 1 on eth0's clsact that takes every packet first. Runs
A (42358540751) and B (42360760676) were shaped only by the emulator's own
`network speed` (the app measured 2.5–5.5 Mbit/s), and the "0.5 % loss"
of every earlier lab never applied. Found because the flow now proves its
cap before it runs (a 600 KB probe under 900 kbit came in at 32 Mbit/s,
run 42363479008). The line is now on loopback: the emulator's HTTPS goes
through `tool/netlab/line_relay.py` (iptables REDIRECT, TLS untouched)
and netem on lo is the line; the probe then read 757 kbps under the cap.

**What one connection carries.** With 0.5 % loss and 120 ms of round
trip, one TCP connection carries ~1.5–2 Mbit/s whatever the cap above it
(TCP's own limit: segment / RTT × 1.22 / √loss). The proxy reads a
ladder's segments on one connection per film, so on such a line the
720p rung (peak 2 Mbit/s) cannot be kept up by design. Two connections
would carry twice — a candidate, weighed against the Worker requests it
costs (BACKLOG).

**Run B' (42365863693), the branch on a shaped line** (4 Mbit/s 40 s,
900 kbit/s 120 s, 3 Mbit/s 100 s; 60 ms each way, 0.5 % loss):

| Step | Stops ≥ 250 ms | Frozen | Blips | Rungs |
|---|---|---|---|---|
| 4 Mbit/s (start) | 3 | 5.9 s (longest 3.2 s) | 4 | 720 → 360 → 480 → 360 |
| 900 kbit/s | 0 | 0 | 11 | 480 → 360 → 240 |
| 3 Mbit/s | 0 | 0 | 4 | 360 → 480 |

- The collapse cost no stop a viewer sees: the line read during a read
  (fix 1, `_recordInterim`) moved Auto down in time. A' (fix 1 off, same
  line) says how much of that is fix 1.
- The worst was the START: 720p unmeasured on "Wi-Fi", frozen 3.2 s right
  after the first frame and 2.4 s more while stepping down to 360p. Fixed:
  an unmeasured film opens at 480p on every connection
  (`kUnmeasuredStartHeight`); every later film opens from what the first
  measured.
- Blips (under 250 ms, no spinner) are counted apart now, in the summary
  and the lab verdict; a stop logs how much film was in hand (`ahead`), so
  the next run says whether they are the line or the emulator.
- The climb back after the line returned took ~80 s: at 240p the buffer
  fills to its minute and the player stops reading, so there is nothing to
  measure. Slow, but it is a softer picture, not a stop.

