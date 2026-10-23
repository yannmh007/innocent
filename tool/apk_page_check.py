#!/usr/bin/env python3
"""Fail if an APK carries an arm64 native library that a 16 KB-page phone
cannot load.

Android 15+ devices may run with 16 KB memory pages. A shared library whose
LOAD segments are aligned to less than that fails to load there — the app
crashes the moment it reaches the feature that library serves. This reads
every lib/arm64-v8a/*.so in the APK and checks each PT_LOAD p_align is at
least 16384. Files under lib/ that are not ELF (data packed as .so so the
installer extracts them, e.g. libpython.zip.so) are not loaded by the linker
and are skipped.

Uncompressed libraries must also start on a 16 KB boundary inside the APK
(they are mapped straight from it); compressed ones are extracted at install
and their zip offset does not matter.

    python3 tool/apk_page_check.py app.apk     # exit 1 when any is 4 KB
"""
import struct
import sys
import zipfile

PAGE = 16384


def load_aligns(data):
    if data[:4] != b'\x7fELF' or data[4] != 2:  # ELF64 only (arm64)
        return None
    phoff = struct.unpack_from('<Q', data, 32)[0]
    phentsize, phnum = struct.unpack_from('<HH', data, 54)
    out = []
    for k in range(phnum):
        o = phoff + k * phentsize
        if struct.unpack_from('<I', data, o)[0] == 1:  # PT_LOAD
            out.append(struct.unpack_from('<Q', data, o + 48)[0])
    return out


def main(path):
    bad = []
    seen = 0
    with zipfile.ZipFile(path) as z, open(path, 'rb') as raw:
        for info in z.infolist():
            name = info.filename
            if not (name.startswith('lib/arm64-v8a/') and name.endswith('.so')):
                continue
            aligns = load_aligns(z.read(info))
            if aligns is None:
                continue
            seen += 1
            problems = []
            if not aligns or min(aligns) < PAGE:
                problems.append(f'LOAD aligned to {min(aligns) if aligns else 0}')
            if info.compress_type == zipfile.ZIP_STORED:
                raw.seek(info.header_offset)
                head = raw.read(30)
                n, m = struct.unpack_from('<HH', head, 26)
                if (info.header_offset + 30 + n + m) % PAGE:
                    problems.append('stored, not on a 16 KB boundary in the APK')
            print(('BAD ' if problems else 'ok  ') + name +
                  (' — ' + '; '.join(problems) if problems else ''))
            if problems:
                bad.append(name)
    print(f'{seen} arm64 libraries, {len(bad)} that a 16 KB-page phone cannot load')
    return 1 if bad or seen == 0 else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
