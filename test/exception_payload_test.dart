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

class _Silent {
  const _Silent();
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
        expect(kept.split('\n').reversed.skip(1).first, startsWith('    #'));
      });
    },
  );

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
