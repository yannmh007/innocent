#!/usr/bin/env python3
"""A climb, then a stop: BACKLOG "Streaming without stutter" item 2 (14 Nov 2026).

Item 2's failure, as written on 7 Nov: on a line that fell and came back,
Auto climbed to a higher rung (720 -> 240 -> 720) and the film stopped
again. This reads the weakline flow's per-pass trails (weakline_N.txt, the
app's trail between the pass's markers; test_device/run.sh) and counts, per
pass:

  - every CLIMB: an `exo rung NNNp` line (the decoder's input changed rung)
    above the rung before it;
  - every STOP a viewer sees: `rebuffer start (ahead N ms)` whose
    `rebuffer end N ms` is 250 ms or more (PlaybackQoe.visibleMs; shorter
    is a blip);
  - a CLIMB THEN A STOP: a stop that starts within WINDOW_S of a climb.

`ahead` says whose stop it was: little film in hand (under EMPTY_MS) is the
line running dry — item 2's failure; seconds in hand is the phone (a
decoder's restart at a rung change). The decoder meets the new rung only
after the film buffered before the choice has played, so a climb the line
cannot carry runs dry after its `exo rung` line, not before: with B seconds
in hand at the choice and the new rung arriving at r seconds of film a
second, the film stops B*r/(1-r) s after it (B 10 s, r 0.75: 30 s).

Usage: weakline_climbs.py [-v] DIR_OR_FILES...
  DIR: a results directory holding weakline_N.txt (and weakline_passes.tsv,
  whose stop count each pass is checked against).
  -v: for each climb, the line readings (`measured`, `line N kbps`) in the
  60 s before its choice was made, to see what the climb believed.
Prints plain lines; run.sh logs each one to steps.txt.
"""
import os
import re
import sys

WINDOW_S = 30.0     # a stop this soon after a climb is counted against it
VISIBLE_MS = 250    # PlaybackQoe.visibleMs: shorter is a blip
EMPTY_MS = 4000     # under this in hand (two segments) the line ran dry
LOOKBACK_S = 60.0   # -v: readings this long before the climb's choice

TIMED = re.compile(r"^LAB +(\d+\.\d+) (.*)$")
RUNG = re.compile(r"^exo rung (\d+)p")
START = re.compile(r"^(rebuffer|jump fill) start(?: \(ahead (\d+) ms\))?")
END = re.compile(r"^(rebuffer|jump fill) end (\d+) ms")
READING = re.compile(r"^(measured|line) (\d+) kbps(, in a read|, a read)?")
BEGIN = re.compile(r"LAB weakline begin pass=(\d+) peak=(\S+)")
STEP = re.compile(r"LAB weakline line (\S+) for (\d+)s")


def read_pass(path):
    """One pass's trail: its climbs, stops and readings, in order."""
    p = {"pass": None, "variant": "-", "climbs": [], "stops": [], "readings": [],
         "steps": []}
    step = None
    rung = None
    started = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            m = BEGIN.search(line)
            if m:
                p["pass"], p["variant"] = int(m.group(1)), m.group(2)
                continue
            m = STEP.search(line)
            if m:
                step = "%d:%s" % (len(p["steps"]) + 1, m.group(1))
                p["steps"].append(step)
                continue
            m = TIMED.match(line)
            if not m:
                continue
            t, body = float(m.group(1)), m.group(2)
            r = RUNG.match(body)
            if r:
                h = int(r.group(1))
                if rung is not None and h > rung:
                    p["climbs"].append({"t": t, "from": rung, "to": h, "step": step})
                rung = h
                continue
            s = START.match(body)
            if s:
                ahead = int(s.group(2)) if s.group(2) else None
                started = {"t": t, "ahead": ahead, "rung": rung, "step": step,
                           "jump": s.group(1) == "jump fill"}
                continue
            e = END.match(body)
            if e and started is not None:
                started["ms"] = int(e.group(2))
                p["stops"].append(started)
                started = None
                continue
            rd = READING.match(body)
            if rd:
                p["readings"].append((t, int(rd.group(2)), rd.group(1)))
    return p


def passes_tsv(path):
    """weakline_passes.tsv: pass -> (variant, stops >= 250 ms)."""
    out = {}
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as f:
        for row in f:
            c = row.rstrip("\n").split("\t")
            if len(c) >= 4 and c[0].isdigit():
                out[int(c[0])] = (c[1], int(c[3]) if c[3].isdigit() else None)
    return out


def main(argv):
    verbose = "-v" in argv
    args = [a for a in argv if a != "-v"]
    files, tsv = [], {}
    for a in args:
        if os.path.isdir(a):
            names = [n for n in os.listdir(a) if re.fullmatch(r"weakline_\d+\.txt", n)]
            files += [os.path.join(a, n) for n in sorted(names, key=lambda n: int(n[9:-4]))]
            tsv.update(passes_tsv(os.path.join(a, "weakline_passes.tsv")))
        else:
            files.append(a)
    if not files:
        print("weakline climbs: no weakline_N.txt found")
        return 1
    total = {"passes": 0, "with": 0, "climbs": 0, "after": 0, "dry": 0, "stops": 0}
    per_variant = {}
    for path in files:
        p = read_pass(path)
        n = p["pass"] if p["pass"] is not None else os.path.basename(path)
        visible = [s for s in p["stops"] if s["ms"] >= VISIBLE_MS and not s["jump"]]
        hits = []
        for c in p["climbs"]:
            after = [s for s in visible if c["t"] <= s["t"] <= c["t"] + WINDOW_S]
            c["after"] = after
            if after:
                hits.append(c)
        dry = [c for c in hits
               if any(s["ahead"] is not None and s["ahead"] < EMPTY_MS for s in c["after"])]
        total["passes"] += 1
        total["climbs"] += len(p["climbs"])
        total["after"] += len(hits)
        total["dry"] += len(dry)
        total["stops"] += len(visible)
        if hits:
            total["with"] += 1
        v = per_variant.setdefault(p["variant"], {"passes": 0, "with": 0, "dry": 0,
                                                  "stops": 0, "frozen": 0})
        v["passes"] += 1
        v["with"] += 1 if hits else 0
        v["dry"] += 1 if dry else 0
        v["stops"] += len(visible)
        v["frozen"] += sum(s["ms"] for s in visible)
        climbs = ", ".join("%d->%dp at %.1f (step %s)" % (c["from"], c["to"], c["t"], c["step"])
                           for c in p["climbs"]) or "none"
        check = ""
        if isinstance(n, int) and n in tsv and tsv[n][1] is not None and tsv[n][1] != len(visible):
            check = " [weakline_passes.tsv says %d stops]" % tsv[n][1]
        print("weakline climbs pass %s (%s): climbs %d (%s); stops >= %d ms %d%s; "
              "a climb then a stop within %.0f s: %d, the line dry (ahead < %d ms): %d"
              % (n, p["variant"], len(p["climbs"]), climbs, VISIBLE_MS, len(visible), check,
                 WINDOW_S, len(hits), EMPTY_MS, len(dry)))
        for s in visible:
            since = [c for c in p["climbs"] if c["t"] <= s["t"]]
            last = since[-1] if since else None
            print("weakline climbs pass %s (%s): stop %d ms at %.1f (step %s, rung %sp, ahead %s ms)%s"
                  % (n, p["variant"], s["ms"], s["t"], s["step"], s["rung"],
                     s["ahead"] if s["ahead"] is not None else "-",
                     ", %.1f s after the climb %d->%dp" % (s["t"] - last["t"], last["from"], last["to"])
                     if last else ", no climb before it"))
        if verbose:
            for c in p["climbs"]:
                # The choice was made about a buffer's worth of film before
                # the decoder met the rung: look back from the climb.
                rd = [r for r in p["readings"] if c["t"] - LOOKBACK_S <= r[0] <= c["t"]]
                print("weakline climbs pass %s: climb %d->%dp at %.1f, readings before: %s"
                      % (n, c["from"], c["to"], c["t"],
                         " ".join("%.0f:%s=%d" % (t, k[0], kb) for t, kb, k in rd) or "none"))
    for name, v in per_variant.items():
        print("weakline climbs %s, %d passes: a climb then a stop in %d, the line dry in %d; "
              "stops >= %d ms %d, frozen %d ms"
              % (name, v["passes"], v["with"], v["dry"], VISIBLE_MS, v["stops"], v["frozen"]))
    print("weakline climbs, all %d passes: climbs %d, a climb then a stop within %.0f s %d "
          "(in %d passes), the line dry %d; stops >= %d ms %d"
          % (total["passes"], total["climbs"], WINDOW_S, total["after"], total["with"],
             total["dry"], VISIBLE_MS, total["stops"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
