#!/usr/bin/env python3
"""What someone on the network between a phone and Innocent can see, read or
change — measured against the real servers, the way the app talks to them.

    transport_check.py            (SB_URL and SB_KEY in the environment)

The owner's question (2026-10-26): can the film path be intercepted and
read, can an attacker on the path tell what is being watched, and can the
storage behind the Worker be reached or even located? Each section prints
what it found and a verdict; the run fails if a verdict is BAD.

  1. TLS on every host the app talks to: which versions are accepted,
     whether the certificate verifies, what the Worker says about HSTS.
  2. Plain HTTP: does a host answer without TLS, and how.
  3. The door: a token altered by one character, cut short, given extra
     path, or sent with another method, and an old app's unbound token.
  4. What an answer says about where the bytes come from: headers and the
     grant itself, searched for the account, the bucket, the object key.
  5. What a passive observer records: a packet capture of one real fetch,
     searched for the token, the device id and the request's own headers;
     which names are visible (DNS, SNI), and whether the hosts offer
     Encrypted Client Hello.
  6. Expiry: the same token, 10 minutes and 10 seconds later.
  7. Public files (posters, photos, the APK) on the bucket's own domain:
     the APK's fingerprint as the release row states it, no writes, no
     listing, and the r2.dev development URL off (since 2026-10-27; until
     then the two were compared byte for byte). Printed before the
     10-minute wait of 6.

NEVER PRINTS a token, a token URL, the device id or the Worker's host: this
log is public. The Worker's host is masked for the runner's log too.
"""
import hashlib, json, os, re, socket, ssl, subprocess, sys, time, urllib.error, urllib.parse, urllib.request, uuid

UA = 'innocent-transport-check/1'
SINTEL = '0839dacb-59ae-4c95-9279-4901b925965d'
# The public bucket: its own domain since 2026-10-27, and the r2.dev
# development URL it replaced, which stays off: rate-limited, outside the
# zone's rules, and a second address for the same files.
CDN = 'cdn.innocentplayer.com'
DEV_CDN = 'pub-18c62521649645be87d4d36225021e15.r2.dev'

bad = 0


def verdict(ok, label):
    global bad
    bad += not ok
    print(f"{'ok ' if ok else 'BAD'} {label}")


def mask(value):
    # The runner replaces a masked value with *** wherever it is printed.
    print(f'::add-mask::{value}')


def http(url, method='GET', headers=None, body=None, timeout=30):
    h = {'User-Agent': UA, **(headers or {})}
    req = urllib.request.Request(url, data=body, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def run(cmd, timeout=60, stdin=b''):
    p = subprocess.run(cmd, input=stdin, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode('utf-8', 'replace'), p.stderr.decode('utf-8', 'replace')


# ── the grant ─────────────────────────────────────────────────────────────
sb = os.environ['SB_URL'].rstrip('/')
key = os.environ['SB_KEY']
device = 'transport-check-' + uuid.uuid4().hex[:12]
mask(device)
st, _, raw = http(sb + '/functions/v1/request-playback', 'POST',
                  {'apikey': key, 'Content-Type': 'application/json'},
                  json.dumps({'title_id': SINTEL, 'device_id': device, 'bind': True}).encode(), 60)
grant = json.loads(raw or b'{}')
print(f'grant: HTTP {st} via={grant.get("via")}')
if st != 200:
    sys.exit(1)
rungs = sorted([r for r in grant.get('renditions') or [] if r.get('url')],
               key=lambda r: r.get('bytes') or 10 ** 18)
url = rungs[0]['url'] if rungs else grant.get('url')
# STREAM_HOST: the same Worker reached at another of its addresses (a token
# names no host), to prove a new one before request-playback is moved to it.
moved = os.environ.get('STREAM_HOST', '').strip()
if moved:
    if not re.fullmatch(r'[a-z0-9.-]+', moved):
        print('STREAM_HOST is not a host name'); sys.exit(1)
    url = urllib.parse.urlsplit(url)._replace(netloc=moved).geturl()
    print('checking the Worker at the host given in STREAM_HOST')
parts = urllib.parse.urlsplit(url)
worker = parts.netloc
token = parts.path.rsplit('/', 1)[-1]
mask(worker)
mask(token)
origin = f'https://{worker}'
dev = {'X-Innocent-Device': device}
st, _, raw = http(sb + '/functions/v1/request-playback', 'POST',
                  {'apikey': key, 'Content-Type': 'application/json'},
                  json.dumps({'title_id': SINTEL}).encode(), 60)
old = json.loads(raw or b'{}')
old_url = sorted([r for r in old.get('renditions') or [] if r.get('url')],
                 key=lambda r: r.get('bytes') or 10 ** 18)[0]['url']
if moved:
    old_url = urllib.parse.urlsplit(old_url)._replace(netloc=moved).geturl()
mask(urllib.parse.urlsplit(old_url).path.rsplit('/', 1)[-1])
hosts = {'worker': worker, 'supabase': urllib.parse.urlsplit(sb).netloc, 'cdn': CDN}
label_of = lambda n: next((k for k, v in hosts.items() if v == n), 'other')

# ── 1. TLS ────────────────────────────────────────────────────────────────
print('\n== 1. TLS on every host the app talks to')
for label, host in hosts.items():
    got = {}
    for proto in ('tls1', 'tls1_1', 'tls1_2', 'tls1_3'):
        # SECLEVEL=0 so OpenSSL here really OFFERS the old versions: the
        # question is whether the server takes them, not whether we do.
        _, out, err = run(['openssl', 's_client', '-connect', f'{host}:443', '-servername', host,
                           f'-{proto}', '-cipher', 'DEFAULT:@SECLEVEL=0'], 20)
        m = re.search(r'New, (TLSv[\d.]+), Cipher is (\S+)', out + err)
        got[proto] = m.group(1) if m else None
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, 443), timeout=20) as s:
            with ctx.wrap_socket(s, server_hostname=host) as t:
                cert = t.getpeercert()
                ver, cipher = t.version(), t.cipher()[0]
        issuer = dict(x[0] for x in cert['issuer']).get('organizationName')
        verified = True
    except (ssl.SSLError, OSError) as e:
        ver = cipher = issuer = '?'
        cert = {'notAfter': '?'}
        verified = False
        print(f'{label}: {e}')
    print(f"{label:<9} TLS 1.0 {'taken' if got['tls1'] else 'refused'} | 1.1 {'taken' if got['tls1_1'] else 'refused'} | "
          f"1.2 {'taken' if got['tls1_2'] else 'refused'} | 1.3 {'taken' if got['tls1_3'] else 'refused'} | "
          f"a modern client gets {ver} {cipher} | issuer {issuer} | until {cert['notAfter']}")
    verdict(verified, f'{label}: the certificate verifies for its name')
    verdict(ver == 'TLSv1.3', f'{label}: a modern client is given TLS 1.3')
    if got['tls1'] or got['tls1_1']:
        # Not a hole for the app: when both sides speak 1.3, TLS 1.3's
        # downgrade sentinel (RFC 8446 4.1.3) makes forcing an older
        # version detectable, so an attacker cannot push the app down.
        # Cloudflare's edge on workers.dev and r2.dev keeps them for old
        # clients and they cannot be turned off there; the Worker itself
        # refuses a request that came over them (since 2026-10-26).
        print(f'    note: {label}\'s edge still completes a TLS 1.0/1.1 handshake')
        if label == 'worker':
            for proto in ('tls1', 'tls1_1'):
                ask = f'GET /health HTTP/1.1\r\nHost: {host}\r\nUser-Agent: {UA}\r\nConnection: close\r\n\r\n'
                _, out, _ = run(['openssl', 's_client', '-connect', f'{host}:443', '-servername', host,
                                 f'-{proto}', '-cipher', 'DEFAULT:@SECLEVEL=0', '-quiet'], 20, ask.encode())
                m = re.search(r'HTTP/1\.1 (\d{3})', out)
                code = m.group(1) if m else 'no answer'
                verdict(code != '200', f'worker: a request over {proto.replace("tls", "TLS ").replace("_", ".")} is not answered ({code})')
st, h, _ = http(origin + '/health')
print(f"worker /health: HTTP {st}, Strict-Transport-Security: {h.get('Strict-Transport-Security')}")

# ── 2. Plain HTTP ─────────────────────────────────────────────────────────
print('\n== 2. Plain HTTP (no TLS)')
clear = {}
for label, host, path in (('worker', worker, '/health'), ('supabase', hosts['supabase'], '/rest/v1/'),
                          ('cdn', CDN, '/')):
    code, out, err = run(['curl', '-sS', '-o', '/dev/null', '--max-time', '20', '-A', UA,
                          '-w', '%{http_code} %{redirect_url}', f'http://{host}{path}'], 30)
    status, _, where = out.partition(' ')
    how = ('redirects to https' if where.startswith('https://') else
           'no answer' if status in ('', '000') else
           f'refuses ({status})' if status in ('400', '403', '404', '426') else
           f'ANSWERS IN THE CLEAR ({status})')
    print(f'{label:<9} http://…{path:<10} {how}')
    clear[label] = how.startswith('ANSWERS')
# The app never asks over plain HTTP: every address it fetches comes from
# request-playback over TLS and is https://, and Android's network security
# config forbids cleartext to these domains. This is the second line: the
# Worker answers nothing over plain HTTP — /health included, which is how
# this tells "refused for the protocol" from "refused for the token".
verdict(not clear['worker'], 'worker: nothing is answered over plain HTTP')

# ── 3. The door ───────────────────────────────────────────────────────────
print('\n== 3. The door: altered tokens, other methods, old tokens')
rng = {'Range': 'bytes=0-65535'}
st, h, body = http(url, headers={**rng, **dev})
verdict(st == 206 and len(body) == 65536, f'the real token from its own install: HTTP {st}, {len(body)} B')
flip = lambda s, i: s[:i] + ('A' if s[i] != 'A' else 'B') + s[i + 1:]
cases = {
    'one character changed (start)': flip(token, 5),
    'one character changed (middle)': flip(token, len(token) // 2),
    'one character changed (end)': flip(token, len(token) - 2),
    'cut short by 4': token[:-4],
    'with extra path': token + '/x',
    'traversal after it': token + '/..%2f..%2f',
    'empty': '',
}
for name, t in cases.items():
    st, h, body = http(f'{origin}/v/{t}', headers={**rng, **dev})
    verdict(st == 404 and body == b'Not found', f'{name}: HTTP {st}')
# On our own domain a WAF rule refuses these before the Worker runs (403,
# Cloudflare's block page, no film); on workers.dev the Worker does (405).
blocked = lambda st, h: st == 403 and 'cf-ray' in {k.lower() for k in h}
for m in ('POST', 'PUT', 'DELETE', 'PATCH'):
    st, h, body = http(url, method=m, headers=dev, body=b'' if m != 'DELETE' else None)
    verdict((st in (404, 405) and len(body) < 100) or blocked(st, h),
            f'{m} on a real token: HTTP {st}, nothing served' + (' (stopped in front of the Worker)' if st == 403 else ''))
# Paths the Worker has no door for: a scanner's usual first questions.
for path in ('/', '/wp-login.php', '/.env', '/admin'):
    st, h, body = http(origin + path)
    verdict(st in (403, 404) and b'ftyp' not in body,
            f'{path}: HTTP {st}' + (' (stopped in front of the Worker)' if blocked(st, h) else ''))
st, h, _ = http(url, method='OPTIONS', headers={'Origin': 'https://example.com',
                                                 'Access-Control-Request-Method': 'GET'})
verdict('Access-Control-Allow-Origin' not in h, 'a web page elsewhere is given no CORS access')
st, h, body = http(url, headers=rng)
verdict(st == 404, f'the bound token with no install id: HTTP {st}')
st, h, body = http(old_url, headers=rng)
verdict(st == 206, f'an older app\'s unbound token: HTTP {st} (plays, as it must)')

# ── 4. What an answer says about where the bytes live ─────────────────────
print('\n== 4. Does anything the phone receives name the storage?')
st, h, body = http(url, headers={**rng, **dev})
_, h404, _ = http(f'{origin}/v/{flip(token, 5)}')
print('headers on a 206:', ', '.join(sorted(h)))
print('headers on a 404:', ', '.join(sorted(h404)))
tell = re.compile(r'r2\.cloudflarestorage|innocent-(?:media|public)|x-amz|x-r2|bucket|/video/|\b[0-9a-f]{32}\b', re.I)
leaked = [k for k, v in {**h, **h404}.items() if tell.search(k) or tell.search(str(v))]
verdict(not leaked, f'no header names the account, the bucket or the object ({leaked or "none"})')
text = json.dumps(grant)
found = sorted(set(m.group(0).lower() for m in tell.finditer(text)))
verdict(not found, f'the grant names no account, bucket or object key ({found or "none"})')
print('addresses in the grant:', sorted(set(label_of(urllib.parse.urlsplit(u).netloc)
                                            for u in re.findall(r'https?://[^"\s]+', text))))
print('fields in the grant:', sorted(grant), '| per copy:', sorted(rungs[0]) if rungs else '-')

# ── 5. What a passive observer records ────────────────────────────────────
print('\n== 5. A packet capture of one real fetch')
cap = '/tmp/transport.pcap'
tcpd = subprocess.Popen(['sudo', 'tcpdump', '-i', 'any', '-s', '0', '-U', '-w', cap,
                         'port 443 or port 53'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(2)
run(['curl', '-sS', '-o', '/dev/null', '-A', UA, '-H', 'Range: bytes=0-262143',
     '-H', f'X-Innocent-Device: {device}', url], 60)
time.sleep(2)
subprocess.run(['sudo', 'kill', '-INT', str(tcpd.pid)])
tcpd.wait(10)
run(['sudo', 'chmod', '644', cap])
blob = open(cap, 'rb').read()
print(f'captured {len(blob)} bytes')
for name, needle in (('the token', token), ('the device id', device), ('"/v/" (the path)', '/v/'),
                     ('the Range header', 'bytes=0-262143'), ('the device header\'s name', 'X-Innocent-Device'),
                     ('"Content-Range"', 'Content-Range'), ('"ftyp" (the film\'s first box)', 'ftyp')):
    verdict(needle.encode() not in blob, f'{name}: not in the capture')
_, sni, _ = run(['tshark', '-r', cap, '-Y', 'tls.handshake.type == 1', '-T', 'fields',
                 '-e', 'tls.handshake.extensions_server_name'], 60)
_, dns, _ = run(['tshark', '-r', cap, '-Y', 'dns.flags.response == 0', '-T', 'fields', '-e', 'dns.qry.name'], 60)
print('names an observer reads in the clear —')
print('  TLS server name (SNI):', sorted(set(label_of(n) for n in sni.split() if n)) or 'none')
print('  DNS questions:', sorted(set(label_of(n.rstrip('.')) for n in dns.split() if n)) or 'none (resolver cached)')
for lab, host in hosts.items():
    _, out, _ = run(['dig', '+short', 'HTTPS', host], 20)
    print(f"  {lab:<9} DNS HTTPS record: {'ech= present' if 'ech=' in out else ('present, no ech' if out.strip() else 'none')}")

# ── 7. Public files on our own domain ─────────────────────────────────────
print('\n== 7. Posters, photos and the APK on ' + CDN)
read = {'apikey': key, 'Authorization': f'Bearer {key}'}
st, _, raw = http(f'{sb}/rest/v1/titles?id=eq.{SINTEL}&select=poster_url', headers=read)
poster = (json.loads(raw or b'[]') or [{}])[0].get('poster_url') or ''
st, _, raw = http(f'{sb}/rest/v1/app_releases?select=apk_url,apk_bytes,apk_sha256&order=version_code.desc&limit=1',
                  headers=read)
release = (json.loads(raw or b'[]') or [{}])[0]
files = [('poster', urllib.parse.urlsplit(poster).path)] if poster else []
if release.get('apk_url'):
    files.append(('apk', urllib.parse.urlsplit(release['apk_url']).path))
verdict(len(files) == 2, f'the test film\'s poster and the current APK are named ({len(files)} of 2)')
for what, path in files:
    st, h, body = http(f'https://{CDN}{path}', timeout=180)
    digest = hashlib.sha256(body).hexdigest()
    print(f'{what:<6} {CDN}: HTTP {st}, {len(body)} B, cache {h.get("cf-cache-status") or h.get("CF-Cache-Status")}')
    verdict(st == 200 and len(body) > 0, f'{what}: served from {CDN}')
    if what == 'apk':
        verdict(len(body) == release.get('apk_bytes') and digest == release.get('apk_sha256'),
                'apk: the bytes and SHA-256 the release row states (the updater checks both)')
    try:
        st2, _, _ = http(f'https://{DEV_CDN}{path}', timeout=60)
    except (urllib.error.URLError, OSError) as e:
        st2 = f'no answer ({type(e).__name__})'
    verdict(st2 != 200, f'{what}: not served at r2.dev ({st2})')
    # A public bucket is read-only to the world: a write is refused by R2
    # (401) or stopped in front of it (403).
    st, h, body = http(f'https://{CDN}{path}', method='PUT', body=b'x')
    verdict(st in (400, 401, 403, 405, 501), f'{what}: PUT refused (HTTP {st})')
# R2 answers a missing key with its own error page (a few KB): what matters
# is that it is not a listing of the bucket.
listing = lambda b: b'ListBucketResult' in b or b'<Key>' in b or b'apk/' in b
for path in ('/', '/.env', '/wp-login.php'):
    st, _, body = http(f'https://{CDN}{path}')
    verdict(st in (403, 404) and not listing(body), f'{CDN}{path}: HTTP {st}, no listing')

# ── 6. Expiry ─────────────────────────────────────────────────────────────
print('\n== 6. The same token after its 10 minutes')
time.sleep(610)
st, h, body = http(url, headers={**rng, **dev})
verdict(st == 404, f'610 s later: HTTP {st}')

print()
if bad:
    print(f'{bad} check(s) BAD')
    sys.exit(1)
print('every transport check passed')
