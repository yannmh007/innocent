#!/usr/bin/env python3
"""The restore script, against a small fake backup.

WHY. A backup is only as good as the way back. The order (a child inserted
before its parent fails the whole restore), the quoting (a row containing the
quote tag would end the statement early and run the rest as SQL) and the
refusal of an odd table name are the three things that would turn a restore
into a second accident.

RUN:  python3 tool/restore_backup_test.py
"""

import gzip
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import restore_backup as rb  # noqa: E402

fails = 0
checks = 0


def check(name, ok):
    global fails, checks
    checks += 1
    if not ok:
        fails += 1
        print('FAIL', name)


doc = {
    'format': 'innocent-db-backup', 'version': 1, 'taken_at': '2026-10-02T10:15:00Z',
    'trigger': 'daily', 'order': ['titles', 'title_assets', 'empty_one'],
    'counts': {'titles': 1, 'title_assets': 2, 'empty_one': 0},
    'tables': {
        'title_assets': [{'id': 'a1', 'title_id': 't1'}, {'id': 'a2', 'title_id': 't1',
                                                         'label': "it's $r0000$ and $$"}],
        'titles': [{'id': 't1', 'title': 'Ψ Burmese ကား'}],
        'empty_one': [],
    },
    'auth_users': [{'id': 'u1', 'email': 'x@example.com'}],
}
tmp = tempfile.mkdtemp()
path = os.path.join(tmp, 'b.json.gz')
with open(path, 'wb') as fh:
    fh.write(gzip.compress(json.dumps(doc).encode()))

loaded = rb.load(path)
check('a gzipped backup loads', loaded['tables']['titles'][0]['id'] == 't1')
sql = rb.to_sql(loaded)
check('parents before children', sql.index('public.titles') < sql.index('public.title_assets'))
check('one transaction', sql.startswith('-- Innocent') and 'begin;' in sql and sql.rstrip().split('\n')[-2] == 'commit;')
check('nothing is overwritten', sql.count('on conflict do nothing') == 2)
check('an empty table writes no statement', 'empty_one: empty' in sql and 'public.empty_one' not in sql)
check('the accounts are counted, not written', '1 account(s)' in sql and 'auth.users\n' not in sql
      and 'x@example.com' not in sql)
check('Burmese survives', 'ကား' in sql)
# Every dollar-quoted body must end where it started: the tag must not occur
# inside the JSON it quotes.
for line in sql.split('\n'):
    if 'json_populate_recordset' in line:
        start = line.index(', $r') + 2
        tag = line[start:line.index('$', start + 1) + 1]
        inner = line[start + len(tag):line.rindex(tag)]
        check('the quote tag does not occur in its body', tag not in inner)
only = rb.to_sql(loaded, {'titles'})
check('--tables restores only those', 'public.titles' in only and 'public.title_assets' not in only)
try:
    rb.ident('titles; drop table x')
    check('an odd table name is refused', False)
except SystemExit:
    check('an odd table name is refused', True)
try:
    bad = os.path.join(tmp, 'x.json')
    with open(bad, 'w') as fh:
        json.dump({'format': 'something else'}, fh)
    rb.load(bad)
    check('a file that is not a backup is refused', False)
except SystemExit:
    check('a file that is not a backup is refused', True)
try:
    sealed = os.path.join(tmp, 'b.json.gz.sealed')
    with open(sealed, 'wb') as fh:
        fh.write(b'IBK1' + os.urandom(12) + os.urandom(64))
    rb.load(sealed)
    check('a sealed backup is refused, pointing at the console', False)
except SystemExit as e:
    check('a sealed backup is refused, pointing at the console', 'console' in str(e))

# HKDF-SHA256(key = bytes 0..31, salt = 32 zero bytes, info =
# 'innocent-db-backup-v1'), 32 bytes; the same vector is in pii_test.mjs.
BACKUP_KEY_VECTOR = '138cd64bae9bf39faf2071a0abdc3921568565bbd5c867078d11f586fd3f62c0'

# Opened with the owner's PII_ENC_KEY when the project is gone. The file is
# sealed here the way docs/edge/pii.ts seals it (tool/js/pii_test.mjs pins
# that pii.ts and this derivation agree).
try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    have_aead = True
except BaseException:   # missing, or a broken build that panics on import
    have_aead = False
if have_aead:
    import base64
    enc = base64.b64encode(os.urandom(32)).decode()
    iv = os.urandom(12)
    gz = gzip.compress(json.dumps(doc).encode())
    body = b'IBK1' + iv + AESGCM(rb.backup_key(enc)).encrypt(iv, gz, b'innocent-db-backup')
    with open(sealed, 'wb') as fh:
        fh.write(body)
    check('a sealed backup opens with its key', rb.load(sealed, enc)['tables']['titles'][0]['id'] == 't1')
    for what, k in (('another key', base64.b64encode(os.urandom(32)).decode()),
                    ('a short key', base64.b64encode(os.urandom(16)).decode())):
        try:
            rb.load(sealed, k)
            check('%s does not open it' % what, False)
        except SystemExit:
            check('%s does not open it' % what, True)
    with open(sealed, 'wb') as fh:
        fh.write(body[:-1] + bytes([body[-1] ^ 1]))
    try:
        rb.load(sealed, enc)
        check('an altered backup does not open', False)
    except SystemExit:
        check('an altered backup does not open', True)
    # The vector tool/js/pii_test.mjs checks pii.ts against.
    check('the derivation is HKDF-SHA256 as pii.ts makes it',
          rb.backup_key(base64.b64encode(bytes(range(32))).decode()).hex() == BACKUP_KEY_VECTOR)
else:
    print('skip sealed-backup checks: no cryptography module')

print(('FAIL' if fails else 'PASS'), '=== %d check(s) on the restore script ===' % checks)
sys.exit(1 if fails else 0)
