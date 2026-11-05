// Showing a sealed object in the console (docs/MEDIA_ENCRYPTION.md §7.3,
// ENC-4 step 8). `previewUrl` and `objectUrl` answer a sealed object with
// its key (`seal`); these turn that answer into something an <img> or a
// <video> can use, without the console ever asking for a plain byte:
//
//   sealedImageSrc(p)   the picture's bytes (still sealed, from the studio's
//                       `sealedImage`), opened here, as a blob: URL
//   sealedVideoSrc(p)   `sealed/<id>`, answered by sealed_sw.js, which reads
//                       ranges from the streaming Worker and opens them
//
// Classic script, loaded after upload.js (it uses sealLib and unb64).

/// A sealed picture as a blob: URL. The caller revokes it when done.
async function sealedImageSrc(p) {
  const ms = await sealLib();
  const r = await api({ op: 'sealedImage', key: p.seal.sealedKey });
  const dek = unb64(p.seal.dek);
  try {
    const plain = await ms.openAll(unb64(r.bytes), dek, ms.aadFor(p.seal.dekId));
    return URL.createObjectURL(new Blob([plain], { type: p.seal.mime || 'image/jpeg' }));
  } finally {
    dek.fill(0);
  }
}

let sealedSwReady = null;

/// The console's Service Worker, registered once and in control of the page.
function sealedWorker() {
  if (sealedSwReady) return sealedSwReady;
  sealedSwReady = (async () => {
    if (!('serviceWorker' in navigator)) {
      throw new Error('This browser cannot play a sealed film here (no Service Worker).');
    }
    await navigator.serviceWorker.register('sealed_sw.js', { type: 'module', scope: './' });
    await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) {
      await new Promise((resolve) => navigator.serviceWorker.addEventListener('controllerchange', resolve, { once: true }));
    }
    return navigator.serviceWorker.controller;
  })();
  sealedSwReady.catch(() => { sealedSwReady = null; });
  return sealedSwReady;
}

/// Hands the film's key to the worker, and waits until it holds it.
async function postSealedFilm(id, p) {
  const sw = await sealedWorker();
  await new Promise((resolve, reject) => {
    const ch = new MessageChannel();
    const t = setTimeout(() => reject(new Error('The console\'s worker did not answer.')), 5000);
    ch.port1.onmessage = () => { clearTimeout(t); resolve(); };
    sw.postMessage({ type: 'sealed-film', id, url: p.url, sealedKey: p.seal.sealedKey,
      dekId: p.seal.dekId, dek: p.seal.dek, header: p.seal.header || null,
      plainSize: p.seal.plainSize }, [ch.port2]);
  });
}

/// A sealed film's address for a <video>, answered by sealed_sw.js. The
/// returned `again()` posts the key once more — for when the browser stopped
/// the worker while the film was paused (it then answers 410).
async function sealedVideoSrc(p) {
  const id = Array.from(crypto.getRandomValues(new Uint8Array(16)),
    (b) => b.toString(16).padStart(2, '0')).join('');
  await postSealedFilm(id, p);
  return { src: 'sealed/' + id, again: () => postSealedFilm(id, p) };
}

/// For a <video> playing a sealed film: on an error, post the key again
/// once and carry on from where it was.
function keepSealedPlaying(video, film) {
  let retried = false;
  video.addEventListener('error', async () => {
    if (retried) return;
    retried = true;
    const at = video.currentTime;
    try {
      await film.again();
      video.src = film.src;
      video.currentTime = at;
      video.play().catch(() => {});
    } catch (_) { /* the page's own error message stands */ }
  });
}
