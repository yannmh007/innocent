// docs/edge/media_read.js: a range of a stored object as its plaintext,
// plain or sealed — what probe-media and backfill-dimensions read (§7.3).
//
//   node tool/js/media_read_test.mjs

import * as ms from '../../docs/edge/media_seal.js';
import { readPlain } from '../../docs/edge/media_read.js';

let checks = 0;
function ok(cond, what) {
  checks++;
  if (!cond) {
    console.log('FAIL ' + what);
    process.exit(1);
  }
  console.log('ok   ' + what);
}
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

const n = ms.FIRST_PLAIN + 6 * ms.PLAIN_SEGMENT + 1234;
const plain = ms.randomBytes(n);
const dek = ms.randomBytes(32);
const dekId = '00000000-0000-4000-8000-000000000001';
const sealed = await ms.sealAll(plain, dek, ms.aadFor(dekId));
const KEY = 's/' + 'ab'.repeat(16);
let reads = [];

function io({ header = true, store = { 'v/plain.mp4': plain, [KEY]: sealed } } = {}) {
  return {
    get: async (key, first, last) => {
      const obj = store[key];
      if (!obj) return null;
      reads.push([key, first, last]);
      return { bytes: obj.slice(first, Math.min(last, obj.length - 1) + 1), total: obj.length };
    },
    seal: async (key) => (key === KEY
      ? { dekId, dek: dek.slice(), plainSize: n, header: header ? sealed.subarray(0, ms.HEADER) : null }
      : null),
  };
}

// A plain object: one ranged read, as before.
reads = [];
let g = await readPlain(io(), 'v/plain.mp4', 0, 65536);
ok(same(g.bytes, plain.subarray(0, 65536)) && g.total === n && reads.length === 1, 'a plain object: its bytes, one read');

// A sealed one: the same plaintext, ranges anywhere.
let good = true;
const cases = [[0, 65536], [0, 1], [n - 1024 * 1024 > 0 ? n - 1024 * 1024 : 0, n], [ms.FIRST_PLAIN - 3, ms.FIRST_PLAIN + 3],
  [n - 10, n + 500], [123456, 123457], [ms.FIRST_PLAIN + 2 * ms.PLAIN_SEGMENT, ms.FIRST_PLAIN + 3 * ms.PLAIN_SEGMENT]];
for (let k = 0; k < 40; k++) {
  const a = Math.floor(Math.random() * n);
  cases.push([a, a + 1 + Math.floor(Math.random() * 200000)]);
}
for (const [a, b] of cases) {
  g = await readPlain(io(), KEY, a, b);
  if (!same(g.bytes, plain.subarray(a, Math.min(b, n))) || g.total !== n) good = false;
}
ok(good, 'a sealed object: the plaintext of ' + cases.length + ' ranges, head, tail and across segments');
reads = [];
g = await readPlain(io(), KEY, 0, 65536);
ok(reads.length === 1 && reads[0][1] === ms.HEADER, 'one ranged read of the segments that hold the range');
reads = [];
g = await readPlain(io({ header: false }), KEY, 200000, 200100);
ok(same(g.bytes, plain.subarray(200000, 200100)) && reads.length === 1 && reads[0][1] === 0,
  'a key row without its header: read in the same request');
g = await readPlain(io(), KEY, n + 5, n + 10);
ok(g.bytes.length === 0 && g.total === n, 'past the end: nothing, and the size');

// Never a byte it could not authenticate.
const bad = sealed.slice();
bad[ms.sealedStart(2) + 9] ^= 1;
let threw = false;
try {
  await readPlain(io({ store: { [KEY]: bad } }), KEY, ms.FIRST_PLAIN + ms.PLAIN_SEGMENT, ms.FIRST_PLAIN + ms.PLAIN_SEGMENT + 10);
} catch (e) {
  threw = e instanceof ms.SealError;
}
ok(threw, 'an altered segment throws rather than answering');
threw = false;
try {
  await readPlain({ ...io(), get: async (key, a, b) => ({ bytes: sealed.slice(a, b), total: sealed.length }) }, KEY, 0, 100);
} catch (e) {
  threw = e instanceof ms.SealError;
}
ok(threw, 'a short answer from the store throws');
ok((await readPlain(io(), 's/' + 'cd'.repeat(16), 0, 10)) === null, 'a sealed key with no key row: null');

console.log('media read: all checks passed (' + checks + ')');
