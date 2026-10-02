#!/usr/bin/env python3
"""Give every album item a blurhash, for the app's data saver.

Run by .github/workflows/ingest.yml on its usual tick, after the bin.

WHAT IT IS FOR. With the data saver on, the app draws an album as frosted
tiles — the colour and the shape of each photo and clip, none of the detail —
and fetches the real one only when the viewer taps it. The frosting has to
cost next to nothing, or drawing it spends what the data saver is saving. A
blurhash is about thirty characters per item and rides inside the album
response the app already makes (title_media.preview, migration 031).

WHAT IT SEES. Public addresses only: `previews_due` hands over the photo, a
clip's thumbnail, or the title's poster, all in the public bucket. This script
holds no bucket credentials and never learns a private key.

WHAT IT SENDS BACK. One string per item, or nothing for an image it could not
read — which the database records as a time, so that item is tried again in a
day rather than on every tick.

THE ENCODER IS HERE, NOT A PACKAGE. It is forty lines of arithmetic from the
published algorithm (github.com/woltapp/blurhash), and the app decodes with
the same forty lines in Dart. A dependency for it would be one more thing for
a five-minute cron to install, for code that will never change.
"""

import io
import json
import math
import os
import subprocess
import sys
import urllib.request

ALPHABET = ('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
            '#$%*+,-.:;=?@[]^_{|}~')

# Images are shrunk to this before encoding. A blurhash of 4x3 components
# cannot hold more detail than a 32-pixel image has, and the sum below is
# O(pixels x components).
SAMPLE = 32

# Per tick. One photo is a GET of ~100 KB and a few milliseconds of maths, so
# this is a minute at worst, and a backlog drains over a few ticks.
BATCH = 60

FETCH_TIMEOUT = 20
MAX_BYTES = 25 * 1024 * 1024


def encode83(value, length):
    out = ''
    for i in range(1, length + 1):
        digit = (value // (83 ** (length - i))) % 83
        out += ALPHABET[digit]
    return out


def srgb_to_linear(v):
    v = v / 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def linear_to_srgb(v):
    v = max(0.0, min(1.0, v))
    if v <= 0.0031308:
        return int(v * 12.92 * 255 + 0.5)
    return int((1.055 * (v ** (1 / 2.4)) - 0.055) * 255 + 0.5)


def sign_pow(v, exp):
    return math.copysign(abs(v) ** exp, v)


def encode(pixels, width, height, cx, cy):
    """Blurhash of `pixels` — a list of (r, g, b) tuples, row-major, sRGB 0-255."""
    if not (1 <= cx <= 9 and 1 <= cy <= 9):
        raise ValueError('components must be 1..9')
    linear = [(srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b))
              for (r, g, b) in pixels]
    factors = []
    for j in range(cy):
        for i in range(cx):
            norm = 1.0 if (i == 0 and j == 0) else 2.0
            r = g = b = 0.0
            for y in range(height):
                cos_y = math.cos(math.pi * j * y / height)
                row = y * width
                for x in range(width):
                    basis = norm * math.cos(math.pi * i * x / width) * cos_y
                    pr, pg, pb = linear[row + x]
                    r += basis * pr
                    g += basis * pg
                    b += basis * pb
            scale = 1.0 / (width * height)
            factors.append((r * scale, g * scale, b * scale))

    dc, ac = factors[0], factors[1:]
    out = encode83((cx - 1) + (cy - 1) * 9, 1)
    if ac:
        actual_max = max(abs(c) for f in ac for c in f)
        quant = int(max(0, min(82, math.floor(actual_max * 166 - 0.5))))
        max_value = (quant + 1) / 166.0
        out += encode83(quant, 1)
    else:
        max_value = 1.0
        out += encode83(0, 1)
    out += encode83((linear_to_srgb(dc[0]) << 16)
                    + (linear_to_srgb(dc[1]) << 8)
                    + linear_to_srgb(dc[2]), 4)
    for f in ac:
        q = [int(max(0, min(18, math.floor(sign_pow(c / max_value, 0.5) * 9 + 9.5))))
             for c in f]
        out += encode83(q[0] * 19 * 19 + q[1] * 19 + q[2], 2)
    return out


def components_for(width, height):
    """4x3 for a landscape picture, 3x4 for a portrait one: the axis that is
    longer gets the extra detail."""
    return (3, 4) if height > width else (4, 3)


def hash_image(data):
    """Blurhash of an encoded image (JPEG, PNG, WebP…), or None."""
    from PIL import Image  # imported late: see ensure_pillow
    with Image.open(io.BytesIO(data)) as img:
        img.draft('RGB', (SAMPLE * 4, SAMPLE * 4))  # JPEG: decode small, fast
        img = img.convert('RGB')
        w, h = img.size
        if w <= 0 or h <= 0:
            return None
        scale = SAMPLE / float(max(w, h))
        sw, sh = max(1, round(w * scale)), max(1, round(h * scale))
        small = img.resize((sw, sh))
        cx, cy = components_for(w, h)
        return encode(list(small.getdata()), sw, sh, cx, cy)


# Where Pillow goes when the runner does not have it. A FIXED DIRECTORY ADDED
# TO THE PATH, not a plain `pip install`: installed from inside a running
# interpreter, the package lands in a site directory that interpreter did not
# know about when it started, and the import that follows still fails. The
# first run of this script skipped all sixty items with ModuleNotFoundError
# for exactly that reason.
DEPS = '/tmp/previews-deps'


def ensure_pillow():
    try:
        import PIL  # noqa: F401
        return
    except ImportError:
        pass
    subprocess.run([sys.executable, '-m', 'pip', 'install', '--quiet',
                    '--disable-pip-version-check', '--target', DEPS, 'pillow'],
                   check=True)
    if DEPS not in sys.path:
        sys.path.insert(0, DEPS)
    import importlib
    importlib.invalidate_caches()
    import PIL  # noqa: F401,E402  — fails loudly here, not once per image


def call(url, secret, body):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), method='POST',
        headers={'Authorization': 'Bearer ' + secret,
                 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as res:
        return json.loads(res.read() or b'{}')


def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'innocent-previews'})
    with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as res:
        data = res.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError('too large')
    return data


def main():
    base = (os.environ.get('SB_URL') or '').rstrip('/')
    secret = os.environ.get('RUNNER_SECRET') or ''
    if not base or not secret:
        print('previews: not configured')
        return 0
    endpoint = base + '/functions/v1/ingest'
    due = call(endpoint, secret, {'op': 'previews_due', 'limit': BATCH}).get('rows') or []
    if not due:
        print('previews: none due')
        return 0
    ensure_pillow()
    items = []
    for row in due:
        item_id, src = row.get('id'), row.get('source_url')
        preview = None
        if src:
            try:
                preview = hash_image(fetch(src))
            except Exception as e:  # one unreadable image is not the batch's problem
                print('previews: skip', item_id, type(e).__name__)
        items.append({'id': item_id, 'preview': preview})
    res = call(endpoint, secret, {'op': 'previews_set', 'items': items})
    print('previews: saved', res.get('saved'), 'failed', res.get('failed'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
