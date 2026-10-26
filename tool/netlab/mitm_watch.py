"""A mitmproxy addon for the device lab's `mitm` flow: what an attacker in
the middle of the phone's connection gets, written down without keeping it.

The emulator is started behind mitmproxy (`-http-proxy`), so every TCP
connection the app opens is handed to the proxy, which answers the app's
TLS with a certificate of its own making — the man in the middle. The app
should refuse that certificate. This records, per connection, only:

  * which service it was for, by kind (worker, supabase, cdn, google,
    other), never the Worker's own host name;
  * whether the app refused the proxy's certificate or accepted it;
  * for a connection the proxy could read: the method, what kind of path
    (`/v/<token>`, `/rest/v1/…`), the response status and the NAMES of the
    request's headers — never a value, never a path, never a body.

Nothing is saved but those lines (no flow file). The lab writes them to
out/mitm_events.jsonl through MITM_EVENTS.
"""
import json
import os
import re
import time

from mitmproxy import http, tls

OUT = os.environ.get('MITM_EVENTS', '/tmp/mitm_events.jsonl')


def kind(host):
    host = (host or '').lower().rstrip('.')
    if host.endswith('.workers.dev'):
        return 'worker'
    if host.endswith('.supabase.co'):
        return 'supabase'
    if host.endswith('.r2.dev'):
        return 'cdn'
    if host.endswith(('.google.com', '.googleapis.com', '.gstatic.com', '.android.com',
                      '.googleusercontent.com', '.gvt1.com', '.gvt2.com', '.doubleclick.net')):
        return 'google'
    return 'other'


def path_kind(path):
    p = path.split('?', 1)[0]
    if p.startswith('/v/'):
        return '/v/<token>'
    segs = [s for s in p.split('/') if s][:2]
    return '/' + '/'.join(segs) + ('/…' if p.count('/') > 2 else '')


def why(error):
    # Without any name in it: the Worker's host is not printed anywhere.
    text = str(error or '')
    if 'does not trust' in text or 'unknown ca' in text.lower() or 'bad certificate' in text.lower():
        return 'the client does not trust the proxy\'s certificate'
    return re.sub(r'[A-Za-z0-9.-]+\.(?:dev|co|com|net|org|io)\b', '<host>', text)[:120]


def write(event):
    event['t'] = round(time.time(), 1)
    with open(OUT, 'a') as f:
        f.write(json.dumps(event) + '\n')


def tls_failed_client(data: tls.TlsData):
    # The app saw the proxy's certificate and closed the connection.
    write({'ev': 'refused', 'to': kind(data.context.client.sni),
           'why': why(data.conn.error)})


def tls_established_client(data: tls.TlsData):
    # The app accepted the proxy's certificate: what follows is readable.
    write({'ev': 'accepted', 'to': kind(data.context.client.sni)})


def response(flow: http.HTTPFlow):
    write({'ev': 'read', 'to': kind(flow.request.pretty_host), 'method': flow.request.method,
           'path': path_kind(flow.request.path), 'status': flow.response.status_code,
           'headers': sorted({k.lower() for k in flow.request.headers.keys()})})
