---
name: device-labs
description: "Run and read Innocent's device lab (emulator, device-lab.yml) and Firebase Test Lab (real phones, device-cloud.yml). Use when a change needs proof on a phone or before a release."
---

# The labs

Both run only on non-main branches, started by pushing their config file.

## Device lab — `test_device/config.env` → device-lab.yml (emulator)
- `FLOWS="genres jumps"` etc. (files in `test_device/flows/`; named flows
  in `test_device/run.sh`: jumps, vault_lock, titleloop).
- `MEDIA_SEAL=0` builds what users get; `1` builds the sealed canary.
- `JUMPS_TITLE` / `CLIMB_TITLE`: open films only (Big Buck Bunny
  5c01507a-…, Sintel 0839dacb-…). Never a catalogue title.
- Add a dated comment at the top saying what the run is for and what to
  compare with. Concurrency cancels an older run on a new push.
- Results are committed back by the workflow (`device-lab: results of run
  N`): pull, then read `test_device/results/latest/` (or use the
  `lab-reader` agent). Jumps on Big Buck Bunny: 15 checks is the full set.
- **A shaped line is only shaped if a probe says so.** Until 7 Nov 2026
  every "lossy" run was unshaped: the ifb redirect on eth0 was accepted
  and fed nothing (the runner's bpf filter at pref 1 on clsact comes
  first), and the script said "dropped" anyway. The weak line is now
  `line_up` in run.sh: the emulator's HTTPS through
  `tool/netlab/line_relay.py` (iptables REDIRECT by uid, TLS untouched),
  netem on lo, the emulator's own cap set to full. Read steps.txt for
  "the line under a 900kbit cap measured N kbps" before trusting a verdict;
  a flow that needs a shaped line refuses to run without that proof.
  **A probe well under the usual (~786 kbps) warns of a bad runner line,
  and a pass on it is the line's, not the app's**: W1 (14 Nov) probed 495,
  and its first pass stopped 14 times while the line read 520 kbps under
  the 4 Mbit/s cap (the next passes: 2000-2600) with TCP handshakes of
  0.5-5 s. Before reading a pass's stops, compare its line readings
  (`line N kbps`, `measured`) per step with the other passes'.
- **A weak line limits one connection more than its cap**: 0.5 % loss at
  120 ms round trip is ~1.5–2 Mbit/s per TCP connection. Compare runs on
  the same line (WEAK_STEPS, WEAK_DELAY, NET_LOSS), never across lines.
- weakline's verdict is per step: stops >= 250 ms (a viewer sees them)
  apart from blips, with the rungs; `rebuffer start (ahead N ms)` says
  whether the buffer was empty (the line) or full (the phone).
  `test_device/weakline_climbs.py` (logged by the flow since 14 Nov) counts
  climbs (`exo rung` up) and a stop within 30 s of one — BACKLOG item 2's
  failure, not seen on the live build (W1 43555903291: 8 climbs, 0).
- **An A/B is passes in ONE run, never one run per variant.** One play of
  the film says little about its picture (runs F and G, one build: 3 % and
  100 % at 480p). `WEAK_PASSES` plays the film once per word from a cleared
  app, writing the word to `lab_peak` (a lab build's switch; add a variant
  there), and steps.txt ends with one summary line per variant listing
  every pass's share. Alternate the words, and run again in the other
  order: H and H2 (8 Nov) disagreed because H2's runner carried more. A
  pass is ~5 min; twelve fit the 120-minute job.
- **Jumps: flow `weakjumps`** (JUMP_PASSES, JUMP_LINE, JUMP_AT): the film
  from a cleared app per word (written to `lab_jump`), 40 s of film, then
  jumps in Auto, one `LAB autojump` line each; ~4 min a pass, sixteen fit.
  `test_device/weakjumps_summary.py` pairs the same jump of neighbouring
  passes. `stall_ms` under 600 ms is the position's 250 ms tick, not a
  stop. **Before changing what a jump fetches, read how its wait divides**
  (`hls jump: answer … first byte … segment …`, `exo picture after seek`):
  5c (9 Nov) shrank the segment and gained ~0.2 s, because the Worker's
  answer and the phone's restart were most of the wait, and the bigger
  segment asked for next with 2 s in hand stopped the film again.
- **The answer has parts too** (since 11 Nov): `hls jump: …; conn new|kept
  N ms (dns, tcp, tls), wait N ms, before N ms; a read cut|no read cut`,
  and the same on the `LAB autojump` line (`conn= wait_ms= answer_ms=
  cut=`), summed per variant by the summary. A response cut before its end
  takes its connection with it (Dart's HttpClient), so a jump during a read
  ahead pays a handshake: M1 (42951731347), 33 of 34 such jumps on a new
  connection, answer 885 ms (DNS 25 + TCP 147 + TLS 189 + the Worker's
  wait 441) against 466 on a kept one. A/A spread: 0.35 s over 28 pairs
  (J3), 0.31 s over 21 (M1). **And the pools' state** (since 14 Nov):
  `…, pool N, open|lost (cut, 3.1 s ago)|reading|never, the other …` in
  the trail, `state=` / `other=` on the autojump line, summed per variant
  ("the pool the jump took"). Open and new is the server or the path; lost
  is a read cut since its last whole one; lost and kept is a second
  connection in that pool. L1 (43560088068): open kept 101 of 102, lost
  0 of 10. **Before an A/B of a rule, count from the trail how often its
  case comes up**: L1's `lost` rule (take the open pool of two free ones)
  had none in 112 jumps — the other pool was always busy or lost too.
  `JUMPS_JUMP` writes a `lab_jump` word for the
  jumps flow, so the release gate can run with a switch on before the
  build's default is.

## Test Lab — `test_device/cloud.env` → device-cloud.yml (real phones)
- `DEVICES="RE58C2,35 OP573DL1,34"` (realme, OPPO). Five physical tests a
  day, reset 07:00 UTC; each device in a run is one.
- `MEDIA_SEAL=` empty for the release build; `MODE=stream` plays Sintel.
- `STREAM_AUTOJUMPS` (shares of the film): jumps in Auto after the checks,
  measured as on the emulator; the app then closes at 330 s, not 240. The
  phones' lines decide whether a jump rule has anything to act on: on
  9 Nov the realme's (~15 Mbit/s) and the OPPO's (~0.3) gave 5c none. No
  word can be written there: a switch is compared jump by jump in one
  playback (`_labAutoJumps(alternate:)`, odd jumps on).
- Results: `test_device/results/cloud/<device>/lab_trace.txt`. A seek or
  quality check failing with "measured" line speeds far below earlier runs
  is the line: say so with the numbers, and run that phone once more.

## Both labs write to the live `events` table
A lab build is a phone to the database: its plays land in `events` with
`app_version` `1.64.78+391` (the branch's version; main alone is bumped)
and a fresh `viewer_key` each run — 1,594 of 1,798 events in the week to
14 Nov. Leave that version out when reading viewer data (`play_summary` has
none: a lab's play ends in a force-stop), and out of any number shown as
the viewers' (the console's start-up latency and Trending read the lab
until BACKLOG §0's fix).

main never carries `test_device/results/`.
