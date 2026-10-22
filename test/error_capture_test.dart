// The installed handlers: chained, restored, idempotent, once per error, limited, never throwing.
// Each test builds its own `ErrorCapture` over the real `FlutterError` / `PlatformDispatcher`
// statics, which it puts back.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:bugsee_flutter/src/exceptions/error_capture.dart';
import 'package:bugsee_flutter/src/exceptions/exception_payload.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class Reported {
  Reported(this.payload, this.handled);
  final ExceptionPayload payload;
  final bool handled;
  String get name => payload.name;
  String get reason => payload.reason;
}

/// A clock a test moves.
class Clock {
  Duration now = const Duration(hours: 1);
  Duration call() => now;
  void advance(Duration d) => now += d;
}

bool ok(ReportLimiter l, String f) => l.check(f) == LimiterVerdict.allowed;

final stack = StackTrace.fromString('#0      f (package:app/a.dart:1:1)\n');

void entryThatThrows(Object? _) => throw StateError('from an isolate');

void main() {
  late List<Reported> reports;
  late Clock clock;
  late FlutterExceptionHandler? savedFlutter;
  late ErrorCallback? savedPlatform;
  late bool enabled;
  late ErrorCapture capture;
  late List<String> warnings;
  Future<void> Function(ExceptionPayload payload, {required bool handled})?
  reporterOverride;

  setUp(() {
    reports = [];
    clock = Clock();
    enabled = true;
    warnings = [];
    reporterOverride = null;
    savedFlutter = FlutterError.onError;
    savedPlatform = PlatformDispatcher.instance.onError;
    capture = ErrorCapture(
      report: (payload, {required handled}) {
        final override = reporterOverride;
        if (override != null) return override(payload, handled: handled);
        reports.add(Reported(payload, handled));
        return Future<void>.value();
      },
      enabled: () => enabled,
      limiter: ReportLimiter(now: clock.call),
      warn: warnings.add,
    );
  });

  tearDown(() {
    capture.uninstall();
    FlutterError.onError = savedFlutter;
    PlatformDispatcher.instance.onError = savedPlatform;
  });

  FlutterErrorDetails details(Object error, {bool silent = false}) =>
      FlutterErrorDetails(exception: error, stack: stack, silent: silent);

  group('FlutterError.onError', () {
    test(
      'reports, then calls the handler that was there, with the same details',
      () {
        final order = <String>[];
        FlutterErrorDetails? seen;
        FlutterError.onError = (d) {
          order.add('previous');
          seen = d;
        };
        reporterOverride = (p, {required handled}) {
          order.add('report');
          return Future<void>.value();
        };
        capture.install(platformErrors: false, isolateErrors: false);

        final d = details(StateError('x'));
        FlutterError.onError!(d);

        expect(order, ['report', 'previous']);
        expect(seen, same(d));
      },
    );

    test('with no previous handler it just reports', () {
      FlutterError.onError = null;
      capture.install(platformErrors: false, isolateErrors: false);
      FlutterError.onError!(details(StateError('x')));
      expect(reports, hasLength(1));
    });

    test(
      'the previous handler runs when reporting throws, and when we are disabled',
      () {
        var previousCalls = 0;
        FlutterError.onError = (_) => previousCalls++;
        capture.install(platformErrors: false, isolateErrors: false);

        reporterOverride = (p, {required handled}) =>
            throw StateError('sdk down');
        FlutterError.onError!(details(StateError('a')));
        expect(previousCalls, 1);

        reporterOverride = null;
        enabled = false;
        FlutterError.onError!(details(StateError('b')));
        expect(previousCalls, 2);
        expect(reports, isEmpty);
      },
    );

    test(
      'an exception of the previous handler is the app\'s: it is not swallowed',
      () {
        FlutterError.onError = (_) => throw StateError('app handler bug');
        capture.install(platformErrors: false, isolateErrors: false);
        expect(
          () => FlutterError.onError!(details(StateError('x'))),
          throwsStateError,
        );
        expect(
          reports,
          hasLength(1),
          reason: 'reported before the handler ran',
        );
      },
    );

    test('silent errors are not reported, but still chained', () {
      var previousCalls = 0;
      FlutterError.onError = (_) => previousCalls++;
      capture.install(platformErrors: false, isolateErrors: false);
      FlutterError.onError!(details(StateError('x'), silent: true));
      expect(reports, isEmpty);
      expect(previousCalls, 1);
    });

    test('leaves it alone when flutterErrors is false', () {
      void mine(FlutterErrorDetails _) {}
      FlutterError.onError = mine;
      capture.install(
        flutterErrors: false,
        platformErrors: false,
        isolateErrors: false,
      );
      expect(FlutterError.onError, same(mine));
    });

    test(
      'nothing but the exception and its stack is read from the details',
      () {
        capture.install(platformErrors: false, isolateErrors: false);
        FlutterError.onError!(
          FlutterErrorDetails(
            exception: FlutterError.fromParts([
              ErrorSummary('Overflowed.'),
              ErrorDescription('on Text("secret")'),
            ]),
            stack: stack,
            library: 'rendering library',
            context: ErrorDescription('during layout'),
            informationCollector: () => [
              ErrorDescription('widget tree: secret'),
            ],
          ),
        );
        final json = reports.single.payload.json;
        expect(json, isNot(contains('secret')));
        expect(json, isNot(contains('rendering library')));
        expect(json, isNot(contains('during layout')));
        expect(reports.single.reason, 'Overflowed.');
      },
    );
  });

  group('PlatformDispatcher.onError', () {
    test('reports, then returns what the previous handler answered', () {
      var previousCalls = 0;
      PlatformDispatcher.instance.onError = (e, s) {
        previousCalls++;
        return true;
      };
      capture.install(flutterErrors: false, isolateErrors: false);
      expect(
        PlatformDispatcher.instance.onError!(StateError('x'), stack),
        isTrue,
      );
      expect(previousCalls, 1);
      expect(reports, hasLength(1));
    });

    test('a previous handler that answers false is not turned into true', () {
      PlatformDispatcher.instance.onError = (e, s) => false;
      capture.install(flutterErrors: false, isolateErrors: false);
      expect(
        PlatformDispatcher.instance.onError!(StateError('x'), stack),
        isFalse,
      );
    });

    test(
      'with no previous handler it answers false: the engine reports as it would have',
      () {
        PlatformDispatcher.instance.onError = null;
        capture.install(flutterErrors: false, isolateErrors: false);
        expect(
          PlatformDispatcher.instance.onError!(StateError('x'), stack),
          isFalse,
        );
      },
    );

    test('the previous handler still answers when reporting throws', () {
      PlatformDispatcher.instance.onError = (e, s) => true;
      capture.install(flutterErrors: false, isolateErrors: false);
      reporterOverride = (p, {required handled}) => throw StateError('down');
      expect(
        PlatformDispatcher.instance.onError!(StateError('x'), stack),
        isTrue,
      );
    });

    test('leaves it alone when platformErrors is false', () {
      bool mine(Object _, StackTrace __) => true;
      PlatformDispatcher.instance.onError = mine;
      capture.install(
        flutterErrors: false,
        platformErrors: false,
        isolateErrors: false,
      );
      expect(PlatformDispatcher.instance.onError, same(mine));
    });
  });

  group('a previous PlatformDispatcher handler that handled the error', () {
    test(
      'makes it an error report, never a crash, even with reportAsCrash',
      () {
        PlatformDispatcher.instance.onError = (e, s) => true;
        capture.install(
          flutterErrors: false,
          isolateErrors: false,
          reportAsCrash: true,
        );
        PlatformDispatcher.instance.onError!(
          StateError('app handled it'),
          stack,
        );
        expect(reports.single.handled, isTrue);
      },
    );

    test('one that did not handle it leaves it a crash with reportAsCrash', () {
      PlatformDispatcher.instance.onError = (e, s) => false;
      capture.install(
        flutterErrors: false,
        isolateErrors: false,
        reportAsCrash: true,
      );
      PlatformDispatcher.instance.onError!(
        StateError('nobody handled it'),
        stack,
      );
      expect(reports.single.handled, isFalse);
    });

    test('no previous handler: nobody handled it', () {
      PlatformDispatcher.instance.onError = null;
      capture.install(
        flutterErrors: false,
        isolateErrors: false,
        reportAsCrash: true,
      );
      PlatformDispatcher.instance.onError!(StateError('x'), stack);
      expect(reports.single.handled, isFalse);
    });

    test(
      'one that throws: the error is still reported, and its exception goes on',
      () {
        PlatformDispatcher.instance.onError = (e, s) =>
            throw StateError('handler bug');
        capture.install(flutterErrors: false, isolateErrors: false);
        expect(
          () => PlatformDispatcher.instance.onError!(StateError('x'), stack),
          throwsStateError,
        );
        expect(reports, hasLength(1));
      },
    );
  });

  group('isActive: is ours still the current handler', () {
    test('true after install, false before it and after uninstall', () {
      expect(capture.isActive, isFalse);
      capture.install(isolateErrors: false);
      expect(capture.isActive, isTrue);
      capture.uninstall();
      expect(capture.isActive, isFalse);
    });

    test(
      'false when another tool replaced FlutterError.onError (Crashlytics\' setup)',
      () {
        capture.install(isolateErrors: false);
        FlutterError.onError = (_) {};
        expect(capture.isInstalled, isTrue);
        expect(capture.isActive, isFalse);
      },
    );

    test('false when another tool replaced PlatformDispatcher.onError', () {
      capture.install(flutterErrors: false, isolateErrors: false);
      PlatformDispatcher.instance.onError = (e, s) => true;
      expect(capture.isActive, isFalse);
    });

    test('only the hooks that were installed count', () {
      capture.install(platformErrors: false, isolateErrors: false);
      PlatformDispatcher.instance.onError = (e, s) => true;
      expect(capture.isActive, isTrue);
    });

    test('warnIfReplaced says so once, and only when replaced', () {
      capture.install(isolateErrors: false);
      capture.warnIfReplaced();
      expect(warnings, isEmpty);
      FlutterError.onError = (_) {};
      capture.warnIfReplaced();
      capture.warnIfReplaced();
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('AFTER'));
    });
  });

  test('the limiter runs on a monotonic clock, not the wall clock', () {
    final limiter = ReportLimiter();
    final first = limiter.now;
    final second = limiter.now;
    expect(second, greaterThanOrEqualTo(first));
    expect(limiter.check('a'), LimiterVerdict.allowed);
    expect(limiter.check('a'), LimiterVerdict.duplicate);
    expect(
      File('lib/src/exceptions/error_capture.dart').readAsStringSync(),
      isNot(contains('DateTime')),
    );
  });

  group('install and uninstall', () {
    test(
      'install is idempotent: one wrapper, one report, the previous called once',
      () {
        var previousCalls = 0;
        FlutterError.onError = (_) => previousCalls++;
        capture.install(platformErrors: false, isolateErrors: false);
        final first = FlutterError.onError;
        capture.install(platformErrors: false, isolateErrors: false);
        expect(FlutterError.onError, same(first));
        expect(capture.isInstalled, isTrue);

        FlutterError.onError!(details(StateError('x')));
        expect(reports, hasLength(1));
        expect(previousCalls, 1);
      },
    );

    test('uninstall puts the previous handlers back', () {
      void flutterBefore(FlutterErrorDetails _) {}
      bool platformBefore(Object _, StackTrace __) => true;
      FlutterError.onError = flutterBefore;
      PlatformDispatcher.instance.onError = platformBefore;
      capture.install(isolateErrors: false);
      expect(FlutterError.onError, isNot(same(flutterBefore)));

      capture.uninstall();
      expect(FlutterError.onError, same(flutterBefore));
      expect(PlatformDispatcher.instance.onError, same(platformBefore));
      expect(capture.isInstalled, isFalse);
    });

    test('uninstall restores "no handler" too', () {
      FlutterError.onError = null;
      PlatformDispatcher.instance.onError = null;
      capture.install(isolateErrors: false);
      capture.uninstall();
      expect(FlutterError.onError, isNull);
      expect(PlatformDispatcher.instance.onError, isNull);
    });

    test(
      'if another tool wrapped ours, uninstall leaves theirs and ours reports nothing but still chains',
      () {
        var previousCalls = 0;
        FlutterError.onError = (_) => previousCalls++;
        capture.install(platformErrors: false, isolateErrors: false);
        final ours = FlutterError.onError!;
        final seenByTheirs = <FlutterErrorDetails>[];
        void theirs(FlutterErrorDetails d) {
          seenByTheirs.add(d);
          ours(d);
        }

        FlutterError.onError = theirs;
        capture.uninstall();

        expect(FlutterError.onError, same(theirs), reason: 'not unlinked');
        FlutterError.onError!(details(StateError('x')));
        expect(reports, isEmpty, reason: 'ours is inert now');
        expect(previousCalls, 1, reason: 'but the chain below it still runs');
        expect(seenByTheirs, hasLength(1));
      },
    );

    test(
      'install again after uninstall works; the old wrapper stays inert',
      () {
        var previousCalls = 0;
        FlutterError.onError = (_) => previousCalls++;
        capture.install(platformErrors: false, isolateErrors: false);
        final old = FlutterError.onError!;
        capture.uninstall();
        capture.install(platformErrors: false, isolateErrors: false);

        old(details(StateError('through the old wrapper')));
        expect(reports, isEmpty);
        FlutterError.onError!(details(StateError('through the new one')));
        expect(reports, hasLength(1));
        expect(previousCalls, 2);
      },
    );

    test(
      'a new ErrorCapture starts clean (a hot restart is a new isolate)',
      () {
        capture.install(platformErrors: false, isolateErrors: false);
        FlutterError.onError!(details(StateError('x')));
        final fresh = ErrorCapture(
          report: (p, {required handled}) async =>
              reports.add(Reported(p, handled)),
          enabled: () => true,
          limiter: ReportLimiter(now: clock.call),
        );
        expect(fresh.isInstalled, isFalse);
      },
    );
  });

  group('once per error, and flood protection', () {
    test(
      'the same object through FlutterError and PlatformDispatcher is one report',
      () {
        capture.install(isolateErrors: false);
        final error = StateError('x');
        FlutterError.onError!(details(error));
        PlatformDispatcher.instance.onError!(error, stack);
        expect(reports, hasLength(1));
      },
    );

    test(
      'a constant error object is reported again after 30 s, not before',
      () {
        capture.install(isolateErrors: false);
        const error = FormatException(
          'bad input',
        ); // the same object at every throw
        FlutterError.onError!(details(error));
        clock.advance(const Duration(seconds: 10));
        FlutterError.onError!(details(error));
        expect(
          reports,
          hasLength(1),
          reason: 'limited: an equal error within 30 s',
        );
        clock.advance(const Duration(seconds: 25));
        FlutterError.onError!(details(error));
        expect(
          reports,
          hasLength(2),
          reason: 'the same object is not remembered for good',
        );
      },
    );

    test(
      'the same object arriving by two routes within a second is one, silently',
      () {
        capture.install(isolateErrors: false);
        final error = StateError('x');
        FlutterError.onError!(details(error));
        clock.advance(const Duration(milliseconds: 500));
        PlatformDispatcher.instance.onError!(error, stack);
        expect(reports, hasLength(1));
        expect(
          capture.suppressedCount,
          0,
          reason: 'a duplicate is not a flood',
        );
        expect(warnings, isEmpty);
      },
    );

    test(
      'the same object by two routes with different stacks is one, by identity',
      () {
        capture.install(isolateErrors: false);
        final error = StateError('x');
        FlutterError.onError!(details(error)); // the details' stack
        PlatformDispatcher.instance.onError!(
          error,
          StackTrace.fromString(
            '#0      elsewhere (package:app/other.dart:9:9)\n',
          ),
        );
        expect(reports, hasLength(1));
        expect(capture.suppressedCount, 0);
      },
    );

    test(
      'the same text by two routes (zone and FlutterError, a thrown String) is one, silently',
      () {
        capture.install(isolateErrors: false);
        capture.captureZoneError('boom', stack);
        FlutterError.onError!(details('boom'));
        expect(reports, hasLength(1));
        expect(capture.suppressedCount, 0);
        expect(warnings, isEmpty);
      },
    );

    test(
      'an async FlutterError by the object route and the isolate-text route is one, silently',
      () async {
        capture.install(platformErrors: false);
        final error = FlutterError(
          'A summary line\nthe detail that only toString has',
        );
        FlutterError.onError!(details(error));
        // The isolate listener gets `error.toString()`, the whole message.
        capture.debugIsolateSendPort!.send([
          error.toString(),
          '${FlutterError.demangleStackTrace(stack)}',
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(reports, hasLength(1));
        expect(reports.single.reason, 'A summary line');
        expect(capture.suppressedCount, 0);
        expect(warnings, isEmpty);
      },
    );

    test(
      'an equal error (a new object) within 30 s is limited, after 30 s it is reported',
      () {
        capture.install(isolateErrors: false);
        FlutterError.onError!(details(StateError('x')));
        clock.advance(const Duration(seconds: 29));
        FlutterError.onError!(details(StateError('x')));
        expect(reports, hasLength(1));
        expect(capture.suppressedCount, 1);

        clock.advance(const Duration(seconds: 2));
        FlutterError.onError!(details(StateError('x')));
        expect(reports, hasLength(2));
      },
    );

    test('a render error that repeats every frame is one report', () {
      capture.install(isolateErrors: false);
      for (var i = 0; i < 600; i++) {
        FlutterError.onError!(details(FlutterError('overflow')));
        clock.advance(const Duration(milliseconds: 16));
      }
      expect(reports, hasLength(1));
    });

    test('different errors are limited to 10 in 60 s, then allowed again', () {
      capture.install(isolateErrors: false);
      for (var i = 0; i < 25; i++) {
        FlutterError.onError!(details(StateError('distinct $i')));
      }
      expect(reports, hasLength(10));
      clock.advance(const Duration(seconds: 61));
      FlutterError.onError!(details(StateError('after the window')));
      expect(reports, hasLength(11));
    });

    test('the limit is announced once (debug), not per error', () {
      capture.install(isolateErrors: false);
      for (var i = 0; i < 30; i++) {
        FlutterError.onError!(details(StateError('distinct $i')));
      }
      expect(warnings, hasLength(1));
    });

    test('a string is not an Expando key: it is limited by fingerprint', () {
      capture.install(isolateErrors: false);
      PlatformDispatcher.instance.onError!('boom', stack);
      PlatformDispatcher.instance.onError!('boom', stack);
      PlatformDispatcher.instance.onError!('other', stack);
      expect(reports.map((r) => r.reason), ['boom', 'other']);
    });
  });

  group('limiter', () {
    test(
      'a fingerprint that is reported again becomes the newest, not the oldest',
      () {
        final limiter = ReportLimiter(
          now: clock.call,
          maxTracked: 3,
          maxInWindow: 1000,
          perFingerprint: const Duration(seconds: 10),
        );
        for (final f in ['a', 'b', 'c']) {
          ok(limiter, f);
        }
        clock.advance(const Duration(seconds: 11));
        expect(ok(limiter, 'a'), isTrue, reason: 'refreshed');
        expect(ok(limiter, 'd'), isTrue, reason: 'evicts b, the oldest now');
        expect(ok(limiter, 'a'), isFalse, reason: 'a is still tracked');
        expect(ok(limiter, 'b'), isTrue, reason: 'b was forgotten');
      },
    );

    test('forgets the oldest fingerprint beyond what it tracks', () {
      final limiter = ReportLimiter(
        now: clock.call,
        maxTracked: 3,
        maxInWindow: 1000,
      );
      for (final f in ['a', 'b', 'c', 'd']) {
        expect(ok(limiter, f), isTrue);
      }
      expect(ok(limiter, 'd'), isFalse, reason: 'still tracked');
      expect(ok(limiter, 'a'), isTrue, reason: 'forgotten, so allowed');
    });
  });

  group('what is reported', () {
    test(
      'handled (an error report) by default, unhandled (a crash report) with reportAsCrash true',
      () {
        capture.install(isolateErrors: false);
        FlutterError.onError!(details(StateError('a')));
        capture.uninstall();
        capture.install(isolateErrors: false, reportAsCrash: true);
        FlutterError.onError!(details(StateError('b')));
        expect(reports.map((r) => r.handled), [true, false]);
      },
    );

    test('non-Error objects: a String, an int, a custom object', () {
      capture.install(isolateErrors: false);
      PlatformDispatcher.instance.onError!('plain string', stack);
      PlatformDispatcher.instance.onError!(42, stack);
      PlatformDispatcher.instance.onError!(Object(), stack);
      expect(reports.map((r) => r.name), ['String', 'int', 'Object']);
      expect(reports.map((r) => r.reason), [
        'plain string',
        '42',
        "Instance of 'Object'",
      ]);
    });

    test(
      'nothing is reported while detect.crash is false, the chain still runs',
      () {
        var previousCalls = 0;
        FlutterError.onError = (_) => previousCalls++;
        capture.install(platformErrors: false, isolateErrors: false);
        enabled = false;
        FlutterError.onError!(details(StateError('x')));
        expect(reports, isEmpty);
        expect(previousCalls, 1);
      },
    );

    test('a payload carries the document the backend routes on', () {
      capture.install(isolateErrors: false);
      FlutterError.onError!(details(StateError('x')));
      final doc = jsonDecode(reports.single.payload.json) as Map;
      expect(doc['internalType'], 'FlutterManagedException');
      expect(doc['name'], 'StateError');
    });
  });

  group('never throws', () {
    test(
      'a reporter that throws synchronously, and one that fails later',
      () async {
        capture.install(isolateErrors: false);
        reporterOverride = (p, {required handled}) => throw StateError('sync');
        FlutterError.onError!(details(StateError('a')));
        reporterOverride = (p, {required handled}) =>
            Future<void>.error(StateError('async'));
        FlutterError.onError!(details(StateError('b')));
        await Future<void>.delayed(Duration.zero);
        // nothing escaped into the zone: the test would have failed
      },
    );

    test('a callback that throws never reaches the app, in either hook', () {
      var previousCalls = 0;
      FlutterError.onError = (_) => previousCalls++;
      PlatformDispatcher.instance.onError = (e, s) => true;
      final throwing = ErrorCapture(
        report: (p, {required handled}) async {},
        enabled: () => throw StateError('enabled() blew up'),
        limiter: ReportLimiter(now: clock.call),
      );
      throwing.install(isolateErrors: false);
      FlutterError.onError!(details(StateError('a')));
      expect(
        PlatformDispatcher.instance.onError!(StateError('b'), stack),
        isTrue,
        reason: 'and the previous handler still answers',
      );
      expect(previousCalls, 1);
      throwing.uninstall();
    });

    test(
      'an error raised while reporting does not report itself (re-entrancy)',
      () {
        capture.install(isolateErrors: false);
        reporterOverride = (p, {required handled}) {
          reports.add(Reported(p, handled));
          FlutterError.onError!(details(StateError('raised while reporting')));
          return Future<void>.value();
        };
        FlutterError.onError!(details(StateError('first')));
        expect(reports, hasLength(1));
      },
    );

    test('an error whose toString throws is still reported', () {
      capture.install(isolateErrors: false);
      PlatformDispatcher.instance.onError!(_Hostile(), stack);
      expect(reports.single.reason, '<message unavailable: _Hostile>');
    });
  });

  group('isolate errors', () {
    test(
      'the root isolate listener reports the text the VM sends, typed by its prefix',
      () async {
        capture.install(flutterErrors: false, platformErrors: false);
        final port = capture.debugIsolateSendPort!;
        port.send([
          'Bad state: no element',
          '#0      f (package:app/a.dart:1:1)\n',
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(reports, hasLength(1));
        expect(reports.single.name, 'StateError');
        expect(reports.single.reason, 'Bad state: no element');
        expect(reports.single.handled, isTrue);
      },
    );

    test('a malformed message is ignored', () async {
      capture.install(flutterErrors: false, platformErrors: false);
      final port = capture.debugIsolateSendPort!;
      port.send('not a list');
      port.send([1]);
      port.send(['text only', null]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        reports,
        hasLength(1),
        reason: 'only the well-formed pair, with no stack',
      );
      expect(reports.single.reason, 'text only');
    });

    test(
      'the same error that came as an object and as isolate text is one report',
      () async {
        capture.install(platformErrors: false);
        FlutterError.onError!(details(StateError('same one')));
        capture.debugIsolateSendPort!.send([
          'Bad state: same one',
          '${FlutterError.demangleStackTrace(stack)}',
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(reports, hasLength(1));
      },
    );

    test(
      'listenTo reports an isolate the app spawned until cancelled',
      () async {
        final isolate = await Isolate.spawn(
          entryThatThrows,
          null,
          paused: true,
          errorsAreFatal: false,
        );
        final listener = capture.listenTo(isolate);
        isolate.resume(isolate.pauseCapability!);
        for (var i = 0; i < 50 && reports.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        listener.cancel();
        listener.cancel(); // idempotent
        isolate.kill(priority: Isolate.immediate);

        expect(reports, hasLength(1));
        expect(reports.single.name, 'StateError');
        expect(reports.single.reason, 'Bad state: from an isolate');
        expect(reports.single.payload.json, contains('entryThatThrows'));
      },
    );

    test('uninstall removes the root listener', () {
      capture.install(flutterErrors: false, platformErrors: false);
      expect(capture.debugIsolateSendPort, isNotNull);
      capture.uninstall();
      expect(capture.debugIsolateSendPort, isNull);
    });
  });

  group('zone errors', () {
    test(
      'are reported as handled (error reports) unless crash reports were asked for',
      () {
        capture.captureZoneError(StateError('zone'), stack);
        expect(reports.single.handled, isTrue);
        expect(reports.single.name, 'StateError');
      },
    );

    test('follow reportAsCrash of the installation', () {
      capture.install(
        flutterErrors: false,
        platformErrors: false,
        isolateErrors: false,
        reportAsCrash: true,
      );
      capture.captureZoneError(StateError('zone'), stack);
      expect(reports.single.handled, isFalse);
    });

    test('are limited and deduplicated like the hooks', () {
      final error = StateError('zone');
      capture.captureZoneError(error, stack);
      capture.captureZoneError(error, stack);
      capture.captureZoneError(StateError('zone'), stack);
      expect(reports, hasLength(1));
    });
  });
}

class _Hostile {
  @override
  String toString() => throw StateError('no');
}
