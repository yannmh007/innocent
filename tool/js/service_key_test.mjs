// docs/edge/service_key.js: the Supabase keys, from wherever the project keeps
// them, and the headers that carry them (docs/security_review_2026_11.md S1).
//
// WHY. Supabase retires the legacy JWT keys by the end of 2026. Their
// replacements are not JWTs and are refused in `Authorization: Bearer`. Pinned
// here: a legacy key is chosen and sent exactly as before (both headers); a
// new key goes in `apikey` alone, including through supabase-js; `prefer:
// 'new'` falls back to the legacy key on a project without new keys; nothing
// about a key's value reaches a log; and no edge function reads a key or
// builds a key header any other way.
//
//   node tool/js/service_key_test.mjs

import { readFileSync, readdirSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const sk = await import(join(ROOT, 'docs/edge/service_key.js'));
let failed = 0;
const check = (what, ok) => {
  if (ok) console.log('ok   ' + what);
  else { failed += 1; console.log('FAIL ' + what); }
};

// Shapes only; none of these is a real key. The JWTs are joined at run
// time so that no line holds a whole one (Semgrep's detected-jwt-token).
const JWT_SVC = ['eyJhbGciOiJIUzI1NiJ9', 'eyJyb2xlIjoic2VydmljZV9yb2xlIn0', 'c2lnbmF0dXJlLXNlcnZpY2U'].join('.');
const JWT_ANON = ['eyJhbGciOiJIUzI1NiJ9', 'eyJyb2xlIjoiYW5vbiJ9', 'c2lnbmF0dXJlLWFub24'].join('.');
const SECRET = 'sb_secret_' + 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p';
const SECRET2 = 'sb_secret_' + 'Zz9Yy8Xx7Ww6Vv5Uu4Tt3Ss2Rr1Qq0P';
const PUB = 'sb_publishable_' + 'Pp1Oo2Nn3Mm4Ll5Kk6Jj7Ii8Hh9Gg0F';
const env = (o) => (name) => o[name];

const today = env({ SUPABASE_SERVICE_ROLE_KEY: JWT_SVC, SUPABASE_ANON_KEY: JWT_ANON });
const both = env({
  SUPABASE_SERVICE_ROLE_KEY: JWT_SVC, SUPABASE_ANON_KEY: JWT_ANON,
  SUPABASE_SECRET_KEYS: JSON.stringify({ default: SECRET, billing: SECRET2 }),
  SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: PUB }),
});

// The choice every function made before this file, unchanged by default.
let k = sk.pickKey(today, 'service');
check('legacy only: the legacy service key, as before', k.key === JWT_SVC && k.source === 'SUPABASE_SERVICE_ROLE_KEY' && k.shape === 'jwt');
k = sk.pickKey(both, 'service');
check('both kinds, default prefer: still the legacy key (no change on deploy)', k.key === JWT_SVC);
k = sk.pickKey(env({ SB_SERVICE_KEY: JWT_SVC, SUPABASE_SECRET_KEYS: JSON.stringify({ default: SECRET }) }), 'service');
check('the owner\'s SB_SERVICE_KEY wins by default', k.source === 'SB_SERVICE_KEY');
k = sk.pickKey(env({ SUPABASE_SECRET_KEYS: JSON.stringify({ default: SECRET }) }), 'service');
check('legacy gone: the platform\'s default secret key, not nothing', k.key === SECRET && k.source === 'SUPABASE_SECRET_KEYS.default');

// prefer: 'new'
k = sk.pickKey(both, 'service', { prefer: 'new' });
check('prefer new: the default secret key', k.key === SECRET && k.shape === 'secret');
k = sk.pickKey(today, 'service', { prefer: 'new' });
check('prefer new on a project without new keys: the legacy key, as before', k.key === JWT_SVC);
k = sk.pickKey(env({ SB_SERVICE_KEY: JWT_SVC, SUPABASE_SECRET_KEYS: JSON.stringify({ default: SECRET }) }), 'service', { prefer: 'new' });
check('prefer new: a legacy SB_SERVICE_KEY gives way to the new key', k.key === SECRET);
k = sk.pickKey(env({ SB_SERVICE_KEY: SECRET2, SUPABASE_SECRET_KEYS: JSON.stringify({ default: SECRET }) }), 'service', { prefer: 'new' });
check('prefer new: the owner\'s own new key first', k.key === SECRET2 && k.source === 'SB_SERVICE_KEY');
k = sk.pickKey(both, 'public', { prefer: 'new' });
check('prefer new: the publishable key for the public side', k.key === PUB && k.source === 'SUPABASE_PUBLISHABLE_KEYS.default');
k = sk.pickKey(both, 'public');
check('public, default prefer: the legacy anon key, as before', k.key === JWT_ANON);
k = sk.pickKey(env({ SUPABASE_SECRET_KEYS: 'not json' }), 'service', { prefer: 'new' });
check('nothing usable: an empty key that says NONE (the function refuses, as before)', k.key === '' && k.source === 'NONE' && k.shape === 'none');
k = sk.pickKey(env({ SUPABASE_SECRET_KEYS: JSON.stringify({ other: SECRET }) }), 'service');
check('a key not named default is not taken', k.key === '');

// Headers
let h = sk.keyHeaders(JWT_SVC);
check('a legacy key: apikey and Bearer, exactly as before', h.apikey === JWT_SVC && h.Authorization === 'Bearer ' + JWT_SVC && Object.keys(h).length === 2);
h = sk.keyHeaders(SECRET);
check('a secret key: apikey only, never Bearer', h.apikey === SECRET && !('Authorization' in h));

// keyFetch: what supabase-js sends, as the platform documents it
const seen = [];
const base = async (input, init) => { seen.push(new Headers(init.headers)); return new Response('[]'); };
await sk.keyFetch(SECRET, base)('https://x/rest/v1/t', { headers: { apikey: SECRET, Authorization: 'Bearer ' + SECRET } });
check('supabase-js with a secret key: its Bearer copy of the key is removed', !seen[0].has('Authorization') && seen[0].get('apikey') === SECRET);
await sk.keyFetch(SECRET, base)('https://x/auth/v1/user', { headers: { apikey: SECRET, Authorization: 'Bearer ' + JWT_ANON } });
check('a user\'s own token is left alone', seen[1].get('Authorization') === 'Bearer ' + JWT_ANON);
check('a legacy key: fetch is not wrapped at all', sk.keyFetch(JWT_SVC, base) === base);
check('clientOptions carries the fetch', typeof sk.clientOptions(SECRET).global.fetch === 'function');

// Facts: names and shapes, never a value
const facts = sk.keyFacts(both, { prefer: 'new' });
const text = JSON.stringify(facts);
check('facts: sources and shapes', facts.service.shape === 'secret' && facts.public.shape === 'publishable' &&
  facts.legacy_service === 'jwt' && facts.secret_keys.join() === 'default,billing');
check('facts never carry a key', ![JWT_SVC, JWT_ANON, SECRET, SECRET2, PUB].some((v) => text.includes(v)) &&
  !/eyJ|sb_secret_|sb_publishable_[A-Za-z0-9]/.test(text));

// Every edge function reads its keys here, and builds no key header itself.
const EDGE = join(ROOT, 'docs/edge');
const bad = [];
for (const f of readdirSync(EDGE).filter((n) => n.endsWith('.ts'))) {
  const src = readFileSync(join(EDGE, f), 'utf8');
  const code = src.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
  for (const [re, what] of [
    [/Bearer \$\{SERVICE_KEY\}/, 'a Bearer header built from SERVICE_KEY'],
    [/Bearer \$\{key\}/, 'a Bearer header built from a key'],
    [/Deno\.env\.get\(['"](SUPABASE_SERVICE_ROLE_KEY|SUPABASE_ANON_KEY|SB_SERVICE_KEY|SB_ANON_KEY)['"]\)/, 'a key read from the environment directly'],
    [/createClient\([^,]+,\s*SERVICE_KEY\s*\)/, 'createClient with the service key and no keyFetch'],
  ]) {
    if (re.test(code)) bad.push(`${f}: ${what}`);
  }
}
check('no edge function reads a key or builds a key header itself' + (bad.length ? ': ' + bad.join('; ') : ''), bad.length === 0);

if (failed) {
  console.log(`\n${failed} check(s) FAILED`);
  process.exit(1);
}
console.log('\n=== all checks on the Supabase keys passed ===');
