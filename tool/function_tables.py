#!/usr/bin/env python3
"""Every table the edge functions name is in the service-role grants test.

A new table in this project gives the service role nothing until a
migration grants it (077), and supabase-js hands the refusal back as data
that a caller may never look at: the console's Genres section failed for a
week that way. tool/sql/service_role_grants_test.sql reads each table the
functions use as the service role, on the live database. This keeps its
list honest: a table named in docs/edge (`.from('x')` or `rest('x...')`)
that the list does not carry fails here, before it fails in production.

    python3 tool/function_tables.py
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EDGE = os.path.join(ROOT, 'docs', 'edge')
TEST = os.path.join(ROOT, 'tool', 'sql', 'service_role_grants_test.sql')

FROM = re.compile(r"\.from\('([a-z_0-9]+)'\)")
REST = re.compile(r"\brest\(\s*[`'\"]([a-z_0-9]+)[?'\"`]")


def named_in_functions() -> dict[str, set[str]]:
    found: dict[str, set[str]] = {}
    for name in sorted(os.listdir(EDGE)):
        if not name.endswith(('.ts', '.js')):
            continue
        src = open(os.path.join(EDGE, name), encoding='utf-8').read()
        # Comments name tables too ("asset_renditions grants the service role
        # nothing"); only code counts.
        code = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
        code = re.sub(r'(^|[^:])//[^\n]*', r'\1', code)
        for rx in (FROM, REST):
            for m in rx.finditer(code):
                found.setdefault(m.group(1), set()).add(name)
    return found


def listed_in_test() -> list[str]:
    src = open(TEST, encoding='utf-8').read()
    m = re.search(r'FUNCTION_TABLES.*?array\[(.*?)\]', src, flags=re.S)
    if not m:
        raise SystemExit('FAIL no FUNCTION_TABLES list in ' + TEST)
    return re.findall(r"'([a-z_0-9]+)'", m.group(1))


def main() -> int:
    named = named_in_functions()
    listed = listed_in_test()
    bad = 0
    missing = sorted(set(named) - set(listed))
    for t in missing:
        bad += 1
        print(f"FAIL {t} is used by {', '.join(sorted(named[t]))} but not checked in "
              'tool/sql/service_role_grants_test.sql (add it, and a grant if the test fails)')
    if listed != sorted(listed):
        bad += 1
        print('FAIL the FUNCTION_TABLES list is not sorted')
    if len(named) < 20:
        bad += 1
        print(f'FAIL only {len(named)} tables found in docs/edge: the patterns no longer match the code')
    if bad:
        return 1
    print(f'=== {len(named)} tables the functions use, all in the grants test ===')
    return 0


if __name__ == '__main__':
    sys.exit(main())
