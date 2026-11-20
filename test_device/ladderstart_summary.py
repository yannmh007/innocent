#!/usr/bin/env python3
"""The ladder's start, pass by pass and per line and word (flow ladderstart).

Reads out/ladderstart_passes.tsv (pass, line, word) and each pass's trail,
out/ladderstart_<pass>.txt — lines "MM-DD HH:MM:SS.mmm LAB …", logcat's own
time kept — and says, for each pass, when each step of the start came, in
ms from the tap (`LAB title: opening`):

  grant · register (the ladder's rungs made local) · the start rung's index
  · master · its playlist · the first film segment asked and in · the
  picture (`first frame`), and the neighbours' indexes beside them;

then in the 30 s after the picture: stops a viewer sees (>= 250 ms), the
time at 480p or better, Auto's first change of rung; and the seek bar's
drags (`LAB drag …`) with each preview's parts (`preview at …`).

Per line and word: the first picture's median and p90, stops, 480p+ share,
each step's median, the drags. Two words of one build (`a`, `b`) are an
A/A: their difference is the noise a rule must clear.
"""
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path

STOP_MS = 250
WINDOW_S = 30.0


def stamp(line):
    m = re.match(r'(\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) (LAB .*)$', line)
    if not m:
        return None, None
    t = datetime.strptime('2026-' + m.group(1), '%Y-%m-%d %H:%M:%S.%f')
    return t.timestamp(), m.group(2)


def pct(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def med(xs):
    return round(statistics.median(xs)) if xs else None


def fmt(v):
    return '-' if v is None else str(round(v))


def read_pass(path):
    rows = []
    for raw in Path(path).read_text(errors='replace').splitlines():
        t, msg = stamp(raw)
        if t is not None:
            # PlaybackLog's own 0.1 s stamp, when there is one, is dropped.
            msg = re.sub(r'^LAB\s+\d+\.\d\s+', 'LAB ', msg)
            rows.append((t, msg[4:]))
    return rows


def first(rows, pat, after=None):
    for t, m in rows:
        if after is not None and t < after:
            continue
        mm = re.search(pat, m)
        if mm:
            return t, mm
    return None, None


def analyse(rows):
    out = {}
    tap, _ = first(rows, r'^LAB title: opening')
    if tap is None:
        return None
    out['tap'] = tap
    ms = lambda t: None if t is None else (t - tap) * 1000.0
    t, mm = first(rows, r'^play \S+ .* in (\d+) ms', tap)
    out['grant'] = ms(t)
    out['grant_own'] = int(mm.group(1)) if mm else None
    marks = {}
    for t, m in rows:
        mm = re.match(r'hls start \+(\d+) ms: (.*)$', m)
        if mm and t >= tap and mm.group(2) not in marks:
            marks[mm.group(2)] = ms(t)
    out['marks'] = marks
    t, mm = first(rows, r'^play rung (\d+)p', tap)
    start_h = int(mm.group(1)) if mm else None
    out['start_h'] = start_h
    t, _ = first(rows, r'^open ladder \(exo\)', tap)
    out['open'] = ms(t)
    frame_t, mm = first(rows, r'^first frame (\d+) ms', tap)
    out['picture'] = ms(frame_t)
    out['frame_own'] = int(mm.group(1)) if mm else None
    t, _ = first(rows, r'^warm: ', None)
    out['warmed'] = t is not None
    # The 30 s after the picture.
    rung_at = []  # (t, h) as shown
    for t, m in rows:
        mm = re.match(r'exo rung (\d+)p', m)
        if mm and t >= tap:
            rung_at.append((t, int(mm.group(1))))
    stops = []
    if frame_t is not None:
        end = frame_t + WINDOW_S
        for t, m in rows:
            mm = re.match(r'rebuffer end (\d+) ms', m)
            if mm and frame_t <= t <= end + 10:
                v = int(mm.group(1))
                # Its start inside the window.
                if t - v / 1000.0 <= end and v >= STOP_MS:
                    stops.append(v)
        # Time at each rung over [picture, +30 s].
        shown = None
        for t, h in rung_at:
            if t <= frame_t:
                shown = h
        if shown is None and rung_at:
            shown = rung_at[0][1]
        cur_t, cur_h = frame_t, shown
        share = {}
        for t, h in rung_at:
            if t <= frame_t:
                continue
            if t >= end:
                break
            if cur_h is not None:
                share[cur_h] = share.get(cur_h, 0) + (t - cur_t)
            cur_t, cur_h = t, h
        if cur_h is not None:
            share[cur_h] = share.get(cur_h, 0) + (end - cur_t)
        tot = sum(share.values()) or 1
        out['hi_share'] = 100.0 * sum(v for h, v in share.items() if h >= 480) / tot
        out['rungs'] = '>'.join(str(h) for h in [shown] + [h for t, h in rung_at if frame_t < t < end] if h)
        later = [(t, h) for t, h in rung_at if frame_t < t < end and h != shown]
        out['first_change'] = None if not later else ((later[0][0] - frame_t), later[0][1])
    else:
        out['hi_share'] = None
        out['rungs'] = '-'
        out['first_change'] = None
    out['stops'] = stops
    # Drags and previews.
    drags = []
    for t, m in rows:
        mm = re.match(r'LAB drag (\d+)/(\d+) (.*)$', m)
        if mm:
            kv = dict(x.split('=', 1) for x in mm.group(3).split() if '=' in x)
            drags.append(kv)
    out['drags'] = drags
    previews = []
    for t, m in rows:
        mm = re.match(r'preview at (\d+)s: (\d+) KB, (\d+) ms \(bytes (\d+) ms, (.*); picture (\d+) ms\)', m)
        if mm:
            p = {'kb': int(mm.group(2)), 'ms': int(mm.group(3)), 'bytes_ms': int(mm.group(4)),
                 'how': mm.group(5), 'pic_ms': int(mm.group(6))}
            hw = re.search(r'conn (new|kept|\?) (\d+) ms.*wait (\d+) ms, read (\d+) ms', p['how'])
            if hw:
                p.update(conn=hw.group(1), conn_ms=int(hw.group(2)), wait_ms=int(hw.group(3)),
                         read_ms=int(hw.group(4)))
            previews.append(p)
    out['previews'] = previews
    out['ahead'] = sum(1 for t, m in rows if m.startswith('preview (ahead) at '))
    # The pack (20 Nov, docs/trickplay_plan.md): its header's read, and the
    # runs taken ahead of the drags.
    pk = [re.match(r'preview pack: (\d+) pictures, header (\d+) ms', m) for t, m in rows]
    pk = [x for x in pk if x]
    out['pack_header_ms'] = int(pk[0].group(2)) if pk else None
    out['pack_unused'] = [m for t, m in rows if m.startswith('preview pack: not used')]
    out['pack_ahead'] = [
        {'took': int(x.group(1)), 'ms': int(x.group(2)), 'requests': int(x.group(3)), 'kb': int(x.group(4))}
        for x in (re.match(r'preview ahead \(pack\): around \d+s, (\d+) taken in (\d+) ms, (\d+) requests, '
                           r'(\d+) KB', m) for t, m in rows) if x]
    return out


def first_seg(a):
    """The first film segment's rung, its index, asked and in (ms)."""
    asked = [(ms, k) for k, ms in a['marks'].items() if k.endswith('p segment asked')]
    if not asked:
        return None, None, None, None
    ms, k = min(asked)
    h = k.split('p ')[0]
    return h, a['marks'].get(f'{h}p index'), ms, a['marks'].get(f'{h}p segment in')


STEPS = [
    ('grant', lambda a, h: a.get('grant')),
    ('register', lambda a, h: a['marks'].get('register')),
    ('start index', lambda a, h: a['marks'].get(f'{h}p index')),
    ('master', lambda a, h: a['marks'].get('master served')),
    ('start playlist', lambda a, h: a['marks'].get(f'{h}p playlist served')),
    ('1st seg index', lambda a, h: first_seg(a)[1]),
    ('1st seg asked', lambda a, h: first_seg(a)[2]),
    ('1st seg in', lambda a, h: first_seg(a)[3]),
    ('picture', lambda a, h: a.get('picture')),
]


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else 'out')
    tsv = out / 'ladderstart_passes.tsv'
    if not tsv.exists():
        print('ladderstart: no passes')
        return
    passes = []
    for line in tsv.read_text().splitlines():
        p, lk, word = line.split('\t')
        a = analyse(read_pass(out / f'ladderstart_{p}.txt'))
        passes.append((int(p), lk, word, a))
    for p, lk, word, a in passes:
        if a is None:
            print(f'ladderstart pass {p} ({lk}, {word}): no tap in the trail')
            continue
        h = a['start_h']
        steps = ', '.join(f'{n} {fmt(f(a, h))}' for n, f in STEPS)
        others = sorted({k for k in a['marks'] if k.endswith('p index') and not k.startswith(f'{h}p')})
        nb = ', '.join(f'{k} {fmt(a["marks"][k])}' for k in others) or 'none'
        fc = a['first_change']
        fh = first_seg(a)[0]
        print(f'ladderstart pass {p} ({lk}, {word}): start {h}p{" warmed" if a["warmed"] else ""}, '
              f'first segment {fh or "?"}p; '
              f'ms from the tap: {steps}; other indexes: {nb}; '
              f'30 s: stops {len(a["stops"])} ({sum(a["stops"])} ms), 480p+ {fmt(a["hi_share"])} %, '
              f'rungs {a["rungs"]}, first change '
              f'{"none" if fc is None else f"+{fc[0]:.1f} s to {fc[1]}p"}')
    print()
    # A word may be `START+PREVIEW` (fix+near): the start's numbers are
    # grouped by the first, the seek bar's by the second.
    def sw(w):
        seed = w.split('@')[1] if '@' in w else ''
        return w.split('@')[0].split('+')[0] + (f'@{seed}' if seed else '')
    pw = lambda w: w.split('@')[0].split('+')[1] if '+' in w.split('@')[0] else '-'
    groups = {}
    for p, lk, word, a in passes:
        if a is not None:
            groups.setdefault((lk, sw(word)), []).append(a)
    for (lk, word), xs in sorted(groups.items()):
        pics = [a['picture'] for a in xs if a['picture'] is not None]
        stops = [len(a['stops']) for a in xs]
        frozen = [sum(a['stops']) for a in xs]
        hi = [a['hi_share'] for a in xs if a['hi_share'] is not None]
        h = xs[0]['start_h']
        stepmeds = ', '.join(
            f'{n} {fmt(med([f(a, a["start_h"]) for a in xs if f(a, a["start_h"]) is not None]))}'
            for n, f in STEPS)
        print(f'ladderstart {lk} {word}, {len(xs)} passes: first picture median {fmt(med(pics))} ms, '
              f'p90 {fmt(pct(pics, 0.9))} ms (each {",".join(fmt(x) for x in pics)}); '
              f'stops in 30 s {sum(stops)} in {sum(1 for s in stops if s)} passes, {sum(frozen)} ms; '
              f'480p+ mean {fmt(statistics.mean(hi) if hi else None)} %; step medians: {stepmeds}')
    # The A/A (or A/B): per line, neighbouring passes of two words paired.
    for lk in sorted({k[0] for k in groups}):
        seq = [(sw(w), a) for p, l, w, a in passes if l == lk and a is not None and a['picture'] is not None]
        # Neighbouring passes of two words, paired in turn, per pair of words.
        pairs = {}
        i = 0
        while i + 1 < len(seq):
            (w1, a1), (w2, a2) = seq[i], seq[i + 1]
            if w1 != w2:
                x, y = sorted((w1, w2))
                d = (a1['picture'] - a2['picture']) if w1 == x else (a2['picture'] - a1['picture'])
                pairs.setdefault((x, y), []).append(d)
                i += 2
            else:
                i += 1
        for (x, y), ds in sorted(pairs.items()):
            wins = sum(1 for d in ds if d < 0)
            print(f'ladderstart {lk}: {x} minus {y}, first picture, {len(ds)} pairs: '
                  f'median {fmt(med(ds))} ms, mean {fmt(statistics.mean(ds))} ms, '
                  f'{x} sooner in {wins} of {len(ds)}')
    # The drags, by the pass's preview word (`trick` the pack, `near` the
    # fragments, `base` 1.64.85), short (30 s of film or less), long (to
    # 120 s) and far (further: a part never seen). Each: the first picture
    # (`first_ms`), one within 10 s of where the finger stopped
    # (`near_ms`), its own picture (`stop_ms`) — median and p90 — and what
    # a drag cost on the line (requests, KB; the pictures ahead included).
    pgroups = {}
    for p, lk, word, a in passes:
        if a is not None:
            pgroups.setdefault((lk, pw(word)), []).append(a)

    def ints(sel, k):
        return [int(d[k]) for d in sel if d.get(k, '-1') not in ('-1', None)]

    def size_of(d):
        by = abs(int(d.get('by', '0')))
        return 'short' if by <= 30 else ('long' if by <= 120 else 'far')

    for (lk, pword), xs in sorted(pgroups.items()):
        ds = [d for a in xs for d in a['drags']]
        pv = [v for a in xs for v in a['previews']]
        if not ds and not pv:
            continue
        for size in ('short', 'long', 'far', 'all'):
            sel = [d for d in ds if size == 'all' or size_of(d) == size]
            if not sel:
                continue
            stop = ints(sel, 'stop_ms')
            firsts = ints(sel, 'first_ms')
            near = ints(sel, 'near_ms')
            fetched = [int(d.get('fetched', '0')) for d in sel]
            miss = sum(1 for d in sel if d.get('stop_ms') == '-1')
            srcs = {}
            for d in sel:
                srcs[d.get('src', '?')] = srcs.get(d.get('src', '?'), 0) + 1
            reqs = ints(sel, 'requests')
            kb = [b / 1024 for b in ints(sel, 'bytes')]
            print(f'ladderstart {lk} drags, previews {pword}, {size}: {len(sel)} '
                  f'(src {", ".join(f"{k} {v}" for k, v in sorted(srcs.items()))}); '
                  f'first picture median {fmt(med(firsts))} ms, p90 {fmt(pct(firsts, 0.9))}; '
                  f'one within 10 s median {fmt(med(near))} ms, p90 {fmt(pct(near, 0.9))}; '
                  f'its own picture median {fmt(med(stop))} ms, p90 {fmt(pct(stop, 0.9))}, never {miss}; '
                  f'a drag: {fmt(med(reqs))} requests, {fmt(med(kb))} KB median '
                  f'(mean {fmt(statistics.mean(reqs) if reqs else None)}, {fmt(statistics.mean(kb) if kb else None)}); '
                  f'fetches {fmt(statistics.mean(fetched))}')
        hdr = [a['pack_header_ms'] for a in xs if a.get('pack_header_ms') is not None]
        runs = [r for a in xs for r in a.get('pack_ahead', [])]
        unused = [u for a in xs for u in a.get('pack_unused', [])]
        if hdr or runs or unused:
            print(f'ladderstart {lk} previews {pword}: pack opened in {len(hdr)} of {len(xs)} passes, header '
                  f'median {fmt(med(hdr))} ms; runs ahead {len(runs)}, median {fmt(med([r["ms"] for r in runs]))} ms, '
                  f'{fmt(med([r["took"] for r in runs]))} pictures, {fmt(med([r["kb"] for r in runs]))} KB'
                  f'{"; NOT USED: " + "; ".join(sorted(set(unused))) if unused else ""}')
        line_pv = [v for v in pv if v['how'].startswith('line')]
        phone_pv = [v for v in pv if v['how'] == 'phone']
        new = [v for v in line_pv if v.get('conn') == 'new']
        if line_pv:
            print(f'ladderstart {lk} previews {pword} from the line: {len(line_pv)}, median '
                  f'{fmt(med([v["ms"] for v in line_pv]))} ms (p90 {fmt(pct([v["ms"] for v in line_pv], 0.9))}): '
                  f'conn new {len(new)} (median {fmt(med([v["conn_ms"] for v in new]))} ms), '
                  f'wait {fmt(med([v["wait_ms"] for v in line_pv if "wait_ms" in v]))} ms, '
                  f'read {fmt(med([v["read_ms"] for v in line_pv if "read_ms" in v]))} ms, '
                  f'{fmt(med([v["kb"] for v in line_pv]))} KB, '
                  f'picture {fmt(med([v["pic_ms"] for v in line_pv]))} ms')
        if phone_pv:
            print(f'ladderstart {lk} previews {pword} from the phone: {len(phone_pv)}, median '
                  f'{fmt(med([v["ms"] for v in phone_pv]))} ms (picture {fmt(med([v["pic_ms"] for v in phone_pv]))} ms)')
        ahead = sum(a['ahead'] for a in xs)
        if ahead:
            print(f'ladderstart {lk} previews {pword}: {ahead} taken ahead of the drags')
    for line in drag_pairs(passes):
        print(line)


def drag_pairs(passes):
    """Neighbouring passes of two preview words, per line and drag size:
    the difference of each pass's median near_ms and stop_ms (x minus y).
    Two words of one build (`a`, `b`) are the drags' A/A."""
    pw = lambda w: w.split('@')[0].split('+')[1] if '+' in w.split('@')[0] else '-'
    out = []
    for lk in sorted({l for p, l, w, a in passes}):
        seq = [(pw(w), a) for p, l, w, a in passes if l == lk and a is not None and a['drags']]
        for size in ('short', 'long', 'far', 'all'):
            def m(a, k):
                sel = [d for d in a['drags']
                       if size == 'all' or ((abs(int(d.get('by', '0'))) <= 30 and size == 'short')
                                            or (30 < abs(int(d.get('by', '0'))) <= 120 and size == 'long')
                                            or (abs(int(d.get('by', '0'))) > 120 and size == 'far'))]
                v = [int(d[k]) for d in sel if d.get(k, '-1') != '-1']
                return med(v)
            pairs = {}
            i = 0
            while i + 1 < len(seq):
                (w1, a1), (w2, a2) = seq[i], seq[i + 1]
                if w1 != w2:
                    x, y = sorted((w1, w2))
                    ax, ay = (a1, a2) if w1 == x else (a2, a1)
                    for k in ('near_ms', 'stop_ms'):
                        if m(ax, k) is not None and m(ay, k) is not None:
                            pairs.setdefault((x, y, k), []).append(m(ax, k) - m(ay, k))
                    i += 2
                else:
                    i += 1
            for (x, y, k), ds in sorted(pairs.items()):
                out.append(f'ladderstart {lk} drags {size}: {x} minus {y}, {k}, {len(ds)} pairs: '
                           f'median {fmt(med(ds))} ms, {x} sooner in {sum(1 for d in ds if d < 0)} of {len(ds)}')
    return out


if __name__ == '__main__':
    main()
