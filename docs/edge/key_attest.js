// Android Key Attestation: does a phone's media key live in real secure
// hardware, made by our own signed app, on a phone that boots what it should?
// (docs/security_review_2026_11.md S3/P3; docs/MEDIA_ENCRYPTION.md §5)
//
// WHY. request-playback wraps each film's DEK for the RSA key a phone sends
// (`device_key`). Nothing checked where that key came from: a script on a
// computer could make its own key pair and receive keys it can open. Since
// Android 7, Keystore can certify a key it generated: the key's own
// certificate carries a KeyDescription extension (OID 1.3.6.1.4.1.11129.2.1.17)
// and chains up to Google's attestation root. The DEK is wrapped for the
// key, so a copied chain is useless without the phone: whoever replays
// someone else's genuine chain receives DEKs only that phone can open.
//
// WHAT THIS CHECKS, and what `verdict()` reports:
//   chain     every certificate is signed by the next; the last is, or is
//             signed by, one of Google's two attestation roots (pinned by
//             public key below: the RSA-4096 root, and the ECDSA P-384
//             "Key Attestation CA1" root brought in 2025-26 for phones with
//             Remote Key Provisioning). Validity is checked for every
//             certificate above the leaf; a phone's clock sets the leaf's.
//   revoked   any serial in Google's status list
//             (https://android.googleapis.com/attestation/status), which is
//             how leaked factory keys are switched off
//   key       the leaf certifies the very key the phone sent
//   challenge what the app asked Keystore to put in it
//   level     software / tee / strongbox (attestation and KeyMint)
//   boot      verifiedBootState and deviceLocked (an unlocked or modified
//             phone says so here, unless its hardware has been broken)
//   app       our package name and our signing certificate's SHA-256
//
// A PURE FUNCTION OF ITS INPUTS, in Node and Deno (WebCrypto only). It never
// fetches: the caller passes the revocation list it has (`revokedFrom`).
// Nothing here throws on hostile input; a malformed chain is a verdict.

const OID_KEY_DESCRIPTION = '1.3.6.1.4.1.11129.2.1.17';

/** Google's attestation roots, by public key (SubjectPublicKeyInfo, base64). */
export const GOOGLE_ROOTS = {
  // RSA-4096. The same key across the 2016, 2019 and 2022 root
  // certificates (serial f92009e853b6b045 is the 2022 one); SPKI SHA-256
  // feb2ea7551ee316ed4bb443c8293b884dbfdea40b603ee3e4f4a897e4580fbae.
  'google-rsa':
    'MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAr7bHgiuxpwHsK7Qui8xUFmOr75gvMsd/' +
    'dTEDDJdSSxtf6An7xyqpRR90PL2abxM1dEqlXnf2tqw1Ne4Xwl5jlRfdnJLmN0pTy/4lj4/7tv0S' +
    'k3iiKkypnEUtR6WfMgH0QZfKHM1+di+y9TFRtv6y//0rb+T+W8a9nsNL/ggjnar86461qO0rOs2c' +
    'Xjp3kOG1FEJ5MVmFmBGtnrKpa73XpXyTqRxB/M0n1n/W9nGqC4FSYa04T6N5RIZGBN2z2MT5IKGb' +
    'FlbC8UrW0DxW7AYImQQcHtGl/m00QLVWutHQoVJYnFPlXTcHYvASLu+RhhsbDmxMgJJ0mcDpvsC4' +
    'PjvB+TxywElgS70vE0XmLD+OJtvsBslHZvPBKCOdT0MS+tgSOIfga+z1Z1g7+DVagf7quvmag8jf' +
    'PioyKvxnK/EgsTUVi2ghzq8wm27ud/mIM7AY2qEORR8Go3TVB4HzWQgpZrt3i5MIlCaY504LzSRi' +
    'igHCzAPlHws+W0rB5N+er5/2pJKnfBSDiCiFAVtCLOZ7gLiMm0jhO2B6tUXHI/+MRPjy02i59lIN' +
    'MRRev56GKtcd9qO/0kUJWdZTdA2XoS82ixPvZtXQpUpuL12ab+9EaDK8Z4RHJYYfCT3Q5vNAXaiW' +
    'Q+8PTWm2QgBR/bkwSWc+NpUFgNPN9PvQi8WEg5UmAGMCAwEAAQ==',
  // ECDSA P-384, "Key Attestation CA1", 2025-07-17 to 2035-07-15; SPKI
  // SHA-256 3ee44512a1af2beb39c889490c60ea3f82e43f5d5a5532f5ab9419f676cd07ec.
  'google-ec':
    'MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEI9ojcU7fPlsFCjxy6IRqzgeOoK0b+YsV9FPQywiyw8EQ' +
    'RTkJ9u3qwfnI4DGoSLlBqClTXJfgfCcZvs60FikNMHnu4fkRzObfgDkU2KNXezT9/RQ+XvNslxPH' +
    'rHCowhGr',
};

/** Our app: the package and the release signing certificate's SHA-256. */
export const OUR_APP = {
  packageName: 'com.innocent.media',
  signers: ['e3e1effa993ced6745a33f75c97742a3b8badd79d54927d2515538594c85cdb1'],
};

/** What SealDevice.kt asks Keystore to certify the key with. */
export const CHALLENGE = 'inv-media-device-v2';

// ── DER ─────────────────────────────────────────────────────────────────

class Der extends Error {}

function tlv(b, off) {
  if (off + 2 > b.length) throw new Der('short');
  const start = off;
  const first = b[off++];
  const cls = first >> 6;
  const constructed = (first & 0x20) !== 0;
  let num = first & 0x1f;
  if (num === 0x1f) {
    num = 0;
    let x;
    let n = 0;
    do {
      if (off >= b.length || ++n > 4) throw new Der('tag');
      x = b[off++];
      num = num * 128 + (x & 0x7f);
    } while (x & 0x80);
  }
  if (off >= b.length) throw new Der('short');
  let len = b[off++];
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4) throw new Der('length');
    len = 0;
    for (let i = 0; i < n; i++) {
      if (off >= b.length) throw new Der('short');
      len = len * 256 + b[off++];
    }
  }
  const end = off + len;
  if (end > b.length) throw new Der('overrun');
  return { cls, constructed, num, start, body: off, end };
}

function kids(b, t) {
  const out = [];
  let o = t.body;
  while (o < t.end) {
    const c = tlv(b, o);
    out.push(c);
    o = c.end;
  }
  return out;
}

const bytes = (b, t) => b.subarray(t.body, t.end);
const whole = (b, t) => b.subarray(t.start, t.end);
const hex = (u) => Array.from(u, (x) => x.toString(16).padStart(2, '0')).join('');

function oid(b, t) {
  const v = bytes(b, t);
  if (!v.length) throw new Der('oid');
  const parts = [Math.floor(v[0] / 40), v[0] % 40];
  let n = 0;
  for (let i = 1; i < v.length; i++) {
    n = n * 128 + (v[i] & 0x7f);
    if (!(v[i] & 0x80)) {
      parts.push(n);
      n = 0;
    }
  }
  return parts.join('.');
}

function int(b, t) {
  const v = bytes(b, t);
  if (v.length > 6) return Number.NaN; // never needed above 2^48 here
  let n = 0;
  for (const x of v) n = n * 256 + x;
  if (v.length && v[0] & 0x80) n -= 2 ** (8 * v.length);
  return n;
}

function time(b, t) {
  const s = new TextDecoder().decode(bytes(b, t));
  const m = t.num === 23
    ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s)
    : /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s);
  if (!m) return Number.NaN;
  let y = Number(m[1]);
  if (t.num === 23) y += y < 50 ? 2000 : 1900;
  return Date.UTC(y, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
}

// ── X.509 ───────────────────────────────────────────────────────────────

const SIG = {
  '1.2.840.113549.1.1.11': { kind: 'rsa', hash: 'SHA-256' },
  '1.2.840.113549.1.1.12': { kind: 'rsa', hash: 'SHA-384' },
  '1.2.840.113549.1.1.13': { kind: 'rsa', hash: 'SHA-512' },
  '1.2.840.10045.4.3.2': { kind: 'ec', hash: 'SHA-256' },
  '1.2.840.10045.4.3.3': { kind: 'ec', hash: 'SHA-384' },
  '1.2.840.10045.4.3.4': { kind: 'ec', hash: 'SHA-512' },
};
const CURVE = {
  '1.2.840.10045.3.1.7': { name: 'P-256', size: 32 },
  '1.3.132.0.34': { name: 'P-384', size: 48 },
  '1.3.132.0.35': { name: 'P-521', size: 66 },
};

/** One certificate, DER, into the parts verification needs. */
export function parseCert(der) {
  const b = der;
  const cert = tlv(b, 0);
  if (cert.end !== b.length) throw new Der('trailing');
  const [tbs, alg, sigT] = kids(b, cert);
  if (!tbs || !alg || !sigT || sigT.num !== 3) throw new Der('cert');
  let f = kids(b, tbs);
  if (f[0] && f[0].cls === 2 && f[0].num === 0) f = f.slice(1); // [0] version
  const [serialT, , issuerT, validityT, subjectT, spkiT, ...rest] = f;
  if (!spkiT) throw new Der('tbs');
  const [nb, na] = kids(b, validityT);
  const spkiKids = kids(b, spkiT);
  const algKids = kids(b, spkiKids[0]);
  const keyAlg = oid(b, algKids[0]);
  const curve = algKids[1] && algKids[1].num === 6 ? oid(b, algKids[1]) : null;
  const ext = {};
  for (const r of rest) {
    if (r.cls !== 2 || r.num !== 3) continue;
    for (const e of kids(b, kids(b, r)[0])) {
      const ek = kids(b, e);
      const id = oid(b, ek[0]);
      const value = ek[ek.length - 1];
      ext[id] = bytes(b, value);
    }
  }
  let serial = hex(bytes(b, serialT)).replace(/^0+/, '');
  if (!serial) serial = '0';
  const sigBits = bytes(b, sigT);
  return {
    tbs: whole(b, tbs),
    sigAlg: oid(b, kids(b, alg)[0]),
    sig: sigBits.subarray(1),
    serial,
    issuer: whole(b, issuerT),
    subject: whole(b, subjectT),
    notBefore: time(b, nb),
    notAfter: time(b, na),
    spki: whole(b, spkiT),
    keyAlg,
    curve,
    ext,
  };
}

/** ECDSA's DER (r, s) into the fixed-width r||s WebCrypto wants. */
function ecRaw(sig, size) {
  const seq = tlv(sig, 0);
  const [r, s] = kids(sig, seq);
  const out = new Uint8Array(size * 2);
  for (const [i, t] of [[0, r], [1, s]]) {
    let v = bytes(sig, t);
    while (v.length > size && v[0] === 0) v = v.subarray(1);
    if (v.length > size) throw new Der('ecdsa');
    out.set(v, (i + 1) * size - v.length);
  }
  return out;
}

async function verifySig(child, issuerSpki, subtle) {
  const s = SIG[child.sigAlg];
  if (!s) return false;
  const k = parseSpki(issuerSpki);
  if (s.kind === 'rsa' && k.alg === '1.2.840.113549.1.1.1') {
    const key = await subtle.importKey('spki', issuerSpki, { name: 'RSASSA-PKCS1-v1_5', hash: s.hash }, false, ['verify']);
    return subtle.verify('RSASSA-PKCS1-v1_5', key, child.sig, child.tbs);
  }
  if (s.kind === 'ec' && k.alg === '1.2.840.10045.2.1' && CURVE[k.curve]) {
    const c = CURVE[k.curve];
    const key = await subtle.importKey('spki', issuerSpki, { name: 'ECDSA', namedCurve: c.name }, false, ['verify']);
    return subtle.verify({ name: 'ECDSA', hash: s.hash }, key, ecRaw(child.sig, c.size), child.tbs);
  }
  return false;
}

function parseSpki(spki) {
  const t = tlv(spki, 0);
  const a = kids(spki, kids(spki, t)[0]);
  return { alg: oid(spki, a[0]), curve: a[1] && a[1].num === 6 ? oid(spki, a[1]) : null };
}

// ── KeyDescription ──────────────────────────────────────────────────────

const LEVEL = ['software', 'tee', 'strongbox'];
const BOOT = ['verified', 'self-signed', 'unverified', 'failed'];

/** The AuthorizationList's fields this cares about, by tag. */
function authList(b, t) {
  const out = {};
  for (const e of kids(b, t)) {
    if (e.cls !== 2) continue;
    const inner = kids(b, e)[0];
    if (!inner) continue;
    if (e.num === 704) { // rootOfTrust
      const r = kids(b, inner);
      out.rootOfTrust = {
        locked: r[1] ? bytes(b, r[1])[0] !== 0 : null,
        state: r[2] ? int(b, r[2]) : null,
      };
    } else if (e.num === 709) { // attestationApplicationId
      out.appId = bytes(b, inner);
    } else if (e.num === 705 || e.num === 706 || e.num === 718 || e.num === 719 || e.num === 702) {
      out[e.num] = int(b, inner);
    }
  }
  return out;
}

function appIdOf(raw) {
  const t = tlv(raw, 0);
  const [infos, digests] = kids(raw, t);
  const packages = [];
  const signers = [];
  if (infos) {
    for (const p of kids(raw, infos)) {
      const f = kids(raw, p);
      if (f[0]) packages.push(new TextDecoder().decode(bytes(raw, f[0])));
    }
  }
  if (digests) for (const d of kids(raw, digests)) signers.push(hex(bytes(raw, d)));
  return { packages, signers };
}

/** The KeyDescription extension's contents, or null when there is none. */
export function keyDescription(cert) {
  const raw = cert.ext[OID_KEY_DESCRIPTION];
  if (!raw) return null;
  const t = tlv(raw, 0);
  const f = kids(raw, t);
  if (f.length < 8) throw new Der('keydescription');
  const sw = authList(raw, f[6]);
  const hw = authList(raw, f[7]);
  const appRaw = sw.appId ?? hw.appId ?? null;
  return {
    version: int(raw, f[0]),
    attestLevel: LEVEL[int(raw, f[1])] ?? 'unknown',
    keymintLevel: LEVEL[int(raw, f[3])] ?? 'unknown',
    challenge: bytes(raw, f[4]),
    rootOfTrust: hw.rootOfTrust ?? sw.rootOfTrust ?? null,
    app: appRaw ? appIdOf(appRaw) : null,
    origin: hw[702] ?? sw[702] ?? null,
    osVersion: hw[705] ?? sw[705] ?? null,
    osPatch: hw[706] ?? sw[706] ?? null,
    vendorPatch: hw[718] ?? null,
    bootPatch: hw[719] ?? null,
  };
}

// ── the verdict ─────────────────────────────────────────────────────────

const b64d = (s) => {
  const bin = atob(String(s));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
};
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

/** Google's status list (JSON) into the set of revoked serials. */
export function revokedFrom(json) {
  const out = new Set();
  const e = json && typeof json === 'object' ? json.entries : null;
  if (e && typeof e === 'object') {
    for (const [k, v] of Object.entries(e)) {
      if (v && typeof v === 'object' && String(v.status ?? '').toUpperCase() !== '') {
        out.add(String(k).toLowerCase().replace(/^0+/, '') || '0');
      }
    }
  }
  return out;
}

/**
 * @param {string[]} chainB64  DER certificates, leaf first, base64
 * @param {{
 *   deviceKey?: string,          the SPKI (base64) the phone sent as device_key
 *   challenge?: string,          expected attestation challenge (UTF-8)
 *   app?: {packageName: string, signers: string[]},
 *   roots?: Record<string, string>,   name -> SPKI base64
 *   revoked?: Set<string> | null,     null: not known
 *   now?: number,
 *   subtle?: SubtleCrypto,
 * }} [opts]
 */
export async function verdict(chainB64, opts = {}) {
  const roots = opts.roots ?? GOOGLE_ROOTS;
  const app = opts.app ?? OUR_APP;
  const now = opts.now ?? Date.now();
  const subtle = opts.subtle ?? globalThis.crypto.subtle;
  const out = {
    ok: false, chain: 'unchecked', root: null, revoked: null, key: 'unchecked',
    challenge: 'unchecked', level: null, keymint: null, boot: null, locked: null,
    app: 'unchecked', os_patch: null, vendor_patch: null, version: null, length: 0, why: [],
  };
  let certs;
  try {
    if (!Array.isArray(chainB64) || chainB64.length < 2 || chainB64.length > 10) {
      out.chain = 'bad_length';
      out.why.push('chain');
      return out;
    }
    // Keystore's certificates are 0.5-2 KB each; a request may not make
    // this do more work than a real chain would.
    if (chainB64.some((c) => typeof c !== 'string' || c.length > 12000) ||
      chainB64.reduce((n, c) => n + String(c).length, 0) > 40000) {
      out.chain = 'too_large';
      out.why.push('chain');
      return out;
    }
    certs = chainB64.map((c) => parseCert(b64d(c)));
  } catch (_) {
    out.chain = 'malformed';
    out.why.push('chain');
    return out;
  }
  out.length = certs.length;

  // The chain: each signed by the next; validity above the leaf.
  try {
    for (let i = 0; i < certs.length - 1; i++) {
      if (!(await verifySig(certs[i], certs[i + 1].spki, subtle))) {
        out.chain = `bad_signature_${i}`;
        break;
      }
      if (i + 1 < certs.length && (now < certs[i + 1].notBefore || now > certs[i + 1].notAfter)) {
        out.chain = `expired_${i + 1}`;
        break;
      }
    }
    if (out.chain === 'unchecked') {
      const top = certs[certs.length - 1];
      for (const [name, spkiB64] of Object.entries(roots)) {
        const pinned = b64d(spkiB64);
        if (same(top.spki, pinned)) {
          out.root = (await verifySig(top, pinned, subtle)) ? name : null;
        } else if (await verifySig(top, pinned, subtle).catch(() => false)) {
          out.root = name; // the phone left its root off; the top is signed by it
        }
        if (out.root) break;
      }
      out.chain = out.root ? 'ok' : 'unknown_root';
    }
  } catch (_) {
    out.chain = 'unverifiable';
  }
  if (out.chain !== 'ok') out.why.push('chain');

  // Revocation: any certificate in the chain.
  if (opts.revoked instanceof Set) {
    out.revoked = certs.some((c) => opts.revoked.has(c.serial));
    if (out.revoked) out.why.push('revoked');
  }

  // The leaf: the key the phone sent, and what Keystore says about it.
  const leaf = certs[0];
  if (opts.deviceKey) {
    out.key = same(leaf.spki, b64d(opts.deviceKey)) ? 'match' : 'mismatch';
    if (out.key !== 'match') out.why.push('key');
  }
  let kd = null;
  try {
    kd = keyDescription(leaf);
  } catch (_) {
    kd = undefined;
  }
  if (!kd) {
    out.why.push(kd === undefined ? 'keydescription_malformed' : 'no_keydescription');
    return out;
  }
  out.version = kd.version;
  out.level = kd.attestLevel;
  out.keymint = kd.keymintLevel;
  out.os_patch = kd.osPatch;
  out.vendor_patch = kd.vendorPatch;
  if (opts.challenge != null) {
    out.challenge = same(kd.challenge, new TextEncoder().encode(opts.challenge)) ? 'match' : 'mismatch';
    if (out.challenge !== 'match') out.why.push('challenge');
  }
  if (kd.rootOfTrust) {
    out.boot = BOOT[kd.rootOfTrust.state] ?? 'unknown';
    out.locked = kd.rootOfTrust.locked;
  }
  if (out.level !== 'tee' && out.level !== 'strongbox') out.why.push('level');
  if (out.boot !== 'verified' || out.locked !== true) out.why.push('boot');
  if (!kd.app) {
    out.app = 'missing';
  } else if (!kd.app.packages.includes(app.packageName)) {
    out.app = 'other_package';
  } else if (!kd.app.signers.some((s) => app.signers.includes(s))) {
    out.app = 'other_signer';
  } else {
    out.app = 'ok';
  }
  if (out.app !== 'ok') out.why.push('app');
  if (kd.origin != null && kd.origin !== 0) out.why.push('imported_key');
  out.ok = out.why.length === 0;
  return out;
}
