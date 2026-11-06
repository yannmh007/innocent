// The project's two Supabase keys — the service key and the public one —
// read from wherever this project keeps them, and the headers that carry
// them (docs/security_review_2026_11.md S1/P1).
//
// WHY THIS EXISTS. Supabase retires the legacy JWT keys (`service_role`,
// `anon`) by the end of 2026. Their replacements, `sb_secret_…` and
// `sb_publishable_…`, are not JWTs and belong in the `apikey` header only:
// "Send publishable and secret keys on the apikey header only. If you also
// pass the key on the Authorization: Bearer header … the platform tries to
// parse it as a JWT and rejects the request with Invalid JWT" (Supabase,
// "Migrating to publishable and secret API keys"). Every call here used to
// send the service key in both headers. A legacy key still gets exactly
// those two headers; a new one gets `apikey` alone.
//
// WHERE A KEY COMES FROM:
//
//   SB_SERVICE_KEY / SB_ANON_KEY         set by the owner, either shape
//   SUPABASE_SECRET_KEYS /               injected by the platform: JSON by
//     SUPABASE_PUBLISHABLE_KEYS            key name; `default` is the one used
//   SUPABASE_SERVICE_ROLE_KEY /          injected, legacy
//     SUPABASE_ANON_KEY
//
// `prefer: 'legacy'` (the default until the canary proves the new keys)
// keeps the choice every function made before this file: the owner's key,
// else the legacy one, else (only when both are missing) the new one.
// `prefer: 'new'` takes the first new-shaped key, owner's then platform's,
// and falls back to the legacy choice when there is none — so a function
// switched to 'new' on a project without new keys works exactly as before.
//
// NEVER LOGGED, NEVER RETURNED: a key's value. `keyFacts` says which names
// are set and what shape each key has, nothing more.

const JWT = /^eyJ[\w-]+\.[\w-]+\.[\w-]+$/;
const NEW = /^sb_(secret|publishable)_[\w-]+$/;

/** @param {string} k */
export const isJwt = (k) => JWT.test(String(k ?? ''));
/** @param {string} k */
export const isNewKey = (k) => NEW.test(String(k ?? ''));

/** @param {string} k @returns {'none'|'jwt'|'secret'|'publishable'|'other'} */
export function keyShape(k) {
  const s = String(k ?? '');
  if (!s) return 'none';
  if (isJwt(s)) return 'jwt';
  if (s.startsWith('sb_secret_')) return 'secret';
  if (s.startsWith('sb_publishable_')) return 'publishable';
  return 'other';
}

/** The `default` key out of SUPABASE_SECRET_KEYS / _PUBLISHABLE_KEYS. */
function fromJson(raw, name = 'default') {
  if (!raw) return '';
  try {
    const o = JSON.parse(raw);
    const v = o && typeof o === 'object' ? o[name] : '';
    return typeof v === 'string' ? v : '';
  } catch (_) {
    return '';
  }
}

/** The key names in SUPABASE_SECRET_KEYS / _PUBLISHABLE_KEYS (names only). */
function namesIn(raw) {
  if (!raw) return [];
  try {
    const o = JSON.parse(raw);
    return o && typeof o === 'object' ? Object.keys(o).filter((k) => typeof o[k] === 'string') : [];
  } catch (_) {
    return [];
  }
}

const NAMES = {
  service: { own: 'SB_SERVICE_KEY', platform: 'SUPABASE_SECRET_KEYS', legacy: 'SUPABASE_SERVICE_ROLE_KEY' },
  public: { own: 'SB_ANON_KEY', platform: 'SUPABASE_PUBLISHABLE_KEYS', legacy: 'SUPABASE_ANON_KEY' },
};

/**
 * @param {(name: string) => string | undefined} get   Deno.env.get, or a stand-in
 * @param {'service'|'public'} kind
 * @param {{prefer?: 'legacy'|'new'}} [opts]
 * @returns {{key: string, source: string, shape: string}}
 */
export function pickKey(get, kind, { prefer = 'legacy' } = {}) {
  const n = NAMES[kind];
  if (!n) throw new Error('pickKey: kind is service or public');
  const own = { key: get(n.own) ?? '', source: n.own };
  const platform = { key: fromJson(get(n.platform)), source: n.platform + '.default' };
  const legacy = { key: get(n.legacy) ?? '', source: n.legacy };
  const order = prefer === 'new'
    ? [own, platform].filter((c) => isNewKey(c.key)).concat([own, legacy, platform])
    : [own, legacy, platform];
  const hit = order.find((c) => c.key) ?? { key: '', source: 'NONE' };
  return { key: hit.key, source: hit.source, shape: keyShape(hit.key) };
}

/**
 * The headers that carry a key on a call made with that key's authority.
 * A legacy JWT: `apikey` and `Authorization: Bearer`, as before. Any other
 * key: `apikey` only.
 * @param {string} key
 * @returns {Record<string, string>}
 */
export function keyHeaders(key) {
  return isJwt(key) ? { apikey: key, Authorization: `Bearer ${key}` } : { apikey: key };
}

/**
 * A fetch for supabase-js: supabase-js puts its key in `Authorization:
 * Bearer` when no session token is given. For a key that is not a JWT this
 * removes exactly that header, so the call goes out the documented way
 * (`apikey` alone); a user's own token, or anything else, is left alone.
 * @param {string} key
 * @param {typeof fetch} [base]
 */
export function keyFetch(key, base) {
  const send = base ?? ((input, init) => fetch(input, init));
  if (!key || isJwt(key)) return send;
  const bearer = `Bearer ${key}`;
  return (input, init = {}) => {
    const from = init.headers ?? (typeof Request !== 'undefined' && input instanceof Request ? input.headers : undefined);
    const h = new Headers(from);
    if (h.get('Authorization') === bearer) h.delete('Authorization');
    return send(input, { ...init, headers: h });
  };
}

/** Options for `createClient(url, key, …)` that carry `keyFetch`. */
export function clientOptions(key) {
  return { global: { fetch: keyFetch(key) } };
}

/**
 * What a boot log may say about the keys: names set, shapes, sources.
 * @param {(name: string) => string | undefined} get
 * @param {{prefer?: 'legacy'|'new'}} [opts]
 */
export function keyFacts(get, opts = {}) {
  const s = pickKey(get, 'service', opts);
  const p = pickKey(get, 'public', opts);
  return {
    service: { source: s.source, shape: s.shape },
    public: { source: p.source, shape: p.shape },
    own_service: keyShape(get('SB_SERVICE_KEY')),
    own_public: keyShape(get('SB_ANON_KEY')),
    secret_keys: namesIn(get('SUPABASE_SECRET_KEYS')),
    publishable_keys: namesIn(get('SUPABASE_PUBLISHABLE_KEYS')),
    legacy_service: keyShape(get('SUPABASE_SERVICE_ROLE_KEY')),
    legacy_public: keyShape(get('SUPABASE_ANON_KEY')),
    prefer: opts.prefer ?? 'legacy',
  };
}
