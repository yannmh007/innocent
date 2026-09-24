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
// SLICED BETWEEN MARKERS, NOT BETWEEN WHATEVER HAPPENS TO FOLLOW. The first
// version ended the slice at `const json =`, which silently swallowed every
// function added between the two — and the day one was, this file failed to
// parse rather than failing a check, which is a much worse way to learn.
const between = (from, to) => src.slice(src.indexOf(from), src.indexOf(to));
const body = between('function boxes(', '// --- how long is it') +
  between('function mvhdSeconds(', '// --- a token');
const mod = await import('data:text/javascript,' + encodeURIComponent(
  // Strip the type annotations the parser cannot take. Declarations only —
  // an object literal's `key: value` must survive untouched.
  body.replace(/const out: [^=]+=/, 'const out =')
      .replace(/: DataView/g, '')
      .replace(/: Uint8Array/g, '')
      .replace(/: number \| null/g, '')
      .replace(/: number/g, '')
  + '\nexport { boxes, mvhdSeconds };'));

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
// ── mvhd, which is where the bitrate comes from ────────────────────────
//
// WHY A DURATION IS WORTH TESTING. It is what turns 133 MB from a size into
// 35 Mbps, and 35 Mbps is the sentence that tells an operator their camera
// clip cannot be streamed over the connection their viewers have. A wrong
// duration produces a wrong bitrate, which reads as a confident and entirely
// fabricated verdict about somebody's network.
const mvhdV0 = (timescale, duration) => Buffer.concat([
  be32(108), Buffer.from('mvhd', 'ascii'),
  Buffer.from([0]), Buffer.alloc(3),          // version 0, flags
  be32(0), be32(0),                            // created, modified
  be32(timescale), be32(duration),
  Buffer.alloc(80),
]);
const mvhdV1 = (timescale, duration) => Buffer.concat([
  be32(120), Buffer.from('mvhd', 'ascii'),
  Buffer.from([1]), Buffer.alloc(3),
  Buffer.alloc(16),                            // created, modified (64-bit)
  be32(timescale),
  be32(Math.floor(duration / 4294967296)), be32(duration >>> 0),
  Buffer.alloc(80),
]);

{
  const b = Buffer.concat([box('ftyp', 24), mvhdV0(600, 600 * 95)]);
  check('mvhd v0 gives seconds', mod.mvhdSeconds(new Uint8Array(b)) === 95);
}
{
  const b = Buffer.concat([box('ftyp', 24), mvhdV1(90000, 90000 * 42)]);
  check('mvhd v1 gives seconds', mod.mvhdSeconds(new Uint8Array(b)) === 42);
}
{
  // The case that makes the bitrate column blank rather than wrong.
  const b = Buffer.concat([box('ftyp', 24), box('mdat', 4000)]);
  check('no mvhd is null, not zero', mod.mvhdSeconds(new Uint8Array(b)) === null);
}
{
  // A timescale of zero is a division by zero waiting to be reported as
  // Infinity kbps. It must read as "not measured".
  const b = mvhdV0(0, 1000);
  check('a zero timescale is null', mod.mvhdSeconds(new Uint8Array(b)) === null);
}
{
  // Four matching characters at the very end of the chunk, with no header
  // behind them. Scanning must not read past the buffer or invent a number.
  const b = Buffer.concat([box('ftyp', 24), Buffer.from('mvhd', 'ascii')]);
  check('a truncated match is null', mod.mvhdSeconds(new Uint8Array(b)) === null);
}
{
  // The tail case: the header sits at the END of the chunk, which is exactly
  // what a second ranged read of the last megabyte hands this function.
  const b = Buffer.concat([box('mdat', 5000), mvhdV0(1000, 12345)]);
  const s = mod.mvhdSeconds(new Uint8Array(b));
  check('mvhd found in a tail chunk', Math.abs(s - 12.345) < 0.001);
}

// THE EXIT CODE, which the first version of this file did not have: it
// printed "all checks passed" whether or not they had, so a red FAIL line
// scrolled past in a green summary. A test that cannot fail the build is a
// comment.
if (fail) {
  console.error(`probe box walker: ${fail} check(s) FAILED`);
  process.exit(1);
}
console.log('probe box walker: all checks passed');
