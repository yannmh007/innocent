#!/usr/bin/env python3
"""PreToolUse hook on the Agent tool: write one line per delegation, decide nothing.

Where the tokens go is the question model routing answers, so each agent
call is logged — time, agent type, model asked for, effort, the short
description — to .claude/state/agent-log.tsv (gitignored). It never denies,
allows or changes a call; any error is swallowed.
"""
import json
import os
import sys
import time

try:
    d = json.load(sys.stdin)
    if d.get('tool_name') == 'Agent':
        i = d.get('tool_input') or {}
        base = os.path.join(os.environ.get('CLAUDE_PROJECT_DIR') or d.get('cwd') or '.', '.claude', 'state')
        os.makedirs(base, exist_ok=True)
        row = [time.strftime('%Y-%m-%d %H:%M', time.gmtime()), str(i.get('subagent_type') or 'general-purpose'),
               str(i.get('model') or '(agent file)'), str(i.get('effort') or '-'),
               str(i.get('description') or '').replace('\t', ' ')[:120]]
        with open(os.path.join(base, 'agent-log.tsv'), 'a', encoding='utf-8') as f:
            f.write('\t'.join(row) + '\n')
except Exception:  # noqa: BLE001
    pass
sys.exit(0)
