#!/usr/bin/env python3
"""Claude's instruction files stay loadable, findable and true.

Rules, skills and agents (.claude/) are read by every session; a broken
frontmatter makes Claude Code ignore a file without a word, and a rule
whose `paths:` match nothing never loads again — a stale memory that looks
alive. Checked here:
  - CLAUDE.md stays under 200 lines (the size the docs give for adherence);
  - every rule has parseable `paths:` and each pattern matches a file;
  - every skill and agent has name and description; agents name a model;
  - every repository path CLAUDE.md, rules and skills mention in backticks
    exists (a moved file leaves a wrong instruction behind);
  - nothing that looks like a secret is in them (the repository is public).

    python3 tool/claude_config_test.py
"""
from __future__ import annotations

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failed = 0
count = 0


def check(what: str, ok: bool) -> None:
    global failed, count
    count += 1
    print(('ok   ' if ok else 'FAIL ') + what)
    if not ok:
        failed += 1


def frontmatter(path: str) -> dict | None:
    s = open(path, encoding='utf-8').read()
    m = re.match(r'^---\n(.*?)\n---\n', s, re.S)
    if not m:
        return None
    try:
        import yaml  # noqa: PLC0415
        return yaml.safe_load(m.group(1)) or {}
    except Exception:  # noqa: BLE001
        return None


def files_matching(pattern: str) -> list[str]:
    return glob.glob(os.path.join(ROOT, pattern), recursive=True, include_hidden=True)


claude_md = os.path.join(ROOT, 'CLAUDE.md')
n = len(open(claude_md, encoding='utf-8').read().splitlines())
check(f'CLAUDE.md is under 200 lines ({n})', n < 200)

rules = sorted(glob.glob(os.path.join(ROOT, '.claude', 'rules', '**', '*.md'), recursive=True))
check('there are rules', len(rules) > 0)
for r in rules:
    name = os.path.relpath(r, ROOT)
    fm = frontmatter(r)
    paths = (fm or {}).get('paths')
    if isinstance(paths, str):
        paths = [p.strip() for p in paths.split(',')]
    check(f'{name}: frontmatter parses and has paths', isinstance(paths, list) and len(paths) > 0)
    for p in paths or []:
        check(f'{name}: "{p}" matches a file', len(files_matching(p)) > 0)

for kind, pattern, need in (('skill', '.claude/skills/*/SKILL.md', ('name', 'description')),
                            ('agent', '.claude/agents/*.md', ('name', 'description', 'model'))):
    for f in sorted(glob.glob(os.path.join(ROOT, pattern))):
        fm = frontmatter(f) or {}
        check(f'{kind} {os.path.relpath(f, ROOT)}: has {", ".join(need)}',
              all(isinstance(fm.get(k), str) and fm.get(k).strip() for k in need))

# Paths mentioned in backticks that look like repository paths must exist.
docs = [claude_md] + rules + sorted(glob.glob(os.path.join(ROOT, '.claude', 'skills', '*', 'SKILL.md')))
PATHY = re.compile(r'`((?:docs|tool|lib|test|test_device|android|\.github|\.claude)/[A-Za-z0-9_./*{}-]+)`')
for d in docs:
    text = open(d, encoding='utf-8').read()
    for m in PATHY.finditer(text):
        p = m.group(1).rstrip('.')
        if 'NNN' in p or '<' in p or p.startswith('.claude/state/'):
            continue  # a placeholder, or a file the hooks write at run time
        if any(c in p for c in '*{'):
            ok = len(files_matching(p.replace('{', '').replace('}', ''))) > 0
        else:
            ok = os.path.exists(os.path.join(ROOT, p))
        check(f'{os.path.relpath(d, ROOT)} mentions `{p}`, which exists', ok)

SECRETISH = re.compile(r'(sb_secret_[A-Za-z0-9]{8,}|eyJ[A-Za-z0-9_-]{14,}\.[A-Za-z0-9_-]{13,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)')
for d in docs + sorted(glob.glob(os.path.join(ROOT, '.claude', 'agents', '*.md'))):
    check(f'{os.path.relpath(d, ROOT)}: nothing secret-shaped', not SECRETISH.search(open(d, encoding='utf-8').read()))

if failed:
    print(f'\n{failed} of {count} check(s) FAILED')
    sys.exit(1)
print(f'\n=== {count} check(s) on Claude\'s instruction files passed ===')
