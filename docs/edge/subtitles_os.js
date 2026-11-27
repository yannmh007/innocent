// OpenSubtitles.com's REST API (v1), the parts subtitles-online.ts uses —
// plain enough to test in node (tool/js/subtitles_os_test.mjs). Nothing
// here holds or sees a secret: the key and the login are the handler's.
//
// Read off OpenSubtitles' own client (github.com/opensubtitles/
// service.subtitles.opensubtitles-com, resources/lib/osclient/provider.py,
// 27 Nov 2026): base https://api.opensubtitles.com/api/v1/; every call
// carries `Api-Key` and a `User-Agent` naming the app and its version;
// GET subtitles (a search; the key alone); POST login {username,
// password} → token (the client keeps it 20 h and logs in again on a 401);
// POST download {file_id, sub_format} with `Authorization: Bearer` →
// {link, remaining, reset_time_utc, …}, the link fetched once for the
// file; 406 = the day's downloads are spent, 429 = too fast (Retry-After).

export const API = 'https://api.opensubtitles.com/api/v1/';

/** A login's `base_url`, when it names another OpenSubtitles API host. */
export function apiFor(baseUrl) {
  const h = String(baseUrl ?? '').trim().toLowerCase().replace(/^https?:\/\//, '').replace(/\/.*$/, '');
  return /^[a-z0-9-]+(\.[a-z0-9-]+)*\.opensubtitles\.com$/.test(h)
    ? `https://${h}/api/v1/` : API;
}

const LANG = /^[a-z]{2}(-[a-z]{2})?$/;
const HASH = /^[0-9a-f]{16}$/;

/** Language codes from a list or 'en,my': lower case, known shape, at most 4. */
export function languages(v) {
  const list = (Array.isArray(v) ? v : String(v ?? '').split(','))
    .map((s) => String(s).trim().toLowerCase())
    .filter((s) => LANG.test(s));
  return [...new Set(list)].slice(0, 4).sort();
}

/**
 * The search's query string from what the app sent, or an error. The
 * parameters go sorted and in lower case (one URL per search).
 * @param {{query?: string, moviehash?: string, languages?: string|string[],
 *          season?: number, episode?: number, page?: number}} input
 * @returns {{params: string} | {error: string}}
 */
export function searchParams(input) {
  const p = {};
  const q = String(input?.query ?? '').normalize('NFC').replace(/\s+/g, ' ').trim().toLowerCase();
  if (q.length > 120) return { error: 'query too long' };
  if (q) p.query = q;
  const h = String(input?.moviehash ?? '').trim().toLowerCase();
  if (h) {
    if (!HASH.test(h)) return { error: 'moviehash must be 16 hex digits' };
    p.moviehash = h;
  }
  if (!p.query && !p.moviehash) return { error: 'nothing to search for' };
  const langs = languages(input?.languages);
  if (langs.length) p.languages = langs.join(',');
  for (const k of ['season', 'episode']) {
    const n = Number(input?.[k]);
    if (Number.isInteger(n) && n > 0 && n < 1000) p[`${k}_number`] = String(n);
  }
  const page = Number(input?.page);
  if (Number.isInteger(page) && page > 1 && page <= 5) p.page = String(page);
  const keys = Object.keys(p).sort();
  return { params: keys.map((k) => `${k}=${encodeURIComponent(p[k])}`).join('&') };
}

/**
 * The answer's subtitles, one row per file, for the app's list — never a
 * link or anything of the uploader's but a name.
 * @param {any} json OpenSubtitles' search answer
 * @param {string[]} wanted the languages asked for, first wanted first
 */
export function shapeSearch(json, wanted = []) {
  const rows = [];
  for (const d of Array.isArray(json?.data) ? json.data : []) {
    const a = d?.attributes ?? {};
    const f = a.feature_details ?? {};
    for (const file of Array.isArray(a.files) ? a.files : []) {
      const id = Number(file?.file_id);
      if (!Number.isSafeInteger(id) || id <= 0) continue;
      rows.push({
        file_id: id,
        lang: String(a.language ?? '').slice(0, 8),
        release: String(a.release ?? '').slice(0, 160),
        name: String(file?.file_name ?? '').slice(0, 160),
        downloads: Number(a.download_count) || 0,
        hi: a.hearing_impaired === true,
        ai: a.ai_translated === true || a.machine_translated === true,
        fps: Number(a.fps) || 0,
        hash_match: a.moviehash_match === true,
        title: String(f.title ?? f.movie_name ?? '').slice(0, 160),
        year: Number(f.year) || 0,
      });
      if (rows.length >= 60) break;
    }
    if (rows.length >= 60) break;
  }
  const rank = (l) => {
    const i = wanted.indexOf(l);
    return i < 0 ? wanted.length : i;
  };
  // The film's own file first, then the language asked first, then the
  // most downloaded; a machine translation last within its language.
  rows.sort((x, y) => (Number(y.hash_match) - Number(x.hash_match)) ||
    (rank(x.lang) - rank(y.lang)) || (Number(x.ai) - Number(y.ai)) ||
    (y.downloads - x.downloads));
  return rows.slice(0, 40);
}

/** The download's body: the file as SubRip. */
export function downloadBody(fileId) {
  const id = Number(fileId);
  if (!Number.isSafeInteger(id) || id <= 0) return null;
  return { file_id: id, sub_format: 'srt' };
}

/** Seconds until the downloads come back: the answer's reset time, else
 *  the next UTC midnight; at least a minute. */
export function secondsToReset(json, now = Date.now()) {
  const t = Date.parse(String(json?.reset_time_utc ?? ''));
  const at = Number.isFinite(t) && t > now ? t
    : Date.UTC(new Date(now).getUTCFullYear(), new Date(now).getUTCMonth(), new Date(now).getUTCDate() + 1);
  return Math.max(60, Math.ceil((at - now) / 1000));
}

/** A Retry-After header's seconds (10 when absent or odd, at most an hour). */
export function retryAfter(header) {
  const n = Number(header);
  return Number.isFinite(n) && n > 0 ? Math.min(3600, Math.ceil(n)) : 10;
}

/** The file name the app saves it under: the name given, made safe. */
export function safeName(name, fileId) {
  const base = String(name ?? '').replace(/\.[a-z0-9]{2,4}$/i, '')
    .replace(/[^\p{L}\p{N} ._()-]+/gu, ' ').replace(/\.{2,}/g, ' ')
    .replace(/\s+/g, ' ').replace(/^[ .]+/, '').trim().slice(0, 80);
  return `${base || `subtitle-${Number(fileId) || 0}`}.srt`;
}
