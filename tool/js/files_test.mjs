// The Files page's one shared rule: which folder a key is in.
//
// WHY. The page groups files by `r2_folder_of` (migration 028, in Postgres);
// a folder move picks its files by `folderOf` (studio.ts, in TypeScript). If
// the two ever disagreed, the operator would look at folder A and move a
// slightly different set of files — `movies` taking `movies/solar` with it, or
// leaving a thumbnail behind. So: the two patterns must be the same pattern,
// and the TypeScript one must give the answers the SQL test expects.
//
//   node tool/js/files_test.mjs

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
let failed = 0;
const check = (what, ok) => {
  if (ok) console.log('ok   ' + what);
  else { failed += 1; console.log('FAIL ' + what); }
};

const sql = readFileSync(join(ROOT, 'docs/migrations/028_files_manager.sql'), 'utf8');
const ts = readFileSync(join(ROOT, 'docs/edge/studio.ts'), 'utf8');

const sqlPat = /substring\(p_key from '([^']+)'\)/.exec(sql);
const tsFn = /function folderOf\(key: string\): string \{([\s\S]*?)\n\}/.exec(ts);
check('the SQL rule is where it should be', !!sqlPat);
check('the TypeScript rule is where it should be', !!tsFn);

const tsPat = tsFn ? /\/(\^.*\$)\/\.exec\(key\)/.exec(tsFn[1]) : null;
check('both rules use the same pattern',
  !!sqlPat && !!tsPat && tsPat[1].replace(/\\\//g, '/') === sqlPat[1]);

// The TypeScript one, run.
const folderOf = new Function('key', tsFn[1].replace(/: string/g, ''));
const cases = [
  ['movies/solar/video/x.mp4', 'movies/solar'],
  ['test006/video/a-720p.mp4', 'test006'],
  ['test006/thumb/a.jpg', 'test006'],
  ['v/20260922-a.mp4', 'v'],
  ['p/Picsart_26-08-30.jpg', 'p'],
  ['inbox/photo/a.jpg', 'inbox'],
  ['loose.mp4', ''],
  ['_selftest/abc.txt', '_selftest'],
  // a folder NAMED like a kind is still the folder, not the kind
  ['video/video/x.mp4', 'video'],
];
for (const [key, want] of cases) {
  check(`folderOf(${key}) = '${want}'`, folderOf(key) === want);
}
// The cases the SQL test asserts, so the two tests pin the same answers.
const sqlTest = readFileSync(join(ROOT, 'tool/sql/files_test.sql'), 'utf8');
for (const [, key, want] of sqlTest.matchAll(/r2_folder_of\('([^']+)'\) <> '([^']*)'/g)) {
  check(`and agrees with the SQL test: ${key} → '${want}'`, folderOf(key) === want);
}

// A move takes EXACTLY one folder: the edge function filters a prefix
// listing through folderOf, and these are the keys a listing of `movies/`
// returns that must not be taken when moving `movies`.
check('moving `movies` does not take `movies/solar`',
  folderOf('movies/solar/video/x.mp4') !== 'movies');
check('moving `zz-old` does not take `zz-old-2` (a prefix listing would not return it, but)',
  folderOf('zz-old-2/video/x.mp4') !== 'zz-old');

if (failed) {
  console.log(`${failed} files check(s) failed`);
  process.exit(1);
}
console.log('files: all checks passed');
