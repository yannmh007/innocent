// What request-playback puts in `url` — the field every installed app reads
// and every offline download fetches.
//
// WHY. The storage policy (migration 029) can leave a film's original only in
// Telegram once its streaming copies exist. `url` used to be the original,
// unconditionally; signed for a key with nothing behind it, every app older
// than the ladder — and every download — would get a URL to nothing. So the
// rule is pinned here: the original while it is in R2 (exactly as before),
// the best streaming copy when it is not, nothing (and a refusal) when there
// is neither. And the function must never sign the original's key when the
// original is not in R2.
//
//   node tool/js/playback_url_test.mjs

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
let failed = 0;
const check = (what, ok) => {
  if (ok) console.log('ok   ' + what);
  else { failed += 1; console.log('FAIL ' + what); }
};

const src = readFileSync(join(ROOT, 'docs/edge/request-playback.ts'), 'utf8');
const m = /function primaryUrl\(([\s\S]*?)\): string \| null \{([\s\S]*?)\n\}/.exec(src);
check('primaryUrl is where it should be', !!m);
const body = m[2].replace(/: Record<string, unknown> \| null/g, '');
const primaryUrl = new Function('masterUrl', 'ladder', body);

const ladder = [
  { height: 360, kbps: 700, url: 'L360' },
  { height: 1080, kbps: 5000, url: 'L1080' },
  { height: 720, kbps: 2500, url: 'L720' },
];
check('the original, while it is in R2', primaryUrl('MASTER', ladder) === 'MASTER');
check('the original with no ladder, exactly as before', primaryUrl('MASTER', []) === 'MASTER');
check('only in Telegram: the best streaming copy', primaryUrl(null, ladder) === 'L1080');
check('only in Telegram and no ladder: nothing', primaryUrl(null, []) === null);
check('a rung with no URL is never chosen',
  primaryUrl(null, [{ kbps: 9000, url: '' }, { kbps: 100, url: 'small' }]) === 'small');

// The original is signed only when it is in R2, and the refusal exists.
check('the original is signed only when it is in R2',
  /const viaWorker = masterInR2 \? await workerUrl\(objectKey\) : null;/.test(src) &&
  /const masterUrl = masterInR2 \? \(viaWorker \?\? await presign\(objectKey\)\) : null;/.test(src));
check('no URL at all is a refusal, logged', /if \(!url\) \{[\s\S]{0,300}logRefusal\('master_in_telegram'/.test(src));
check('an asset played by id reads where its original is',
  /select\('id, object_key, is_free, title_id, kind, master_state'\)/.test(src));
check('a title played by its locator reads it too',
  /select\('id, master_state'\)[\s\S]{0,200}masterInR2 = byKey\.master_state/.test(src));
check('both read "restoring" as not in R2 yet',
  (src.match(/master_state !== 'telegram' && [\w.]+master_state !== 'restoring'/g) || []).length === 2);

if (failed) {
  console.log(`${failed} playback url check(s) failed`);
  process.exit(1);
}
console.log('playback url: all checks passed');
