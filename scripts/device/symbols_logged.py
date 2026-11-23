"""Runs the pinned 9.x `symbols.py` UNCHANGED and prints what it never does: each HTTP exchange's method,
host, path with the app token redacted, and status. Used by scripts/device/e2e_symbolication.dart.

    python3 symbols_logged.py <path to symbols.py> <the arguments symbols.py takes: -t -v -d -e>

The uploader's own exit code is the exit code here. The token is never printed (it is replaced in every
URL), and a presigned upload URL is shown as host and path only (its query holds a signature).
"""
import runpy
import sys
from urllib.parse import urlsplit

import requests

script = sys.argv[1]
argv = sys.argv[2:]
token = ''
for i, a in enumerate(argv):
    if a == '-t' and i + 1 < len(argv):
        token = argv[i + 1]


def redact(url):
    p = urlsplit(url)
    path = p.path.replace(token, '<APP_TOKEN>') if token else p.path
    return f'{p.scheme}://{p.netloc}{path}' + ('?<query-dropped>' if p.query else '')


_send = requests.Session.send


def send(self, request, **kwargs):
    response = _send(self, request, **kwargs)
    size = request.headers.get('Content-Length', '?')
    print(f'HTTP {request.method} {redact(request.url)} -> {response.status_code} (request body {size} bytes)', flush=True)
    if not response.ok:
        body = (response.text or '')[:300].replace(token, '<APP_TOKEN>') if token else (response.text or '')[:300]
        print(f'HTTP error body: {body}', flush=True)
    return response


requests.Session.send = send
sys.argv = [script] + argv
try:
    runpy.run_path(script, run_name='__main__')
except SystemExit as e:
    print(f'symbols.py exit: {e.code}', flush=True)
    raise
