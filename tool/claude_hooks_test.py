#!/usr/bin/env python3
"""The project's Claude Code hooks (.claude/hooks): they help, and never stand in the way.

Hooks run on every matching tool call in every session on this repository.
A hook that throws, prints junk or blocks would cost more than it saves, so
each is checked here to keep the facts, change nothing it does not
recognise, and exit 0 on any input at all.

    python3 tool/claude_hooks_test.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOKS = os.path.join(ROOT, '.claude', 'hooks')
failed = 0
count = 0


def check(what: str, ok: bool) -> None:
    global failed, count
    count += 1
    print(('ok   ' if ok else 'FAIL ') + what)
    if not ok:
        failed += 1


def run(hook: str, stdin: str, env: dict | None = None):
    # Each hook is run by a literal command, from the repository root, as
    # settings.json runs it: nothing in the command line comes from a variable
    # (Semgrep's subprocess rule, and no way to run anything but the two hooks).
    kw = dict(input=stdin, capture_output=True, text=True, timeout=20, cwd=ROOT,
              env={**os.environ, **(env or {})})
    if hook == 'trim_github.py':
        p = subprocess.run(['python3', '.claude/hooks/trim_github.py'], **kw)
    elif hook == 'agent_log.py':
        p = subprocess.run(['python3', '.claude/hooks/agent_log.py'], **kw)
    else:
        raise ValueError(f'no such hook: {hook}')
    return p.returncode, p.stdout.strip(), p.stderr.strip()


# ── trim_github.py ─────────────────────────────────────────────────────────
run_obj = {'id': 42, 'name': 'Build', 'status': 'completed', 'conclusion': 'failure',
           'head_branch': 'main', 'head_sha': 'abc1234', 'html_url': 'https://github.com/x/y/actions/runs/42',
           'head_commit': {'message': 'First line\n\n' + 'detail ' * 300, 'id': 'abc1234'},
           'actor': {'login': 'x', 'avatar_url': 'https://a'}, 'triggering_actor': {'login': 'x'}}
listing = {'total_count': 2, 'workflow_runs': [run_obj, dict(run_obj, id=43, conclusion='success')]}


def trimmed(resp):
    code, out, err = run('trim_github.py', json.dumps({'tool_name': 'mcp__github__actions_list', 'tool_response': resp}))
    return code, (json.loads(out)['hookSpecificOutput']['updatedToolOutput'] if out else None), err


code, new, err = trimmed([{'type': 'text', 'text': json.dumps(listing)}])
inner = json.loads(new[0]['text']) if new else {}
runs = inner.get('workflow_runs') or [{}]
check('a run listing is trimmed', code == 0 and new is not None)
check('every fact of a run is kept (id, status, conclusion, branch, sha, url)',
      all(runs[0].get(k) == run_obj[k] for k in ('id', 'status', 'conclusion', 'head_branch', 'head_sha', 'html_url'))
      and [r['id'] for r in runs] == [42, 43])
check('the commit message keeps its first line', runs[0].get('head_commit') == {'message': 'First line'})
check('the actors are dropped', 'actor' not in runs[0] and 'triggering_actor' not in runs[0])
check('it is much smaller', len(new[0]['text']) * 4 < len(json.dumps(listing)) if new else False)
code, new, _ = trimmed([{'type': 'text', 'text': json.dumps({'jobs': [{'id': 1, 'steps': [{'name': 'x'}]}]})}])
check('a result with nothing to trim passes unchanged (no output)', code == 0 and new is None)
code, new, _ = trimmed([{'type': 'text', 'text': 'Workflow run has been queued'}])
check('a plain-text result passes unchanged', code == 0 and new is None)
code, new, _ = trimmed({'content': 'something else'})
check('an unknown shape passes unchanged', code == 0 and new is None)
for junk in ('', 'not json', '[]', 'null'):
    code, out, err = run('trim_github.py', junk)
    check(f'input {junk!r}: exit 0, says nothing', code == 0 and out == '')

# ── agent_log.py ───────────────────────────────────────────────────────────
with tempfile.TemporaryDirectory() as d:
    call = {'tool_name': 'Agent', 'cwd': d, 'tool_input': {
        'subagent_type': 'ci-reader', 'description': 'read\tthe build', 'prompt': 'x' * 5000}}
    code, out, err = run('agent_log.py', json.dumps(call), env={'CLAUDE_PROJECT_DIR': d})
    log = os.path.join(d, '.claude', 'state', 'agent-log.tsv')
    rows = open(log).read().splitlines() if os.path.exists(log) else []
    check('an agent call is logged, one line', code == 0 and len(rows) == 1)
    cols = rows[0].split('\t') if rows else []
    check('the line has time, type, model, effort, description (tabs in it removed)',
          len(cols) == 5 and cols[1] == 'ci-reader' and cols[2] == '(agent file)' and cols[4] == 'read the build')
    check('the logger decides nothing (prints nothing)', out == '')
    check('the prompt itself is not logged', 'xxxx' not in (rows[0] if rows else ''))
    code, out, _ = run('agent_log.py', json.dumps({'tool_name': 'Bash', 'tool_input': {}}), env={'CLAUDE_PROJECT_DIR': d})
    check('another tool is not logged', code == 0 and len(open(log).read().splitlines()) == 1)
for junk in ('', 'garbage', '{"tool_name": "Agent", "tool_input": null}'):
    code, out, _ = run('agent_log.py', junk, env={'CLAUDE_PROJECT_DIR': '/nonexistent/dir'})
    check(f'agent_log input {junk[:20]!r}: exit 0, says nothing', code == 0 and out == '')

# ── settings.json wires them, and only them ────────────────────────────────
s = json.load(open(os.path.join(ROOT, '.claude', 'settings.json')))
cmds = [h['command'] for ev in s.get('hooks', {}).values() for m in ev for h in m['hooks']]
check('settings.json runs exactly the two hooks', sorted(os.path.basename(c.split('"')[-2]) for c in cmds)
      == ['agent_log.py', 'trim_github.py'])
check('no hook can block (no deny/allow decisions in the scripts)',
      not any(w in open(os.path.join(HOOKS, f)).read() for f in os.listdir(HOOKS) if f.endswith('.py')
              for w in ('permissionDecision', '"deny"', 'exit(2)')))

if failed:
    print(f'\n{failed} of {count} check(s) FAILED')
    sys.exit(1)
print(f'\n=== {count} check(s) on the Claude Code hooks passed ===')
