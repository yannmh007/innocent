#!/usr/bin/env python3
"""Is a streaming rung laid out the way the players can seek in?

    cmaf_layout.py FILE

The ladder's layout (tool/transcode.sh): `ftyp`, `moov`, one `sidx` per
track, then fragments; exactly one picture track and at most one sound
track; and every `sidx` indexing fragments that reach the end of the file.

That last one is the line that matters. A source with CHAPTERS used to give
its rungs a third track — the MP4 muxer writes chapters as a text track —
whose `sidx` covered one fragment and stopped. FFmpeg's demuxer then cannot
trust its fragment index, and every seek READS THE FILM FROM THE START:
208 MB for a seek to 40 % of Sintel's 720p copy (playback-check run
39205401856), minutes on a Myanmar line. Exit 1, saying what is wrong, so a
rung like that is never uploaded again.
"""
import struct
import sys


def boxes(buf):
    out, at = [], 0
    while at + 8 <= len(buf):
        size, kind = struct.unpack('>I4s', buf[at:at + 8])
        hdr = 8
        if size == 1:
            size = struct.unpack('>Q', buf[at + 8:at + 16])[0]
            hdr = 16
        elif size == 0:
            size = len(buf) - at
        if size < 8:
            break
        out.append((kind.decode('latin1'), at, size, hdr))
        if kind in (b'moof', b'mdat'):
            break
        at += size
    return out


def children(buf, at, size, hdr):
    out, p, end = [], at + hdr, at + size
    while p + 8 <= end:
        s, k = struct.unpack('>I4s', buf[p:p + 8])
        if s < 8:
            break
        out.append((k.decode('latin1'), p, s))
        p += s
    return out


def handlers(buf, moov):
    found = []
    for k, at, s in children(buf, *moov):
        if k != 'trak':
            continue
        for k2, at2, s2 in children(buf, at, s, 8):
            if k2 != 'mdia':
                continue
            for k3, at3, s3 in children(buf, at2, s2, 8):
                if k3 == 'hdlr':
                    found.append(buf[at3 + 16:at3 + 20].decode('latin1'))
    return found


def sidx_end(buf, at, size):
    p = at + 8
    ver = buf[p]
    p += 12
    if ver == 0:
        first = struct.unpack('>I', buf[p + 4:p + 8])[0]
        p += 8
    else:
        first = struct.unpack('>Q', buf[p + 8:p + 16])[0]
        p += 16
    p += 2
    n = struct.unpack('>H', buf[p:p + 2])[0]
    p += 2
    end = at + size + first
    for _ in range(n):
        end += struct.unpack('>I', buf[p:p + 4])[0] & 0x7fffffff
        p += 12
    return end


def problems(path):
    with open(path, 'rb') as f:
        head = f.read(4 * 1024 * 1024)
        f.seek(0, 2)
        total = f.tell()
    top = boxes(head)
    names = [k for k, *_ in top]
    if not names or names[0] != 'ftyp' or 'moov' not in names or 'moof' not in names:
        return [f'not a fragmented MP4: {names[:6]}']
    found = []
    moov = next((at, s, h) for k, at, s, h in top if k == 'moov')
    tracks = handlers(head, moov)
    if tracks.count('vide') != 1 or tracks.count('soun') > 1 or any(t not in ('vide', 'soun') for t in tracks):
        found.append(f'tracks are {tracks}: one picture track and at most one sound track expected')
    sidx = [(at, s) for k, at, s, _ in top if k == 'sidx']
    if not sidx:
        found.append('no sidx: a seek would have to read its way there')
    for at, s in sidx:
        end = sidx_end(head, at, s)
        if end != total:
            found.append(f'the sidx at byte {at} ends {end - total:+d} bytes from the end of the file')
    return found


def main():
    path = sys.argv[1]
    bad = problems(path)
    for line in bad:
        print(f'{path}: {line}')
    if bad:
        sys.exit(1)
    print(f'{path}: layout ok')


if __name__ == '__main__':
    main()
