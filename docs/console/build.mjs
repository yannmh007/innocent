// Builds what console.innocentplayer.com serves (docs/console/README.md).
//
//   node build.mjs [outDir]       (default: ./dist)
//
// ONLY THE CONSOLE. GitHub Pages publishes the whole of docs/ — the
// migrations, the edge functions' source, every plan. This copies the
// console (docs/studio, without its README) and the four edge modules the
// console's own code imports for sealing (upload.js, sealed_sw.js), and
// nothing else. Paths stay as they are on Pages (/studio/, /edge/), so the
// console's relative imports ('../edge/media_seal.js') resolve unchanged.
//
// AND REAL HEADERS (`_headers`, which Workers static assets applies to
// every file). GitHub Pages cannot send any, so the console has carried its
// policy in a <meta>; a <meta> cannot say frame-ancestors, HSTS or COOP,
// and its connect-src had to allow any https host. Here they are headers,
// and connect-src names the four hosts the console talks to. The <meta>
// stays in index.html (for the Pages copy); a browser enforces both, so
// the stricter header wins.

import { copyFileSync, cpSync, existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DOCS = join(HERE, '..');
const OUT = resolve(process.argv[2] ?? join(HERE, 'dist'));

/** The edge modules the console imports, and theirs (checked by the test). */
export const EDGE_MODULES = ['media_seal.js', 'media_read.js', 'media_twin.js', 'media_keys.js'];

const SUPABASE = 'https://yqonvmuiezqvyqmexrft.supabase.co';
const STREAM = 'https://stream.innocentplayer.com';
const CDN = 'https://cdn.innocentplayer.com';
// Uploads go to presigned R2 URLs on `<account>.r2.cloudflarestorage.com`.
// The account id is a secret, so the host is named by its suffix.
const R2 = 'https://*.r2.cloudflarestorage.com';

export const CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  `img-src 'self' data: blob: ${CDN} ${STREAM} ${R2}`,
  `media-src 'self' blob: ${STREAM} ${CDN} ${R2}`,
  `connect-src 'self' ${SUPABASE} ${STREAM} ${CDN} ${R2}`,
  "font-src 'self'",
  "manifest-src 'self'",
  "worker-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "object-src 'none'",
  "frame-ancestors 'none'",
].join('; ');

export const HEADERS = `/*
  Content-Security-Policy: ${CSP}
  Strict-Transport-Security: max-age=31536000
  X-Frame-Options: DENY
  X-Content-Type-Options: nosniff
  Referrer-Policy: no-referrer
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Resource-Policy: same-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()
  X-Robots-Tag: noindex, nofollow

/studio/sealed_sw.js
  Cache-Control: no-cache
`;

export const REDIRECTS = '/ /studio/ 302\n';

export function build(out = OUT) {
  rmSync(out, { recursive: true, force: true });
  mkdirSync(join(out, 'studio'), { recursive: true });
  mkdirSync(join(out, 'edge'), { recursive: true });
  for (const name of readdirSync(join(DOCS, 'studio'))) {
    if (name === 'README.md') continue;
    cpSync(join(DOCS, 'studio', name), join(out, 'studio', name), { recursive: true });
  }
  // A tree whose console seals nothing (main before the ENC release) has
  // none of them, and needs none; console_build_test.mjs checks that every
  // import the console makes is in the bundle.
  for (const m of EDGE_MODULES) {
    if (existsSync(join(DOCS, 'edge', m))) copyFileSync(join(DOCS, 'edge', m), join(out, 'edge', m));
  }
  writeFileSync(join(out, '_headers'), HEADERS);
  writeFileSync(join(out, '_redirects'), REDIRECTS);
  writeFileSync(join(out, 'robots.txt'), 'User-agent: *\nDisallow: /\n');
  return out;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log('console built into ' + build());
}
