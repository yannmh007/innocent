// The MP4 box walker behind the console's "Start-up" check.
//
// WHY IT IS TESTED. Its output is an instruction: a verdict of `tail` tells
// the operator to upload a film again, which over a Myanmar mobile
// connection costs them a gigabyte of data and an hour. A verdict of
// `faststart` on a file that is not tells them to stop looking for the
// reason viewers wait. Both directions are expensive to get wrong, and
// neither throws — a mis-walked box list returns a confident, plausible,
// wrong answer.
//
// The cases that matter are the ones where the answer is inferred from what
// is ABSENT. The probe reads only the first 64 KB, so a file with its index
// at the end shows `ftyp mdat` and nothing more: the verdict comes from
// moov's absence beside a present mdat, and that inference is what case 2
// pins down.
//
// The walker is lifted out of the deployed function rather than copied,
// because a copy would pass this test forever while the function drifted.
//
// RUN:  node tool/js/probe_boxes_test.mjs
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', '..',
  'docs', 'edge', 'probe-media.ts'), 'utf8');
const body = src.slice(src.indexOf('function boxes('), src.indexOf('const json ='));
const mod = await import('data:text/javascript,' + encodeURIComponent(
  // Strip the one type annotation the parser cannot take, then the rest.
  body.replace(/const out: [^=]+=/, 'const out =')
      .replace(/: DataView/g, '').replace(/: number/g, '')
  + '\nexport { boxes };'));

let fail = 0;
const check = (l, ok) => { console.log((ok?'ok   ':'FAIL ')+l); if(!ok) fail++; };

const be32 = (n) => { const b=Buffer.alloc(4); b.writeUInt32BE(n); return b; };
const box = (type, len) => Buffer.concat([be32(len+8), Buffer.from(type,'ascii'), Buffer.alloc(len)]);

const verdict = (names) => {
  const moov = names.indexOf('moov'), mdat = names.indexOf('mdat');
  return moov >= 0 && (mdat < 0 || moov < mdat) ? 'faststart'
    : (moov < 0 && mdat >= 0) ? 'tail'
    : (moov >= 0 && mdat >= 0 && moov > mdat) ? 'tail' : 'unknown';
};
const run = (buf, total) => mod.boxes(new DataView(
  buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength)), total);

// 1. faststart: ftyp, moov, mdat — all inside the first 64 KB.
{
  const f = Buffer.concat([box('ftyp',16), box('moov',400), box('mdat',1000)]);
  const names = run(f, f.length).map(b=>b.type);
  check('faststart file reads ftyp moov mdat', names.join(' ') === 'ftyp moov mdat');
  check('faststart verdict', verdict(names) === 'faststart');
}

// 2. tail: ftyp then a HUGE mdat — moov is past the 64 KB we fetched, so it
//    must never appear, and the absence must read as `tail` rather than as
//    "unknown" or, worse, "faststart".
{
  const head = Buffer.concat([box('ftyp',16), Buffer.concat([be32(900000000), Buffer.from('mdat','ascii')])]);
  const names = run(head, 900000100).map(b=>b.type);
  check('tail file reads only ftyp mdat from the head', names.join(' ') === 'ftyp mdat');
  check('tail verdict', verdict(names) === 'tail');
}

// 3. 64-bit mdat (a film over 4 GiB) must not derail the walk.
{
  const big = Buffer.concat([
    box('ftyp',16),
    Buffer.concat([be32(1), Buffer.from('mdat','ascii'), be32(1), be32(0)]),
  ]);
  const names = run(big, 5e9).map(b=>b.type);
  check('64-bit mdat is recognised', names.join(' ') === 'ftyp mdat');
}

// 4. Garbage must not be reported as either state. A wrong "re-upload this"
//    costs a gigabyte of someone's data.
{
  const junk = Buffer.alloc(64, 0);
  const names = run(junk, 64).map(b=>b.type);
  check('a zero-filled file yields no confident verdict', verdict(names) === 'unknown');
}

// 5. A box claiming an impossible size stops the walk rather than looping.
{
  const bad = Buffer.concat([be32(2), Buffer.from('ftyp','ascii'), Buffer.alloc(40)]);
  const names = run(bad, 48).map(b=>b.type);
  check('an impossible box size stops the walk', names.length === 0);
}

if (fail) { console.error(fail + ' failed'); process.exit(1); }
console.log('probe box walker: all checks passed');
