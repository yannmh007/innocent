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

**Run H2 (42450352466): H again, `window` first.** No stop in any pass
again, and this time no clear winner:

| Pair | `window` | `fragment` |
|---|---|---|
| 1-2 | 95 % | 88 % |
| 3-4 | 56 % (240p 41 %) | 94 % |
| 5-6 | 95 % | 87 % |
| 7-8 | 97 % | 87 % |
| 9-10 | 75 % (240p 15 %) | 84 % |
| mean | 84 % (360p 5 %, 240p 11 %) | 88 % (360p 12 %, 240p 0 %) |

- Over both runs, `window` led 8 pairs of 10 (means 85 % and 74 %, medians
  95 % and 88 %); the signed ranks fall short of chance at 5 %
  (W- = 13 of 55). On H2's runner one connection carried more in the
  3 Mbit/s steps (readings 2.2-2.8 Mbit/s against H's 1.2-1.9), above
  even `fragment`'s 2.27 Mbit/s for 480p, so the two rules chose alike —
  the rule matters on a line between 1.7 and 2.3 Mbit/s, which is H's.
- **Each rule has its own bad pass.** `fragment`'s (H 20 %, 43 %, 53 %):
  stuck at 360p or 240p after the start, because climbing back needs
  2.27 Mbit/s. `window`'s (H 39 %, H2 56 %, 75 %): 480p held into the
  900 kbit/s step, the buffer drained under 25 s (ExoPlayer defers every
  step down until then), and the step down went to **240p**, because 360p
  (745 kbps over 0.7) needs 1.06 Mbit/s of line — on a line of ~860 kbit/s
  that carries 360p's 578 kbps average half again over. Which pass meets
  which depends on where the 30-60 s refill cycle stands when the line
  falls (the buffer is refilled from 30 s up to 60 s, then left).
- So the next variant, `deep` (run H3): `window`, and with 15 s or more in
  hand Auto weighs a rung against the whole measured line instead of 70 %
  of it (`SteeredSelection.canSelectFormat`); under 15 s the reserve is
  back. In the collapse that is 360p, not 240p; on a 2-2.8 Mbit/s line
  with a deep buffer it lets 720p (2168) in.

**Run H3 (42455719742): three variants, four passes each, rotated.**
`deep` is `window` with a deep buffer (15 s or more in hand) weighed
against the whole measured line rather than 70 % of it:

| Variant | At 480p or better, each pass | Mean | Stops ≥ 250 ms | Rung changes a pass |
|---|---|---|---|---|
| `fragment` | 5, 94, 33, 94 % | 57 % (240p 12 %) | 1 (564 ms) | 3-6 |
| `window` | 96, 100, 100, 100 % | 99 % | 0 | 1-3 |
| `deep` | 55, 54, 52, 93 % | 64 % (720p 18 %, 360p 36 %) | 0 | 6-15 |

- `deep` is dropped (reverted): with a deep buffer it climbed to 720p in
  the 4 Mbit/s step, met the collapse there, and went 720p → 360p → 240p →
  360p, and up and down again in steps 3-5 (pass 7: fifteen changes, 26
  blips). A 720p a viewer gets for a minute and loses again is worse than
  a 480p they keep.
- `fragment`'s one stop (564 ms) came with 30 s in hand, right after
  360p reached the screen: the emulator's decoder starting again at a new
  size, as in C — so fewer rung changes is fewer of them too.

**The decision (8 Nov): `window` is the rule.** Over H, H2 and H3, 14
passes each: `window` kept the film at 480p or better 89 % of the time
against `fragment`'s 69 %, led 12 pairs of 14 (one-sided sign test
p ≈ 0.0065), had no stop in 14 passes (`fragment` one), the fewest rung
changes, and the same first frame. Its weakness is the step down to 240p
on a line that falls under the rung in hand (H 39 %, H2 56 %, 75 %): a
softer picture, not a stop. `StreamCacheServer.peakRule` is
`PeakRule.window` from this commit on; `lab_peak` still picks either for
an A/B. The price is data: more of the film at 480p.

**Test Lab, run 42461966293** (the branch with `window` as the rule;
realme C53 and OPPO A79): **15 checks of 15 passed on both**, and Auto
weighed the rungs as meant (`peaks=1174,2168,745,394`). First frame 2.7 s
(realme) and 2.5 s (OPPO) from the hand-over. Both lines were far slower
than in run 42376634865: the realme's read 0.4-1.1 Mbit/s at first
(answers ~1 s; it played 240p, the right rung for it) and the OPPO's
7.5-10 Mbit/s against 20-40. So the jumps' frozen times — realme seek
2.6 s at 240p, OPPO 0.9 s at 720p (its 537,551 B segment in 800 ms) — are
the line, not comparable with that run, and the baseline for 5c stays
that run's (realme 1.7 s on a 720p segment at ~4.6 Mbit/s).

**Runs J and J2 (42616754742, 42628158249; 9 Nov): BACKLOG 5c, a jump's
first segment from a rung that arrives quickly.** The rule
(`Steer.jumpLow`, `SteeredSelection`): in Auto, a jump out of the buffer
takes its first segment from the best rung whose segment arrives in
~0.5 s at the meter's estimate (rate × 2 s / line), the second from the
rung before the jump again. Flow `weakjumps`: Sintel on the weak line
held at 4 Mbit/s (60 ms each way, 0.5 % loss; probes 785 and 783 kbps
under 900 kbit), 16 passes from a cleared app, `lab_jump` on and off in turn
(J on first, J2 off first); each pass jumps in Auto to 40, 70, 20, 85,
55, 31, 95 % of the film, each far from what is in hand. 224 jumps;
the same jump of a pair of passes lands on the same moment, so they are
compared pair by pair:

| | J on | J off | J2 on | J2 off |
|---|---|---|---|---|
| The jump's stop (frozen, median) | 1719 ms | 1842 ms | 2096 ms | 2082 ms |
| First picture after the seek (median) | 1544 ms | 1531 ms | 1802 ms | 1646 ms |
| A second stop ≥ 0.6 s within 20 s | 7 (13.0 s) | 2 (2.1 s) | 16 (16.1 s) | 3 (2.0 s) |
| Mean rung over the 20 s after | 485p | 494p | 439p | 465p |
| First segment (median) | 79 KB in 425 ms | 228 KB in 772 ms | 83 KB in 760 ms | 267 KB in 916 ms |
| The Worker's answer before it (median) | 798 ms | 790 ms | 804 ms | 800 ms |

- **Over both runs, 112 pairs**: the jump's own stop was shorter under the
  rule in 62 and longer in 42 (8 alike; sign test p 0.03), by a median
  0.18 s. Counting the stop right after the jump too, 54 against 50,
  median 0.04 s: nothing. The first picture came no sooner (J) or later
  (J2).
- **Why so little: the segment is not the wait.** The Worker's answer is
  ~0.8 s of the ~1.6 s to the first picture, and ExoPlayer starts once
  1 s of film is in (half a segment), not the whole segment. And at
  120 ms and 0.5 % loss an 80 KB segment cost nearly what a 250 KB one
  did (J2: 760 against 916 ms) — most likely TCP's slow start on the
  jump's fresh read, where round trips, not bytes, set the time.
  BACKLOG's premise ("a jump needs one whole segment, so its size is the
  wait") is wrong for this line.
- **And the rule costs a second stop.** The rung before the jump, asked
  for with 2 s in hand on a connection still in slow start, did not come
  in time: 23 jumps of 112 stopped again for 0.6-2.7 s within seconds of
  starting, against 5 of 112 without the rule. A viewer who sees a film
  start and freeze again is worse off than one who waits 0.2 s longer.
  The picture is softer too: 240p for the first segment where Auto plays
  480p.
- `stall_ms` under ~500 ms is the position's own tick (250 ms, stretched
  by the emulator): 183 of 224 jumps read 231-490 ms, 13 read 500-600 ms,
  28 read 0.6 s or more. The flow's summary now counts a stop after the
  jump from 600 ms and pairs the jump's stop and that one together.

**Test Lab, run 42641532315** (the rule present and off for the checks,
then six jumps in Auto, the rule on for the odd ones): the phones' lines
put both outside the band where the rule acts (a line between a rung's
peak / 0.7 and four times it). The realme's read 3-28 Mbit/s (median
14.8): the quick rung was 720p, the rung Auto held, on all six; each
jump: the Worker's answer ~290 ms, the 270-540 KB 720p segment whole in
0.4-0.8 s, the first picture at 1.0-1.2 s, frozen 1.1-1.4 s, rule on or
off alike — the last 0.4-0.7 s, after the segment was in, is the phone
(the decoder starting again), not the line. The OPPO's read 64-3885 kbps (median 330 of 92 readings,
the slowest it has had): 240p all along, the rule acted once (360p → 240p:
frozen 1.2 s, no stop after). Checks: realme 15 of 16 (the Original,
9989 kbps, opened on a line measured at 3.0-9.3 Mbit/s — BACKLOG's
"Original on a borderline line"), OPPO 12 of 15 (seek, quality->240 and
tour->360 waited for bytes that a 330 kbps line did not bring; the OPPO
runs again alone).

**The decision (9 Nov): 5c's rule is taken out.** Over 224 jumps on the
emulator's weak line it shortened the jump's own stop by a median 0.18 s
in 62 pairs of 104 that differed, gave no sooner first picture, stopped
the film a second time right after the jump in 23 jumps against 5, and
softened the picture; on the phones' lines it had nothing to act on. A
jump's wait is, in order: the Worker's answer (0.3 s on the realme's good
line, 0.8 s on the weak one, 0.2-0.9 s on the OPPO's), the phone's own
restart (0.4-0.7 s on the realme), and only then the bytes of half a
segment. What could shorten it is the answer — a connection kept warm
for a jump, say — not the rung; untried. The `weakjumps`
flow and the jumps in Auto (`_labAutoJumps`, `STREAM_AUTOJUMPS` on Test
Lab) stay, to measure that.

**After the decision.** Device lab J3 (42655210613), the build with the
rule taken out: the jumps on Big Buck Bunny 15 of 15; then an A/A of
`weakjumps`, eight passes, both words alike (probe 750 kbps under
900 kbit). Identical variants came apart by a median 0.35 s in the
jump's own stop over 28 pairs (15 shorter against 10, sign p 0.21), with
a stop after the jump in 1 and 2 of 28. So the flow's own spread is of
the size of 5c's gain in the jump's stop (0.18 s over 112 pairs; a median
over four times the pairs spreads about half as far): that gain is not
shown. The second stops are: 23 of 112 under the rule against 5 of 112
without it and 3 of 56 in the A/A. Test Lab 42655210615, the OPPO alone
on the same build: 16 of 16 on a line of 11.5-38.6 Mbit/s (median 31),
seek frozen 400 ms at 720p, far-jump 599 ms — run 42641532315's three
failures were its 0.3 Mbit/s line.

**Runs M1, S1, S2 (11 Nov): what a jump's answer is made of, and a
connection kept open for a jump.** M1 (42951731347) was the build before,
with a richer trail only: each jump's first read now names its connection
(new or kept, told by its local port), what getting it took (lab builds:
DNS, TCP and TLS apart), the wait from the request going out to the
Worker's answer, and whether a read was cut for the jump. Six weakjumps
passes on the weak line (an A/A) after the jumps on Big Buck Bunny (15 of
15). All 93 reads that jumped:

| M1 | reads | answer (median / p90) | getting the connection | the Worker's wait |
|---|---|---|---|---|
| on a new connection | 57 | 885 / 1337 ms | 383 ms: DNS 25, TCP 147, TLS 189 (p90 853) | 441 ms |
| on a kept connection | 36 | 466 / 738 ms | 0 | 466 ms |

- **Why new: a jump cuts the read ahead in flight, and a response cut
  before its end takes its connection with it** (Dart's HttpClient
  destroys a socket whose body was not read through; shown on a local TLS
  server too). 34 of the 42 jumps in Auto cut a read, and 33 of those
  waited for a new connection. A read cut for a rung change (another
  rung's read ahead ended) does the same.
- **The wait is the round trip and the Worker**: 466 ms on a kept
  connection = 120 ms of round trip on this line + ~300-350 ms of the
  Worker and R2; on the emulator's own line (the jumps flow, a round trip
  of ~30 ms) 260-500 ms. The app cannot shorten that part (an edge copy or
  the bucket's place could; both are the Worker's, not tried). The
  handshake, ~0.4 s here, it can.
- The cut read's writer closing (`before`) costs nothing: median 0, p90
  47 ms, waited for alongside the answer.
- The A/A: the jump's stop came apart by 0.31 s over 21 pairs (9 against
  12), as J3's 0.35 s over 28.

**The change (`StreamCacheServer.keepSpare`, lab switch `lab_jump`
on/off):** a ladder gets a second pool, and its segment reads take turns
on the two (each read that carries on goes to the pool used less
recently), so while one read is in flight the other pool's connection
stays open; a jump, or a rung's first read, takes the pool with no read on
it whose last read came in whole most recently (`firstPool`). The same
reads: no request more to the Worker.

| | S1 on | S1 off | S2 on | S2 off |
|---|---|---|---|---|
| The Worker's answer to the jump's first read (median) | 478 ms | 870 ms | 442 ms | 676 ms |
| On a kept connection | 51 of 56 | 6 of 56 | 49 of 56 | 9 of 56 |
| The jump's own stop (median) | 1726 ms | 2098 ms | 1468 ms | 1682 ms |
| First picture after the seek (median) | 1233 ms | 1698 ms | 1057 ms | 1340 ms |
| Stops ≥ 0.6 s within 20 s after | 2 (609, 728 ms) | 0 | 1 (679 ms) | 0 |
| Mean rung over the 20 s after | 455p | 463p | 493p | 511p |

- **S1 (42957372146, on first), 56 pairs**: the answer sooner under on in
  46, off in 4 (median -395 ms); the jump's stop shorter under on in 39
  against 14 (median -390 ms, sign p 0.0004); with any stop after it 38
  against 15 (-367 ms, p 0.0011); the first picture sooner in 39 against
  9 (-340 ms).
- **S2 (42982586873, off first, another runner), 56 pairs**: the answer
  sooner under on in 36, off in 6 (-218 ms); the jump's stop shorter under
  on in 30 against 19 (-134 ms, sign p 0.08); the first picture sooner in
  37 against 8 (-266 ms). Then the jumps on Big Buck Bunny with the spare
  on (`JUMPS_JUMP=on`): 15 of 15.
- **Both, 112 pairs**: the jump's stop shorter under on in 69 against 33,
  median -312 ms, sign p 0.0002 (the A/A: 15 against 10 and 9 against 12,
  p 0.21 and 0.33); with any stop after it 68 against 34 (-303 ms, p
  0.0005); the first picture sooner in 76 against 17 (-300 ms); the answer
  sooner in 82 against 10 (-303 ms). The stops after the jump, 3 of
  0.61-0.73 s against 0, sit at the flow's tick and inside the A/A's own
  rate (3 of 56 in J3); the one read in the trail (S1 pass 13) was a rung
  change a second after the jump whose read found its pool's connection
  gone — a handshake either way. The mean rung after paired: lower under on
  in 14 and 21 pairs, higher in 11 and 17 (p 0.35, 0.31; the A/A runs
  differ by +23p and -10p): alike. The first picture after the start
  (`first frame`) paired: -130 and -65 ms, alike.

**Test Lab** (the spare on for the whole playback, the checks included;
six jumps in Auto, the spare taken by the odd ones, the even ones sent
onto the pool whose read they cut, as one pool would): run 42982587122,
the OPPO 16 of 16 on 10.5-40 Mbit/s (median 27; seek frozen 600 ms,
far-jump 598, first frame 1.69 s), its six jumps all on a kept connection,
the answer 215-272 ms, frozen ~0.4 s, on and off alike — on a fast line a
read is in whole well before the next jump, so one pool's connection is
open anyway. The realme's line read 64-303 kbps for its first 110 s (its
first TCP handshake 621 ms; 0.5 MB in 110 s): stops of 30, 16 and 8.5 s,
and the checks never began; its later jumps on 0.1-4 Mbit/s waited for TCP
handshakes of 288-862 ms, the cost the spare removes, too few to compare.
Run again alone, 42985879375: 16 of 16 on 10-47 Mbit/s (median 20; first
frame 1.43 s), its six jumps all on a kept connection, 222-359 ms.

**The decision (11 Nov): the spare is on by default.** A jump's wait on a
weak line was the Worker's answer (~0.9 s), and nearly half of that was a
handshake the jump paid because it cut the read in flight; a second pool,
read in turn, removes it in nine jumps of ten (0.30 s off the answer, the
stop and the first picture over 112 pairs, both orders, past the A/A's
spread), costs no Worker request, and changed nothing the labs could see
in the picture after or on the phones' fast lines. One fix with it: a read
that carries on from a short one (the head at the start) stays on that
pool, so the length check's connection carries the first fragment as
before (the alternation had sent it to the second pool's first handshake;
stream_cache_hls_test caught it). On that build, with no word (the
build's own): the jumps on Big Buck Bunny 15 of 15 twice, G1 (42995970597;
first frame 2.8 s, one sample, against the 1.64.81 candidate's 2.2 s) and
G2 (42999722877, after two weakjumps passes, which also proved the jumps
flow's trail now holds its own lines only).

**What is left of a jump's wait, and what it would take.**
- The Worker's own wait, ~0.35-0.47 s on a kept connection: a round trip
  plus the Worker and R2 (~0.25-0.35 s: on the emulator's own line, a
  round trip of ~30 ms, it was 0.26-0.50 s). Not the app's. Most likely
  R2's read from the data centre that answers (where the bucket is), but
  that is not measured: splitting the Worker's time from R2's needs a
  `Server-Timing` header from the Worker (a Worker change, the owner's
  call).
- A pool's connection found gone though the rule took it for open: in
  S2's on passes, a read that jumped found its pool's connection open in
  91 of 100 when the pool's last whole read was under 10 s before, in 8 of
  48 when 10-30 s. Over M1, S1 and S2, reads that cut nothing found it open
  in 88 % under 2 s after, 44 % at 4-6 s, 18 % at 8-10 s. That fits a read
  that took the connection since and was ended (by a rung change, taking
  it with it) as well as a server closing idle connections early; the
  trail cannot tell them apart yet. Marking a pool's connection lost when
  a read on it ends cut would settle the first; a follow-up, untried.
  **Settled 14 Nov (run L1 below): the first.** An open pool found its
  connection in 101 of 102 jumps, idle up to 11 s; a lost one in none of
  10. The server does not close them; a read cut since does.
- The phone's restart after the bytes (0.4-0.7 s on the realme) and half
  a segment's bytes, as before.

**BACKLOG 5 (two connections for a ladder's reads on a lossy line), in
Worker requests.** At 2 MB a read, an hour of film is 360 reads at 720p
(1683 kbps), 196 at 480p (912), 124 at 360p (578), 66 at 240p (306).
Split in two connections at once, each read is two requests: on the Free
plan's 100,000 a day, ~510 viewer-hours at 480p become ~255 (720p: ~280 to
~140). It would also take the spare away — both connections busy when a
jump comes — and so cost the 0.3 s just won, for throughput a viewer sees
only on a line that holds one connection under a rung. The spare costs
none of that: the same reads, one more connection held while a ladder
plays, and a handshake (~5 KB) off the jump's path when a pool's
connection has closed (at 240p, reads ~55 s apart, most of them).

**Runs W1 and L1 (14 Nov): item 2 looked for, and a pool known lost.**

*W1 (43555903291), BACKLOG item 2 ("climb back only once the slow average
clears the higher rung"), looked for before writing a rule.* The live build
(1.64.84 with the lab hooks; the lab APK was the one already built from
that source), eight weakline passes of an A/A (the words `a` / `b` are no
`PeakRule`, so every pass plays the build's own `window`), the usual line
(4 Mbit/s 40 s, 0.9 Mbit/s 120 s, 3 Mbit/s 60 s, none 8 s, 3 Mbit/s 60 s;
60 ms each way, 0.5 % loss). `test_device/weakline_climbs.py` (now logged by
the flow) counts a climb (`exo rung` up) followed within 30 s by a stop of
250 ms or more, with what was in hand at the stop.

| | passes | climbs | a climb then a stop | stops >= 250 ms |
|---|---|---|---|---|
| W1, 14 Nov | 8 | 8 | 0 | 14, all in pass 1 |
| H, H2, H3, 8 Nov | 32 | 61 | 1 (564 ms, 30 s in hand) | 1 |

- No climb ended in a stop. The one in H3 had 30 s in hand: the decoder at
  a change of rung, not the line. The ProxyMeter believes a recovery only
  once its slow average holds (min of the fast and slow averages), and 5b
  weighs a rung by its fastest 20 s: item 2's failure (720 -> 240 -> 720 ->
  stall, 7 Nov) does not happen on this build. No rule written.
- Pass 1's 14 stops (49.6 s frozen, longest 16 s) were the runner's line,
  not the app: every one with the buffer dry and no climb before it, while
  the line read 520 kbps on average under the 4 Mbit/s cap (passes 2 and
  3: 2023 and 2596), 261 kbps under the 0.9 Mbit/s cap (852, 914), and its
  TCP handshakes took 0.5-5.2 s (0.15-0.24 s after). The cap probe before
  it had warned: 495 kbps under 900 kbit, against ~786 in every run before.
  Passes 2-8: no stop; at 480p or better 96 % (`b`) and 100 % (`a`, three
  passes).

*L1 (43560088068): a pool known lost when a read on it ends cut.* Each
pool now remembers how its last read ended (`_PoolUse.lost`: cut, hung up,
short, stalled, failed; whole clears it), and every jump's trail names the
state of the pool it took and of the other (open, lost-why, reading,
never). The rule tried (`lab_jump` = `lost`): of two free pools, a jump
takes the open one though the lost one came in whole more recently, and a
read that carries on takes the lost one to mend it. Sixteen weakjumps
passes on the weak line, on (the live rule) and lost alternating, 112
jumps; the cap probe 786 kbps.

| | on | lost |
|---|---|---|
| On a kept connection | 50 of 56 | 51 of 56 |
| The Worker's answer (median / p90) | 500 / 734 ms | 478 / 744 ms |
| The jump's own stop (median / mean) | 1530 / 1615 ms | 1758 / 1783 ms |
| First picture after the seek (median / p90) | 1165 / 1724 ms | 1292 / 1965 ms |
| Stops >= 0.6 s within 20 s after | 1 (1522 ms) | 3 (longest 807 ms) |
| Mean rung over the 20 s after | 464p | 459p |

- Paired, the same jump of neighbouring passes: the answer sooner 13
  against 13, alike 30 (median +10 ms); the jump's stop shorter under on
  in 27, under lost in 20 (sign p 0.19 for on); with any stop after it 28
  against 19 (median -102 ms, p 0.12). Inside the A/A's 0.31-0.35 s: no
  gain, if anything the other way.
- Why: the rule had nothing to choose. Whenever the pool a jump took was
  lost (6 under on, 4 under lost), the other pool was reading (7) or lost
  too (3); the case it was written for — two free pools, the lost one in
  whole more recently — did not come up.
- What the state showed, which S1/S2 could not: open pools found their
  connection in 101 of 102 jumps (idle up to 11 s: 29 under 2 s, 44 at
  2-6, 24 at 6-10, 4 at 10-30; the one new at 5.3 s), lost pools in none of
  10 (idle 5-40 s). So the falling share with idle time (S2: 91 of 100
  under 10 s, 8 of 48 at 10-30) was reads cut since the last whole one,
  not the server or the path closing idle connections.
- What is left is a jump whose free pool a previous cut took: 10 of 112
  on this line (~9 %; the other pool reading in 7, lost in 3). Only a third
  connection would cover it — made after every cut (one Worker request
  more each: a jump or a change of rung) for ~0.4 s off one jump in ten.
  Not proposed.
- Test Lab 43560350582 (the build with the rule, six jumps in Auto,
  odd ones lost-on): realme 15 of 15 (its line 1.06-2.06 Mbit/s, median
  1.39; first frame 3.7 s), OPPO 15 of 15 (2.05-8.3 Mbit/s, median 3.97;
  3.4 s), the Original skipped on both lines and Back by design; no crash,
  no ANR. Of their twelve jumps, 7 took a lost pool with the other reading
  or lost (2 of them still kept — a second connection in the pool) and 5
  an open one, all kept: the same shape as L1, the rule again with nothing
  to choose. Slow lines that day (realme ~1.4 Mbit/s against 10-68 before).

**The decision (14 Nov): no rule from either.** Item 2's failure is not on
the live build. A pool known lost is taken out (as 5c and `deep` were):
`poolLost`, its branch in `firstPool`, the lab word `lost` and Test Lab's
alternation of it. What stays: `_PoolUse`'s record of how a pool's last
read ended and the pools' state in a jump's trail (`state=` / `other=` on
the lab's line, summed per variant by `weakjumps_summary.py`), and
`weakline_climbs.py` — measurements, not rules. The gate on that build
(93ef4e5e): device lab 43567588467, the jumps on Big Buck Bunny 15 of 15
with the build's own spare. On the emulator's own line its jumps and
changes of rung (14 first reads) found a connection open in 6 and paid a
handshake in 8: 5 on a pool a cut had taken (7 such, 2 still kept — a
second connection in the pool), 2 on one never yet read in whole, 1 on an
open one. There a handshake is ~30-60 ms: the weak line, not this flow, is
where a pool rule is judged.

