#!/usr/bin/env python3
"""Every workflow file parses, and still has the triggers it is run by.

WHY. A step was added to ingest.yml whose `run:` was a plain scalar holding
`: ` — "previews: skipped this tick". YAML reads that as a mapping, the whole
file failed to parse, and GitHub's answer was not a syntax error but "Workflow
does not have 'workflow_dispatch' trigger": the schedule and the manual run
both silently gone. On main that would have stopped every ingest, every bin
purge and every storage check, with nothing failing anywhere to say so.

RUN:  python3 tool/workflow_yaml.py
"""

import glob
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

try:
    import yaml
except ImportError:
    print('PASS  (PyYAML not installed; workflow files not parsed)')
    sys.exit(0)

fails = 0
files = sorted(glob.glob(os.path.join(ROOT, '.github', 'workflows', '*.yml')))
for path in files:
    name = os.path.relpath(path, ROOT)
    try:
        doc = yaml.safe_load(open(path, encoding='utf-8'))
    except yaml.YAMLError as e:
        fails += 1
        print('FAIL', name, 'does not parse:', str(e).replace('\n', ' ')[:200])
        continue
    # PyYAML reads the bare key `on` as the boolean True.
    triggers = doc.get('on', doc.get(True)) if isinstance(doc, dict) else None
    if not triggers:
        fails += 1
        print('FAIL', name, 'has no triggers')
    if not (isinstance(doc, dict) and doc.get('jobs')):
        fails += 1
        print('FAIL', name, 'has no jobs')

print(('FAIL' if fails else 'PASS'), f'=== {len(files)} workflow file(s) parse ===')
sys.exit(1 if fails else 0)
