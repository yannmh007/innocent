#!/usr/bin/env python3
"""The app's first seconds on the CPU (flow coldcpu), read.

For each cold start c:
  out/coldcpu_top_<c>.txt    `top -H -b -d 2 -n 12 -p PID` (every thread, every 2 s)
  out/coldcpu_stacks_<c>.txt `debuggerd -j PID` at 3, 6, 10 and 15 s (Java stacks)
  out/coldcpu_perf_<c>.txt   simpleperf by thread and library, by thread and symbol
and the trail's `LAB cpu` lines (CpuProbe, every 10 s) between the start's
markers in out/logcat_raw.txt.

Says: the app's CPU over time and by thread family (pool-N-thread-M is one
family: Java's default thread factory, used by plugins and by code that
did not name its threads); which code the busy threads were running —
each Java thread that was not parked, by its first frame outside the
platform — and the profile's lines for the families that matter. The busy
threads' stacks are also written whole to out/coldcpu_busy_stacks.txt.
"""
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

IDLE = ('Waiting', 'TimedWaiting', 'Sleeping', 'Blocked')
PLATFORM = ('java.', 'javax.', 'android.', 'androidx.', 'dalvik.', 'libcore.', 'sun.',
            'kotlin.', 'kotlinx.', 'com.android.')


def family(name):
    name = name.strip()
    if re.match(r'pool-\d+-thread-\d+', name):
        return 'pool-thread'
    if name.startswith('DartWorker'):
        return 'DartWorker'
    if re.match(r'binder:\d+_\d+', name):
        return 'binder'
    if name.startswith('glide-'):
        return 'glide'
    return re.sub(r'[-_:#]?\d+$', '', name) or name


def read_top(path):
    """[(sample index, {thread: cpu%}, total%)] from the second block on."""
    blocks = []
    cur = None
    for line in Path(path).read_text(errors='replace').splitlines():
        if re.match(r'\s*TID\s+USER', line):
            cur = {}
            blocks.append(cur)
            continue
        if cur is None:
            continue
        parts = line.split()
        if len(parts) < 12 or not parts[0].isdigit():
            continue
        try:
            cpu = float(parts[8])
        except ValueError:
            continue
        name = ' '.join(parts[11:-1]) or parts[11]
        cur[name] = cur.get(name, 0.0) + cpu
    return blocks[1:] if len(blocks) > 1 else blocks


def read_stacks(path):
    """[(dump label, [(thread, state, [frames])])]"""
    dumps = []
    cur = None
    th = None
    for line in Path(path).read_text(errors='replace').splitlines():
        if line.startswith('== '):
            cur = (line[3:].strip(), [])
            dumps.append(cur)
            th = None
            continue
        if cur is None:
            continue
        m = re.match(r'"(.+?)".*\b(Runnable|Native|Waiting|TimedWaiting|Sleeping|Blocked|Suspended|'
                     r'WaitingForGcToComplete|WaitingPerformingGc|Starting|VmWait)\b', line)
        if m:
            th = (m.group(1), m.group(2), [])
            cur[1].append(th)
            continue
        if th is not None:
            f = re.match(r'\s+at (\S+)', line)
            if f:
                th[2].append(f.group(1))
            elif re.match(r'\s+native: ', line) and len(th[2]) < 3:
                th[2].append(line.strip()[:110])
    return dumps


def busy(thread):
    name, state, frames = thread
    if state in IDLE:
        return False
    java = [f for f in frames if not f.startswith('native:')]
    if not java:
        return False
    top = java[0]
    # Parked or waiting on a queue, whatever the state says.
    if any(k in top for k in ('Unsafe.park', 'Object.wait', 'MessageQueue.nativePollOnce',
                               'Thread.sleep', 'LockSupport.park', 'SocketInputStream.socketRead',
                               'ServerSocket', 'accept0', 'Posix.poll', 'Posix.accept', 'EPoll')):
        return False
    return True


def ours(frames):
    for f in frames:
        if f.startswith('native:'):
            continue
        if not f.startswith(PLATFORM):
            return f.split('(')[0]
    return (frames[0].split('(')[0] if frames else '?') + ' (platform)'


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else 'out')
    starts = sorted({int(m.group(1)) for p in out.glob('coldcpu_top_*.txt')
                     if (m := re.match(r'coldcpu_top_(\d+)\.txt', p.name))})
    if not starts:
        print('coldcpu: nothing measured')
        return
    by_family_all = defaultdict(list)
    busy_out = []
    code = Counter()
    code_threads = defaultdict(set)
    for c in starts:
        blocks = read_top(out / f'coldcpu_top_{c}.txt')
        totals = [round(sum(b.values())) for b in blocks]
        fam_mean = defaultdict(float)
        for b in blocks[:10]:  # the first ~20 s
            fams = defaultdict(float)
            for name, cpu in b.items():
                fams[family(name)] += cpu
            for k, v in fams.items():
                fam_mean[k] += v / max(1, min(10, len(blocks)))
        for k, v in fam_mean.items():
            by_family_all[k].append(v)
        top = sorted(fam_mean.items(), key=lambda kv: -kv[1])[:8]
        print(f'coldcpu start {c}: app % every 2 s: {" ".join(str(t) for t in totals)}; '
              f'first 20 s by family: ' + ', '.join(f'{k} {v:.0f}%' for k, v in top))
        sp = out / f'coldcpu_stacks_{c}.txt'
        if sp.exists():
            for label, threads in read_stacks(sp):
                for t in threads:
                    if busy(t) or (t[0].startswith('pool-') and t[1] not in IDLE):
                        key = ours(t[2])
                        code[(family(t[0]), key)] += 1
                        code_threads[(family(t[0]), key)].add(t[0])
                        busy_out.append(f'== start {c}, {label}: "{t[0]}" {t[1]}\n' +
                                        '\n'.join('    ' + f for f in t[2][:14]))
    print('coldcpu over all starts, first 20 s, mean % by family: ' + ', '.join(
        f'{k} {sum(v) / len(starts):.0f}%' for k, v in
        sorted(by_family_all.items(), key=lambda kv: -sum(kv[1]))[:10]))
    if code:
        print('coldcpu: busy Java threads in the stack dumps, by family and the first frame not the platform\'s:')
        for (fam, key), n in code.most_common(25):
            print(f'  {n:3d}  {fam:12s} {key}  ({", ".join(sorted(code_threads[(fam, key)])[:4])})')
    else:
        print('coldcpu: no busy Java thread in the stack dumps (none taken, or all parked)')
    (out / 'coldcpu_busy_stacks.txt').write_text('\n'.join(busy_out) + '\n')
    for c in starts:
        pp = out / f'coldcpu_perf_{c}.txt'
        if not pp.exists():
            continue
        lines = [l for l in pp.read_text(errors='replace').splitlines()
                 if re.search(r'DartWorker|pool-|1\.ui|1\.raster|1\.io|Overhead|Samples|Error|error', l)]
        print(f'coldcpu start {c} profile (simpleperf), the lines for the families that matter:')
        for l in lines[:40]:
            print('  ' + l.strip()[:160])
    # CpuProbe's own lines.
    raw = out / 'logcat_raw.txt'
    if raw.exists():
        on = None
        for line in raw.read_text(errors='replace').splitlines():
            m = re.search(r'LAB coldcpu (begin|end) start=(\d+)', line)
            if m:
                on = int(m.group(2)) if m.group(1) == 'begin' else None
                continue
            if on is not None and 'LAB cpu ' in line:
                print(f'coldcpu start {on} CpuProbe: ' + line.split('LAB cpu ', 1)[1].strip()[:200])


if __name__ == '__main__':
    main()
