// The signatures R2 will accept, and the multipart body S3 will accept.
//
// WHY THIS IS TESTED RATHER THAN READ. Nothing in this file can be tried
// against the real bucket from a checkout — the credentials live in Supabase's
// secret store and R2 is not reachable from CI. And every way of getting SigV4
// wrong fails the same way: HTTP 403 SignatureDoesNotMatch, with a body that
// names no parameter, no header and no reason. A canonical query in the wrong
// order, a header listed in SignedHeaders that is not sent, a payload hash that
// disagrees with the `x-amz-content-sha256` header, a `partNumber` appended to
// a finished URL — all of them are that one opaque 403, discovered by an
// operator halfway through a four-gigabyte master.
//
// So the real functions are pulled out of `docs/edge/studio.ts` (never copied —
// a copy would pass this test forever while the file drifted) and checked
// against an INDEPENDENT signer written here on node's crypto, which is itself
// first verified against AWS's own published example. Two implementations that
// agree, one of which is known-correct against the vector.
//
// The multipart XML is tested for the same reason one level up: S3 rejects a
// CompleteMultipartUpload whose parts are not in ascending order, and takes an
// ETag only in exactly one quoting. Both are silent until the upload that has
// already cost the operator an hour of data fails at the last step.
//
// RUN:  node tool/js/sigv4_test.mjs
// tool/check.py runs it when node is present, and says so loudly when not.

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createHash, createHmac } from 'crypto';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

let failures = 0;
const check = (label, ok) => {
  console.log((ok ? 'ok   ' : 'FAIL ') + label);
  if (!ok) failures++;
};

// ── the independent signer, on node's crypto ─────────────────────────────
const sha = (s) => createHash('sha256').update(s, 'utf8').digest('hex');
const mac = (k, s) => createHmac('sha256', k).update(s, 'utf8').digest();

function sigv4({
  method, canonicalUri, canonicalQuery = '', headers, payloadHash,
  amzDate, region, service, secret,
}) {
  const names = Object.keys(headers).map((h) => h.toLowerCase()).sort();
  const canonicalHeaders = names.map((n) => `${n}:${headers[n]}\n`).join('');
  const signedHeaders = names.join(';');
  const canonicalRequest = [method, canonicalUri, canonicalQuery,
    canonicalHeaders, signedHeaders, payloadHash].join('\n');
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope,
    sha(canonicalRequest)].join('\n');
  let k = Buffer.from(`AWS4${secret}`, 'utf8');
  for (const p of [dateStamp, region, service, 'aws4_request']) k = mac(k, p);
  return {
    canonicalRequestHash: sha(canonicalRequest),
    signedHeaders,
    scope,
    signature: mac(k, stringToSign).toString('hex'),
  };
}

// 1. THE VECTOR. AWS publishes this worked example (GET Object with a Range
//    header) with the intermediate values, so it proves the signer above
//    before it is used to judge anybody else's.
{
  const got = sigv4({
    method: 'GET',
    canonicalUri: '/test.txt',
    headers: {
      host: 'examplebucket.s3.amazonaws.com',
      range: 'bytes=0-9',
      'x-amz-content-sha256': sha(''),
      'x-amz-date': '20130524T000000Z',
    },
    payloadHash: sha(''),
    amzDate: '20130524T000000Z',
    region: 'us-east-1',
    service: 's3',
    secret: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
  });
  check('the reference signer reproduces AWS\'s published canonical hash',
    got.canonicalRequestHash ===
      '7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972');
  check('the reference signer reproduces AWS\'s published signature',
    got.signature ===
      'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41');
  check('the empty-payload hash is the one AWS documents',
    sha('') ===
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
}

// ── the real thing, lifted out of the edge function ──────────────────────
const src = readFileSync(join(ROOT, 'docs/edge/studio.ts'), 'utf8');

// Strip the TypeScript the plain-JavaScript parser cannot take. Only the
// signatures carry types; every body below is JavaScript already.
const ts = (s) => s
  .replace(/interface SignedReq \{[\s\S]*?\}/g, '')
  .replace(/ as BufferSource/g, '')
  .replace(/ as Record<string, unknown>/g, '')
  .replace(/: Promise<[^>]*>/g, '')
  .replace(/: Record<string, string>/g, '')
  .replace(/: string \| null/g, '')
  .replace(/: Uint8Array\b/g, '')
  .replace(/: string\b/g, '')
  .replace(/: boolean\b/g, '');

const between = (from, to) => {
  const a = src.indexOf(from);
  const b = src.indexOf(to);
  if (a < 0 || b < 0 || b <= a) {
    console.log('FAIL could not find ' + JSON.stringify(from) + ' .. ' +
      JSON.stringify(to) + ' in docs/edge/studio.ts');
    process.exit(1);
  }
  return src.slice(a, b);
};

// The expiry is read out of the file rather than repeated, so the assertion
// below is about the real number and not about a copy of it.
const EXPIRY = Number(/const EXPIRY_SECONDS = (\d+)/.exec(src)[1]);

// Credentials that exist only here. The account id has to be a real-looking
// hex string because it becomes the host, and the host is signed.
const ACCOUNT = '0123456789abcdef0123456789abcdef';
const ACCESS = 'AKIAIOSFODNN7EXAMPLE';
const SECRET = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';
const HOST = `${ACCOUNT}.r2.cloudflarestorage.com`;

const signers = await import('data:text/javascript,' + encodeURIComponent(
  `const R2_ACCOUNT_ID = ${JSON.stringify(ACCOUNT)};\n` +
  `const R2_ACCESS_KEY_ID = ${JSON.stringify(ACCESS)};\n` +
  `const R2_SECRET_ACCESS_KEY = ${JSON.stringify(SECRET)};\n` +
  `const EXPIRY_SECONDS = ${EXPIRY};\n` +
  ts(between('const enc = new TextEncoder();',
    '/// One tag out of an S3 XML response.')) +
  ts(between('function xmlTag(', '/// An object key the operator is allowed')) +
  ts(between('function isMintedKey(', '// --- who is asking')) +
  '\nexport function completeBody(body) {\n' +
  '  const req = null;\n' +
  '  const json = (o) => { throw new Error(String(o.error)); };\n' +
  ts(between('const raw = Array.isArray(body.parts)',
    "'</CompleteMultipartUpload>';")) +
  "'</CompleteMultipartUpload>';\n  return xmlBody;\n}\n" +
  '\nexport { presignPut, signRequest, xmlTag, isMintedKey, encodeKey };'
));

const KEY = 'solar-2026/video/20260922-solar-a1b2c3d4.mp4';
const CANON_PATH = `/mx-media/${KEY}`;

// ── presignPut: the URL the browser uploads a part to ────────────────────
//
// 2. Its signature is the one an independent implementation computes for the
//    same request. This is the whole of SigV4 query signing in one assertion:
//    method, path, every query parameter, the host header and
//    UNSIGNED-PAYLOAD.
function recomputePresign(url) {
  const u = new URL(url);
  const params = [...u.searchParams.keys()]
    .filter((k) => k !== 'X-Amz-Signature').sort()
    .map((k) => `${k}=${encodeURIComponent(u.searchParams.get(k))
      .replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase())}`)
    .join('&');
  return sigv4({
    method: 'PUT',
    canonicalUri: u.pathname,
    canonicalQuery: params,
    headers: { host: u.host },
    payloadHash: 'UNSIGNED-PAYLOAD',
    amzDate: u.searchParams.get('X-Amz-Date'),
    region: 'auto',
    service: 's3',
    secret: SECRET,
  }).signature;
}

{
  const url = await signers.presignPut('mx-media', KEY);
  const u = new URL(url);
  check('a presigned PUT signs as an independent implementation signs it',
    u.searchParams.get('X-Amz-Signature') === recomputePresign(url));
  check('the presigned URL addresses the object it was asked for',
    u.host === HOST && u.pathname === CANON_PATH);
  check('the presigned URL carries the expiry the function declares',
    u.searchParams.get('X-Amz-Expires') === String(EXPIRY));
  check('the presigned URL signs only the host header',
    u.searchParams.get('X-Amz-SignedHeaders') === 'host');
}

// 3. THE PART PARAMETERS ARE INSIDE THE SIGNATURE. `partNumber` and `uploadId`
//    go through the signer rather than being appended to a finished URL. An
//    appended parameter is refused as SignatureDoesNotMatch — a 403 that names
//    nothing — so this is asserted from both sides: the signature matches when
//    they are counted, and does not when they are not.
{
  const url = await signers.presignPut('mx-media', KEY, {
    partNumber: '7', uploadId: 'abc-XYZ_123.def~ghi',
  });
  const u = new URL(url);
  check('a part URL carries partNumber and uploadId',
    u.searchParams.get('partNumber') === '7' &&
    u.searchParams.get('uploadId') === 'abc-XYZ_123.def~ghi');
  check('the part parameters are covered by the signature',
    u.searchParams.get('X-Amz-Signature') === recomputePresign(url));

  // The same URL with the two parameters dropped from the canonical query —
  // what appending them afterwards would amount to — signs differently.
  const withoutParts = new URL(url);
  withoutParts.searchParams.delete('partNumber');
  withoutParts.searchParams.delete('uploadId');
  check('appending a parameter afterwards would NOT have signed',
    recomputePresign(withoutParts.toString()) !==
      u.searchParams.get('X-Amz-Signature'));

  // 4. Sorted, and the signature last. SigV4 requires the canonical query in
  //    ascending order; the signature itself is not part of what it signs.
  const order = [...u.searchParams.keys()];
  const signed = order.slice(0, -1);
  check('the canonical query is in ascending order',
    JSON.stringify(signed) === JSON.stringify([...signed].sort()));
  check('X-Amz-Signature is appended after the signed query',
    order[order.length - 1] === 'X-Amz-Signature');
}

// 5. A part number that changes changes the signature. Reusing one part's URL
//    for another part would otherwise write the wrong bytes at the wrong index
//    and produce a file of exactly the right length that plays as noise.
{
  const a = new URL(await signers.presignPut('mx-media', KEY,
    { partNumber: '1', uploadId: 'u' })).searchParams.get('X-Amz-Signature');
  const b = new URL(await signers.presignPut('mx-media', KEY,
    { partNumber: '2', uploadId: 'u' })).searchParams.get('X-Amz-Signature');
  check('two part numbers sign differently', a !== b);
}

// ── signRequest: begin, complete and abort, with a real payload hash ─────
function recomputeSigned(method, path, canonicalQuery, signed) {
  return sigv4({
    method,
    canonicalUri: path,
    canonicalQuery,
    headers: {
      host: HOST,
      'x-amz-content-sha256': signed.headers['x-amz-content-sha256'],
      'x-amz-date': signed.headers['x-amz-date'],
    },
    // Deliberately the HEADER's value and not a fresh hash of the body: if the
    // function put a different hash in the canonical request than it sends in
    // the header, this recomputation disagrees and the check fails. That
    // mismatch is the one SigV4 error R2 reports as a signature problem rather
    // than a content problem.
    payloadHash: signed.headers['x-amz-content-sha256'],
    amzDate: signed.headers['x-amz-date'],
    region: 'auto',
    service: 's3',
    secret: SECRET,
  });
}

const authOf = (signed) => {
  const m = /^AWS4-HMAC-SHA256 Credential=([^,]+), SignedHeaders=([^,]+), Signature=([0-9a-f]+)$/
    .exec(signed.headers['Authorization']);
  return m ? { credential: m[1], signedHeaders: m[2], signature: m[3] } : null;
};

// 6. CreateMultipartUpload: POST ?uploads with an empty body.
{
  const signed = await signers.signRequest(
    'POST', 'mx-media', KEY, { uploads: '' }, '');
  const auth = authOf(signed);
  check('the Authorization header has the shape R2 parses', auth !== null);
  check('begin addresses ?uploads on the object',
    signed.url === `https://${HOST}${CANON_PATH}?uploads=`);
  check('the signed headers are host;x-amz-content-sha256;x-amz-date, in order',
    auth.signedHeaders === 'host;x-amz-content-sha256;x-amz-date');
  const ref = recomputeSigned('POST', CANON_PATH, 'uploads=', signed);
  check('begin signs as an independent implementation signs it',
    auth.signature === ref.signature);
  check('the credential scope is the region and service R2 wants',
    auth.credential === `${ACCESS}/${signed.headers['x-amz-date'].slice(0, 8)}/auto/s3/aws4_request`);
  check('an empty body is hashed, not declared unsigned',
    signed.headers['x-amz-content-sha256'] === sha(''));
}

// 7. THE HEADERS SENT ARE EXACTLY THE HEADERS SIGNED. A header named in
//    SignedHeaders and not sent — or sent and not named — is a bare 403. `host`
//    is the one exception: fetch sets it from the URL and forbids setting it by
//    hand.
{
  const signed = await signers.signRequest(
    'DELETE', 'mx-media', KEY, { uploadId: 'u-1' }, '');
  const named = authOf(signed).signedHeaders.split(';')
    .filter((h) => h !== 'host');
  const sent = Object.keys(signed.headers)
    .map((h) => h.toLowerCase()).filter((h) => h !== 'authorization');
  check('every signed header is one the function actually sends',
    JSON.stringify(named.sort()) === JSON.stringify(sent.sort()));
  check('abort signs as an independent implementation signs it',
    authOf(signed).signature ===
      recomputeSigned('DELETE', CANON_PATH, 'uploadId=u-1', signed).signature);
}

// 8. The method is signed. The same request as POST and as DELETE cannot share
//    a signature, or an abort URL would complete an upload.
{
  const q = { uploadId: 'u-1' };
  const post = await signers.signRequest('POST', 'mx-media', KEY, q, '');
  const del = await signers.signRequest('DELETE', 'mx-media', KEY, q, '');
  check('POST and DELETE sign differently',
    authOf(post).signature !== authOf(del).signature ||
      post.headers['x-amz-date'] !== del.headers['x-amz-date']);
}

// 9. THE BODY IS SIGNED, and the hash the function publishes is the hash of
//    what it will send. CompleteMultipartUpload is the only request here with a
//    body, and it is the one that finalises the object.
{
  const body = '<CompleteMultipartUpload><Part><PartNumber>1</PartNumber>' +
    '<ETag>"abc"</ETag></Part></CompleteMultipartUpload>';
  const signed = await signers.signRequest(
    'POST', 'mx-media', KEY, { uploadId: 'u-1' }, body);
  check('the published payload hash is the hash of the body',
    signed.headers['x-amz-content-sha256'] === sha(body));
  check('complete signs as an independent implementation signs it',
    authOf(signed).signature ===
      recomputeSigned('POST', CANON_PATH, 'uploadId=u-1', signed).signature);

  const other = await signers.signRequest(
    'POST', 'mx-media', KEY, { uploadId: 'u-1' }, body + ' ');
  check('one changed byte in the body changes the hash',
    other.headers['x-amz-content-sha256'] !==
      signed.headers['x-amz-content-sha256']);
}

// 10. No query, no question mark. `?` with nothing after it is not the same
//     canonical request, and R2 would be signing something the URL does not say.
{
  const signed = await signers.signRequest('PUT', 'mx-media', KEY, {}, '');
  check('an empty query leaves the URL without a ?',
    signed.url === `https://${HOST}${CANON_PATH}`);
}

// 11. Several parameters are sorted. The page never sends two today; the signer
//     is shared with presignPut, which does.
{
  const signed = await signers.signRequest(
    'POST', 'mx-media', KEY, { uploadId: 'u', partNumber: '3', a: 'b' }, '');
  check('a multi-parameter query is sorted', signed.url.endsWith(
    '?a=b&partNumber=3&uploadId=u'));
  check('and the sorted query is what was signed',
    authOf(signed).signature === recomputeSigned(
      'POST', CANON_PATH, 'a=b&partNumber=3&uploadId=u', signed).signature);
}

// 12. The path is encoded per segment. A slash separates segments and must stay
//     a slash; everything else in a segment is escaped, or the canonical path
//     and the URL disagree.
{
  check('slashes are kept and spaces escaped',
    signers.encodeKey('a b/video/x y.mp4') === 'a%20b/video/x%20y.mp4');
  check('the characters encodeURIComponent leaves alone are escaped too',
    signers.encodeKey("v/a(b)c!'*.mp4") === 'v/a%28b%29c%21%27%2A.mp4');
}

// ── the object key a page is allowed to name ─────────────────────────────
//
// 13. `complete` and `abort` take a key from the browser, and a key from a
//     browser is a path. Without this guard a stale tab could finalise a
//     multipart upload onto an object somebody is watching.
{
  for (const good of [
    'solar-2026/video/20260922-solar-a1b2c3d4.mp4',
    'video/x.mp4',
    'a/b/c/thumb/1.jpg',
    'folder/photo/2026-09-22.jpg',
  ]) check(`a minted key is accepted (${good})`, signers.isMintedKey(good));

  for (const bad of [
    '',
    '/video/x.mp4',
    'video/../../etc/passwd',
    '../video/x.mp4',
    'evideo/x.mp4',
    'other/x.mp4',
    'video/X.mp4',
    'video/',
    'video/-x.mp4',
    'video/x.mp4/y',
    'video/' + 'x'.repeat(600),
  ]) check(`a key the function never mints is refused (${JSON.stringify(bad.slice(0, 22))})`,
    !signers.isMintedKey(bad));
}

// ── the XML read back out of S3 ──────────────────────────────────────────
{
  const begun = '<?xml version="1.0"?><InitiateMultipartUploadResult>' +
    '<Bucket>mx-media</Bucket><Key>video/x.mp4</Key>' +
    '<UploadId>ABC.123-_xyz</UploadId></InitiateMultipartUploadResult>';
  check('the upload id is read out of the begin response',
    signers.xmlTag(begun, 'UploadId') === 'ABC.123-_xyz');
  check('a tag that is not there reads as nothing, and does not throw',
    signers.xmlTag(begun, 'Message') === null);
  check('the walk does not run past the element it was asked for',
    signers.xmlTag(begun, 'Bucket') === 'mx-media');
  check('an error message is read out of a failure',
    signers.xmlTag('<Error><Code>NoSuchUpload</Code><Message>no</Message></Error>',
      'Message') === 'no');
}

// ── the body S3 will accept for CompleteMultipartUpload ──────────────────
//
// 14. ASCENDING PART NUMBERS, WHATEVER ORDER THEY ARRIVED IN. S3 refuses the
//     whole upload otherwise. The page uploads sequentially today, which is
//     exactly the kind of thing a later change to parallel uploads breaks
//     silently.
{
  const xml = signers.completeBody({ parts: [
    { partNumber: 3, etag: 'ccc' },
    { partNumber: 1, etag: 'aaa' },
    { partNumber: 2, etag: 'bbb' },
  ] });
  check('the parts come out in ascending order',
    xml === '<CompleteMultipartUpload>' +
      '<Part><PartNumber>1</PartNumber><ETag>"aaa"</ETag></Part>' +
      '<Part><PartNumber>2</PartNumber><ETag>"bbb"</ETag></Part>' +
      '<Part><PartNumber>3</PartNumber><ETag>"ccc"</ETag></Part>' +
      '</CompleteMultipartUpload>');

  // 15. AND EXACTLY ONE QUOTING. R2 answers the part upload with a quoted ETag
  //     in a header; S3 wants it quoted in the XML. Sending it bare or doubly
  //     quoted is an InvalidPart on a finished transfer.
  const quoted = signers.completeBody({ parts: [
    { partNumber: 1, etag: '"aaa"' },
    { partNumber: 2, etag: 'bbb' },
    { partNumber: 3, etag: '""ccc""' },
  ] });
  check('every ETag is quoted exactly once, however it arrived',
    quoted.includes('<ETag>"aaa"</ETag>') &&
    quoted.includes('<ETag>"bbb"</ETag>') &&
    quoted.includes('<ETag>"ccc"</ETag>'));

  // 16. A part with no ETag is refused rather than dropped. Dropping it would
  //     complete the upload without those bytes — a shorter file that plays
  //     until it stops.
  for (const bad of [
    [{ partNumber: 1, etag: 'a' }, { partNumber: 2, etag: '' }],
    [{ partNumber: 1, etag: 'a' }, { partNumber: 0, etag: 'b' }],
    [{ partNumber: 1, etag: 'a' }, null],
  ]) {
    let refused = false;
    try { signers.completeBody({ parts: bad }); } catch (e) {
      refused = e.message === 'bad_parts';
    }
    check('an incomplete part list is refused, not silently shortened',
      refused);
  }

  let noParts = false;
  try { signers.completeBody({ parts: [] }); } catch (e) {
    noParts = e.message === 'no_parts';
  }
  check('no parts at all is refused', noParts);
}

// ── the BUCKET-level signer, and the list parsing that depends on it ──────
//
// `presignBucketGet` in probe-media.ts is what makes the unused-file report
// possible, and it is the one signer in this project that signs a path with no
// object in it AND folds caller-supplied parameters into the signed query.
// Both are new ways to be wrong and both fail as the same opaque 403:
//
//   * a canonical path of `/bucket/` rather than `/bucket`;
//   * `list-type=2` appended to the finished URL instead of signed, which is
//     the mistake that looks most like working code;
//   * a parameter sorted before signing but appended after, so the query the
//     server canonicalises is not the query that was signed.
//
// The XML readers are checked here too, because the failure they cause is
// worse than a 403. A key mis-decoded is a key the catalogue cannot match, so
// it lands in a list headed "nothing points at these" — and the operator's next
// action is to delete it.
{
  const psrc = readFileSync(join(ROOT, 'docs/edge/probe-media.ts'), 'utf8');
  const pts = (x) => x
    .replace(/ as BufferSource/g, '')
    .replace(/: Promise<[^>]*>/g, '')
    .replace(/: Record<string, string>/g, '')
    .replace(/: Uint8Array\b/g, '')
    .replace(/: string\[\]/g, '')
    .replace(/: string\b/g, '')
    .replace(/<Uint8Array>/g, '');
  const pbetween = (from, to) => {
    const a = psrc.indexOf(from);
    const b = psrc.indexOf(to);
    if (a < 0 || b < 0 || b <= a) {
      console.log('FAIL could not find ' + JSON.stringify(from) + ' .. ' +
        JSON.stringify(to) + ' in docs/edge/probe-media.ts');
      process.exit(1);
    }
    return psrc.slice(a, b);
  };

  const BUCKET = 'innocent-media';
  const probe = await import('data:text/javascript,' + encodeURIComponent(
    `const R2_ACCOUNT_ID = ${JSON.stringify(ACCOUNT)};\n` +
    `const R2_ACCESS_KEY_ID = ${JSON.stringify(ACCESS)};\n` +
    `const R2_SECRET_ACCESS_KEY = ${JSON.stringify(SECRET)};\n` +
    `const MEDIA_BUCKET = ${JSON.stringify(BUCKET)};\n` +
    pts(pbetween('const enc = new TextEncoder();',
      '// --- the actual question')) +
    '\nexport { presignGet, presignBucketGet, xmlBlocks, xmlTag, unescapeXml, decodeKey };'
  ));

  // 1. A bucket listing, signed and then judged by the independent signer.
  {
    const url = new URL(await probe.presignBucketGet(BUCKET, {
      'list-type': '2',
      'max-keys': '1000',
      'encoding-type': 'url',
      'continuation-token': '1/abc+def=/ghi',
    }));
    check('the bucket listing is signed against the bucket path, with no '
      + 'trailing slash', url.pathname === `/${BUCKET}`);

    const q = url.searchParams;
    // EVERY caller parameter has to be inside SignedHeaders' sibling — the
    // canonical query — which means it has to be present here AND have been
    // part of the string that was signed. Rebuilding the canonical query from
    // the URL minus the signature is exactly what R2 does.
    const pairs = [];
    for (const [k, v] of q.entries()) {
      if (k === 'X-Amz-Signature') continue;
      pairs.push([k, v]);
    }
    const rfc = (c) => encodeURIComponent(c)
      .replace(/[!'()*]/g, (x) => '%' + x.charCodeAt(0).toString(16).toUpperCase());
    const canonicalQuery = pairs
      .map(([k, v]) => `${rfc(k)}=${rfc(v)}`).sort().join('&');
    const amzDate = q.get('X-Amz-Date');
    const mine = sigv4({
      method: 'GET',
      canonicalUri: `/${BUCKET}`,
      canonicalQuery,
      headers: { host: HOST },
      payloadHash: 'UNSIGNED-PAYLOAD',
      amzDate,
      region: 'auto',
      service: 's3',
      secret: SECRET,
    });
    check('the bucket listing signature matches an independent signer',
      q.get('X-Amz-Signature') === mine.signature);
    check('list-type is SIGNED rather than appended afterwards',
      q.get('list-type') === '2');
    check('the continuation token survives signing intact',
      q.get('continuation-token') === '1/abc+def=/ghi');
    check('encoding-type=url is asked for, so a key XML cannot carry still '
      + 'comes back', q.get('encoding-type') === 'url');
    check('only host is signed', q.get('X-Amz-SignedHeaders') === 'host');
  }

  // 2. The multipart listing is the same signer with a valueless parameter.
  //    `?uploads` is a flag, and SigV4 requires `uploads=` in the canonical
  //    query — dropping the `=` is a 403.
  {
    const url = new URL(await probe.presignBucketGet(BUCKET, {
      uploads: '', 'max-uploads': '200', 'encoding-type': 'url',
    }));
    check('the unfinished-upload listing signs `uploads` as an empty value',
      url.search.includes('uploads=&') || url.search.includes('&uploads=&') ||
      /[?&]uploads=(&|$)/.test(url.search));
    const q = url.searchParams;
    const pairs = [];
    for (const [k, v] of q.entries()) {
      if (k === 'X-Amz-Signature') continue;
      pairs.push([k, v]);
    }
    const rfc = (c) => encodeURIComponent(c)
      .replace(/[!'()*]/g, (x) => '%' + x.charCodeAt(0).toString(16).toUpperCase());
    const mine = sigv4({
      method: 'GET',
      canonicalUri: `/${BUCKET}`,
      canonicalQuery: pairs.map(([k, v]) => `${rfc(k)}=${rfc(v)}`).sort().join('&'),
      headers: { host: HOST },
      payloadHash: 'UNSIGNED-PAYLOAD',
      amzDate: q.get('X-Amz-Date'),
      region: 'auto',
      service: 's3',
      secret: SECRET,
    });
    check('the unfinished-upload listing signature matches an independent '
      + 'signer', q.get('X-Amz-Signature') === mine.signature);
  }

  // 3. The object presigner still signs the object path, so adding the bucket
  //    one did not break it.
  {
    const url = new URL(await probe.presignGet('v/a b&c.mp4'));
    check('an object is still signed under bucket/key',
      url.pathname === `/${BUCKET}/v/a%20b%26c.mp4`);
  }

  // 4. The XML readers. Each case here is a key that would otherwise be
  //    reported as unreferenced and deleted.
  {
    const xml = '<ListBucketResult>'
      + '<IsTruncated>true</IsTruncated>'
      + '<Contents><Key>v%2Fa%26b.mp4</Key><Size>1234</Size>'
      + '<LastModified>2026-01-02T03:04:05.000Z</LastModified></Contents>'
      + '<Contents><Key>t%2F%E1%80%99.mp4</Key><Size>7</Size>'
      + '<LastModified>2026-09-26T00:00:00.000Z</LastModified></Contents>'
      + '<NextContinuationToken>abc123==</NextContinuationToken>'
      + '</ListBucketResult>';
    const blocks = probe.xmlBlocks(xml, 'Contents');
    check('every Contents block is found, not just the first',
      blocks.length === 2);
    const keyOf = (b) => probe.decodeKey(
      (/<Key>([\s\S]*?)<\/Key>/.exec(b) || ['', ''])[1]);
    check('a key containing & survives the round trip',
      keyOf(blocks[0]) === 'v/a&b.mp4');
    // A Burmese filename is not hypothetical here.
    check('a non-ASCII key decodes to itself',
      keyOf(blocks[1]) === 't/\u1019.mp4');
    check('the size is read as a number', probe.xmlTag(blocks[0], 'Size') === '1234');
    check('truncation is read', probe.xmlTag(xml, 'IsTruncated') === 'true');
    check('the continuation token is read, padding and all',
      probe.xmlTag(xml, 'NextContinuationToken') === 'abc123==');
    // ORDER OF THE ENTITIES. Replacing &amp; first turns the escaping of the
    // literal text "&lt;" into "<" — a different key, reported as unreferenced.
    check('&amp;lt; unescapes to the text &lt; and not to <',
      probe.unescapeXml('&amp;lt;') === '&lt;');
    check('all five predefined entities are handled',
      probe.unescapeXml('&lt;&gt;&quot;&apos;&amp;') === '<>"\'&');
    // A key this code cannot decode must come back unchanged rather than be
    // dropped: a dropped key is a key nothing reports and nothing reaches.
    check('an invalid percent escape returns the key verbatim',
      probe.decodeKey('v%2Gbroken') === 'v%2Gbroken');
    check('a missing tag reads as empty rather than throwing',
      probe.xmlTag('<a></a>', 'Size') === '');
  }
}

if (failures) {
  console.error(failures + ' sigv4/multipart check(s) failed');
  process.exit(1);
}
console.log('sigv4 + multipart: all checks passed');
