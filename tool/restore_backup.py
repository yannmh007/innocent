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

SEALED BACKUPS. Since 30 Oct 2026 the copy in R2 and off-site is sealed
(`….json.gz.sealed`, starting `IBK1`). The console's Download opens it and
saves the plain `.json.gz` this reads. When the project itself is gone and
there is no console, open the off-site copy here with the owner's copy of the
Edge secret PII_ENC_KEY (asked for, never echoed; `pip install cryptography`):

    python3 tool/restore_backup.py x.json.gz.sealed --key > restore.sql

The key is turned into the backup key exactly as docs/edge/pii.ts does it
(HKDF-SHA256, zero salt, info `innocent-db-backup-v1`), then AES-256-GCM with
`innocent-db-backup` as associated data. Only this one step needs a library or
a secret; without `--key` a sealed file is refused, saying so.
"""

import base64
import gzip
import hashlib
import hmac
import json
import secrets
import sys

SEALED_MAGIC = b'IBK1'
BACKUP_KEY_INFO = b'innocent-db-backup-v1'
BACKUP_AAD = b'innocent-db-backup'


def backup_key(enc_b64):
    """pii.ts derivedKey: HKDF-SHA256 of PII_ENC_KEY, zero salt, one block."""
    try:
        ikm = base64.b64decode(enc_b64.strip(), validate=True)
    except Exception:
        raise SystemExit('that is not a base64 key')
    if len(ikm) != 32:
        raise SystemExit('PII_ENC_KEY is 32 bytes; that one is %d' % len(ikm))
    prk = hmac.new(b'\0' * 32, ikm, hashlib.sha256).digest()
    return hmac.new(prk, BACKUP_KEY_INFO + b'\x01', hashlib.sha256).digest()


def unseal(raw, enc_b64):
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except KeyboardInterrupt:
        raise
    except BaseException:   # missing, or a broken build (pyo3 panics are BaseException)
        raise SystemExit('opening a sealed backup needs: pip install cryptography')
    try:
        return AESGCM(backup_key(enc_b64)).decrypt(raw[4:16], raw[16:], BACKUP_AAD)
    except SystemExit:
        raise
    except Exception:
        raise SystemExit('the key does not open this backup (another key, or the file was altered)')


def load(path, enc_b64=None):
    with open(path, 'rb') as fh:
        raw = fh.read()
    if raw[:4] == SEALED_MAGIC:
        if enc_b64 is None:
            raise SystemExit('this backup is sealed: download it from the console '
                             '(Status, Database backups, Download), which hands over the '
                             'opened .json.gz, or run with --key (see --help)')
        raw = unseal(raw, enc_b64)
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
    key = None
    if '--key' in argv:
        import getpass
        key = getpass.getpass('PII_ENC_KEY: ') if sys.stdin.isatty() else sys.stdin.readline()
    doc = load(argv[1], key)
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
