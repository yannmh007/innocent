#!/usr/bin/env python3
"""Turn a daily database backup into SQL that puts the rows back.

A backup is what the ingest function writes to `_backup/db/` every day
(migration 032), downloaded from the console's Status page:

    python3 tool/restore_backup.py 20261002T101500-daily.json.gz > restore.sql
    python3 tool/restore_backup.py backup.json.gz --list
    python3 tool/restore_backup.py backup.json.gz --tables titles,title_assets

Then paste restore.sql into the Supabase SQL editor.

WHAT IT WRITES. One statement per table, parents before children (the order
the backup recorded, worked out from the foreign keys), each:

    insert into public.<table>
    select * from json_populate_recordset(null::public.<table>, $tag$[...]$tag$)
    on conflict do nothing;

`on conflict do nothing`, because the usual restore is into a database that
still has some of its rows — a table emptied by mistake, not a project lost —
and a row that is already there is the newer one. To put a table back exactly,
empty it first, by hand, knowing what that does.

WHAT IT DOES NOT. The accounts (`auth_users` in the backup) are not written
back: auth.users is Supabase's own table and its rows are made by signing in.
Into the SAME project nothing is needed — the accounts were never lost. Into a
NEW project, people sign in again and get new ids; the list in the backup says
who had which subscription, so the owner can grant them again.

Nothing here needs a network or a credential: the file in, SQL out.
"""

import gzip
import json
import secrets
import sys


def load(path):
    with open(path, 'rb') as fh:
        raw = fh.read()
    if raw[:2] == b'\x1f\x8b':
        raw = gzip.decompress(raw)
    doc = json.loads(raw.decode('utf-8'))
    if doc.get('format') != 'innocent-db-backup':
        raise SystemExit('not an Innocent database backup')
    return doc


def dollar_tag(text):
    """A dollar-quote tag that does not occur in [text]."""
    while True:
        tag = '$r%s$' % secrets.token_hex(4)
        if tag not in text:
            return tag


def ident(name):
    if not name.replace('_', '').isalnum() or not name[0].isalpha():
        raise SystemExit('refusing a table name that is not a plain identifier: %r' % name)
    return name


def to_sql(doc, only=None):
    order = doc.get('order') or list((doc.get('tables') or {}).keys())
    tables = doc.get('tables') or {}
    out = ['-- Innocent database restore', '-- backup taken %s (%s)' % (
        doc.get('taken_at'), doc.get('trigger')), 'begin;']
    for name in order:
        if only and name not in only:
            continue
        rows = tables.get(name) or []
        if not rows:
            out.append('-- %s: empty in the backup' % name)
            continue
        body = json.dumps(rows, ensure_ascii=False, separators=(',', ':'))
        tag = dollar_tag(body)
        t = ident(name)
        out.append('-- %s: %d row(s)' % (name, len(rows)))
        out.append('insert into public.%s\nselect * from json_populate_recordset(null::public.%s, %s%s%s)\n'
                   'on conflict do nothing;' % (t, t, tag, body, tag))
    out.append('commit;')
    users = doc.get('auth_users') or []
    out.append('-- %d account(s) were in auth.users when this was taken; see the docstring' % len(users))
    return '\n'.join(out) + '\n'


def main(argv):
    if len(argv) < 2 or argv[1] in ('-h', '--help'):
        print(__doc__)
        return 0
    doc = load(argv[1])
    if '--list' in argv:
        for name in doc.get('order') or []:
            print('%-24s %6d' % (name, (doc.get('counts') or {}).get(name, 0)))
        print('%-24s %6d' % ('(accounts)', len(doc.get('auth_users') or [])))
        return 0
    only = None
    if '--tables' in argv:
        i = argv.index('--tables')
        only = set(x.strip() for x in argv[i + 1].split(',') if x.strip())
    sys.stdout.write(to_sql(doc, only))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
