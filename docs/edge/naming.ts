// naming — R2 object keys that say nothing about what they hold
// (2026-10-30). Used by studio.ts (the console's uploads).
//
// WHY. A key used to be `<folder>/<video|photo|thumb>/<date>-<file name>-<8
// hex>.<ext>`, the folder being what the operator typed for the title. A list
// of the bucket — a leaked R2 token, a log, a public photo's URL — read as a
// catalogue. With the Edge secret R2_NAMING_KEY set, a new title's files go to
//
//   f/<20 hex>/<video|photo|thumb>/<32 hex>.<ext>
//
// FOLDER  HMAC-SHA256 of the folder the operator typed, under that key, cut to
//         80 bits: the same name is always the same folder (an upload resumed
//         tomorrow finds it, a second title cannot take it), and without the
//         key nobody can work back from a folder to a name, or test guesses
//         against it — a plain SHA-256 of a film's name could be tested
//         against every film's name. What the operator typed is kept as the
//         folder's display name (r2_folder_labels), so the console's Files
//         page reads as before.
// FILE    122 random bits. The name a phone gave the file says nothing to
//         anyone after the upload, and is not kept.
//
// The kind segment stays: it says which bucket and which checks apply
// (isMintedKey, record_frames), and "a video" is not a secret.
//
// Without the secret, keys are made as before. Files already in R2 keep their
// keys: moving them would cost a copy of every file and a window in which the
// catalogue points at nothing.
//
// No Deno API here, so `node tool/js/naming_test.mjs` runs it as it is.

export const OPAQUE_FOLDER = /^f\/[0-9a-f]{20}$/;

/// The naming key, or null when it is missing or not 32 bytes.
export async function namingKey(b64: string): Promise<CryptoKey | null> {
  let raw: Uint8Array;
  try {
    const bin = atob(String(b64 ?? '').trim());
    raw = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
  if (raw.length !== 32) return null;
  return await crypto.subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-256' },
    false, ['sign']);
}

/// The folder for a name the operator typed, already reduced to the
/// alphabet a path may use (studio.ts slugifyPath).
export async function opaqueFolder(key: CryptoKey, folder: string): Promise<string> {
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key,
    new TextEncoder().encode(`r2-folder:${folder}`)));
  return 'f/' + Array.from(mac.slice(0, 10), (b) => b.toString(16).padStart(2, '0')).join('');
}

/// A file name that is only a file name: random, with the extension kept
/// (players and browsers still go by it).
export function opaqueName(ext: string): string {
  const e = String(ext ?? '').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 8);
  const id = crypto.randomUUID().replace(/-/g, '');
  return e ? `${id}.${e}` : id;
}
