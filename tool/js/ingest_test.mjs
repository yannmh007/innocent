// The two decisions in the Telegram ingest that cannot be taken back.
//
// WHY THIS IS TESTED RATHER THAN READ. Neither of these can be tried against
// anything from a checkout: the bot needs credentials that live in Actions
// secrets, and the queue lives in Supabase. Both are pure functions on a
// message, so they can be exercised exactly — and both fail silently.
//
//   THE OBJECT KEY is a path, built from a file name a stranger chose and a
//   caption typed on a phone. A key that escapes its folder writes somewhere
//   in the bucket nobody expects; a key `studio.ts` would refuse is a file the
//   console cannot later complete, abort or recognise as its own. The second
//   one is the quiet failure: the upload works and the file is orphaned.
//
//   WHICH PART OF A MESSAGE IS THE FILM decides what enters the catalogue. A
//   round selfie video or a sticker treated as a master would be published;
//   a document rejected because the code only looked at `video` would send
//   the operator back to re-upload a gigabyte.
//
//   WHICH BUCKET IT GOES IN is the third, and it failed in the live system
//   before it was checked here. Video is private and reached through a signed
//   URL; artwork is public and served off the public bucket's domain. The
//   `title_media` view builds a photo's URL from `public_asset_base()` and the
//   object key and never reads the `bucket` column — so a photo written to the
//   media bucket is a broken image in the app, with a row that looks correct
//   from every angle.
//
// The functions are pulled out of `docs/edge/ingest.ts` — never copied, since
// a copy would pass for ever while the file drifted — and `isMintedKey` out
// of `docs/edge/studio.ts`, so the agreement between the two is checked and
// not assumed.
//
// RUN:  node tool/js/ingest_test.mjs

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

let failures = 0;
const check = (label, ok) => {
  console.log((ok ? 'ok   ' : 'FAIL ') + label);
  if (!ok) failures++;
};

function sliceOut(file, from, to) {
  const src = readFileSync(join(ROOT, file), 'utf8');
  const a = src.indexOf(from);
  const b = src.indexOf(to);
  if (a < 0 || b < 0 || b <= a) {
    console.log('FAIL could not find ' + JSON.stringify(from) + ' .. ' +
      JSON.stringify(to) + ' in ' + file);
    process.exit(1);
  }
  return src.slice(a, b);
}

// Only the signatures carry types; every body is JavaScript already.
const ts = (s) => s
  .replace(/: Record<string, unknown> \| undefined/g, '')
  .replace(/: Array<Record<string, unknown>> \| undefined/g, '')
  .replace(/: Record<string, unknown>/g, '')
  .replace(/as Record<string, unknown> \| undefined/g, '')
  .replace(/as Array<Record<string, unknown>> \| undefined/g, '')
  .replace(/\): \{[\s\S]*?\} \| null \{/g, ') {')
  .replace(/: string\b/g, '')
  .replace(/: number \| null/g, '')
  .replace(/: number\b/g, '');

// Sliced in two pieces on purpose: `say()` sits between them and talks to
// Telegram, which has no business in a test of two pure functions.
const mod = await import('data:text/javascript,' + encodeURIComponent(
  // The buckets come from Deno.env in the real file. Named here so the
  // CHOICE is what is checked, rather than the two default strings.
  "const MEDIA_BUCKET = 'media-bucket';\n"
  + "const PUBLIC_BUCKET = 'public-bucket';\n"
  + ts(sliceOut('docs/edge/ingest.ts', 'function bucketFor(', '\nconst SUPABASE_URL')) +
  ts(sliceOut('docs/edge/ingest.ts', 'function slugify(', '/// Tell the operator')) +
  ts(sliceOut('docs/edge/ingest.ts', 'function fileOf(', 'Deno.serve(')) +
  '\nexport { slugify, safeKey, fileOf, bucketFor };'
));

// The raw file, for the three places the choice has to be USED. A correct
// bucketFor that nothing calls is the same bug with extra steps.
const ingestSrc = readFileSync(join(ROOT, 'docs/edge/ingest.ts'), 'utf8');

// `isMintedKey` is the console's own gate on a key. Lifted rather than
// restated, because the point of these checks is that the two files agree.
const studio = await import('data:text/javascript,' + encodeURIComponent(
  sliceOut('docs/edge/studio.ts', 'function isMintedKey(', '// --- who is asking')
    .replace(/: boolean\b/g, '').replace(/: string\b/g, '') +
  '\nexport { isMintedKey };'
));

// ── the object key ────────────────────────────────────────────────────────
{
  const key = mod.safeKey('video', 'My Film (2026).MP4', 'Solar Eclipse');
  check('the folder comes from the caption',
    key.startsWith('solar-eclipse/video/'));
  check('the extension survives, lowercased', key.endsWith('.mp4'));
  check('the name is slugified', /\/20\d{6}-my-film-2026-[0-9a-f]{8}\.mp4$/.test(key));
  check('and the console would accept it', studio.isMintedKey(key));

  // THE ONE THAT MATTERS. A caption and a file name both arrive from outside
  // and an object key is a path.
  for (const [name, folder] of [
    ['../../secret.mp4', 'films'],
    ['ok.mp4', '../../../'],
    ['ok.mp4', '/etc'],
    ['.hidden', 'a/../../b'],
    ['ok.mp4', '..'],
  ]) {
    const k = mod.safeKey('video', name, folder);
    check(`no traversal from ${JSON.stringify([name, folder])}`,
      !k.includes('..') && !k.startsWith('/') && studio.isMintedKey(k));
  }

  check('a caption of nothing falls back to one known folder',
    mod.safeKey('video', 'a.mp4', '').startsWith('inbox/video/'));
  check('a caption of only punctuation is the same as none',
    mod.safeKey('video', 'a.mp4', '!!! ???').startsWith('inbox/video/'));

  // A Burmese file name slugifies to nothing, which must produce a usable
  // name rather than a key ending in a bare timestamp and hyphen.
  const burmese = mod.safeKey('video', 'ကျွန်တော့်ဇာတ်ကား.mp4', 'ရုပ်ရှင်');
  check('a Burmese name still makes a legal key', studio.isMintedKey(burmese));
  check('and it does not collapse to an empty stem',
    /\/20\d{6}-file-[0-9a-f]{8}\.mp4$/.test(burmese));

  // Two uploads of the same camera file must be two objects, or the second
  // silently overwrites a film somebody is watching.
  check('the same file name twice is two keys',
    mod.safeKey('video', 'VID_0001.mp4', 'f') !==
    mod.safeKey('video', 'VID_0001.mp4', 'f'));

  check('a name that is all extension still works',
    studio.isMintedKey(mod.safeKey('video', '.mp4', 'f')));
  check('a very long name is cut rather than rejected',
    studio.isMintedKey(mod.safeKey('video', 'x'.repeat(400) + '.mp4', 'f')));
}

// ── which part of the message is the film ─────────────────────────────────
{
  const doc = {
    document: {
      file_id: 'A', file_unique_id: 'U', file_name: 'master.mkv',
      file_size: 2000, mime_type: 'video/x-matroska',
    },
  };
  const got = mod.fileOf(doc);
  check('a document is the film', got && got.kind === 'video');
  check('and keeps its real name', got.name === 'master.mkv');
  check('and its size', got.bytes === 2000);

  const vid = mod.fileOf({
    video: {
      file_id: 'B', file_unique_id: 'V', file_size: 10, mime_type: 'video/mp4',
      duration: 61, width: 1920, height: 1080,
    },
  });
  check('a video is accepted too', vid && vid.kind === 'video');
  check('with the dimensions Telegram supplied',
    vid.width === 1920 && vid.height === 1080 && vid.duration === 61);
  check('and a name invented from the stable id when there is none',
    vid.name === 'V.mp4');

  const photo = mod.fileOf({
    photo: [
      { file_id: 'S', file_unique_id: 'P1', file_size: 100, width: 90, height: 90 },
      { file_id: 'L', file_unique_id: 'P2', file_size: 900, width: 1280, height: 720 },
    ],
  });
  check('a photo takes the LARGEST size Telegram kept', photo && photo.id === 'L');
  check('and is a photo, not a film', photo.kind === 'photo');

  // A DOCUMENT WINS OVER A VIDEO when both are somehow present: the document
  // is the original bytes and the video is Telegram's re-encode.
  check('a document beats a video', mod.fileOf({
    document: { file_id: 'D', file_unique_id: 'DD', file_name: 'a.mp4' },
    video: { file_id: 'V', file_unique_id: 'VV' },
  }).id === 'D');

  // A jpeg SENT AS A DOCUMENT is still a photo, because the mime says so.
  check('a still sent as a document is a photo', mod.fileOf({
    document: {
      file_id: 'J', file_unique_id: 'JJ', file_name: 'poster.jpg',
      mime_type: 'image/jpeg',
    },
  }).kind === 'photo');

  for (const [why, msg] of [
    ['a plain text message', { text: 'hello' }],
    ['a round selfie video', { video_note: { file_id: 'N', file_unique_id: 'NN' } }],
    ['a sticker', { sticker: { file_id: 'S', file_unique_id: 'SS' } }],
    ['an animation', { animation: { file_id: 'G', file_unique_id: 'GG' } }],
    ['a voice note', { voice: { file_id: 'W', file_unique_id: 'WW' } }],
    ['an empty photo array', { photo: [] }],
    ['a file with no id', { document: { file_unique_id: 'X' } }],
    ['a file with no stable id', { document: { file_id: 'X' } }],
  ]) {
    check(`${why} is not a film`, mod.fileOf(msg) === null);
  }
}

// ── which bucket ──────────────────────────────────────────────────────────
{
  check('a video goes to the media bucket',
    mod.bucketFor('video') === 'media-bucket');

  // Everything that is not a video is artwork, including a kind nobody has
  // thought of yet: the public bucket is the safe default because a photo in
  // the private bucket is invisible, while a video in the public one would
  // have to be named in a row before anything could reach it.
  for (const kind of ['photo', 'thumb', 'clip', '']) {
    check(`${kind || '(no kind)'} goes to the public bucket`,
      mod.bucketFor(kind) === 'public-bucket');
  }

  // USED IN ALL THREE PLACES. The row records it, the signature signs it, and
  // the signature reads it back off the ROW rather than deciding again — two
  // independent decisions are two chances to disagree.
  check('the queued row takes the bucket from the kind',
    /bucket:\s*bucketFor\(file\.kind\)/.test(ingestSrc));
  check('the signed path uses the bucket it was given, not a constant',
    /const canonicalPath = `\/\$\{bucket\}\//.test(ingestSrc) &&
    !/const canonicalPath = `\/\$\{MEDIA_BUCKET\}/.test(ingestSrc));
  check('the PUT is signed for the bucket the row names',
    /put_url: await presign\('PUT',[\s\S]{0,160}?String\(job\.bucket/.test(ingestSrc));
}

// ── the one key the RUNNER may write ──────────────────────────────────────
//
// `op: release` hands a presigned PUT into the PUBLIC bucket to anything
// holding the runner secret. That bucket is where every poster the app draws
// lives, so the name is a pattern and not a string the caller picks: without
// one, a leaked Actions secret could overwrite artwork, or drop an APK at a
// path the console's own listing would never show.
{
  // The WHOLE block. Cutting it at the first `return json({` would stop at
  // the 403 on the line above the name check, which is how the first version
  // of this managed to assert things about an empty string.
  const from = ingestSrc.indexOf("op === 'release'");
  const rel = ingestSrc.slice(from, ingestSrc.indexOf("op === 'list'", from));
  const guard = rel;

  check('the release op checks the runner secret first',
    /sameSecret\(given, RUNNER_SECRET\)/.test(guard));
  check('the release key is under apk/',
    /`apk\/\$\{name\}`/.test(rel.slice(0, rel.indexOf('}, 200, req);'))));

  // The pattern itself, lifted out of the source and exercised rather than
  // read: a pattern that looks strict and is not would pass any eyeballing.
  const m = guard.match(/\/(\^innocent-[^/]*\$)\//);
  check('the release name pattern is present', m !== null);
  check('the release name is anchored at both ends',
    m !== null && m[1].startsWith('^') && m[1].endsWith('$'));
  if (m) {
    const re = new RegExp(m[1]);
    check('a real release name is accepted',
      re.test('innocent-1.64.39-352.apk'));
    for (const bad of [
      'innocent-1.64.39-352.apk.exe',
      '../poster.jpg',
      'innocent-1.64.39-352.jpg',
      'x/innocent-1.64.39-352.apk',
      'innocent-1.64.39-352.apk\n',
      '',
    ]) {
      check(`${JSON.stringify(bad)} is refused`, !re.test(bad));
    }
  }
}

if (failures) {
  console.error(failures + ' ingest check(s) failed');
  process.exit(1);
}
console.log('ingest: all checks passed');
