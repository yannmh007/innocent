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

// The original is sealed only when it is in R2, and the refusal exists.
check('the original is sealed only when it is in R2',
  /const masterUrl = masterInR2 \? await workerUrl\(objectKey, who\) : null;/.test(src));
check('no URL at all is a refusal, logged',
  /if \(!url\) \{[\s\S]{0,400}logRefusal\(masterInR2 \? 'no_url' : 'master_in_telegram'/.test(src));

// v4: FAILS CLOSED. No presigned S3 URL anywhere — it names the account, the
// bucket, the key and the access key id — and no Worker secrets is a refusal.
check('request-playback presigns nothing (v4)',
  !/presign\(/.test(src) && !/X-Amz-/.test(src) && !/R2_SECRET_ACCESS_KEY/.test(src));
check('no Worker secrets is a 503, before any URL is made',
  /if \(!STREAM_BASE \|\| !STREAM_TOKEN_SECRET\) \{\s*logRefusal\('stream_not_configured'[\s\S]{0,80}503\)/.test(src) &&
  src.indexOf("'stream_not_configured'") < src.indexOf('const masterUrl ='));
check('a rung whose token cannot be sealed is left out, not presigned',
  /const rUrl = await workerUrl\(key, who\);\s*if \(!rUrl\) continue;/.test(src));

// v4: a premium grant needs the install id; without it the two-device count
// was skipped.
{
  const prem = src.slice(src.indexOf("if (title.access_tier !== 'free' && !assetIsFree)"),
    src.indexOf('NOT CONFIGURED IS CLOSED'));
  check('premium without a device id is refused',
    /if \(!deviceId\) \{[\s\S]{0,300}return json\(\{ code: 'bad_request' \}, 400\)/.test(prem));
  check('and the device count is no longer optional',
    !/if \(deviceId\) \{/.test(prem));
}

// v4: the budget is taken once, for a grant about to be made, after every
// entitlement check; over it is 429 rate_limited with a wait; and a budget
// that cannot be read does not stop playback.
{
  const at = src.indexOf("admin.rpc(\n      'take_playback_budget'");
  check('the budget is taken through take_playback_budget', at > 0);
  check('after the subscription and device checks',
    at > src.indexOf("return json({ code: 'wrong_device' }, 409)") &&
    at > src.indexOf("return json({ code: 'needs_premium' }, 403)"));
  check('before any token is sealed', at < src.indexOf('const masterUrl ='));
  check('with the title from the database, not the request',
    /p_title: title\.id/.test(src));
  check('over budget: 429 rate_limited, retry_after and Retry-After',
    /code: 'rate_limited', retry_after: wait/.test(src) && /status: 429/.test(src) &&
    /'Retry-After': String\(wait\)/.test(src));
  check('a budget error is logged and playback goes on',
    /if \(budgetErr\) \{\s*logRefusal\('budget_unavailable'/.test(src) &&
    /catch \(e\) \{\s*logRefusal\('budget_unavailable'/.test(src));
  check('a token is bound only when the app asked',
    /if \(body\.bind === true\) who\.b = 1;/.test(src));
}
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
