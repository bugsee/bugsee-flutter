#!/usr/bin/env python3
"""Runs the Bugsee worker's REAL Flutter processing on an exception entry, offline.

    python3 -I scripts/verify_worker_contract.py <worker checkout> <entry.json> [--expect-name StateError]

`entry.json` is an `exception` entry of a bundle's crash.json (see test/fixtures/exceptions/*.json).
It loads the worker's `crash/managed/dart.py`, `common.py` and `helpers/recursion.py` unchanged and
stubs everything else (the API client, the symbol store, the native-thread symbolicator, which need
the worker's environment); symbol lookup is stubbed to "no symbols found", so the frames come out as
sent. Local only: the worker is a private repository. It checks what test/exceptions_worker_contract_test.dart
ports by hand: the type is `flutter`, the name and the reason are read out of the document, the
frames survive and the summary is built.
"""
import importlib.util
import json
import sys
from unittest import mock
W = sys.argv[1]
def stub(name, **attrs):
    m = mock.MagicMock(); m.__path__ = []
    for k, v in attrs.items(): setattr(m, k, v)
    sys.modules[name] = m; return m
for n in ['api','logger','symbolfiles','bintools','utils','utils.strutils','typedefs','typedefs.errors','typedefs.crash','typedefs.bundle','typedefs.common','crash','crash.managed','crash.helpers','crash.helpers.symbolication','symbolfiles.flutter']:
    stub(n)
class InvalidInputError(Exception): pass
sys.modules['typedefs.errors'].InvalidInputError = InvalidInputError
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path); m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m; spec.loader.exec_module(m); return m
sys.modules['typing_extensions'] = __import__('typing')
recursion = load('crash.helpers.recursion', W + '/crash/helpers/recursion.py'); sys.modules['crash.helpers'].recursion = recursion
common = load('crash.managed.common', W + '/crash/managed/common.py'); sys.modules['crash.managed'].common = common
dart = load('crash.managed.dart', W + '/crash/managed/dart.py')
dart._get_symbol_file = lambda *a, **k: None
entry = json.load(open(sys.argv[2]))
crash = {'exception': dict(entry['exception']), 'handled': entry.get('handled', False)}
r = dart.process_crash_report('o', 'a', crash, '/tmp', 'android')
ex = crash['exception']
ok = ex['type'] == 'flutter' and r.get('status') == 'ready' and len(ex['frames']) > 0
if '--expect-name' in sys.argv:
    ok = ok and ex['name'] == sys.argv[sys.argv.index('--expect-name') + 1]
print(json.dumps({'type': ex['type'], 'name': ex['name'], 'reason': ex['reason'], 'frames': len(ex['frames']), 'first_frame': ex['frames'][0].get('trace'), 'summary': r.get('summaryUpdate'), 'status': r.get('status')}, indent=1))
sys.exit(0 if ok else 1)
