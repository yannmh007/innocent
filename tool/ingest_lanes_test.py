#!/usr/bin/env python3
"""ingest.yml's lane count (tool/ingest_lanes.py), and the workflow around it.

WHY. The plan job decides how many runners and Telegram sessions start. Too
few and the owner's ten films go one at a time; too many and one photo signs
the bot in ten times, which is what Telegram throttles; none at all and the
queue stops with nothing failing anywhere. And the workflow must keep the
shape that makes ten lanes safe: a lane is one job at a time across runs, the
bin and the backup run once, not once a lane.

RUN:  python3 tool/ingest_lanes_test.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tool'))
import ingest_lanes as il  # noqa: E402

fails = 0
checks = 0


def check(label, ok):
    global fails, checks
    checks += 1
    print(('ok   ' if ok else 'FAIL ') + label)
    if not ok:
        fails += 1


L = il.lanes
check('nothing waiting: one lane (the old workflow, and the vault work)',
      L('{"queued": 0, "running": 0}', '10') == [1])
check('one file: one lane, one sign-in', L('{"queued": 1, "running": 0}', '') == [1])
check('ten files: ten lanes', L('{"queued": 10, "running": 0}', '') == list(range(1, 11)))
check('forty files: still ten', L('{"queued": 40, "running": 0}', '') == list(range(1, 11)))
check('three waiting behind two busy lanes: five, so three are free',
      L('{"queued": 3, "running": 2}', '10') == [1, 2, 3, 4, 5])
check('busy lanes alone open nothing new', L('{"queued": 0, "running": 7}', '10') == [1])
check('INGEST_LANES=1 is the old workflow', L('{"queued": 9, "running": 0}', '1') == [1])
check('INGEST_LANES=3 caps at three', L('{"queued": 9, "running": 0}', '3') == [1, 2, 3])
check('INGEST_LANES past ten is ten', L('{"queued": 30, "running": 0}', '50') == list(range(1, 11)))
check('INGEST_LANES of 0 or junk is read as one or ten, never none',
      L('{"queued": 5, "running": 0}', '0') == [1] and
      L('{"queued": 5, "running": 0}', 'many') == [1, 2, 3, 4, 5])
for junk in ('', '{}', 'not json', '<html>502</html>', '{"queued": "x"}', '[]', 'null'):
    check('an unreadable answer (%r) is one lane' % junk[:12], L(junk, '10') == [1])
check('negative counts are none', L('{"queued": -4, "running": -1}', '10') == [1])

# The workflow, read as text: the shape that makes the lanes safe.
wf = open(os.path.join(ROOT, '.github', 'workflows', 'ingest.yml'), encoding='utf-8').read()
check('a lane is one job at a time across runs',
      'group: ingest-lane-${{ matrix.lane }}' in wf and 'cancel-in-progress: false' in wf)
check('the lanes come from the plan', 'lane: ${{ fromJSON(needs.plan.outputs.lanes) }}' in wf)
check('the plan reads its count with this script, checked out',
      'python3 tool/ingest_lanes.py' in wf and 'sparse-checkout: tool/ingest_lanes.py' in wf)
check('each lane tells the runner its number (the sign-in gap)',
      'INGEST_LANE: ${{ matrix.lane }}' in wf)
check('no more than ten at once', 'max-parallel: 10' in wf)
check('no workflow-wide group holding a run behind its slowest lane',
      '\nconcurrency:\n  group: ingest\n' not in wf)
fetch = wf[wf.index('\n  fetch:\n'):wf.index('\n  house:\n')]
house = wf[wf.index('\n  house:\n'):]
check('the bin and the backup run once a run, not once a lane',
      '"op":"purge"' not in fetch and '"op":"purge"' in house and 'tool/previews.py' in house
      and 'matrix' not in house)
check('the next run is asked for only when none is waiting',
      '--status queued' in fetch and 'gh workflow run ingest.yml' in fetch)
try:
    import yaml
    doc = yaml.safe_load(wf)
    jobs = doc['jobs']
    check('it parses, with plan, fetch and house', set(jobs) == {'plan', 'fetch', 'house'})
    check('fetch waits for the plan', jobs['fetch'].get('needs') == 'plan')
    check('a lane cannot outlive the claim\'s seven-hour recovery',
          int(jobs['fetch']['timeout-minutes']) <= 7 * 60)
except ImportError:
    print('skip  (PyYAML not installed; the workflow was read as text only)')

print(('FAIL' if fails else 'PASS'), '=== %d check(s) on the ingest lanes ===' % checks)
sys.exit(1 if fails else 0)
