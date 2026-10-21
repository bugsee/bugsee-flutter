# A stand-in for the Bugsee API, for the attachments integration test only (run it by hand; CI does not).
# Usage: ISSUE_OK=1 UPLOAD_STATUS=503 python3 mock_api.py <port> <log file>
#   POST /v2/issues  -> 200 with an upload endpoint pointing back here (ISSUE_OK=1), else 503
#   PUT  /upload/... -> the bundle is stored under DUMP_DIR and the answer is UPLOAD_STATUS (503: the SDK
#                       keeps the bundle on disk, where the test reads it)
#   GET  /__bundles  -> what the stored bundles hold (manifest, request, each file's size and sha256), so a
#                       test that cannot read the SDK's own directory (iOS keeps no bundle file once the
#                       upload is handed to the system) can still check what the SDK sent
#   anything else    -> 200 {}
#
#   ISSUE_OK=1 UPLOAD_STATUS=503 DUMP_DIR=/tmp/bundles python3 mock_api.py 8196 /tmp/mock.log
import glob, hashlib, json, sys, tempfile, time, os, zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[2]
UPLOAD_STATUS = int(os.environ.get('UPLOAD_STATUS', '503'))
ISSUE_OK = os.environ.get('ISSUE_OK') == '1'
# Bundles are written here: a fresh temporary directory unless DUMP_DIR says otherwise.
DUMP = os.environ.get('DUMP_DIR') or tempfile.mkdtemp(prefix='bugsee-mock-bundles-')
os.makedirs(DUMP, exist_ok=True)
count = [0]

def bundles():
    out = []
    seen = set()
    for path in sorted(glob.glob(os.path.join(DUMP, '*.zip'))):
        try:
            z = zipfile.ZipFile(path)
            entries = {i.filename: {'size': i.file_size, 'sha256': hashlib.sha256(z.read(i)).hexdigest()} for i in z.infolist()}
            request = json.loads(z.read('request.json')) if 'request.json' in entries else None
            manifest = json.loads(z.read('manifest.json')) if 'manifest.json' in entries else None
        except Exception as e:
            continue
        # The SDK retries a refused upload: one bundle can arrive several times.
        key = json.dumps(entries, sort_keys=True)
        if key in seen:
            continue
        seen.add(key)
        out.append({'file': os.path.basename(path), 'entries': entries, 'request': request, 'manifest': manifest})
    return out

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def _do(self):
        n = int(self.headers.get('content-length') or 0)
        body = self.rfile.read(n) if n else b''
        path = self.path.split('?')[0]
        with open(LOG, 'a') as f:
            f.write(f"{time.strftime('%H:%M:%S')} {self.command} {path} len={len(body)}\n")
        status, out = 200, {}
        if self.command == 'GET' and path == '/__bundles':
            out = bundles()
        elif self.command == 'POST' and path.endswith('/v2/issues'):
            if ISSUE_OK:
                count[0] += 1
                host = self.headers.get('host')
                out = {'result': {'endpoint': f'http://{host}/upload/{count[0]}', 'issue_id': f'issue-{count[0]}', 'recording_id': f'rec-{count[0]}'}}
            else:
                status = 503
        elif self.command in ('PUT', 'POST') and path.startswith('/upload/'):
            with open(os.path.join(DUMP, f"{int(time.time()*1000)}-{self.command}-{path.strip('/').replace('/', '_')}.zip"), 'wb') as f:
                f.write(body)
            status = UPLOAD_STATUS
        data = json.dumps(out).encode()
        self.send_response(status)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = _do
    def log_message(self, *a): pass

# Loopback only: the server stores whatever is PUT to it. The Android emulator reaches it as 10.0.2.2 and
# the iOS simulator as localhost, both of which arrive on the loopback interface of the host.
ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
