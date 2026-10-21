// What a Dart error becomes before it crosses the bridge: its type name, message, frames and raw
// stack, the limits on all of them, and that building it never throws. Pure (no channel).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/src/exceptions/exception_payload.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> decode(ExceptionPayload p) =>
    jsonDecode(p.json) as Map<String, Object?>;

List<Map<String, Object?>> framesOf(ExceptionPayload p) =>
    (decode(p)['frames']! as List).cast<Map<String, Object?>>();

/// An object whose `toString` throws.
class Hostile {
  @override
  String toString() => throw StateError('no');
}

class CustomError extends Error {
  @override
  String toString() => 'CustomError: custom';
}

class CustomException implements Exception {
  @override
  String toString() => 'CustomException: custom';
}

class _Renamed implements Exception {
  @override
  String toString() => 'ProbeError: probe';
}

class _RenamedSilent implements Exception {
  @override
  String toString() => 'no name here';
}

/// A stack that cannot be printed.
class UnprintableStack implements StackTrace {
  @override
  String toString() => throw StateError('no stack');
}

const vmStack = '''
#0      main.<anonymous closure> (package:app/main.dart:10:5)
#1      foo (package:flutter/src/widgets/a.dart:20:3)
<asynchronous suspension>
#2      bar (file:///x/y/z.dart:5:1)
#3      _rootRun (dart:async/zone.dart:1:1)
<asynchronous suspension>
''';

void main() {
  group(
    'the type name (known types by `is`, never the runtime type of an obfuscated build)',
    () {
      final cases = <String, Object>{
        'ArgumentError': ArgumentError('x'),
        'IndexError': IndexError.withLength(5, 2),
        'RangeError': RangeError('x'),
        'AssertionError': AssertionError('x'),
        'ConcurrentModificationError': ConcurrentModificationError(),
        'FormatException': const FormatException('x'),
        'NoSuchMethodError': NoSuchMethodError.withInvocation(
          1,
          Invocation.method(#foo, const []),
        ),
        'StateError': StateError('x'),
        'TypeError': _typeError(),
        'UnimplementedError': UnimplementedError('x'),
        'UnsupportedError': UnsupportedError('x'),
        'TimeoutException': TimeoutException('x'),
        'AsyncError': AsyncError('x', null),
        'DeferredLoadException': DeferredLoadException('x'),
        'FileSystemException': const FileSystemException('x'),
        'HttpException': const HttpException('x'),
        'SocketException': const SocketException('x'),
        'HandshakeException': const HandshakeException('x'),
        'TlsException': const TlsException('x'),
        'FlutterError': FlutterError('x'),
        'PlatformException': PlatformException(code: 'c'),
        'MissingPluginException': MissingPluginException(),
        'TickerCanceled': const TickerCanceled(),
        'StackOverflowError': StackOverflowError(),
        'OutOfMemoryError': OutOfMemoryError(),
      };
      for (final entry in cases.entries) {
        test(entry.key, () {
          expect(classifyExceptionType(entry.value), entry.key);
        });
      }

      test(
        'IndexError and RangeError are told apart from ArgumentError (they are ones)',
        () {
          expect(
            classifyExceptionType(RangeError.range(9, 0, 3)),
            'RangeError',
          );
          expect(
            classifyExceptionType(ArgumentError.value(1)),
            'ArgumentError',
          );
        },
      );

      test('a plain Exception is `Exception`, a custom one its own name', () {
        expect(classifyExceptionType(Exception('x')), 'Exception');
        expect(classifyExceptionType(CustomException()), 'CustomException');
        expect(classifyExceptionType(CustomError()), 'CustomError');
      });

      test(
        'a non-Error value: a String is `String`, an int `int`, a list `List<int>`',
        () {
          expect(classifyExceptionType('boom'), 'String');
          expect(classifyExceptionType(42), 'int');
          expect(classifyExceptionType(<int>[1]), contains('List'));
          expect(classifyExceptionType(null), 'Error');
        },
      );

      test(
        'in an obfuscated build an unknown type is named from its message, not its runtimeType',
        () {
          // runtimeType is `CustomException` here; an obfuscated build would print `bx`.
          expect(classifyExceptionType(CustomException()), 'CustomException');
          expect(
            classifyExceptionType(_Renamed(), obfuscated: true),
            'ProbeError',
            reason: 'the message starts with the name Dart\'s convention gives',
          );
          expect(classifyExceptionType(_Renamed()), 'Exception');
          expect(
            classifyExceptionType(_RenamedSilent(), obfuscated: true),
            'Exception',
            reason: 'no name in the message: the runtime type is all there is',
          );
          // Known types never go through the message.
          expect(
            classifyExceptionType(
              StateError('ProbeError: x'),
              obfuscated: true,
            ),
            'StateError',
          );
        },
      );

      test('the document of an obfuscated stack uses it', () {
        final p = buildExceptionPayload(
          _Renamed(),
          StackTrace.fromString(
            File(
              'test/fixtures/exceptions/real_obfuscated_android_arm64_trace.txt',
            ).readAsStringSync(),
          ),
        );
        expect(p.name, 'ProbeError');
        expect(
          buildExceptionPayload(
            _Renamed(),
            StackTrace.fromString('#0      f (package:app/a.dart:1:1)\n'),
          ).name,
          'Exception',
        );
      });

      test('an error whose runtimeType cannot be read still gets a name', () {
        expect(classifyExceptionType(Hostile()), 'Hostile');
      });
    },
  );

  group('the type of an error that arrives as text (an isolate listener)', () {
    final cases = <String, String>{
      'Invalid argument(s): x': 'ArgumentError',
      'Bad state: no element': 'StateError',
      'Concurrent modification during iteration: [1].':
          'ConcurrentModificationError',
      'Unsupported operation: x': 'UnsupportedError',
      'Assertion failed: "x"': 'AssertionError',
      "type 'int' is not a subtype of type 'String'": 'TypeError',
      'RangeError (index): Invalid value': 'RangeError',
      'FormatException: Unexpected character': 'FormatException',
      'TimeoutException after 0:00:01.000000: Future not completed':
          'TimeoutException',
      'SocketException: Connection refused': 'SocketException',
      'Exception: plain': 'Exception',
      'MyDomainException: x': 'MyDomainException',
      'AppError (7)': 'AppError',
      'something else entirely': 'Error',
      '': 'Error',
    };
    for (final entry in cases.entries) {
      test(entry.key, () => expect(classifyErrorText(entry.key), entry.value));
    }
  });

  group('the message', () {
    test('a FlutterError contributes its summary, not its diagnostics', () {
      final error = FlutterError.fromParts([
        ErrorSummary('A RenderFlex overflowed by 22 pixels.'),
        ErrorDescription('The relevant widget was Text("secret").'),
      ]);
      expect(describeError(error), 'A RenderFlex overflowed by 22 pixels.');
      expect(error.toString(), contains('secret'));
    });

    test('a FlutterError built from a string takes its first line', () {
      expect(describeError(FlutterError('first\nsecond\nthird')), 'first');
    });

    test('anything else is its toString', () {
      expect(describeError(StateError('x')), 'Bad state: x');
      expect(describeError('boom'), 'boom');
      expect(describeError(42), '42');
    });

    test('a toString that throws is described, never thrown', () {
      expect(describeError(Hostile()), '<message unavailable: Hostile>');
    });

    test(
      'over the limit it is cut, marked, and never inside a surrogate pair',
      () {
        final long = 'a' * (ExceptionWire.maxReasonLength + 50);
        final cut = describeError(long);
        expect(cut.length, ExceptionWire.maxReasonLength + 1);
        expect(cut.endsWith('…'), isTrue);

        // The cut would fall between the two halves of an emoji.
        final pair =
            '${'a' * (ExceptionWire.maxReasonLength - 1)}\u{1F600}tail';
        final safe = describeError(pair);
        expect(safe.endsWith('…'), isTrue);
        expect(
          safe.codeUnits.where((u) => u >= 0xD800 && u <= 0xDBFF),
          isEmpty,
        );
      },
    );

    test('a short message is untouched', () {
      expect(capText('abc', 3), 'abc');
    });
  });

  group('the stack of a VM trace', () {
    test('frames in the 9.x shape, an async gap between traces', () {
      final p = buildExceptionPayload(
        StateError('x'),
        StackTrace.fromString(vmStack),
      );
      final frames = framesOf(p);
      expect(frames.map((f) => f['trace']), [
        'main.<fn> (package:app/main.dart:10)',
        'foo (package:flutter/src/widgets/a.dart:20)',
        '<asynchronous gap>',
        'bar (z.dart:5)',
        '_rootRun (dart:async/zone.dart:1)',
      ]);
      expect(frames.map((f) => f['user']), [true, false, false, true, false]);
      expect(frames.map((f) => f['module']), [
        'app',
        'flutter',
        'dart',
        'application',
        'dart',
      ]);
      final data = frames.first['data']! as Map<String, Object?>;
      expect(data['source'], 'package:app/main.dart');
      expect(data['line'], 10);
      expect(data['column'], 5);
      expect(data['package'], 'app');
    });

    test(
      'the raw stack is sent as printed, for the backend to symbolicate',
      () {
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString(vmStack),
        );
        expect(
          decode(p)['originalStackTrace'],
          vmStack.replaceFirst('file:///x/y/z.dart', 'file:///z.dart'),
          reason: 'as printed, but for the directory of a local file',
        );
      },
    );

    test('a trace has no gap at its start or end', () {
      final p = buildExceptionPayload(
        'x',
        StackTrace.fromString(
          '<asynchronous suspension>\n#0      a (package:app/a.dart:1:1)\n<asynchronous suspension>\n',
        ),
      );
      final traces = framesOf(p).map((f) => f['trace']).toList();
      expect(traces, ['a (package:app/a.dart:1)']);
    });

    test('a real stack of this test parses, with its async gaps', () async {
      Future<void> thrower() async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('real');
      }

      StackTrace? captured;
      try {
        await thrower();
      } catch (_, s) {
        captured = s;
      }
      final p = buildExceptionPayload(StateError('real'), captured);
      final frames = framesOf(p);
      expect(
        frames.first['trace'] as String,
        contains('thrower'),
        reason: 'the throwing frame is first',
      );
      expect((frames.first['data']! as Map)['line'], isA<int>());
      expect(
        decode(p)['originalStackTrace'],
        '$captured'.replaceAll(RegExp(r'file://[^\s()]*/'), 'file:///'),
      );
    });

    test('no stack: no frames, no raw text', () {
      final p = buildExceptionPayload(StateError('x'), null);
      expect(framesOf(p), isEmpty);
      expect(decode(p).containsKey('originalStackTrace'), isFalse);
    });

    test('an empty stack is the same as none', () {
      final p = buildExceptionPayload(StateError('x'), StackTrace.empty);
      expect(framesOf(p), isEmpty);
      expect(decode(p).containsKey('originalStackTrace'), isFalse);
    });
  });

  group('the stack of a package:stack_trace Chain (friendly format)', () {
    test('frames and gaps are read from its text', () {
      final p = buildExceptionPayload(
        'x',
        StackTrace.fromString(
          'package:app/a.dart 10:5     main\n'
          'package:app/b.dart 20:3     helper\n'
          '===== asynchronous gap ===========================\n'
          'package:app/c.dart 30:1     later\n',
        ),
      );
      expect(framesOf(p).map((f) => f['trace']), [
        'main (package:app/a.dart:10)',
        'helper (package:app/b.dart:20)',
        '<asynchronous gap>',
        'later (package:app/c.dart:30)',
      ]);
    });
  });

  group(
    'an obfuscated or --split-debug-info stack (the VM\'s non-symbolic format)',
    () {
      final raw = File(
        'test/fixtures/exceptions/obfuscated_stack_trace.txt',
      ).readAsStringSync();

      test('is recognised', () {
        expect(isNonSymbolicStack(raw), isTrue);
        expect(isNonSymbolicStack(vmStack), isFalse);
        // A header alone is enough: the frames may be cut off.
        expect(isNonSymbolicStack("build_id: 'abc'"), isTrue);
      });

      test(
        'is sent byte for byte: the header carries the build id the backend needs',
        () {
          final p = buildExceptionPayload(
            StateError('x'),
            StackTrace.fromString(raw),
          );
          expect(decode(p)['originalStackTrace'], raw);
          expect(
            decode(p)['originalStackTrace'],
            contains("build_id: '9344508edcd3e9114c9429829b80f965'"),
          );
        },
      );

      test('has one frame per #NN line, as printed, no names invented', () {
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString(raw),
        );
        final frames = framesOf(p);
        expect(
          frames.first['trace'],
          '#00 abs 00007d4aab5f1955 virt 0000000000592955 _kDartIsolateSnapshotInstructions+0x419ad5',
        );
        // Every #NN line of the fixture, up to the cap (it has more than that).
        expect(frames.length, ExceptionWire.maxFrames + 1);
        expect(frames.last['trace'], '... more frames omitted');
        expect(
          frames
              .take(ExceptionWire.maxFrames)
              .every((f) => (f['trace']! as String).startsWith('#')),
          isTrue,
        );
      });

      test('keeps its header when it has to be cut', () {
        final many = StringBuffer(raw);
        for (var i = 0; i < 4000; i++) {
          many.writeln(
            '    #${i + 14} abs 00007d4aab5f1955 virt 0000000000592955 _kDartIsolateSnapshotInstructions+0x419ad5',
          );
        }
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString('$many'),
        );
        final kept = decode(p)['originalStackTrace']! as String;
        expect(
          kept.length,
          lessThanOrEqualTo(ExceptionWire.maxRawStackLength + 2),
        );
        expect(kept, startsWith('*** *** ***'));
        expect(kept, contains("build_id: '9344508edcd3e9114c9429829b80f965'"));
        expect(kept.endsWith('…'), isTrue);
        // Cut at a line boundary, not inside a frame.
        final lines = kept.split('\n');
        for (final line in lines.skip(1).take(lines.length - 2)) {
          expect(
            line,
            matches(
              RegExp(r'^(    #\d+ abs [0-9a-f]+ virt [0-9a-f]+ \S+|\S.*)$'),
            ),
            reason: 'a whole line, never half a frame: $line',
          );
        }
        expect(lines[lines.length - 2], endsWith('+0x419ad5'));
      });
    },
  );

  group('local paths', () {
    test(
      'a file path on the developer machine is reduced to the file name everywhere',
      () {
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString(
            '#0      f (file:///Users/someone/secret-project/lib/a.dart:1:1)\n',
          ),
        );
        final frame = framesOf(p).single;
        final data = frame['data']! as Map<String, Object?>;
        expect(frame['trace'], 'f (a.dart:1)');
        expect(data['source'], 'a.dart');
        expect(data['library'], 'a.dart');
        expect(
          decode(p)['originalStackTrace'],
          '#0      f (file:///a.dart:1:1)\n',
        );
        expect(p.json, isNot(contains('someone')));
      },
    );

    test('a non-symbolic stack is never rewritten, whatever it contains', () {
      const raw =
          "build_id: 'abc'\n#00 abs 01 virt 02 _kDartIsolateSnapshotInstructions+0x1 (file:///keep/this/path.dart)\n";
      final p = buildExceptionPayload(
        StateError('x'),
        StackTrace.fromString(raw),
      );
      expect(decode(p)['originalStackTrace'], raw);
    });
  });

  group('limits', () {
    test(
      'frames are cut to the top ${ExceptionWire.maxFrames}, with a marker',
      () {
        final lines = [
          for (var i = 0; i < 1000; i++)
            '#$i      f$i (package:app/a.dart:$i:1)',
        ].join('\n');
        final p = buildExceptionPayload('x', StackTrace.fromString('$lines\n'));
        final frames = framesOf(p);
        expect(frames.length, ExceptionWire.maxFrames + 1);
        expect(frames.first['trace'], 'f0 (package:app/a.dart:0)');
        expect(
          frames[ExceptionWire.maxFrames - 1]['trace'],
          'f255 (package:app/a.dart:255)',
        );
        expect(frames.last['trace'], '... more frames omitted');
      },
    );

    test('a huge document degrades to stay under what native accepts', () {
      final lines = [
        for (var i = 0; i < 256; i++)
          '#$i      ${'m' * 900} (package:${'p' * 100}/${'f' * 900}.dart:$i:1)',
      ].join('\n');
      final p = buildExceptionPayload(
        'r' * 100000,
        StackTrace.fromString('$lines\n'),
      );
      expect(p.json.length, lessThanOrEqualTo(ExceptionWire.maxPayloadLength));
      final doc = decode(p);
      expect(doc['internalType'], ExceptionWire.managedName);
      expect(doc['name'], 'String');
      expect(
        (doc['reason']! as String).length,
        ExceptionWire.maxReasonLength + 1,
      );
    });

    test(
      'a document too big for native loses the frames\' data first, nothing else',
      () {
        final lines = [
          for (var i = 0; i < 256; i++)
            '#$i      ${'m' * 90} (package:${'p' * 20}/${'f' * 110}.dart:$i:1)',
        ].join('\n');
        final p = buildExceptionPayload(
          StateError('x'),
          StackTrace.fromString('$lines\n'),
        );
        expect(
          p.json.length,
          lessThanOrEqualTo(ExceptionWire.maxPayloadLength),
        );
        final frames = framesOf(p);
        expect(frames, isNotEmpty);
        expect(frames.every((f) => !f.containsKey('data')), isTrue);
        expect(decode(p)['originalStackTrace'], isNotNull);
      },
    );

    test('a long frame field is cut', () {
      final p = buildExceptionPayload(
        'x',
        StackTrace.fromString(
          '#0      ${'m' * 5000} (package:app/a.dart:1:1)\n',
        ),
      );
      expect(
        (framesOf(p).first['trace']! as String).length,
        ExceptionWire.maxFieldLength + 1,
      );
    });
  });

  group('the document (what the worker reads)', () {
    test('has exactly the keys the worker reads', () {
      final p = buildExceptionPayload(
        StateError('x'),
        StackTrace.fromString(vmStack),
      );
      expect(decode(p).keys, [
        'internalType',
        'name',
        'reason',
        'signature',
        'frames',
        'originalStackTrace',
      ]);
      expect(decode(p)['internalType'], 'FlutterManagedException');
      expect(decode(p)['name'], 'StateError');
      expect(decode(p)['reason'], 'Bad state: x');
      expect(p.name, 'StateError');
      expect(p.reason, 'Bad state: x');
    });

    test('name and reason can be given (text from an isolate)', () {
      final p = buildExceptionPayload(
        't',
        null,
        name: 'FormatException',
        reason: 'r',
      );
      expect(decode(p)['name'], 'FormatException');
      expect(decode(p)['reason'], 'r');
    });

    test(
      'a captured stack starts where the app called, not inside this package',
      () {
        final p = buildExceptionPayload(
          'x',
          StackTrace.fromString(
            '#0      Bugsee.logException (package:bugsee_flutter/src/bugsee.dart:1:1)\n'
            '#1      BugseeRuntime.logException (package:bugsee_flutter/src/bugsee_runtime.dart:2:1)\n'
            '#2      userCode (package:app/main.dart:3:1)\n',
          ),
          stackCaptured: true,
        );
        expect(framesOf(p).map((f) => f['trace']), [
          'userCode (package:app/main.dart:3)',
        ]);
      },
    );

    test('a stack that is not captured keeps every frame, ours included', () {
      final p = buildExceptionPayload(
        'x',
        StackTrace.fromString(
          '#0      f (package:bugsee_flutter/src/a.dart:1:1)\n',
        ),
      );
      expect(framesOf(p), hasLength(1));
      expect(
        framesOf(p).first['user'],
        isFalse,
        reason: 'our own frames are not the app\'s',
      );
    });
  });

  group('never throws', () {
    test('a hostile error', () {
      final p = buildExceptionPayload(
        Hostile(),
        StackTrace.fromString(vmStack),
      );
      expect(decode(p)['reason'], '<message unavailable: Hostile>');
    });

    test('a stack that cannot be printed', () {
      final p = buildExceptionPayload(StateError('x'), UnprintableStack());
      expect(framesOf(p), isEmpty);
      expect(decode(p)['reason'], 'Bad state: x');
    });

    test('a stack that is garbage', () {
      final p = buildExceptionPayload(
        StateError('x'),
        StackTrace.fromString('\u0000\u0001 not a stack \n\n\n#### \n'),
      );
      expect(decode(p)['internalType'], ExceptionWire.managedName);
    });
  });

  group('the fingerprint', () {
    test(
      'is the same for an object and for the text the isolate listener got',
      () {
        final stack = StackTrace.fromString(vmStack);
        final reason = describeError(StateError('x'));
        expect(
          exceptionFingerprint(reason, '$stack'),
          exceptionFingerprint(describeError('Bad state: x'), vmStack),
        );
      },
    );

    test(
      'looks at the first five frames: the fifth counts, the sixth does not',
      () {
        String stackWith(int changed) => [
          for (var i = 0; i < 8; i++)
            '#$i      ${i == changed ? 'other' : 'f$i'} (package:app/a.dart:$i:1)',
        ].join('\n');
        final base = exceptionFingerprint('r', stackWith(-1));
        expect(exceptionFingerprint('r', stackWith(4)), isNot(base));
        expect(exceptionFingerprint('r', stackWith(5)), base);
      },
    );

    test('differs by reason and by top frames', () {
      expect(
        exceptionFingerprint('a', vmStack),
        isNot(exceptionFingerprint('b', vmStack)),
      );
      expect(
        exceptionFingerprint('a', vmStack),
        isNot(
          exceptionFingerprint('a', vmStack.replaceFirst('main.', 'other.')),
        ),
      );
    });
  });

  group(
    'the signature (both SDKs hash it; without it every Dart error would share one)',
    () {
      String sig(Object error, String stack, {String? name}) =>
          buildExceptionPayload(error, StackTrace.fromString(stack)).signature;

      String stackOf(List<String> frames) =>
          '${[for (var i = 0; i < frames.length; i++) '#$i      ${frames[i]}'].join('\n')}\n';

      final base = stackOf([
        'a (package:app/a.dart:1:1)',
        'b (package:app/b.dart:2:1)',
        'c (package:app/c.dart:3:1)',
      ]);

      test('SHA-1 is right (known vectors, the block boundary, UTF-8)', () {
        expect(sha1Hex(''), 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
        expect(sha1Hex('abc'), 'a9993e364706816aba3e25717850c26c9cd0d89d');
        expect(
          sha1Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
          '84983e441c3bd26ebaae4aa1f95129e5e54670f1',
        );
        expect(sha1Hex('a' * 1000), '291e9a6c66994949b57ba5e650361e98fc36b1ba');
        expect(
          sha1Hex('caf\u00e9'),
          'f424452a9673918c6f09b0cdd35b20be8e6ae7d7',
        );
      });

      test(
        'is a key of the document, 40 hex digits, the one on the payload',
        () {
          final p = buildExceptionPayload(
            StateError('x'),
            StackTrace.fromString(base),
          );
          expect(decode(p)['signature'], p.signature);
          expect(p.signature, matches(RegExp(r'^[0-9a-f]{40}$')));
        },
      );

      test(
        'is there without a stack too, and survives a document that had to be degraded',
        () {
          expect(
            buildExceptionPayload(StateError('x'), null).signature,
            hasLength(40),
          );
          final lines = [
            for (var i = 0; i < 256; i++)
              '#$i      ${'m' * 90} (package:${'p' * 20}/${'f' * 110}.dart:$i:1)',
          ].join('\n');
          final p = buildExceptionPayload(
            StateError('x'),
            StackTrace.fromString('$lines\n'),
          );
          expect(framesOf(p).every((f) => !f.containsKey('data')), isTrue);
          expect(decode(p)['signature'], p.signature);
        },
      );

      test('two different errors have two different signatures', () {
        final a = sig(StateError('x'), base);
        expect(sig(StateError('y'), base), isNot(a), reason: 'the reason');
        expect(sig(ArgumentError('x'), base), isNot(a), reason: 'the type');
        expect(
          sig(
            StateError('x'),
            base.replaceFirst('package:app/a.dart:1', 'package:app/a.dart:9'),
          ),
          isNot(a),
          reason: 'the top frame',
        );
        expect(
          sig(
            StateError('x'),
            base.replaceFirst(
              'c (package:app/c.dart:3:1)',
              'other (package:app/c.dart:3:1)',
            ),
          ),
          isNot(a),
          reason: 'a user frame under the top',
        );
      });

      test(
        'two equal errors have the same one, whatever varies between runs',
        () {
          final a = sig(
            StateError(
              'item 12345 at 0x7fa1b2 id 3f2a9c1e-1111-2222-3333-444455556666',
            ),
            base,
          );
          expect(
            sig(
              StateError(
                'item 99999 at 0x1234 id aaaaaaaa-1111-2222-3333-444455556666',
              ),
              base,
            ),
            a,
          );
          expect(
            sig(StateError('item 1 at'), base),
            isNot(sig(StateError('item 2 at'), base)),
            reason: 'a short number is part of what was said',
          );
        },
      );

      test(
        'the detail lines of a message do not count (only its first line)',
        () {
          expect(
            sig(StateError('summary\ndetail one'), base),
            sig(StateError('summary\ndetail two'), base),
          );
          expect(
            sig(StateError('summary\ndetail one'), base),
            isNot(sig(StateError('other summary\ndetail one'), base)),
          );
        },
      );

      test(
        'framework and core frames do not count while there are user frames',
        () {
          final with1 = stackOf([
            'a (package:app/a.dart:1:1)',
            'build (package:flutter/src/x.dart:5:1)',
            'run (dart:async/zone.dart:7:1)',
          ]);
          final with2 = stackOf([
            'a (package:app/a.dart:1:1)',
            'build (package:flutter/src/y.dart:99:1)',
            'run (dart:async/zone.dart:70:1)',
          ]);
          expect(sig(StateError('x'), with1), sig(StateError('x'), with2));
        },
      );

      test('only the top five user frames count', () {
        List<String> frames(String sixth) => [
          for (var i = 0; i < 5; i++) 'f$i (package:app/f$i.dart:$i:1)',
          sixth,
        ];
        expect(
          sig(StateError('x'), stackOf(frames('a (package:app/s.dart:1:1)'))),
          sig(StateError('x'), stackOf(frames('b (package:app/t.dart:2:1)'))),
        );
      });

      test('with no user frame the first five frames count', () {
        expect(
          sig(StateError('x'), stackOf(['a (package:flutter/a.dart:1:1)'])),
          isNot(
            sig(StateError('x'), stackOf(['b (package:flutter/b.dart:1:1)'])),
          ),
        );
      });

      test(
        'a non-symbolic frame is keyed by virt and symbol, not by the address that moves with ASLR',
        () {
          String stackAt(String abs, String virt) =>
              "build_id: 'abc'\n    #00 abs $abs virt $virt _kDartIsolateSnapshotInstructions+0x1\n";
          final a = sig(
            StateError('x'),
            stackAt('00000078fb02217f', '000000000021a17f'),
          );
          expect(
            sig(
              StateError('x'),
              stackAt('00000099aa11bb22', '000000000021a17f'),
            ),
            a,
          );
          expect(
            sig(
              StateError('x'),
              stackAt('00000078fb02217f', '000000000021a999'),
            ),
            isNot(a),
          );
        },
      );

      test(
        'the documents the JUnit and XCTest feed to the SDKs\' own signature code are these',
        () {
          final stack =
              '#0      Cart.checkout (package:shop/cart.dart:41:7)\n'
              '#1      onTap (package:shop/home.dart:88:3)\n'
              '#2      build (package:flutter/src/gestures/x.dart:5:1)\n';
          final documents = <String, String>{
            'a1': buildExceptionPayload(
              StateError('item 12345 failed'),
              StackTrace.fromString(stack),
            ).json,
            // The same error on another day: only the volatile parts differ.
            'a2': buildExceptionPayload(
              StateError('item 99999 failed'),
              StackTrace.fromString(stack),
            ).json,
            'b': buildExceptionPayload(
              const FormatException('unrelated'),
              StackTrace.fromString(
                '#0      Parser.parse (package:shop/parse.dart:9:1)\n',
              ),
            ).json,
          };
          final file = File('test/fixtures/exceptions/signature_cases.json');
          final wanted =
              '${const JsonEncoder.withIndent(' ').convert({'_source': 'Documents built by buildExceptionPayload (test/exception_payload_test.dart, group "the signature"). a1 and a2 are one error on two days, b another. ExceptionSignatureTest (JUnit) and BGSFlutterExceptionSignatureTests (XCTest) feed them to the SDKs\' own signature code. Regenerate with UPDATE_FIXTURES=1.', 'documents': documents})}\n';
          if (Platform.environment['UPDATE_FIXTURES'] == '1') {
            file.writeAsStringSync(wanted);
          }
          expect(file.readAsStringSync(), wanted);
        },
      );

      test(
        'is the same for the same error built twice (no clock, no counter in it)',
        () {
          expect(sig(StateError('x'), base), sig(StateError('x'), base));
        },
      );
    },
  );
}

Object _typeError() {
  try {
    // ignore: unnecessary_cast
    final Object o = 1;
    return (o as String);
  } on TypeError catch (e) {
    return e;
  }
}
