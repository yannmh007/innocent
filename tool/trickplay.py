#!/usr/bin/env python3
"""The seek bar's pictures, made in advance: one small picture every few
seconds of a film, packed into one file the phone reads by byte range.

WHY (BACKLOG §0, 19 Nov 2026, weak point 6). The app took each seek-bar
picture from the smallest rung — one two-second fragment (~67 KB) fetched
from the Worker and decoded on the phone: 1.2-1.4 s for a part never seen
(device lab S1-S3), most of it the Worker's answer and the decode, which no
app-side change removes. A picture made here costs the phone a slice of a
file it already holds and no decode but the image's own.

THE PACK (`ITP1`, big-endian, every offset from the file's start):

    0   4  magic  b'ITP1'
    4   2  version (1)
    6   2  codec  (1 = JPEG, 2 = WebP)
    8   4  interval_ms — picture i is the film at i * interval_ms
    12  2  width
    14  2  height
    16  4  count
    20  4  header length = 24 + 4 * (count + 1)
    24  4 * (count + 1)  offsets: picture i is bytes [offsets[i], offsets[i+1])
    …   the pictures, each a whole JPEG / WebP file, one after another

The header of a two-hour film at 4 s is 7 KB, so the phone's first read
(a few KB from 0) has every offset; after that any picture, or a run of
neighbours, is one range request — through the same Worker, the same
signed address and the same cache as the film's rungs.

USAGE
    trickplay.py SRC OUT [--interval 4] [--width 224] [--codec jpeg|webp]
                         [--quality N] [--report]

SRC is a file or an http(s) address ffmpeg can read (the smallest rung).
--report prints one JSON line: count, bytes, per-picture median/p90 bytes,
MB per film-hour, seconds taken. Nothing here holds a key or uploads.
"""
import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

MAGIC = b'ITP1'
VERSION = 1
CODECS = {'jpeg': (1, 'jpg'), 'webp': (2, 'webp')}
HEAD = 24


def pack(pictures, interval_ms, width, height, codec):
    """The ITP1 bytes for [pictures] (each a whole image file's bytes)."""
    n = len(pictures)
    header_len = HEAD + 4 * (n + 1)
    offsets = []
    at = header_len
    for p in pictures:
        offsets.append(at)
        at += len(p)
    offsets.append(at)
    head = MAGIC + struct.pack('>HHIHHII', VERSION, CODECS[codec][0], interval_ms,
                               width, height, n, header_len)
    return head + struct.pack(f'>{n + 1}I', *offsets) + b''.join(pictures)


def read_header(data):
    """(interval_ms, width, height, codec, offsets) of an ITP1 pack's head."""
    if data[:4] != MAGIC:
        raise ValueError('not an ITP1 pack')
    if len(data) < HEAD:
        raise ValueError('cut short inside the header')
    version, codec, interval_ms, width, height, n, header_len = struct.unpack(
        '>HHIHHII', data[4:HEAD])
    if version != VERSION or header_len != HEAD + 4 * (n + 1) or len(data) < header_len:
        raise ValueError('a pack this reader does not know, or cut short')
    offsets = list(struct.unpack(f'>{n + 1}I', data[HEAD:header_len]))
    if any(b < a for a, b in zip(offsets, offsets[1:])) or offsets[0] != header_len:
        raise ValueError('offsets out of order')
    name = {v[0]: k for k, v in CODECS.items()}.get(codec)
    if name is None:
        raise ValueError(f'unknown codec {codec}')
    return interval_ms, width, height, name, offsets


def make(src, interval_s, width, codec='jpeg', quality=None):
    """The pictures of [src], one every [interval_s], [width] px wide (an even
    height for its shape), as a list of image files' bytes, and the height."""
    ext = CODECS[codec][1]
    work = tempfile.mkdtemp(prefix='trick_')
    try:
        # One picture at the START of every interval: picture i is the film
        # at i * interval — the moment the seek bar's finger names.
        vf = f'fps=1/{interval_s}:round=down,scale={width}:-2:flags=lanczos'
        args = ['ffmpeg', '-nostdin', '-y', '-hide_banner', '-loglevel', 'error',
                '-i', src, '-an', '-sn', '-vf', vf]
        if codec == 'jpeg':
            args += ['-q:v', str(quality if quality is not None else 5)]
        else:
            args += ['-c:v', 'libwebp', '-quality', str(quality if quality is not None else 60)]
        args.append(os.path.join(work, f'p_%06d.{ext}'))
        subprocess.run(args, check=True)
        names = sorted(f for f in os.listdir(work) if f.endswith('.' + ext))
        pictures = []
        for f in names:
            with open(os.path.join(work, f), 'rb') as fh:
                pictures.append(fh.read())
        height = _height(pictures[0], codec) if pictures else 0
        return pictures, height
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _height(first, codec):
    """The picture's height, read from its own header (JPEG SOF / WebP VP8)."""
    if codec == 'jpeg':
        i = 2
        while i + 9 < len(first):
            if first[i] != 0xFF:
                i += 1
                continue
            marker = first[i + 1]
            size = struct.unpack('>H', first[i + 2:i + 4])[0]
            if marker in (0xC0, 0xC1, 0xC2):
                return struct.unpack('>H', first[i + 5:i + 7])[0]
            i += 2 + size
        return 0
    # WebP: RIFF....WEBPVP8 / VP8L / VP8X; only the lossy simple form is
    # written here (libwebp, a quality), whose frame header holds the size.
    if first[12:16] == b'VP8 ':
        return struct.unpack('<H', first[28:30])[0] & 0x3FFF
    if first[12:16] == b'VP8X':
        return int.from_bytes(first[27:30], 'little') + 1
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('src')
    ap.add_argument('out')
    ap.add_argument('--interval', type=float, default=4.0)
    ap.add_argument('--width', type=int, default=224)
    ap.add_argument('--codec', choices=sorted(CODECS), default='jpeg')
    ap.add_argument('--quality', type=int)
    ap.add_argument('--report', action='store_true')
    a = ap.parse_args(argv)
    t0 = time.monotonic()
    pictures, height = make(a.src, a.interval, a.width, a.codec, a.quality)
    if not pictures:
        print('trickplay: no picture came out of the film', file=sys.stderr)
        return 1
    data = pack(pictures, int(round(a.interval * 1000)), a.width, height, a.codec)
    with open(a.out, 'wb') as fh:
        fh.write(data)
    took = time.monotonic() - t0
    if a.report:
        sizes = sorted(len(p) for p in pictures)
        film_s = len(pictures) * a.interval
        print(json.dumps({
            'count': len(pictures),
            'width': a.width,
            'height': height,
            'interval_s': a.interval,
            'codec': a.codec,
            'bytes': len(data),
            'median_bytes': sizes[len(sizes) // 2],
            'p90_bytes': sizes[min(len(sizes) - 1, int(len(sizes) * 0.9))],
            'mb_per_hour': round(len(data) / 1e6 * 3600 / max(1.0, film_s), 2),
            'seconds': round(took, 1),
        }))
    return 0


if __name__ == '__main__':
    sys.exit(main())
