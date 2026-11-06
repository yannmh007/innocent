#!/usr/bin/env python3
"""The blurhash encoder the runner uses, against fixed vectors.

WHY. The app decodes these strings with its own Dart port of the same
algorithm (lib/features/video_hub/domain/blurhash.dart, tested against the
same vectors in test/blurhash_test.dart). A slip on either side — a swapped
axis, a missed sRGB conversion — draws every frosted tile the wrong colour,
and nothing anywhere would throw. The vectors below were checked against the
reference `blurhash` package when this was written; this file needs nothing
installed.

RUN:  python3 tool/previews_test.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import previews  # noqa: E402

W, H = 8, 6
GRADIENT = [(int(255 * x / (W - 1)), int(255 * y / (H - 1)), 120)
            for y in range(H) for x in range(W)]
VECTORS = [
    ('gradient 4x3', GRADIENT, 4, 3, 'LyI5ej3AfQxtz4NKfQnSeXf7fQf7'),
    ('gradient 3x4', GRADIENT, 3, 4, 'TyI5ej3AfQz4NKfQeXf7fQ%eOWfQ'),
    ('solid', [(200, 40, 90)] * (W * H), 4, 3, 'LVM_Ai]VfQ]V||sofQsofQfQfQfQ'),
]

fails = 0
checks = 0


def check(name, got, want):
    global fails, checks
    checks += 1
    if got != want:
        fails += 1
        print('FAIL', name, 'got', repr(got), 'want', repr(want))


for name, px, cx, cy, want in VECTORS:
    check(name, previews.encode(px, W, H, cx, cy), want)

# Length is the format's own: 1 for the size, 1 for the AC scale, 4 for the
# average colour, 2 for each of the other components.
check('length 4x3', len(previews.encode(GRADIENT, W, H, 4, 3)), 6 + 2 * (12 - 1))
check('portrait gets more rows', previews.components_for(600, 900), (3, 4))
check('landscape gets more columns', previews.components_for(900, 600), (4, 3))
check('square is landscape', previews.components_for(500, 500), (4, 3))

try:
    previews.encode(GRADIENT, W, H, 10, 3)
    check('ten components refused', 'accepted', 'refused')
except ValueError:
    check('ten components refused', 'refused', 'refused')

# Every character is in the alphabet the edge function accepts.
import re  # noqa: E402
edge = re.compile(r'^[0-9A-Za-z#$%*+,\-.:;=?@\[\]^_{|}~]{6,100}$')
for name, px, cx, cy, _ in VECTORS:
    check('edge accepts ' + name, bool(edge.match(previews.encode(px, W, H, cx, cy))), True)

# A SEALED IMAGE (§7.3): opened in memory before it is hashed, every
# segment checked; one that is not what its key row describes is refused.
ms = previews.sealer()
if ms is None:
    print('SKIP the sealed half: `cryptography` does not load here')
else:
    import base64, io as _io  # noqa: E401,E402
    plain = os.urandom(150000)
    dek = os.urandom(32)
    did = '00000000-0000-4000-8000-000000000007'
    out = _io.BytesIO()
    ms.seal_stream(_io.BytesIO(plain), out, dek, ms.aad_for(did), len(plain))
    sealed = out.getvalue()
    seal = {'dek_id': did, 'dek': base64.b64encode(dek).decode(), 'plain_size': len(plain),
            'header': base64.b64encode(sealed[:ms.HEADER]).decode()}
    check('a sealed image opens to its bytes', previews.open_sealed(sealed, seal, ms) == plain, True)
    for name, data, bad in (
        ('a flipped byte is refused', sealed[:70000] + bytes([sealed[70000] ^ 1]) + sealed[70001:], seal),
        ('another object under this key row is refused', sealed, dict(seal, header=base64.b64encode(b'x' * 40).decode())),
        ('a size the key row does not say is refused', sealed, dict(seal, plain_size=len(plain) + 1)),
    ):
        try:
            previews.open_sealed(data, bad, ms)
            check(name, 'opened', 'refused')
        except Exception:  # noqa: BLE001
            check(name, 'refused', 'refused')

print(('FAIL' if fails else 'PASS'), f'=== {checks} check(s) on the album blurhash encoder ===')
sys.exit(1 if fails else 0)
