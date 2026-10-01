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
  '\nexport { slugify, safeKey, keyTail, fileOf, bucketFor };'
));

// The raw file, for the three places the choice has to be USED. A correct
// bucketFor that nothing calls is the same bug with extra steps.
const ingestSrc = readFileSync(join(ROOT, 'docs/edge/ingest.ts'), 'utf8');

// `isMintedKey` is the console's own gate on a key. Lifted rather than
// restated, because the point of these checks is that the two files agree.
const studio = await import('data:text/javascript,' + encodeURIComponent(
  sliceOut('docs/edge/studio.ts', 'function isMintedKey(', '// ── ADMIN GATE (begin)')
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

// ── an album keeps its caption's folder ───────────────────────────────────
//
// The fix lives in `enqueue_ingest` (migration 023) and is checked against a
// real Postgres by tool/sql/album_folder_test.sql, because it is a race
// between messages resolved by a lock. What is checked HERE is the half that
// is in this file, and each of these is a way the two could silently stop
// agreeing while both looked right on their own.
{
  // The database composes `folder || '/' || tail`. If that does not produce
  // exactly what safeKey produces, the console stops recognising keys the
  // ingest mints and the unused-file report starts calling live films
  // orphans — which is a bill, quietly.
  const tail = mod.keyTail('photo', 'Poster.JPG');
  check('a tail is the kind and the name, with no folder',
    /^photo\/20\d{6}-poster-[0-9a-f]{8}\.jpg$/.test(tail));
  check('folder + tail is a key the console accepts',
    studio.isMintedKey('chief-of-war-2025/' + tail));
  check('and inbox + tail is too', studio.isMintedKey('inbox/' + tail));
  check('safeKey is exactly that composition',
    /^\$\{slugify\(folder\) \|\| 'inbox'\}\/\$\{keyTail\(prefix, filename\)\}$/
      .test(
        (ingestSrc.match(/function safeKey[^]*?return `([^`]*)`/) || [])[1] || ''));

  // Telegram sends one update per file of an album and puts the caption on
  // one of them. Not reading `media_group_id` is precisely the bug: three
  // photos of a four-photo album landed in `inbox` with nothing wrong
  // anywhere that anyone could see.
  check('the webhook reads media_group_id',
    /media_group_id/.test(ingestSrc));
  check('and passes it to the database',
    /p_media_group:\s*mediaGroup/.test(ingestSrc));

  // The folder and the tail go SEPARATELY, because the folder is the part the
  // database may override. Sending a finished key would put the decision back
  // in the one place that cannot see the other messages of the album.
  check('the folder is sent on its own', /p_folder:\s*slugify\(caption\)/.test(ingestSrc));
  check('the tail is sent on its own',
    /p_key_tail:\s*keyTail\(file\.kind, file\.name\)/.test(ingestSrc));

  // THE INSERT MUST NOT GO ROUND THE FUNCTION. A plain REST insert would skip
  // the lock and the reconciliation and put the album bug straight back, with
  // every test above still passing.
  check('nothing inserts into ingest_jobs behind the function',
    !/rest\('ingest_jobs',\s*\{[^]*?method:\s*'POST'/.test(ingestSrc));
  check('the enqueue goes through enqueue_ingest',
    /rpc\('enqueue_ingest'/.test(ingestSrc));

  // The bot used to report the caption it had been handed. For three files of
  // that album the true answer was `inbox` and the reported answer was
  // `inbox`, which was correct and told the operator nothing was wrong.
  check('the bot reports the folder the row actually got',
    /Folder: \$\{String\(queued\.folder/.test(ingestSrc));
  check('and says so when siblings were moved to join it',
    /queued\.moved/.test(ingestSrc));
}

// ── a spent job can be sent round again ───────────────────────────────────
{
  const retry = ingestSrc.slice(ingestSrc.indexOf("if (op === 'retry')"));
  check('there is a retry op', retry.length > 0);
  // Behind the admin gate. This requeues work that costs bandwidth and it is
  // reachable from a page on the open internet. That the gate runs before
  // consoleOp at all is tool/js/admin_gate_test.mjs's to prove; this says
  // retry is one of the gated ops and not a runner op beside them.
  check('retry is behind the admin gate',
    /\n  retry: 'uploader',/.test(ingestSrc) &&
    ingestSrc.indexOf("if (op === 'retry')") >
      ingestSrc.indexOf('async function consoleOp('));
  check('retry refuses a call with no job', /no_job/.test(retry.slice(0, 500)));
  check('retry decides in the database, not here',
    /rpc\('retry_ingest'/.test(retry));
}

// ── the console ───────────────────────────────────────────────────────────
//
// Two faults that are invisible in a screenshot of the case somebody thought
// to look at, which is how both survived.
{
  const studioSrc = readFileSync(join(ROOT, 'docs/studio/index.html'), 'utf8');

  // The panel was wired to its own Refresh button and to nothing else, so
  // opening the tab drew a heading and an explanation over an empty div. It
  // reads as a panel that does not exist, and it was looked for three times.
  const onHealth = studioSrc.slice(studioSrc.indexOf("if (tab === 'health')"));
  check('opening Health fills the From Telegram panel too',
    /loadIngest\(\)/.test(onHealth.slice(0, 700)));

  // The heading on the page is `From Telegram`. Anything that calls it the
  // Ingest panel is sending somebody looking for a word that is not there —
  // which is what the runbook did.
  check('the panel is headed From Telegram', />From Telegram</.test(studioSrc));
  check('the runbook calls it by that name',
    /From Telegram/.test(readFileSync(join(ROOT, 'docs/RUNBOOK.md'), 'utf8')));

  check('a failed row offers Try again',
    /r\.state === 'failed'/.test(studioSrc) &&
    /op: 'retry', job_id: r\.id/.test(studioSrc));
}

// ── a title can be born from an ingest ────────────────────────────────────
//
// The ingest put fifteen files in two folders and there was nothing to be
// done with them: creating a title demanded uploading a file from the phone,
// which is the one thing this whole path exists to avoid. Each check below is
// a way that could quietly come back.
{
  const studioSrc = readFileSync(join(ROOT, 'docs/studio/index.html'), 'utf8');
  const studioTs = readFileSync(join(ROOT, 'docs/edge/studio.ts'), 'utf8');

  // studio.ts IS DELIBERATELY UNTOUCHED. Its `create` exists to take files off
  // the phone and is right to insist on one; the ingest path does not go
  // through it at all. A future edit that loosens it there would be solving
  // this problem twice, in the place where it is harder to get right.
  check('studio create still insists on a file for its own path',
    /if \(incoming\.length === 0\) return json\(\{ error: 'no_assets' \}/.test(studioTs));

  // The title is born holding its files, in one statement.
  check('there is a create_title op', /op === 'create_title'/.test(ingestSrc));
  check('create_title is behind the admin gate',
    /create_title: 'uploader'/.test(ingestSrc) &&
    ingestSrc.indexOf("if (op === 'create_title')") >
      ingestSrc.indexOf('async function consoleOp('));
  check('and says who made it, so an uploader can go on editing it',
    /p_actor: who\.id/.test(ingestSrc));
  check('and it decides in the database',
    /rpc\('create_title_from_ingest'/.test(ingestSrc));
  check('the console uses it', /op: 'create_title'/.test(studioSrc));

  // The whole caption, not the one line the folder came from.
  check('the whole caption goes to the database',
    /p_caption: String\(msg\.caption/.test(ingestSrc));
  check('and comes back to the console',
    /tg_caption/.test(ingestSrc) && /tg_caption/.test(studioSrc));

  // Fifteen pickers for one album is fifteen chances to pick wrong.
  check('a folder can be attached in one go', /op === 'attach_folder'/.test(ingestSrc));
  check('attach_folder is behind the admin gate',
    /attach_folder: 'uploader'/.test(ingestSrc) &&
    ingestSrc.indexOf("if (op === 'attach_folder')") >
      ingestSrc.indexOf('async function consoleOp('));
  check('and the console uses it', /op: 'attach_folder'/.test(studioSrc));

  // `inbox` IS NOT AN ALBUM. It is the drawer everything captionless falls
  // into, and one tap filing a year of unrelated uploads under one title is
  // the worst thing this panel could learn to do.
  check('inbox keeps its per-file pickers',
    /drawLooseFiles/.test(studioSrc) &&
    /folder === 'inbox'\s*\n?\s*\? drawLooseFiles/.test(studioSrc));

  // The new title must land in the folder the files are already in. A
  // different one plays fine — attach copies the key — and then disagrees
  // with the R2 listing, the unused-file report, and every later upload from
  // this page, which reads the folder back to decide where files go.
  const born = studioSrc.slice(studioSrc.indexOf('async function startTitleFromIngest'));
  check('a title born from an ingest takes the ingest folder',
    /op: 'create_title', folder,/.test(born));
  check('the caption fills the name and the synopsis',
    /lines\[0\]/.test(born) && /synopsis: rest/.test(born));
  // It is a draft because `create_title_from_ingest` makes drafts, and the
  // trigger refuses to publish an empty one whatever this page sends.
  check('and the operator is told it is a draft', /DRAFT/.test(born));
  check('the picker is refreshed, or every other group offers a stale list',
    /ingestTitles = null/.test(born));
}

if (failures) {
  console.error(failures + ' ingest check(s) failed');
  process.exit(1);
}
console.log('ingest: all checks passed');
