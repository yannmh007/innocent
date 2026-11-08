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

- ~~**Start-up is fine**: first picture 136–240 ms after the player has
  the address on the Test Lab phones (OPPO A79, realme C53); 0.3–1.2 s on
  the shaped emulator line.~~ **Not a measurement** (found 7 Nov, §5): on
  the ladder the "first frame" was libmpv's stop, heard before the streams
  moved to ExoPlayer; the real start came seconds later, logged as a stall.
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

**Run C (42367973983)**: 480p unmeasured start, the film in hand logged at
every stop, interim readings in the trail, and 8 s with no line (steps
4 Mbit/s 40 s, 900 kbit/s 120 s, 3 Mbit/s 60 s, off 8 s, 3 Mbit/s 60 s):

| Step | Stops ≥ 250 ms | Blips | Rungs |
|---|---|---|---|
| 4 Mbit/s (start) | 1: 4.6 s, nothing in hand | 3 | 480 → 360 → 240 |
| 900 kbit/s | 0 | 10 | 360 |
| 3 Mbit/s | 0 | 3 | — |
| off 8 s | 0 | 1 | — |
| 3 Mbit/s | 0 | 9 | 480 → 240 → 360 → 480 |

- **The one stop was the start, mislabelled.** "first frame 928 ms" then
  "rebuffer start (ahead 0 ms)" at the same instant, in B, B' and C alike:
  opening a ladder stopped libmpv before the player screen's streams moved
  to ExoPlayer, and libmpv's stop ("not buffering") was taken for the
  first frame. So open_ms on the ladder was too good, the start's wait was
  counted as a stall, and the screen called it a slow connection at 3 s
  (an open has 6 s and 40 s of rope). Fixed: the streams move first, and
  on the ladder a position counts as the picture only once it has moved.
- **The start also waited for the wrong rung's index**: ExoPlayer reads the
  first variant's playlist before it can start, the master listed 720p
  first, and a playlist needs its rung's index from the Worker — 720p's
  came (5.8–6.2 s) before 480p's (6.4 s). Fixed: the start rung leads the
  master.
- **Blips are the emulator's decoder, not the line**: every one had 21–59 s
  of film in hand and came about a second after a rung change reached the
  screen (a decoder starting again at the new size). 2–75 ms, no spinner.
  Fewer rung changes would mean fewer; a real phone's adaptive decoder may
  have none. Not chased further.
- **Eight seconds with no line cost nothing**: 26 s were in hand. The first
  answer after it took 2.9 s (TCP's retransmission backoff), and the dead
  read watch (8 s, fix 4 in §3) never fired. A shorter watch would only
  matter with a nearly empty buffer: it drops down the list.

**Run D (42370839630)**: C with both start fixes, same line and steps.
The start is honest at last: the picture moved at 5.3 s from the tap
(C: 8.1 s), "first frame 3351 ms" after the hand-over (grant 1.6 s on this
line), 480p's playlist first and no 720p one, and nothing frozen after the
first frame. Steps 2–5: no stop again (blips 4, 1, 0, 2). One stop left,
0.995 s at 9.3 s with 135 ms in hand: Auto stepped down to 360p with no
reading of the line at all, because ExoPlayer's meter starts at 1.5 Mbit/s
(70 % usable), below 480p's peak, and the change of rung on a four-second
buffer emptied it. Fixed in E: with nothing measured, the meter guesses a
line that keeps the rung the app opened on until the first reading.

**Run E (42373118426)**: D with the meter's guess. **No stop a viewer sees
in the whole film**: 6 blips, 175 ms frozen in all, the longest 84 ms;
moving 5.7 s from the tap (the grant took 1.8 s of it on this line; a
viewer who opens the film's page first has it already).

| Run | What changed | Stops ≥ 250 ms | Frozen |
|---|---|---|---|
| B' | the branch at noon (720p start) | 3 | 5.9 s |
| C | 480p start | 1 (the start, mislabelled) | 4.6 s |
| D | first frame from ExoPlayer; start rung leads the master | 1 | 1.0 s |
| E | the meter's guess (it did nothing: see below) | 0 | 0.18 s (blips) |

**Correction (same day):** E's guess changed nothing. Auto still stepped
down to 360p at 6.9 s before any reading, as in D; here the step cost a
58 ms blip with 3 s in hand instead of D's 1 s stop. So D → E is the
spread between two runs of the same start, not the guess. The Test Lab
phones showed the same step down before any reading (below), which is how
it was found: AdaptiveTrackSelection settles its first choice from the
meter when it is built, before the tracks are reported, so the guess now
goes where the selection is built (run F).

**Run A' (42376362339)**: E with fix 1 (the line read during a read) taken
out for one run. Also no stop a viewer sees (8 blips, 210 ms) — on this
line the buffer, not fix 1, is what carries a viewer through the
collapse. What fix 1 buys is the picture:

| | Time at 480p | Time at 360p | Bytes to the phone |
|---|---|---|---|
| E, fix 1 on | 87 % | 13 % | 46.9 MB |
| A', fix 1 off | 3 % | 97 % | 31.4 MB |

Without it the only readings are whole reads (every ~20–45 s at 360p),
too few for Auto to climb back after the start's step down. Fix 1 stays
(restored in the next commit, 5955c06).

**Correction, run F (42381638569):** the branch with fix 1 AND the guess
where it now works also spent 97 % at 360p (480p 3 %), with no stop. So
the 87 % against 3 % above is not fix 1: it is how early readings fall.
In E the first readings were 1.2, 1.9, 3.5 Mbit/s and Auto climbed; in F
0.8, 1.1, 2.2 and it did not, and once the 900 kbit/s step came it
stayed. On this line one connection carries ~1.5–2.2 Mbit/s, and Auto
needs the line to clear a rung's PEAK (the master's BANDWIDTH, the
fastest fragment) over 0.7 — for 480p that is borderline, so one run says
little about picture quality. What F does show: with nothing measured,
Auto no longer steps down before a reading (the 360p playlist now comes
1.3 s after the first one, 776 kbps). Quality needs several runs per
variant, and the peaks logged (next run).

**Test Lab, run 42376634865** (the branch with fix 1 back; realme C53 and
OPPO A79 on their own lines): every check passed on both. The first frame
is now honest: 3.1 s (realme, 4.6–12 Mbit/s) and 1.5 s (OPPO, 20–40
Mbit/s) from the hand-over, where 6 Nov's 0.19 and 0.24 s were libmpv's
stop; nothing froze after it (one 8 ms blip with 6 s in hand on the
realme). Seek: OPPO 402 ms frozen (6 Nov: FAIL, 5.9 s, on a 1.9–4.7 Mbit/s
line — not comparable), realme 1.7 s (6 Nov 0.4 s): the first segment
after the jump was 720p on a ~5 Mbit/s line, which is fix 3's case (a
jump answers from a lower rung first). Both stepped down to 360p before
any reading, the OPPO on a line 20 times faster than 360p.

**Run G (42384151800)**: F's build again, with each rung's peak in the
trail. No stop (7 blips, 181 ms), first frame 2.8 s, and **480p 100 % of
the time** — where F, the same build, spent 97 % at 360p. Picture quality
on this line is decided by the first few readings. The peaks say why:

| Rung | Average (grant) | Peak Auto weighs (master BANDWIDTH) | Line needed (peak / 0.7) |
|---|---|---|---|
| 720p | 1684 | 2105 (index not read: average × 1.25) | 3.0 Mbit/s |
| 480p | 912 | 1591 (index read: fastest fragment, 1.74 × average) | 2.3 Mbit/s |
| 360p | 579 | 723 (average × 1.25) | 1.0 Mbit/s |
| 240p | 306 | 382 (average × 1.25) | 0.55 Mbit/s |

Two things follow (BACKLOG 5b). With a minute of buffer, what must keep
up is the rate over tens of seconds, not the fastest 2 s fragment: a peak
over a sliding window of ~20 s would weigh 480p nearer its average, and a
line of ~1.7 Mbit/s would hold it. And a rung whose index is read is
weighed by its real peak while one not yet read is weighed at 1.25 × its
average: 720p looks cheaper than it is until it is read. Both are one
rule in `HlsLadder.master`; it needs several runs per variant to judge.


**Run H (42445022401, 8 Nov): the first A/B with passes** (BACKLOG 5b).
The weakline flow now plays the film once per word of `WEAK_PASSES`, from
a cleared app each time, and the build weighs rungs by the rule `lab_peak`
names; ten passes, `fragment` (the rule as it was) and `window` (a rung's
fastest 20 s; a rung not read at a read rung's ratio) alternating, on F and
G's line and steps. No pass had a stop a viewer sees; the picture:

| Pair | `fragment`: time at 480p | `window`: time at 480p |
|---|---|---|
| 1-2 | 53 % | 95 % |
| 3-4 | 90 % | 98 % |
| 5-6 | 43 % (720p 2 %) | 100 % |
| 7-8 | 92 % | 100 % |
| 9-10 | 20 % | 39 % |
| mean | 60 % (360p 27 %, 240p 14 %) | 86 % (360p 5 %, 240p 9 %) |

- `window` won all five pairs (a sign test: 1 in 32 by chance). Stops
  ≥ 250 ms: 0 and 0. Blips 87 and 109, every one with film in hand (2 s
  at the least, 40 s typical): the emulator's decoder, as in C; more time
  at 480p is more decoding. First frame alike (median 3.4 s and 3.5 s).
- What Auto weighed (`exo tracks … peaks=`): 480p 1591 → 1174 kbps, 720p
  2105 → 2168, 360p 723 → 745, 240p 382 → 394.
- **The ratio holds.** Each rung's own numbers once read (the trail's
  `hls: Np index`), average / fastest 2 s / 10 s / 20 s, kbps: 720p 1683 /
  3052 / 2317 / 2212; 480p 912 / 1591 / 1224 / 1174; 360p 578 / 976 / 754 /
  725; 240p 306 / 507 / 394 / 380. The 20 s peak is 1.24-1.31 × the average
  on every rung, so 720p weighed from 480p's ratio (2168) is 2 % under its
  own (2212). Under `fragment` 720p was weighed at 2105 against its own
  fastest fragment of 3052: a third cheaper than the rule said.
- The price is data: 480p is 912 kbps against 360p's 578, so a film held
  at 480p costs the viewer more of their plan on a weak line.
