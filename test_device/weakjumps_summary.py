#!/usr/bin/env python3
"""The weakjumps flow's verdict (test_device/run.sh; BACKLOG 5c).

Reads weakjumps.tsv, one row a jump in Auto on the weak line:
  pass, variant, jump, at, frozen_ms, ready_ms, before, first, low_ms,
  back_ms, stall_ms, mean, rule, want
and prints, per variant (a word of JUMP_PASSES, `lab_jump`):
  - the stop a viewer sees at the jump (frozen_ms: the longest the position
    stood still, from the jump to a second of film played after it) as a
    median, mean, 90th percentile and longest;
  - the picture for the 20 s after: how often the first segment came from a
    lower rung than the one before the jump, how long the film stayed under
    that rung, and any stop after the jump's own;
then the variants side by side, jump by jump: passes are played in pairs
(1-2, 3-4, ...), one of each variant, so the same jump of a pair lands on
the same moment of the film on the same hour of the same runner. A one-sided
sign test says how often the split could be chance.

Prints plain lines; run.sh logs each one to steps.txt.
"""
import math
import sys
from collections import Counter, defaultdict

COLUMNS = ["pass", "variant", "jump", "at", "frozen_ms", "ready_ms", "before",
           "first", "low_ms", "back_ms", "stall_ms", "mean", "rule", "want"]
NUMERIC = {"pass", "jump", "frozen_ms", "ready_ms", "before", "first", "low_ms",
           "back_ms", "stall_ms", "mean", "want"}
ALIKE_MS = 100  # closer than this is the position's own tick, not a win
STOP_MS = 250   # a stop a viewer sees (PlaybackQoe.visibleMs)


def read(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            cells = line.rstrip("\n").split("\t")
            if len(cells) < len(COLUMNS):
                continue
            row = {}
            ok = True
            for name, cell in zip(COLUMNS, cells):
                if name in NUMERIC:
                    try:
                        row[name] = int(cell)
                    except ValueError:
                        ok = False
                        break
                else:
                    row[name] = cell
            if ok:
                rows.append(row)
    return rows


def median(xs):
    xs = sorted(xs)
    if not xs:
        return 0
    m = len(xs) // 2
    return xs[m] if len(xs) % 2 else (xs[m - 1] + xs[m]) / 2


def pct(xs, q):
    xs = sorted(xs)
    if not xs:
        return 0
    return xs[min(len(xs) - 1, int(math.ceil(q * len(xs))) - 1)]


def sign_p(wins, losses):
    """One-sided: the chance of `wins` or more of wins+losses by a coin."""
    n = wins + losses
    if n == 0:
        return 1.0
    return sum(math.comb(n, k) for k in range(wins, n + 1)) / 2 ** n


def per_variant(v, rows):
    frozen = [r["frozen_ms"] for r in rows]
    ready = [r["ready_ms"] for r in rows if r["ready_ms"] >= 0]
    lower = [r for r in rows if 0 < r["first"] < r["before"]]
    steps = Counter(f"{r['before']}->{r['first']}" for r in rows)
    back = [r["back_ms"] for r in rows if r["back_ms"] > 0]
    never = sum(1 for r in rows if r["back_ms"] < 0)
    stops = [r["stall_ms"] for r in rows if r["stall_ms"] >= STOP_MS]
    passes = sorted({r["pass"] for r in rows})
    rules = sorted({r["rule"] for r in rows})
    yield (f"weakjumps {v}, {len(rows)} jumps in {len(passes)} passes (the app's rule: "
           f"{','.join(rules)}): frozen median {median(frozen):.0f} ms, mean "
           f"{sum(frozen) / max(1, len(frozen)):.0f}, p90 {pct(frozen, 0.9)}, longest "
           f"{max(frozen, default=0)}; moving again after median {median(ready):.0f} ms "
           f"({len(rows) - len(ready)} never)")
    yield (f"weakjumps {v}, the picture after: first segment under the rung before in "
           f"{len(lower)} of {len(rows)} ({', '.join(f'{k} x{n}' for k, n in steps.most_common())}); "
           f"under it {sum(r['low_ms'] for r in rows) / max(1, len(rows)) / 1000:.1f} s of 20 on "
           f"average, back after median {median(back):.0f} ms ({never} not within 20 s); "
           f"mean rung {sum(r['mean'] for r in rows) / max(1, len(rows)):.0f}p; stops >= {STOP_MS} ms "
           f"after the jump: {len(stops)} (longest {max(stops, default=0)} ms)")
    by_pass = defaultdict(list)
    for r in rows:
        by_pass[r["pass"]].append(r["frozen_ms"])
    yield (f"weakjumps {v}, frozen median per pass: "
           + ", ".join(f"{p}:{median(by_pass[p]):.0f}" for p in passes))


def paired(rows, a, b):
    """The same jump of a pass pair (1-2, 3-4, ...) under a and under b."""
    cell = {}
    for r in rows:
        cell[((r["pass"] + 1) // 2, r["jump"], r["variant"])] = r
    diffs, stop_a, stop_b = [], 0, 0
    for (pair, jump, var), ra in cell.items():
        if var != a:
            continue
        rb = cell.get((pair, jump, b))
        if rb is None:
            continue
        diffs.append(ra["frozen_ms"] - rb["frozen_ms"])
        stop_a += ra["stall_ms"] >= STOP_MS
        stop_b += rb["stall_ms"] >= STOP_MS
    if not diffs:
        yield f"weakjumps: no jump of {a} has its pair under {b}"
        return
    a_wins = sum(1 for d in diffs if d <= -ALIKE_MS)
    b_wins = sum(1 for d in diffs if d >= ALIKE_MS)
    alike = len(diffs) - a_wins - b_wins
    yield (f"weakjumps paired, {len(diffs)} jumps ({a} against {b}, same pair of passes, same "
           f"moment): {a} stood still shorter in {a_wins}, {b} in {b_wins}, alike (within "
           f"{ALIKE_MS} ms) {alike}; median {a} - {b} = {median(diffs):.0f} ms; sign test "
           f"p={sign_p(a_wins, b_wins):.4f} for {a}, p={sign_p(b_wins, a_wins):.4f} for {b}; "
           f"stops after the jump {stop_a} against {stop_b}")


def main(path):
    rows = read(path)
    if not rows:
        print("weakjumps: no jump was recorded")
        return
    order = []
    for r in rows:
        if r["variant"] not in order:
            order.append(r["variant"])
    for v in order:
        for line in per_variant(v, [r for r in rows if r["variant"] == v]):
            print(line)
    if len(order) == 2:
        for line in paired(rows, order[0], order[1]):
            print(line)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "weakjumps.tsv")
