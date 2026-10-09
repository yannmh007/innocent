#!/usr/bin/env python3
"""One file over HTTP with Range support — the stream Worker in miniature.

    range_server.py FILE|DIR PORT

Serves FILE at /film.mp4 — or each file in DIR at /<its name> — on
127.0.0.1:PORT, answering `Range` with 206 and a
Content-Range exactly as the Worker does, and a plain GET with 200. The device
lab puts `tc netem` in front of PORT and plays the film from the emulator at
10.0.2.2:PORT. Not for anything but the lab: no auth, threads.
"""
import http.server
import os
import re
import sys


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    path_file = ''

    def log_message(self, *a):
        pass

    def _file(self):
        name = self.path.split('?')[0].lstrip('/')
        if os.path.isdir(self.path_file):
            # A plain name only: nothing above the directory.
            if not re.match(r'^[A-Za-z0-9._-]+$', name):
                return None
            p = os.path.join(self.path_file, name)
            return p if os.path.isfile(p) else None
        return self.path_file if name == 'film.mp4' else None

    def _serve(self, head_only=False):
        path = self._file()
        if path is None:
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        size = os.path.getsize(path)
        start, end, code = 0, size - 1, 200
        m = re.match(r'bytes=(\d*)-(\d*)$', self.headers.get('Range', ''))
        if m and (m.group(1) or m.group(2)):
            code = 206
            if m.group(1):
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), size - 1)
            else:
                start = max(0, size - int(m.group(2)))
            if start >= size:
                self.send_response(416)
                self.send_header('Content-Range', 'bytes */%d' % size)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
        self.send_response(code)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        if code == 206:
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
        self.end_headers()
        if head_only:
            return
        try:
            with open(path, 'rb') as fh:
                fh.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = fh.read(min(256 * 1024, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self._serve()

    def do_HEAD(self):
        self._serve(head_only=True)


if __name__ == '__main__':
    H.path_file = sys.argv[1]
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[2])), H)
    srv.daemon_threads = True
    srv.serve_forever()
