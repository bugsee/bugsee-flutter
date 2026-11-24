"""Runs the pinned 9.x `symbols.py` UNCHANGED and prints what it never does: each HTTP exchange's method,
host, path with the app token redacted, and status. Used by scripts/device/e2e_symbolication.dart.

    python3 symbols_logged.py <path to symbols.py> <the arguments symbols.py takes: -t -v -d -e>

The uploader's own exit code is the exit code here. The token is never printed (it is replaced in every
URL), and a presigned upload URL is shown as host and path only (its query holds a signature). A failed
request (no connection, a reset) prints `HTTP <method> <url> -> FAILED (<exception type>)` and raises a
new error that carries no part of the original message.
"""
import re
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
    try:
        response = _send(self, request, **kwargs)
    except Exception as e:
        # A transport failure's message (urllib3) can hold the full URL, with the presigned query or the
        # app token in the path. Say method, sanitized URL and the exception type only, and raise a fresh
        # error without the original chain.
        print(f'HTTP {request.method} {redact(request.url)} -> FAILED ({type(e).__name__})', flush=True)
        raise requests.exceptions.RequestException(
            f'{request.method} {redact(request.url)} failed: {type(e).__name__}'
        ) from None
    size = request.headers.get('Content-Length', '?')
    print(f'HTTP {request.method} {redact(request.url)} -> {response.status_code} (request body {size} bytes)', flush=True)
    if not response.ok:
        # Never the body: an S3 error answer echoes signing material (AWSAccessKeyId, StringToSign, ...). Only
        # the error code, from an allow-list of characters, is useful and safe to print.
        m = re.search(r'<Code>([A-Za-z0-9_.-]{1,64})</Code>', response.text or '')
        print(f'HTTP error code: {m.group(1) if m else "-"}', flush=True)
    return response


requests.Session.send = send
sys.argv = [script] + argv
try:
    runpy.run_path(script, run_name='__main__')
except SystemExit as e:
    print(f'symbols.py exit: {e.code}', flush=True)
    raise
