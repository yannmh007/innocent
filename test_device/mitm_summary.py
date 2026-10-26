#!/usr/bin/env python3
"""What the man in the middle got, stage by stage (run.sh, flow `mitm`).

    mitm_summary.py out/mitm_events.jsonl out/logcat_raw.txt

Reads tool/netlab/mitm_watch.py's lines and the app's log, and prints per
stage, per service: how many of the app's connections refused the proxy's
certificate, how many accepted it, and what the proxy could read — the kind
of path and the header names only. Then the app's own word: TLS errors and
first frames between the stage markers.
"""
import collections, json, re, sys

events, logcat = sys.argv[1], sys.argv[2]
stage = 'before'
seen = collections.OrderedDict()
for line in open(events):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get('ev') == 'stage':
        stage = e['stage']
        seen.setdefault(stage, collections.defaultdict(collections.Counter))
        continue
    s = seen.setdefault(stage, collections.defaultdict(collections.Counter))
    s[e.get('to', '?')][e['ev']] += 1
    if e['ev'] == 'read':
        s[e['to']]['path ' + e['path'] + ' ' + str(e['status'])] += 1
        s[e['to']]['headers: ' + ', '.join(e.get('headers') or [])] += 1

app = collections.defaultdict(collections.Counter)
cur = 'before'
for line in open(logcat, errors='replace'):
    m = re.search(r'LAB mitm stage (\w+)', line)
    if m:
        cur = m.group(1)
        continue
    if re.search(r'HandshakeException|CERTIFICATE_VERIFY_FAILED', line):
        app[cur]['TLS refused (app log)'] += 1
    if 'first frame' in line:
        app[cur]['first frame'] += 1

about = {'control': 'the runner\'s own curl, without and then with the proxy\'s CA',
         'A': 'the proxy on the path, its CA trusted nowhere',
         'B': 'its CA also in the phone\'s USER store',
         'C': 'its CA also in the SYSTEM store (root)'}
for st, by in seen.items():
    print(f'stage {st}: {about.get(st, "")}')
    for kind in ('worker', 'supabase', 'cdn', 'google', 'other'):
        c = by.get(kind)
        if not c:
            continue
        print(f"  {kind:<9} refused {c['refused']:>3} | accepted {c['accepted']:>3} | read {c['read']:>3}")
        for k, n in sorted(c.items()):
            if k.startswith(('path ', 'headers: ')):
                print(f'      {n:>3} × {k}')
    if st in app:
        print('  the app: ' + ', '.join(f'{k} {n}' for k, n in app[st].items()))
    print()

# The verdict the owner asked for: on the path, and with a user-installed
# certificate, the app's own services gave the proxy nothing to read.
read_ab = sum(seen.get(s, {}).get(k, collections.Counter())['read']
              for s in ('A', 'B') for k in ('worker', 'supabase', 'cdn'))
refused_ab = sum(seen.get(s, {}).get(k, collections.Counter())['refused']
                 for s in ('A', 'B') for k in ('worker', 'supabase', 'cdn'))
print(f'VERDICT A+B: the proxy read {read_ab} request(s) to Innocent\'s services; '
      f'the app refused its certificate {refused_ab} time(s) -> '
      f"{'PASS' if read_ab == 0 and refused_ab > 0 else 'FAIL'}")
