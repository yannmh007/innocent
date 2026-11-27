// The online subtitles' rules (docs/edge/subtitles_os.js, used by
// docs/edge/subtitles-online.ts).
//
// WHY. The function stands between every viewer and one OpenSubtitles
// account: what it sends must be one clean URL per search (sorted, lower
// case, no stray parameter a viewer could add), and what it sends back must
// be the list the app draws — never a download link, never more than 40
// rows, the film's own file first. A bad file id or hash is refused before
// anything is asked of OpenSubtitles.
//
//   node tool/js/subtitles_os_test.mjs

import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const os = await import(join(ROOT, 'docs/edge/subtitles_os.js'));
let failed = 0;
const check = (what, ok) => {
  if (ok) console.log('ok   ' + what);
  else { failed += 1; console.log('FAIL ' + what); }
};

// The search's URL.
let r = os.searchParams({ query: '  Big  Buck BUNNY ', languages: ['MY', 'en', 'xx-yy-zz', 'en'] });
check('query and languages sorted, lower case, one space',
  r.params === 'languages=en%2Cmy&query=big%20buck%20bunny');
r = os.searchParams({ moviehash: '8E245D9679D31E12', page: 2, season: 1, episode: 3, evil: 'x' });
check('hash, page, season, episode kept; an unknown field dropped',
  r.params === 'episode_number=3&moviehash=8e245d9679d31e12&page=2&season_number=1');
check('a short hash is refused', 'error' in os.searchParams({ moviehash: 'abc' }));
check('nothing to search is refused', 'error' in os.searchParams({ languages: 'en' }));
check('a query over 120 characters is refused', 'error' in os.searchParams({ query: 'x'.repeat(121) }));
check('page 1 and page 9 are not sent',
  os.searchParams({ query: 'a', page: 1 }).params === 'query=a' &&
  os.searchParams({ query: 'a', page: 9 }).params === 'query=a');
check('Burmese words kept (NFC, encoded)',
  os.searchParams({ query: 'မြန်မာ' }).params === 'query=' + encodeURIComponent('မြန်မာ'.normalize('NFC')));
check('at most four languages', os.languages('en,my,th,fr,de').length === 4);

// The list.
const answer = {
  data: [
    { attributes: { language: 'en', release: 'A.Release', download_count: 900, files: [{ file_id: 11, file_name: 'a.srt' }], feature_details: { title: 'Film', year: 2008 }, url: 'https://example.invalid/x' } },
    { attributes: { language: 'my', release: 'B', download_count: 5, files: [{ file_id: 12, file_name: 'b.srt' }] } },
    { attributes: { language: 'en', release: 'C', download_count: 10, moviehash_match: true, files: [{ file_id: 13, file_name: 'c.srt' }] } },
    { attributes: { language: 'my', release: 'D', download_count: 50, ai_translated: true, files: [{ file_id: 14, file_name: 'd.srt' }] } },
    { attributes: { language: 'en', files: [{ file_id: 'x' }, { file_id: -1 }] } },
  ],
};
const rows = os.shapeSearch(answer, ['my', 'en']);
check('bad file ids dropped', rows.length === 4);
check('the film\'s own file first', rows[0].file_id === 13);
check('then the first language asked, a machine translation after a person\'s',
  rows[1].file_id === 12 && rows[2].file_id === 14);
check('then the rest by downloads', rows[3].file_id === 11);
check('no link or url in a row', rows.every((x) => !JSON.stringify(x).includes('http')));
check('title and year kept', rows[3].title === 'Film' && rows[3].year === 2008);
const many = { data: Array.from({ length: 100 }, (_, i) => ({ attributes: { language: 'en', files: [{ file_id: i + 1 }] } })) };
check('at most 40 rows', os.shapeSearch(many).length === 40);
check('an empty or odd answer is an empty list',
  os.shapeSearch(null).length === 0 && os.shapeSearch({ data: 'x' }).length === 0);

// The download.
check('a download asks for SubRip', JSON.stringify(os.downloadBody('77')) === '{"file_id":77,"sub_format":"srt"}');
check('a bad file id asks nothing', os.downloadBody('7x') === null && os.downloadBody(0) === null);
const now = Date.UTC(2026, 10, 28, 10, 0, 0);
check('quota back at the answer\'s reset time',
  os.secondsToReset({ reset_time_utc: '2026-11-28T12:00:00.000Z' }, now) === 7200);
check('else at the next UTC midnight', os.secondsToReset({}, now) === 14 * 3600);
check('Retry-After read, bounded', os.retryAfter('3') === 3 && os.retryAfter('x') === 10 && os.retryAfter('99999') === 3600);
check('the saved name is safe and .srt',
  os.safeName('../../a<b>.SRT', 5) === 'a b.srt' && os.safeName('', 5) === 'subtitle-5.srt');
check('a login\'s base_url only when it is OpenSubtitles\'',
  os.apiFor('vip-api.opensubtitles.com') === 'https://vip-api.opensubtitles.com/api/v1/' &&
  os.apiFor('https://evil.example.com') === os.API && os.apiFor('opensubtitles.com.evil.io') === os.API);

if (failed) {
  console.log(`${failed} failed`);
  process.exit(1);
}
console.log('subtitles_os: all passed');
