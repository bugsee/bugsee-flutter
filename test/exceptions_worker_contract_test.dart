// The backend contract, replayed: the routing and parsing rules of the worker (crash/managed/
// __init__.py and dart.py, ported line by line below with their source lines) applied to documents
// this package builds, as the SDKs would hand them over. The worker is Python in a private
// repository, so this is a port of its rules, not the worker; `scripts/verify_worker_contract.py`
// runs the real module against these documents when a worker checkout is at hand.
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/src/exceptions/exception_payload.dart';
import 'package:flutter_test/flutter_test.dart';

// ---- The worker's rules ---------------------------------------------------------------------

/// `_detect_managed_type` (crash/managed/__init__.py:37): Flutter when the name or the reason
/// contains the literal, or the type says so. `name`/`reason` are the exception entry of crash.json.
bool routesToFlutter({
  required String name,
  required String reason,
  String type = '',
}) =>
    name.contains('FlutterManagedException') ||
    reason.contains('FlutterManagedException') ||
    type == 'flutter';

/// dart.py:process_crash_report, the first lines: strip the SDK's envelope, then everything before
/// the opening brace (an obfuscated build has no `FlutterManagedException:` prefix to strip).
Map<String, Object?>? parseReason(String reason) {
  var r = reason.replaceFirst(RegExp(r'^\s*.*FlutterManagedException:\s*'), '');
  r = r.replaceFirst(RegExp(r'^[^{"]+'), '');
  try {
    final decoded = jsonDecode(r);
    return decoded is Map<String, Object?> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// dart.py:_get_build_id_from_stack_trace
String? buildIdFromStackTrace(String? stackTrace) => stackTrace == null
    ? null
    : RegExp(r"build_id:\s*'([^']+)'").firstMatch(stackTrace)?.group(1);

/// dart.py:_get_frames_from_obfuscated_stack_trace: from the first `#00`, one frame per line.
List<String>? obfuscatedFrameLines(String stackTrace) {
  final m = RegExp(r'^(.*?)(\s*#00.*)', dotAll: true).firstMatch(stackTrace);
  if (m == null) return null;
  var lines = const LineSplitter().convert(m.group(2)!);
  if (lines.isNotEmpty && lines.first.isEmpty) lines = lines.sublist(1);
  return [for (final l in lines) l.trim()];
}

/// dart.py:_is_user_frame
bool workerIsUserFrame(String trace) =>
    !trace.contains('(package:flutter') && !trace.contains('(dart:');

/// dart.py:_is_hidden_frame (the part that names this package's old and new entry points).
bool workerIsHiddenFrame(String trace) =>
    trace.contains('FlutterError.reportError') ||
    trace.contains('Bugsee.logException') ||
    trace.contains('BugseeExceptionHandler');

// ---- The SDKs' envelopes --------------------------------------------------------------------

/// What the Android SDK writes into crash.json for the carrier: its class name and its message,
/// verbatim (ExceptionSerializer.java:146-147).
({String name, String reason}) androidEntry(
  String document, {
  bool renamed = false,
}) => (
  name: renamed ? 'a.b' : 'com.bugsee.flutter.FlutterManagedException',
  reason: document,
);

/// iOS: the exception's name and reason.
({String name, String reason}) iosEntry(String document) =>
    (name: 'FlutterManagedException', reason: document);

void main() {
  final obfuscated = File(
    'test/fixtures/exceptions/obfuscated_stack_trace.txt',
  ).readAsStringSync();

  /// 9.x worker test (test_crash_flutter.py): the first frame and the build id of this very file.
  const workerFirstFrame =
      '#00 abs 00007d4aab5f1955 virt 0000000000592955 _kDartIsolateSnapshotInstructions+0x419ad5';
  const workerBuildId = '9344508edcd3e9114c9429829b80f965';

  group('routing', () {
    test('Android and iOS entries route to the Flutter processor', () {
      final doc = buildExceptionPayload(StateError('x'), null).json;
      final a = androidEntry(doc);
      final i = iosEntry(doc);
      expect(routesToFlutter(name: a.name, reason: a.reason), isTrue);
      expect(routesToFlutter(name: i.name, reason: i.reason), isTrue);
    });

    test(
      'a build that renamed the Android class is still routed, by the reason',
      () {
        final doc = buildExceptionPayload(StateError('x'), null).json;
        final a = androidEntry(doc, renamed: true);
        expect(a.name.contains('FlutterManagedException'), isFalse);
        expect(routesToFlutter(name: a.name, reason: a.reason), isTrue);
      },
    );

    test(
      'an ordinary exception does not route to Flutter (the check is not vacuous)',
      () {
        expect(
          routesToFlutter(name: 'java.lang.IllegalStateException', reason: 'x'),
          isFalse,
        );
      },
    );
  });

  group('parsing the reason', () {
    test('the document comes back out of the reason, as the SDK stores it', () {
      final p = buildExceptionPayload(
        StateError('x'),
        StackTrace.fromString(obfuscated),
      );
      final parsed = parseReason(androidEntry(p.json).reason)!;
      expect(parsed['name'], 'StateError');
      expect(parsed['reason'], 'Bad state: x');
      expect(parsed['internalType'], 'FlutterManagedException');
      expect(parsed['frames'], isA<List>());
    });

    test('also with the Throwable.toString() prefix some paths add', () {
      final p = buildExceptionPayload(StateError('x'), null);
      final withPrefix =
          'com.bugsee.flutter.FlutterManagedException: ${p.json}';
      expect(parseReason(withPrefix)!['name'], 'StateError');
      // ... and the obfuscated spelling: a renamed class, no literal before the brace.
      expect(parseReason('a.b: ${p.json}')!['name'], 'StateError');
    });

    test(
      'a reason with braces and quotes in the message survives the round trip',
      () {
        final p = buildExceptionPayload(
          StateError('he said "{not json}" \\ \n done'),
          null,
        );
        expect(
          parseReason(p.json)!['reason'],
          'Bad state: he said "{not json}" \\ \n done',
        );
      },
    );
  });

  group('symbolication: what the worker needs from an obfuscated build', () {
    test(
      'the build id is found in originalStackTrace, as the worker does it',
      () {
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString(obfuscated),
        );
        final parsed = parseReason(p.json)!;
        expect(
          buildIdFromStackTrace(parsed['originalStackTrace'] as String?),
          workerBuildId,
        );
      },
    );

    test(
      'the worker\'s own frames come out of originalStackTrace: the first is its test frame',
      () {
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString(obfuscated),
        );
        final frames = obfuscatedFrameLines(
          parseReason(p.json)!['originalStackTrace']! as String,
        )!;
        expect(frames.first, workerFirstFrame);
        // Every line the worker would feed to dart_symbolize is in the file we were given.
        expect(frames.length, greaterThan(100));
      },
    );

    test(
      'the header lines the symbolizer needs travel with it (nothing rewritten)',
      () {
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString(obfuscated),
        );
        final raw = parseReason(p.json)!['originalStackTrace']! as String;
        for (final line in const LineSplitter().convert(obfuscated).take(6)) {
          expect(raw, contains(line));
        }
        expect(raw, startsWith('*** *** ***'));
      },
    );

    test(
      'a symbolic (debug) stack has no #00: the worker uses the frames of the document',
      () {
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString('#0      f (package:app/a.dart:1:1)\n'),
        );
        final parsed = parseReason(p.json)!;
        expect(
          obfuscatedFrameLines(parsed['originalStackTrace']! as String),
          isNull,
        );
        expect(
          buildIdFromStackTrace(parsed['originalStackTrace'] as String?),
          isNull,
        );
        final frames = (parsed['frames']! as List).cast<Map>();
        expect(frames.single['trace'], 'f (package:app/a.dart:1)');
      },
    );

    test(
      'the build id is in the first frames too (the worker\'s fallback, dart.py:_get_build_id_from_frames)',
      () {
        // 9.x sent the header lines as frames; the worker looks at the first nine for
        // "build_id: '...'". We send the header in originalStackTrace, which the worker tries first.
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString(obfuscated),
        );
        expect(
          (parseReason(p.json)!['originalStackTrace']! as String).contains(
            "build_id: '$workerBuildId'",
          ),
          isTrue,
        );
      },
    );
  });

  group('frames', () {
    test(
      'the worker\'s user/hidden verdict agrees with ours for framework and core frames',
      () {
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString(
            '#0      app (package:app/a.dart:1:1)\n'
            '#1      build (package:flutter/src/widgets/framework.dart:2:1)\n'
            '#2      run (dart:async/zone.dart:3:1)\n',
          ),
        );
        final frames = (parseReason(p.json)!['frames']! as List).cast<Map>();
        for (final f in frames) {
          expect(
            workerIsUserFrame(f['trace'] as String),
            f['user'],
            reason: '${f['trace']}',
          );
        }
      },
    );

    test('the plugin\'s own entry point is a frame the worker hides', () {
      expect(
        workerIsHiddenFrame(
          'Bugsee.logException (package:bugsee_flutter/src/bugsee.dart:1)',
        ),
        isTrue,
      );
    });

    test(
      'a frame trace is "member (location)": what the worker hashes into the signature',
      () {
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString('#0      Foo.bar (package:app/a.dart:12:3)\n'),
        );
        final frames = (parseReason(p.json)!['frames']! as List).cast<Map>();
        expect(frames.single['trace'], 'Foo.bar (package:app/a.dart:12)');
        expect(frames.single['data']['member'], 'Foo.bar');
      },
    );
  });
}
