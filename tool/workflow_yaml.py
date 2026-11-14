#!/usr/bin/env python3
"""Every workflow file parses, and still has the triggers it is run by.

WHY. A step was added to ingest.yml whose `run:` was a plain scalar holding
`: ` — "previews: skipped this tick". YAML reads that as a mapping, the whole
file failed to parse, and GitHub's answer was not a syntax error but "Workflow
does not have 'workflow_dispatch' trigger": the schedule and the manual run
both silently gone. On main that would have stopped every ingest, every bin
purge and every storage check, with nothing failing anywhere to say so.

AND NO WORKFLOW PUBLISHES GITHUB PAGES (14 Nov 2026). The Pages copy of the
console was retired on 13 Nov; "Unpublish" alone did not hold (the next push
to main's docs/ redeployed it), so Pages' source is now "GitHub Actions" with
no workflow that deploys. A workflow that uploads or deploys a Pages artifact
would publish all of docs/ again — migrations, function source, the old
console — so it fails here. The console lives at console.innocentplayer.com.

RUN:  python3 tool/workflow_yaml.py
"""

import glob
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

fails = 0
files = sorted(glob.glob(os.path.join(ROOT, '.github', 'workflows', '*.y*ml')))
for path in files:
    text = open(path, encoding='utf-8').read()
    for word in ('actions/deploy-pages', 'actions/upload-pages-artifact',
                 'actions/configure-pages', 'pages: write', 'write-all'):
        if word in text:
            fails += 1
            print('FAIL', os.path.relpath(path, ROOT), f'publishes GitHub Pages ({word});'
                  ' Pages stays off since 13 Nov 2026')

try:
    import yaml
except ImportError:
    print(('FAIL' if fails else 'PASS'), '=== no workflow publishes Pages; '
          'PyYAML not installed, workflow files not parsed ===')
    sys.exit(1 if fails else 0)
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

print(('FAIL' if fails else 'PASS'), f'=== {len(files)} workflow file(s) parse, none publishes Pages ===')
sys.exit(1 if fails else 0)
