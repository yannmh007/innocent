// docs/studio/jpeg_clean.js: a photo leaves the phone without its place and
// time, the right way up, and with the picture itself untouched.
//
// A synthetic JPEG with everything a phone writes (EXIF with GPS, the camera
// and an orientation of 6, XMP, a comment, an ICC profile, JFIF) is cleaned
// and checked block by block; then, where ffmpeg is installed, a real JPEG
// with those blocks spliced in is cleaned and both are decoded: the same
// pixels.
//
//   node tool/js/jpeg_clean_test.mjs

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { cleanJpeg, isJpeg } from '../../docs/studio/jpeg_clean.js';

let checks = 0;
function ok(cond, what) {
  checks++;
  if (!cond) {
    console.log('FAIL ' + what);
    process.exit(1);
  }
  console.log('ok   ' + what);
}

const enc = new TextEncoder();
const has = (hay, needle) => {
  const n = typeof needle === 'string' ? enc.encode(needle) : needle;
  outer: for (let i = 0; i + n.length <= hay.length; i++) {
    for (let j = 0; j < n.length; j++) if (hay[i + j] !== n[j]) continue outer;
    return true;
  }
  return false;
};
const seg = (marker, payload) => {
  const p = typeof payload === 'string' ? enc.encode(payload) : Uint8Array.from(payload);
  const len = p.length + 2;
  return Uint8Array.from([0xff, marker, len >> 8, len & 0xff, ...p]);
};
const cat = (...parts) => {
  const out = new Uint8Array(parts.reduce((t, x) => t + x.length, 0));
  let at = 0;
  for (const x of parts) { out.set(x, at); at += x.length; }
  return out;
};

/// An EXIF block as a phone writes it: little-endian, IFD0 with Make,
/// Orientation and a pointer to a GPS IFD holding a latitude.
function exif(orientation, littleEndian = true) {
  const b = [];
  const u16 = (v) => (littleEndian ? [v & 255, v >> 8] : [v >> 8, v & 255]);
  const u32 = (v) => (littleEndian
    ? [v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >>> 24) & 255]
    : [(v >>> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255]);
  b.push(...enc.encode('Exif\0\0'));
  b.push(...(littleEndian ? [0x49, 0x49] : [0x4d, 0x4d]), ...u16(42), ...u32(8));
  // IFD0 at 8: three entries.
  const make = enc.encode('SECRETCAM-SERIAL-1234\0');
  const ifd0 = 8;
  const makeAt = ifd0 + 2 + 3 * 12 + 4;
  const gpsAt = makeAt + make.length;
  b.push(...u16(3));
  b.push(...u16(0x010f), ...u16(2), ...u32(make.length), ...u32(makeAt));     // Make
  b.push(...u16(0x0112), ...u16(3), ...u32(1), ...u16(orientation), 0, 0);   // Orientation
  b.push(...u16(0x8825), ...u16(4), ...u32(1), ...u32(gpsAt));               // GPS IFD
  b.push(...u32(0));
  b.push(...make);
  // GPS IFD: GPSLatitudeRef 'N'.
  b.push(...u16(1), ...u16(0x0001), ...u16(2), ...u32(2), 0x4e, 0, 0, 0, ...u32(0));
  b.push(...enc.encode('16.8409N 96.1735E HOME'));
  return seg(0xe1, b);
}

const APP0 = seg(0xe0, [...enc.encode('JFIF\0'), 1, 1, 0, 0, 1, 0, 1, 0, 0]);
const ICC = seg(0xe2, [...enc.encode('ICC_PROFILE\0'), 1, 1, ...enc.encode('profile-bytes')]);
const XMP = seg(0xe1, [...enc.encode('http://ns.adobe.com/xap/1.0/\0'), ...enc.encode('<x:GPSLatitude>16.84</x:GPSLatitude>')]);
const COM = seg(0xfe, 'taken at home, 5 Nov');
const IPTC = seg(0xed, 'Photoshop 3.0\0 8BIM byline: the owner');
const DQT = seg(0xdb, [0, ...new Array(64).fill(1)]);
const SOF = seg(0xc0, [8, 0, 16, 0, 16, 1, 1, 0x11, 0]);
const SCAN = Uint8Array.from([0xff, 0xda, 0, 8, 1, 1, 0, 0, 0x3f, 0, 0x12, 0xff, 0x00, 0x34, 0xff, 0xd9]);

const phone = cat(Uint8Array.of(0xff, 0xd8), APP0, exif(6), XMP, ICC, IPTC, COM, DQT, SOF, SCAN);
const r = cleanJpeg(phone);
ok(r !== null, 'a phone JPEG is walked');
const c = r.bytes;
ok(c[0] === 0xff && c[1] === 0xd8 && c[2] === 0xff && c[3] === 0xe0, 'it still starts with SOI, then JFIF first');
ok(!has(c, 'SECRETCAM') && !has(c, 'HOME') && !has(c, 'GPSLatitude'), 'no camera, no GPS, no XMP position');
ok(!has(c, 'taken at home') && !has(c, '8BIM'), 'no comment, no IPTC/Photoshop block');
ok(has(c, 'ICC_PROFILE') && has(c, DQT) && has(c, SOF), 'the colour profile and the picture\'s tables stay');
ok(has(c, Uint8Array.from([0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x06])),
  'the orientation (6, on its side) is written back');
ok(r.orientation === 6, 'and reported');
ok(c.subarray(c.length - SCAN.length).every((v, i) => v === SCAN[i]), 'the scan, byte for byte');
ok(r.removed > 0 && c.length < phone.length, 'smaller by what was removed (' + r.removed + ' bytes)');
ok(cleanJpeg(c).bytes.length === c.length, 'cleaning twice changes nothing');

const upright = cleanJpeg(cat(Uint8Array.of(0xff, 0xd8), exif(1, false), DQT, SOF, SCAN));
ok(upright && !has(upright.bytes, 'Exif'), 'an upright photo keeps no EXIF at all (big-endian read too)');
ok(cleanJpeg(enc.encode('not a jpeg at all')) === null && !isJpeg(enc.encode('GIF89a')), 'not a JPEG: null');
ok(cleanJpeg(cat(Uint8Array.of(0xff, 0xd8), APP0, Uint8Array.of(0xff, 0xe1, 0x40, 0x00, 1, 2))) === null,
  'a block longer than the file: null, never a guess');

// ── a real JPEG, decoded before and after ──────────────────────────────────
let ffmpeg = true;
try { execFileSync('ffmpeg', ['-version'], { stdio: 'ignore' }); } catch { ffmpeg = false; }
if (!ffmpeg) {
  console.log('jpeg clean: the decode half skipped (no ffmpeg here)');
} else {
  const dir = mkdtempSync(path.join(tmpdir(), 'jpeg-'));
  const src = path.join(dir, 'src.jpg');
  execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x240',
    '-frames:v', '1', '-q:v', '3', src]);
  const real = new Uint8Array(readFileSync(src));
  // Splice the phone's blocks in after SOI (and its own APP0, if any).
  const withMeta = cat(real.subarray(0, 2), exif(3), XMP, COM, real.subarray(2));
  const cleaned = cleanJpeg(withMeta);
  writeFileSync(path.join(dir, 'a.jpg'), withMeta);
  writeFileSync(path.join(dir, 'b.jpg'), cleaned.bytes);
  const raw = (f) => execFileSync('ffmpeg', ['-v', 'error', '-i', path.join(dir, f),
    '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], { maxBuffer: 1 << 26 });
  const a = raw('a.jpg');
  const b = raw('b.jpg');
  ok(a.length === 320 * 240 * 3 && a.equals(b), 'a real JPEG decodes to the same pixels after cleaning');
  ok(!has(cleaned.bytes, 'SECRETCAM') && cleaned.orientation === 3, 'and keeps its orientation (3) only');
}

console.log('jpeg clean: all checks passed (' + checks + ')');
