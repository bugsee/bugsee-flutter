// Runs on a device or simulator (it needs the native SDKs):
//
//   cd example && flutter test integration_test/exceptions_test.dart -d <device>
//
// Dart errors through the real SDKs: reported by hand (handled and unhandled), and caught by the
// installed handlers (a FlutterError, an error nobody handled in the root zone, a guarded zone, an
// isolate). The SDK's own report handler is the readback: it is told the type of every report the
// SDK builds (`error` for a handled one, `crash` for an unhandled one), so a report that appears
// there is one the SDK made from our call. iOS files nothing on a simulator (the SDK says so in
// its log), so there the test shows what it can: the calls complete and answer as documented.
import 'dart:async';
import 'dart:isolate';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_example/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void say(String line) => debugPrint('integration: $line');

void _isolateThatThrows(Object? _) =>
    throw StateError('hook: uncaught in a spawned isolate');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Dart errors reach the SDK as error and crash reports', (
    tester,
  ) async {
    final android = defaultTargetPlatform == TargetPlatform.android;

    // Before launch both SDKs drop the call, so the answer is false, for both paths.
    expect(
      await Bugsee.logException(StateError('before launch'), null),
      isFalse,
    );
    expect(
      await Bugsee.logException(
        StateError('before launch'),
        null,
        handled: false,
      ),
      isFalse,
    );
    say('before launch: handled and unhandled answered false');

    final deliveries = <String>[];
    final summaries = <String>[];
    await Bugsee.setReportHandler(
      BugseeReportHandler(
        onBeforeReportCreated: (report) async {
          deliveries.add('before:${report.type?.name}');
        },
        onAfterReportCreated: (report) async {
          final snapshot = await report.read();
          deliveries.add('after:${report.type?.name}');
          summaries.add('${report.type?.name}: ${snapshot.summary}');
        },
      ),
    );

    final result = await Bugsee.launch(defaultToken, options: exampleOptions());
    say('launch -> $result');
    expect(await Bugsee.waitUntilLaunched(), isTrue);

    // iOS stops the SDK on its own once the server refuses the placeholder token, so what the SDK
    // is handed depends on whether it is still launched: the answer must say exactly that.
    Future<void> expectHanded(
      Future<bool> call,
      bool launchedBefore, {
      required String what,
    }) async {
      final taken = await call;
      say('$what handed to the SDK: $taken (launched before: $launchedBefore)');
      if (android) {
        expect(taken, isTrue, reason: what);
      } else if (launchedBefore) {
        // It may have stopped while the call was in flight; a call made while launched is only
        // refused if the status changed in between.
        say('$what: iOS answered $taken');
      } else {
        expect(taken, isFalse, reason: what);
      }
    }

    Future<void> waitFor(bool Function() done, String what) async {
      // iOS files nothing on a simulator: no report to wait for.
      if (!android) return;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline) && !done()) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      say('$what: deliveries = $deliveries');
    }

    int count(String d) => deliveries.where((x) => x == d).length;

    // ---- By hand --------------------------------------------------------------------------
    try {
      throw FormatException('handled in the integration test');
    } catch (e, s) {
      await expectHanded(
        Bugsee.logException(e, s, domain: 'integration'),
        await Bugsee.isLaunched(),
        what: 'handled',
      );
    }
    await waitFor(() => count('after:error') >= 1, 'handled');
    if (android) {
      expect(deliveries, containsAll(['before:error', 'after:error']));
    }

    await expectHanded(
      Bugsee.logException(
        StateError('unhandled in the integration test'),
        null,
        handled: false,
      ),
      await Bugsee.isLaunched(),
      what: 'unhandled',
    );
    await waitFor(() => count('after:crash') >= 1, 'unhandled');
    if (android) {
      expect(deliveries, containsAll(['before:crash', 'after:crash']));
    }
    final before = deliveries.length;

    // ---- The installed handlers, chained to the test framework's ---------------------------
    final previous = FlutterError.onError;
    Bugsee.installErrorHandlers();
    expect(Bugsee.errorHandlersInstalled, isTrue);
    expect(FlutterError.onError, isNot(same(previous)));

    // FlutterError.onError
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('hook: FlutterError.reportError'),
        stack: StackTrace.current,
        library: 'integration test',
      ),
    );
    // The framework's own handler (the one we chained to) saw it too.
    expect(tester.takeException(), isA<StateError>());

    // An error nobody handles, started in the root zone like an engine callback would.
    Zone.root.run(() {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 10)).then(
          (_) => throw StateError('hook: unhandled async error, root zone'),
        ),
      );
    });

    // A guarded zone.
    final zoneSaw = Completer<void>();
    Bugsee.runGuarded(
      () => Timer.run(() => throw StateError('hook: error in a guarded zone')),
      onError: (e, s) => zoneSaw.complete(),
    );
    await zoneSaw.future;

    // An isolate the app spawned.
    final isolate = await Isolate.spawn(
      _isolateThatThrows,
      null,
      paused: true,
      errorsAreFatal: false,
    );
    final listener = Bugsee.listenToIsolateErrors(isolate);
    isolate.resume(isolate.pauseCapability!);

    await waitFor(
      () => count('after:crash') >= 5,
      'four hooks (FlutterError, root zone, guarded zone, isolate)',
    );
    listener.cancel();
    isolate.kill(priority: Isolate.immediate);

    // Flood: the same error 100 times is one report.
    final flood = count('after:crash');
    for (var i = 0; i < 100; i++) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: FlutterError('the same error, again')),
      );
      tester.takeException();
    }
    await Future<void>.delayed(const Duration(seconds: 3));
    say(
      'flood: ${count('after:crash') - flood} crash report(s) for 100 equal errors',
    );

    Bugsee.uninstallErrorHandlers();
    expect(FlutterError.onError, same(previous));
    expect(Bugsee.errorHandlersInstalled, isFalse);

    say('summaries: $summaries');
    say('${deliveries.length - before} deliveries from the hooks');
    if (android) {
      // FlutterError, root-zone error (if the engine routed it), guarded zone, isolate, flood.
      expect(count('after:crash'), greaterThanOrEqualTo(4));
      expect(
        count('after:crash') - flood,
        1,
        reason: 'the limiter lets one of 100 equal errors through',
      );
    }

    await Bugsee.setReportHandler(null);
    await Bugsee.stop();

    // After stop the SDK drops it: the answer says so.
    expect(await Bugsee.logException(StateError('after stop'), null), isFalse);
    expect(
      await Bugsee.logException(StateError('after stop'), null, handled: false),
      isFalse,
    );
    say('after stop: handled and unhandled answered false');
  });
}
