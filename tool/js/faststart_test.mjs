// Proof that the console's faststart rewrite does not corrupt a video.
//
// WHY THIS TEST EXISTS AND WHY IT IS NOT OPTIONAL. `faststart()` in
// docs/studio/index.html reorders the top-level boxes of an MP4 and then
// REWRITES THE CHUNK OFFSET TABLE so every sample still points at its own
// bytes. Get the arithmetic wrong by one and the file still uploads, still
// has the right length, still opens in the console — and plays as noise. The
// original is gone by then, because the operator uploaded over a mobile
// connection and deleted their copy.
//
// So the rewrite is exercised against a synthetic MP4 whose three "chunks"
// are filled with distinct marker bytes. The test reads the patched offset
// table out of the OUTPUT file and checks that the byte at each offset is
// still the marker that chunk started with. That is the only assertion that
// actually proves correctness; "the file is the same size" proves nothing.
//
// It also covers the three declines, because a wrong decline is invisible:
// an already-faststart file must be returned as the SAME OBJECT (so nothing
// is copied), a truncated file must be refused rather than guessed at, and a
// non-video must not be touched at all.
//
// RUN IT WITH:  node tool/js/faststart_test.mjs
// tool/check.py runs it automatically when node is on the PATH, and says so
// loudly when it is not — a check that skips in silence is not a check.
//
// The functions are pulled out of the page rather than duplicated here. A
// copy would pass this test forever while the page drifted away from it.

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

// Relative to this file, so the test runs from any working directory — CI
// does not cd into the repo root before running checks.
const PAGE = join(dirname(fileURLToPath(import.meta.url)),
  '..', '..', 'docs', 'studio', 'index.html');
let failures = 0;
const check = (label, ok) => {
  console.log((ok ? 'ok   ' : 'FAIL ') + label);
  if (!ok) failures++;
};
// Pull the two functions out of the console page.
const html = readFileSync(PAGE,'utf8');
const js = html.slice(html.indexOf('<script>')+8, html.lastIndexOf('</script>'));
const start = js.indexOf('async function topLevelBoxes');
const end = js.indexOf('// ── uploading');
const src = js.slice(start, end);
const mod = await import('data:text/javascript,' + encodeURIComponent(src +
  '\nexport { topLevelBoxes, shiftChunkOffsets, faststart };'));

const be32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };
const box = (type, ...payload) => {
  const body = Buffer.concat(payload.map(p => Buffer.isBuffer(p)?p:Buffer.from(p)));
  return Buffer.concat([be32(body.length+8), Buffer.from(type,'ascii'), body]);
};

// mdat holds three "chunks" of 100 bytes each, filled with a marker byte.
const chunk = (b) => Buffer.alloc(100, b);
const mdatBody = Buffer.concat([chunk(0xA1), chunk(0xB2), chunk(0xC3)]);
const ftyp = box('ftyp', Buffer.from([0x69,0x73,0x6f,0x6d,0,0,2,0,0x69,0x73,0x6f,0x6d,0x61,0x76,0x63,0x31]));
const mdatStart = ftyp.length;
const mdat = box('mdat', mdatBody);
// Absolute offsets of each chunk in the ORIGINAL file.
const offs = [0,1,2].map(i => mdatStart + 8 + i*100);
const stco = box('stco', Buffer.alloc(4), be32(3), ...offs.map(be32));
const moov = box('moov', box('trak', box('mdia', box('minf', box('stbl', stco)))));
const original = Buffer.concat([ftyp, mdat, moov]);

// Minimal File shim.
class F {
  constructor(buf, name, type){ this.b=buf; this.name=name; this.type=type; this.size=buf.length; }
  slice(a,b){ const s = this.b.subarray(a,b); return { arrayBuffer: async()=> s.buffer.slice(s.byteOffset, s.byteOffset+s.byteLength), __buf:s, size:s.length }; }
}
globalThis.Blob = class {
  constructor(parts, opts){ this.parts = parts; this.type = (opts&&opts.type)||'';
    this._b = Buffer.concat(parts.map(p => p instanceof ArrayBuffer ? Buffer.from(p) : Buffer.from(p.__buf)));
    this.size = this._b.length; }
};

const f = new F(original, 'test.mp4', 'video/mp4');
const boxes = await mod.topLevelBoxes(f);
console.log('boxes:', boxes.map(b=>b.type+'@'+b.start+'+'+b.size).join(' '));

const res = await mod.faststart(f);
console.log('state:', res.state, '|', res.detail);
const out = res.blob._b;
check('the rewrite changes no byte of length', out.length === original.length);

// Re-parse the output and check the chunks land where stco says.
const f2 = new F(out,'o.mp4','video/mp4');
const b2 = await mod.topLevelBoxes(f2);
console.log('new order:', b2.map(b=>b.type).join(','));
// find stco in the new moov
const m2 = b2.find(b=>b.type==='moov');
const mv = out.subarray(m2.start, m2.start+m2.size);
const idx = mv.indexOf(Buffer.from('stco','ascii'));
const cnt = mv.readUInt32BE(idx+4+4);
const got = [];
for (let i=0;i<cnt;i++) got.push(mv.readUInt32BE(idx+4+8+i*4));
console.log('patched offsets:', got);
const markers = got.map(o => out[o].toString(16));
console.log('bytes at those offsets:', markers, '-> expect a1,b2,c3');
check('every patched offset still lands on its own chunk',
  markers.join(',') === 'a1,b2,c3');
check('moov is now the second box', b2.map(b=>b.type).join(',') === 'ftyp,moov,mdat');

// Case 2: a file that is ALREADY faststart must be returned untouched.
const already = new F(out, 'o.mp4', 'video/mp4');
const r2 = await mod.faststart(already);
check('an already-faststart file is returned untouched',
  r2.state === 'already' && r2.blob === already);

// Case 3: a truncated file must decline, never rewrite.
const r3 = await mod.faststart(new F(original.subarray(0, original.length - 20), 't.mp4', 'video/mp4'));
check('a truncated file is declined, never rewritten',
  r3.state === 'skipped');

// Case 4: not a video at all.
const r4 = await mod.faststart(new F(Buffer.alloc(40), 'a.jpg', 'image/jpeg'));
check('a non-video is not touched', r4.state === 'skipped');

if (failures) {
  console.error(failures + ' faststart check(s) failed');
  process.exit(1);
}
console.log('faststart: all checks passed');
