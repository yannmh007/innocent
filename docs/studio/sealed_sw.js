// The console's Service Worker: a sealed film, played in the console as its
// plaintext (docs/MEDIA_ENCRYPTION.md §7.3, ENC-4 step 8).
//
// THE ONLY THING IT DOES. A <video> in the console asks for
// `sealed/<32 hex>`; this answers each Range request by reading the
// segments that hold it from the streaming Worker (the one origin that
// answers the console with CORS), opening each — checked before a byte is
// served — and answering with the plaintext, as the phone's unseal gateway
// does. Every other request of the page goes to the network untouched:
// nothing is cached, nothing is rewritten.
//
// THE KEY LIVES IN THIS WORKER'S MEMORY ONLY, posted by the page for one
// film and dropped after fifteen minutes (the Worker URL lives ten). If the
// browser stops this worker, the film is forgotten and the page posts it
// again (sealed_view.js).
//
// A module worker: it imports the format from ../edge/, as the page does.

import { rangeAnswer } from '../edge/media_read.js';

const films = new Map(); // id -> { url, sealedKey, dekId, dek, header, plainSize, at }
const LIFE_MS = 15 * 60 * 1000;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('message', (e) => {
  const d = e.data || {};
  if (d.type !== 'sealed-film' || !/^[0-9a-f]{32}$/.test(String(d.id))) return;
  for (const [id, f] of films) if (Date.now() - f.at > LIFE_MS) films.delete(id);
  films.set(d.id, {
    url: String(d.url), sealedKey: String(d.sealedKey), dekId: String(d.dekId), dek: String(d.dek),
    header: d.header ? String(d.header) : null, plainSize: Number(d.plainSize), at: Date.now(),
  });
  if (e.ports && e.ports[0]) e.ports[0].postMessage('ok');
});

self.addEventListener('fetch', (e) => {
  const u = new URL(e.request.url);
  if (u.origin !== self.location.origin) return;
  const m = /\/sealed\/([0-9a-f]{32})$/.exec(u.pathname);
  if (!m) return; // everything else: the network, as if this worker were not here
  e.respondWith(answer(m[1], e.request));
});

const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

async function answer(id, req) {
  const f = films.get(id);
  // 410: this worker no longer holds the film (stopped, or expired); the
  // page posts it again.
  if (!f || Date.now() - f.at > LIFE_MS) return new Response(null, { status: 410 });
  const io = {
    get: async (_key, first, last) => {
      const r = await fetch(f.url, { headers: { Range: `bytes=${first}-${last}` } });
      if (r.status !== 206 && r.status !== 200) return null;
      const all = new Uint8Array(await r.arrayBuffer());
      return { bytes: r.status === 200 ? all.subarray(first, last + 1) : all, total: null };
    },
    // A copy each time: readPlain zeroes the DEK it is handed once used.
    seal: async () => ({
      dekId: f.dekId, dek: unb64(f.dek), plainSize: f.plainSize,
      header: f.header ? unb64(f.header) : null,
    }),
  };
  try {
    const a = await rangeAnswer(io, f.sealedKey, req.headers.get('Range'), f.plainSize);
    return new Response(a.status === 416 || a.status === 502 ? null : a.bytes,
      { status: a.status, headers: a.headers });
  } catch (_) {
    // A segment that does not open: never a corrupt frame, an error.
    return new Response(null, { status: 502 });
  }
}
