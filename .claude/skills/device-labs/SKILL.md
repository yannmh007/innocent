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
- **A weak line limits one connection more than its cap**: 0.5 % loss at
  120 ms round trip is ~1.5–2 Mbit/s per TCP connection. Compare runs on
  the same line (WEAK_STEPS, WEAK_DELAY, NET_LOSS), never across lines.
- weakline's verdict is per step: stops >= 250 ms (a viewer sees them)
  apart from blips, with the rungs; `rebuffer start (ahead N ms)` says
  whether the buffer was empty (the line) or full (the phone).
- **An A/B is passes in ONE run, never one run per variant.** One play of
  the film says little about its picture (runs F and G, one build: 3 % and
  100 % at 480p). `WEAK_PASSES` plays the film once per word from a cleared
  app, writing the word to `lab_peak` (a lab build's switch; add a variant
  there), and steps.txt ends with one summary line per variant listing
  every pass's share. Alternate the words, and run again in the other
  order: H and H2 (8 Nov) disagreed because H2's runner carried more. A
  pass is ~5 min; twelve fit the 120-minute job.

## Test Lab — `test_device/cloud.env` → device-cloud.yml (real phones)
- `DEVICES="RE58C2,35 OP573DL1,34"` (realme, OPPO). Five physical tests a
  day, reset 07:00 UTC; each device in a run is one.
- `MEDIA_SEAL=` empty for the release build; `MODE=stream` plays Sintel.
- Results: `test_device/results/cloud/<device>/lab_trace.txt`. A seek or
  quality check failing with "measured" line speeds far below earlier runs
  is the line: say so with the numbers, and run that phone once more.

main never carries `test_device/results/`.
