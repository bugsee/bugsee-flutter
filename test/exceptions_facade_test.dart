// `Bugsee.logException` and the installer through the public facade, against a fake native side:
// what crosses (the document, handled, domain), what is refused in Dart, and what a failure of
// native does to the app's error path.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter/src/bugsee.dart' show debugSetBugseeRuntime;
import 'package:bugsee_flutter/src/bugsee_runtime.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/launch.dart';
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/facade_fake.dart';

Map<String, Object?> document(FacadeFake native) =>
    jsonDecode(native.last['logException']![0]! as String)
        as Map<String, Object?>;

/// Lets what a handler started without waiting reach the fake.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FacadeFake native;
  late BugseeRuntime runtime;
  OptionPlatform? platform;
  late List<String> warnings;
  late FlutterExceptionHandler? savedFlutter;
  late ErrorCallback? savedPlatform;

  setUp(() {
    native = FacadeFake();
    warnings = [];
    platform = OptionPlatform.android;
    runtime = BugseeRuntime(
      host: native,
      platform: () => platform,
      warn: warnings.add,
    );
    debugSetBugseeRuntime(runtime);
    savedFlutter = FlutterError.onError;
    savedPlatform = PlatformDispatcher.instance.onError;
  });

  tearDown(() {
    Bugsee.uninstallErrorHandlers();
    FlutterError.onError = savedFlutter;
    PlatformDispatcher.instance.onError = savedPlatform;
  });

  group('Bugsee.logException', () {
    test('crosses the document, handled by default, no domain', () async {
      final taken = await Bugsee.logException(
        StateError('x'),
        StackTrace.fromString('#0      f (package:app/a.dart:1:1)\n'),
      );
      expect(taken, isTrue);
      expect(native.last['logException']![1], true);
      expect(native.last['logException']![2], isNull);
      final doc = document(native);
      expect(doc['internalType'], 'FlutterManagedException');
      expect(doc['name'], 'StateError');
      expect(doc['reason'], 'Bad state: x');
      expect(doc['originalStackTrace'], '#0      f (package:app/a.dart:1:1)\n');
    });

    test('handled: false and a domain cross as given', () async {
      await Bugsee.logException(
        StateError('x'),
        null,
        handled: false,
        domain: 'checkout',
      );
      expect(native.last['logException']![1], false);
      expect(native.last['logException']![2], 'checkout');
    });

    test(
      'with no stack the current one is taken, starting at the caller',
      () async {
        Future<void> callerOfLogException() =>
            Bugsee.logException(StateError('x'), null);
        await callerOfLogException();
        final frames = (document(native)['frames']! as List).cast<Map>();
        expect(frames.first['trace'], contains('callerOfLogException'));
        expect(
          frames.where(
            (f) => '${f['trace']}'.contains('package:bugsee_flutter'),
          ),
          isEmpty,
          reason: 'the plugin\'s own frames are not the app\'s',
        );
      },
    );

    test(
      'answers false when native did not hand it to the SDK (before launch)',
      () async {
        native.exceptionAccepted = false;
        expect(await Bugsee.logException('x', null), isFalse);
      },
    );

    test('any object can be thrown: a string, an int', () async {
      await Bugsee.logException('plain', null);
      expect(document(native)['name'], 'String');
      await Bugsee.logException(7, null);
      expect(document(native)['name'], 'int');
      expect(document(native)['reason'], '7');
    });

    test('a bad domain is refused in Dart, nothing crosses', () async {
      for (final domain in ['', 'd' * 257]) {
        await expectLater(
          Bugsee.logException('x', null, domain: domain),
          throwsA(
            isA<BugseeArgumentException>().having(
              (e) => e.argument,
              'argument',
              'domain',
            ),
          ),
        );
      }
      expect(native.calls, isNot(contains(startsWith('logException'))));
      expect(await Bugsee.logException('x', null, domain: 'd' * 256), isTrue);
    });

    test(
      'a native refusal is a BugseeArgumentException, a native error a BugseeException',
      () async {
        native.failing['logException'] = refusal('invalid-argument');
        await expectLater(
          Bugsee.logException('x', null),
          throwsA(isA<BugseeArgumentException>()),
        );
        native.failing['logException'] = refusal('sdk-error');
        await expectLater(
          Bugsee.logException('x', null),
          throwsA(
            isA<BugseeException>().having(
              (e) => e,
              'not an argument error',
              isNot(isA<BugseeArgumentException>()),
            ),
          ),
        );
      },
    );

    test('on a platform with no SDK it is a no-op answering false', () async {
      platform = null;
      expect(await Bugsee.logException('x', null), isFalse);
      expect(native.calls, isEmpty);
    });
  });

  group('the installer through the facade', () {
    test(
      'is opt-in: nothing is installed until asked, and not by a launch',
      () async {
        expect(Bugsee.errorHandlersInstalled, isFalse);
        final flutterBefore = FlutterError.onError;
        await Bugsee.launch('TOKEN');
        expect(Bugsee.errorHandlersInstalled, isFalse);
        expect(FlutterError.onError, same(flutterBefore));
      },
    );

    test('a FlutterError reaches native as an unhandled error, once', () async {
      Bugsee.installErrorHandlers(isolateErrors: false);
      expect(Bugsee.errorHandlersInstalled, isTrue);
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('from the framework'),
          stack: StackTrace.fromString('#0      f (package:app/a.dart:1:1)\n'),
        ),
      );
      await settle();
      expect(
        native.calls.where((c) => c.startsWith('logException')),
        hasLength(1),
      );
      expect(native.last['logException']![1], false);
      expect(document(native)['reason'], 'Bad state: from the framework');
    });

    test('reportAsCrash false reports handled', () async {
      Bugsee.installErrorHandlers(isolateErrors: false, reportAsCrash: false);
      PlatformDispatcher.instance.onError!(StateError('x'), StackTrace.empty);
      await settle();
      expect(native.last['logException']![1], true);
    });

    test('uninstall stops reporting', () async {
      Bugsee.installErrorHandlers(isolateErrors: false);
      Bugsee.uninstallErrorHandlers();
      expect(Bugsee.errorHandlersInstalled, isFalse);
      FlutterError.onError?.call(
        FlutterErrorDetails(exception: StateError('x')),
      );
      await settle();
      expect(native.calls.where((c) => c.startsWith('logException')), isEmpty);
    });

    test(
      'a failing native never reaches the app: not as an exception, not as an unhandled error',
      () async {
        Bugsee.installErrorHandlers(isolateErrors: false);
        native.failing['logException'] = refusal('sdk-error');
        FlutterError.onError!(FlutterErrorDetails(exception: StateError('x')));
        await settle();
        // the test would fail on an uncaught error
      },
    );

    test(
      'nothing is reported when the launch said detect.crash is false',
      () async {
        Bugsee.installErrorHandlers(isolateErrors: false);
        await Bugsee.launch(
          'TOKEN',
          options: const BugseeOptions(detectCrash: false),
        );
        FlutterError.onError!(FlutterErrorDetails(exception: StateError('x')));
        await settle();
        expect(
          native.calls.where((c) => c.startsWith('logException')),
          isEmpty,
        );
      },
    );

    test('and an explicit logException still goes through', () async {
      await Bugsee.launch(
        'TOKEN',
        options: const BugseeOptions(detectCrash: false),
      );
      expect(await Bugsee.logException('x', null), isTrue);
    });

    test('detect.crash true or unset reports', () async {
      Bugsee.installErrorHandlers(isolateErrors: false);
      await Bugsee.launch(
        'TOKEN',
        options: const BugseeOptions(detectCrash: true),
      );
      FlutterError.onError!(FlutterErrorDetails(exception: StateError('x')));
      await settle();
      expect(
        native.calls.where((c) => c.startsWith('logException')),
        hasLength(1),
      );
    });
  });

  group('Bugsee.runGuarded', () {
    test('reports what escapes the body, then calls onError', () async {
      final seen = <Object>[];
      final done = Completer<void>();
      Bugsee.runGuarded(
        () {
          Timer.run(() => throw StateError('from a timer'));
        },
        onError: (e, s) {
          seen.add(e);
          done.complete();
        },
      );
      await done.future;
      await settle();
      expect(seen.single, isA<StateError>());
      expect(native.last['logException']![1], false);
      expect(document(native)['reason'], 'Bad state: from a timer');
    });

    test(
      'with no onError the error still goes to FlutterError.reportError',
      () async {
        final reported = <FlutterErrorDetails>[];
        FlutterError.onError = reported.add;
        Bugsee.runGuarded(() {
          Timer.run(() => throw StateError('unhandled'));
        });
        for (var i = 0; i < 20 && reported.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await settle();
        expect(reported.single.exception, isA<StateError>());
        expect(
          native.calls.where((c) => c.startsWith('logException')),
          hasLength(1),
        );
      },
    );

    test('with the hooks installed too, the error is reported once', () async {
      Bugsee.installErrorHandlers(isolateErrors: false);
      Bugsee.runGuarded(() {
        Timer.run(() => throw StateError('twice?'));
      });
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await settle();
      expect(
        native.calls.where((c) => c.startsWith('logException')),
        hasLength(1),
      );
    });

    test('returns what the body returns', () {
      expect(Bugsee.runGuarded(() => 7), 7);
    });
  });
}
