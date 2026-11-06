---
name: device-labs
description: Run and read Innocent's device lab (emulator, device-lab.yml) and Firebase Test Lab (real phones, device-cloud.yml). Use when a change needs proof on a phone or before a release.
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

## Test Lab — `test_device/cloud.env` → device-cloud.yml (real phones)
- `DEVICES="RE58C2,35 OP573DL1,34"` (realme, OPPO). Five physical tests a
  day, reset 07:00 UTC; each device in a run is one.
- `MEDIA_SEAL=` empty for the release build; `MODE=stream` plays Sintel.
- Results: `test_device/results/cloud/<device>/lab_trace.txt`. A seek or
  quality check failing with "measured" line speeds far below earlier runs
  is the line: say so with the numbers, and run that phone once more.

main never carries `test_device/results/`.
