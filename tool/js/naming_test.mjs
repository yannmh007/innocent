// R2 keys that say nothing about what they hold (docs/edge/naming.ts).
//
// WHY. With R2_NAMING_KEY set, a new title's files go to
// `f/<20 hex>/<kind>/<32 hex>.<ext>`. Pinned here: the folder is the same for
// the same name (an upload resumed tomorrow finds it) and different under
// another key; it is not a plain hash anyone could recompute from a film's
// name; a file name is random and keeps only a clean extension; and the keys
// it makes still pass every check that was written for the old ones — the
// studio's own (isMintedKey), the Files page's folder rule, the frames check
// in migration 043, and the transcoder's rung and frame names.
//
//   node tool/js/naming_test.mjs

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createHash, createHmac, randomBytes } from 'crypto';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const naming = await import(join(ROOT, 'docs/edge/naming.ts'));
let failed = 0;
const check = (what, ok) => {
  if (ok) console.log('ok   ' + what);
  else { failed += 1; console.log('FAIL ' + what); }
};

const raw1 = randomBytes(32);
const k1 = await naming.namingKey(raw1.toString('base64'));
const k2 = await naming.namingKey(randomBytes(32).toString('base64'));
check('a 32-byte key is a key', k1 !== null && k2 !== null);
check('no key: none', (await naming.namingKey('')) === null);
check('a short key is refused', (await naming.namingKey(randomBytes(16).toString('base64'))) === null);
check('junk is refused', (await naming.namingKey('%%% not base64')) === null);

const f = await naming.opaqueFolder(k1, 'spider-man/movies');
check('a folder is f/<20 hex>', naming.OPAQUE_FOLDER.test(f));
check('the same name, the same folder', f === await naming.opaqueFolder(k1, 'spider-man/movies'));
check('another name, another folder', f !== await naming.opaqueFolder(k1, 'spider-man-2/movies'));
check('another key, another folder', f !== await naming.opaqueFolder(k2, 'spider-man/movies'));
check('the folder is the keyed hash, cut to 80 bits',
  f === 'f/' + createHmac('sha256', raw1).update('r2-folder:spider-man/movies').digest('hex').slice(0, 20));
const plain = createHash('sha256').update('spider-man/movies').digest('hex');
check('not a plain SHA-256 of the name', !plain.startsWith(f.slice(2)));
check('nothing of the name is in it', !f.includes('spider') && !f.includes('movie'));

const n1 = naming.opaqueName('MP4');
check('a file name is 32 hex and its extension', /^[0-9a-f]{32}\.mp4$/.test(n1));
check('two names, two different names', n1 !== naming.opaqueName('mp4'));
check('an extension is cleaned', /^[0-9a-f]{32}\.jpg$/.test(naming.opaqueName('j/p.g')));
check('no extension, no dot', /^[0-9a-f]{32}$/.test(naming.opaqueName('')));

// The checks written for the old keys, read from where they live.
const studio = readFileSync(join(ROOT, 'docs/edge/studio.ts'), 'utf8');
const minted = /function isMintedKey\(key: string\): boolean \{([\s\S]*?)\n\}/.exec(studio);
check('isMintedKey is where it should be', !!minted);
const isMintedKey = new Function('key', minted[1].replace(/: string/g, ''));
const folderOfSrc = /function folderOf\(key: string\): string \{([\s\S]*?)\n\}/.exec(studio);
const folderOf = new Function('key', folderOfSrc[1].replace(/: string/g, ''));
const frames043 = readFileSync(join(ROOT, 'docs/migrations/043_video_frames.sql'), 'utf8');
const framePat = /!~ '(\^\(\[a-z0-9\]\[a-z0-9\.\\-\]\*\/\)\*thumb\/[^']+)'/.exec(frames043);
check('the frames check is where it should be', !!framePat);
const frameRe = new RegExp(framePat[1]);

const video = `${f}/video/${naming.opaqueName('mp4')}`;
const photo = `${f}/photo/${naming.opaqueName('jpg')}`;
check('a video key passes isMintedKey', isMintedKey(video));
check('a photo key passes isMintedKey', isMintedKey(photo));
check('the Files page puts both in the folder', folderOf(video) === f && folderOf(photo) === f);

// The transcoder's names, built from the master's key as it builds them.
const transcode = readFileSync(join(ROOT, 'docs/edge/transcode.ts'), 'utf8');
const rungSrc = /function rungKey\(masterKey: string, height: number\): string \{([\s\S]*?)\n\}/.exec(transcode);
const frameSrc = /function frameKey\(masterKey: string, i: number\): string \{([\s\S]*?)\n\}/.exec(transcode);
check('the transcoder\'s namers are where they should be', !!rungSrc && !!frameSrc);
const rungKey = new Function('masterKey', 'height', rungSrc[1].replace(/: string/g, ''));
const frameKey = new Function('masterKey', 'i',
  frameSrc[1].replace(/\(s: string\)/g, '(s)').replace(/: string/g, ''));
const rung = rungKey(video, 720);
const frame = frameKey(video, 3);
check('a rung stays in the folder and passes isMintedKey', folderOf(rung) === f && isMintedKey(rung));
check('a frame stays in the folder', folderOf(frame) === f);
check('a frame passes migration 043\'s check', frameRe.test(frame));
check('a frame passes isMintedKey', isMintedKey(frame));

if (failed) {
  console.log(`\n${failed} check(s) FAILED`);
  process.exit(1);
}
console.log('\n=== all checks on opaque R2 keys passed ===');
