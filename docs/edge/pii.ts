// pii — what a payer types, kept where a stolen copy of the database cannot
// read it (2026-10-30, migration 054).
//
// THE THREAT. A copy of the database leaving with someone else: a backup file
// that leaks, a service key pasted where it should not be, a dump taken by
// whoever got in. Every KPay number and transaction id ever filed was in it
// as plain text. Now three things are kept instead of each one:
//
//   SEALED  AES-256-GCM, a fresh 12-byte IV each time, the row and the column
//           as associated data — a sealed value moved to another row or column
//           does not open. `p1.<iv>.<ciphertext+tag>`, base64url. Opened only
//           by the edge function, for an operator who passed the console gate.
//   INDEX   HMAC-SHA256 of the normalised value under a second key: the same
//           transaction typed twice gives the same index, so a reused number
//           is still caught (premium-request 5c) without the number being
//           stored. A plain SHA-256 would not do: transaction ids and phone
//           numbers are short enough to hash every possible one; without the
//           key there is nothing to try them against.
//   MASK    what the payer is shown of their own request: `09•••••789`.
//
// THE KEYS are two Edge Function secrets, PII_ENC_KEY and PII_INDEX_KEY (32
// random bytes each, base64), never in the database and never in the app. With
// neither set the function stores as it always did, so nothing breaks before
// the owner adds them. Lose PII_ENC_KEY and the sealed values are gone for
// good; keep a copy of both somewhere safe.
//
// No Deno API here, so `node tool/js/pii_test.mjs` runs it as it is.

export type PiiKeys = { enc: CryptoKey; index: CryptoKey };

const VERSION = 'p1';

function fromB64(s: string): Uint8Array | null {
  try {
    const bin = atob(s.trim());
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function toB64url(b: Uint8Array): string {
  let s = '';
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromB64url(s: string): Uint8Array | null {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  return fromB64(s.replace(/-/g, '+').replace(/_/g, '/') + pad);
}

/// The two keys, or null when either is missing or not 32 bytes.
export async function piiKeys(encB64: string, indexB64: string): Promise<PiiKeys | null> {
  const enc = fromB64(encB64 ?? '');
  const index = fromB64(indexB64 ?? '');
  if (!enc || enc.length !== 32 || !index || index.length !== 32) return null;
  return {
    enc: await crypto.subtle.importKey('raw', enc, 'AES-GCM', false, ['encrypt', 'decrypt']),
    index: await crypto.subtle.importKey('raw', index, { name: 'HMAC', hash: 'SHA-256' },
      false, ['sign']),
  };
}

/// [aad] names where the value lives: `premium_requests:reference:<row id>`.
export async function seal(keys: PiiKeys, value: string, aad: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(aad) },
    keys.enc, new TextEncoder().encode(value)));
  return `${VERSION}.${toB64url(iv)}.${toB64url(ct)}`;
}

/// The value, or null when it is not one of ours, was moved, or was altered.
export async function open(keys: PiiKeys, sealed: string, aad: string): Promise<string | null> {
  const parts = String(sealed ?? '').split('.');
  if (parts.length !== 3 || parts[0] !== VERSION) return null;
  const iv = fromB64url(parts[1]);
  const ct = fromB64url(parts[2]);
  if (!iv || iv.length !== 12 || !ct) return null;
  try {
    const pt = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(aad) }, keys.enc, ct);
    return new TextDecoder().decode(pt);
  } catch {
    return null;
  }
}

/// [kind] keeps one column's index from matching another's.
export async function blindIndex(keys: PiiKeys, kind: string, normalised: string): Promise<string> {
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', keys.index,
    new TextEncoder().encode(`${kind}:${normalised}`)));
  return Array.from(mac, (b) => b.toString(16).padStart(2, '0')).join('');
}

/// A transaction id as compared: no spaces, dashes or dots, upper case —
/// the ways people type the same number differently.
export function normaliseReference(ref: string): string {
  return String(ref ?? '').replace(/[^0-9A-Za-z]/g, '').toUpperCase();
}

/// A Myanmar mobile number as compared: digits, +95 / 95 / 0 alike.
export function normalisePhone(phone: string): string {
  let d = String(phone ?? '').replace(/\D/g, '');
  if (d.startsWith('95') && d.length >= 10) d = '0' + d.slice(2);
  return d;
}

export function maskPhone(phone: string): string {
  const d = normalisePhone(phone);
  if (d.length <= 5) return '•'.repeat(Math.max(3, d.length));
  return d.slice(0, 2) + '•'.repeat(d.length - 5) + d.slice(-3);
}

export function maskReference(ref: string): string {
  const r = normaliseReference(ref);
  if (r.length <= 4) return '•'.repeat(Math.max(3, r.length));
  return '•'.repeat(Math.min(6, r.length - 4)) + r.slice(-4);
}

// ── WHOLE FILES (2026-10-30): the daily database backup ──────────────────
//
// The backup (ingest.ts) is every table and the account list. It is sealed
// under a key DERIVED from PII_ENC_KEY (HKDF-SHA256, its own label), so the
// owner keeps one secret, not two, and a key made for one purpose never does
// another's work. `IBK1`, the IV, then the ciphertext and tag. Opened only by
// the console's download (studio.ts backupUrl), for the owner past the 2-step.

const FILE_MAGIC = new TextEncoder().encode('IBK1');

/// An AES-256-GCM key derived from PII_ENC_KEY for one use, named by [info].
export async function derivedKey(encB64: string, info: string): Promise<CryptoKey | null> {
  const raw = fromB64(encB64 ?? '');
  if (!raw || raw.length !== 32) return null;
  const ikm = await crypto.subtle.importKey('raw', raw, 'HKDF', false, ['deriveKey']);
  return await crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32), info: new TextEncoder().encode(info) },
    ikm, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}

export function isSealedFile(bytes: Uint8Array): boolean {
  return bytes.length > 4 + 12 + 16 && FILE_MAGIC.every((b, i) => bytes[i] === b);
}

export async function sealFile(key: CryptoKey, bytes: Uint8Array, aad: string): Promise<Uint8Array> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(aad) }, key, bytes));
  const out = new Uint8Array(FILE_MAGIC.length + iv.length + ct.length);
  out.set(FILE_MAGIC, 0);
  out.set(iv, FILE_MAGIC.length);
  out.set(ct, FILE_MAGIC.length + iv.length);
  return out;
}

/// The file, or null when it is not sealed, not ours, or altered.
export async function openFile(key: CryptoKey, sealed: Uint8Array, aad: string): Promise<Uint8Array | null> {
  if (!isSealedFile(sealed)) return null;
  const iv = sealed.slice(4, 16);
  try {
    return new Uint8Array(await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(aad) }, key, sealed.slice(16)));
  } catch {
    return null;
  }
}

/// The derivation label and the associated data of a database backup: the
/// same in ingest.ts, which seals, and studio.ts, which opens.
export const BACKUP_KEY_INFO = 'innocent-db-backup-v1';
export const BACKUP_AAD = 'innocent-db-backup';

/// Standard base64 of bytes, in pieces: a backup is too long for one
/// `String.fromCharCode(...bytes)`.
export function toB64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
}
