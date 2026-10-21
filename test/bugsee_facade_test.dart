// The public facade (`Bugsee.launch` / `stop` / `status`) against a fake native side: what
// reaches native and in what order, how each answer maps to a result or a typed exception, and
// the status stream.
import 'dart:async';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/bugsee_runtime.dart';
import 'package:bugsee_flutter/src/launch.dart';
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_test/flutter_test.dart';

/// A native end that records calls and answers as scripted.
class FakeNative extends BugseeBridgeHostApi {
  final List<String> calls = [];
  final List<(String, Map<String, Object>)> launches = [];
  LaunchOutcomeMessage outcome = LaunchOutcomeMessage(
    outcome: LaunchWire.launched,
  );
  PlatformException? launchThrows;
  PlatformException? stopThrows;
  PlatformException? statusThrows;
  PlatformException? optionsThrows;
  int failAttach = 0;
  String statusName = 'stopped';
  Map<String, Object> options = {};
  bool? lastHostOnly;
  Completer<void>? stopGate;

  @override
  Future<void> attachLifecycle() async {
    calls.add('attach');
    if (failAttach > 0) {
      failAttach--;
      throw PlatformException(code: 'channel-error');
    }
  }

  @override
  Future<void> resetReportHandlers() async => calls.add('reset');

  @override
  Future<void> setReportHandlerPhases(bool before, bool after) async =>
      calls.add('phases');

  @override
  Future<void> setWrapperIdentity(WrapperIdentityMessage identity) async =>
      calls.add('identity');

  @override
  Future<LaunchOutcomeMessage> launch(
    String token,
    Map<String, Object> options,
  ) async {
    calls.add('launch');
    if (launchThrows != null) throw launchThrows!;
    launches.add((token, options));
    return outcome;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (stopThrows != null) throw stopThrows!;
    await stopGate?.future;
  }

  @override
  Future<String> status() async {
    calls.add('status');
    if (statusThrows != null) throw statusThrows!;
    return statusName;
  }

  @override
  Future<Map<String, Object>> launchOptions(bool hostOnly) async {
    calls.add('launchOptions');
    lastHostOnly = hostOnly;
    if (optionsThrows != null) throw optionsThrows!;
    return options;
  }
}

/// A host whose plugin is missing: every call is a MissingPluginException.
class _MissingPlugin extends FakeNative {
  @override
  Future<void> attachLifecycle() async =>
      throw MissingPluginException('no implementation');
}

LaunchOutcomeMessage refused(String reason) =>
    LaunchOutcomeMessage(outcome: LaunchWire.refused, reason: reason);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNative native;
  late List<String> warnings;
  late BugseeRuntime runtime;
  OptionPlatform? platform;

  setUp(() {
    native = FakeNative();
    warnings = [];
    platform = OptionPlatform.android;
    runtime = BugseeRuntime(
      host: native,
      platform: () => platform,
      warn: warnings.add,
    );
    Bugsee.debugSetRuntime(runtime);
  });

  group('launch', () {
    test('attaches and refines the identity BEFORE the SDK launches', () async {
      final result = await Bugsee.launch('tok');
      expect(result, LaunchResult.launched);
      final launchAt = native.calls.indexOf('launch');
      expect(launchAt, greaterThan(native.calls.indexOf('attach')));
      expect(launchAt, greaterThan(native.calls.indexOf('identity')));
      expect(native.calls.where((c) => c == 'launch'), hasLength(1));
    });

    test(
      'sends the token and the one flat map, enums by internal value',
      () async {
        await Bugsee.launch(
          'my-token',
          options: BugseeOptions(
            captureLogs: false,
            captureLogsLevel: LogLevel.warning,
            captureVideoMode: VideoMode.fullscreen,
            endpoint: 'https://bugsee.example.com/v2/',
          ),
        );
        expect(native.launches.single.$1, 'my-token');
        expect(native.launches.single.$2, {
          'com.bugsee.option.capture.logs': false,
          'com.bugsee.option.capture.logs.level': 2,
          'com.bugsee.option.capture.video.mode': 20,
          'com.bugsee.option.\$\$ENDPOINT': 'https://bugsee.example.com',
        });
      },
    );

    test(
      'on iOS an Android-only option is dropped and a warning says so',
      () async {
        platform = OptionPlatform.ios;
        await Bugsee.launch(
          'tok',
          options: const BugseeOptions(
            captureVideoMode: VideoMode.v1,
            captureLogs: true,
          ),
        );
        expect(native.launches.single.$2, {
          'com.bugsee.option.capture.logs': true,
        });
        expect(
          warnings.single,
          contains('capture.video.mode exists on Android only'),
        );
      },
    );

    test(
      'a blank token is refused before anything native is touched',
      () async {
        for (final token in ['', '   ', '\n']) {
          await expectLater(
            Bugsee.launch(token),
            throwsA(
              isA<BugseeLaunchException>().having(
                (e) => e.reason,
                'reason',
                LaunchFailure.invalidToken,
              ),
            ),
          );
        }
        expect(native.calls, isEmpty);
      },
    );

    test(
      'an option that cannot be honoured is an ArgumentError before anything native',
      () async {
        await expectLater(
          Bugsee.launch(
            'tok',
            options: const BugseeOptions(
              custom: {'com.bugsee.option.typo': true},
            ),
          ),
          throwsArgumentError,
        );
        await expectLater(
          Bugsee.launch(
            'tok',
            options: const BugseeOptions(endpoint: 'nonsense'),
          ),
          throwsArgumentError,
        );
        expect(native.calls, isEmpty);
      },
    );

    test(
      'a platform without an SDK is a typed exception, nothing native is touched',
      () async {
        platform = null;
        await expectLater(
          Bugsee.launch('tok'),
          throwsA(
            isA<BugseeLaunchException>().having(
              (e) => e.reason,
              'reason',
              LaunchFailure.unsupportedPlatform,
            ),
          ),
        );
        expect(native.calls, isEmpty);
      },
    );

    group('what native answers', () {
      test(
        'already running: a result, not an error, and the dropped options are said so',
        () async {
          native.outcome = LaunchOutcomeMessage(
            outcome: LaunchWire.alreadyRunning,
          );
          final result = await Bugsee.launch(
            'tok',
            options: const BugseeOptions(captureLogs: false),
          );
          expect(result, LaunchResult.alreadyRunning);
          expect(warnings.single, contains('NOT applied'));
          expect(warnings.single, contains('com.bugsee.auto-init'));
        },
      );

      test('already running with no options says nothing', () async {
        native.outcome = LaunchOutcomeMessage(
          outcome: LaunchWire.alreadyRunning,
        );
        expect(await Bugsee.launch('tok'), LaunchResult.alreadyRunning);
        expect(warnings, isEmpty);
      });

      test(
        'launching twice: the second call reports the SDK was already running',
        () async {
          expect(await Bugsee.launch('tok'), LaunchResult.launched);
          native.outcome = LaunchOutcomeMessage(
            outcome: LaunchWire.alreadyRunning,
          );
          expect(await Bugsee.launch('tok'), LaunchResult.alreadyRunning);
          expect(native.launches, hasLength(2));
        },
      );

      test('deferred (iOS, app in the background)', () async {
        native.outcome = LaunchOutcomeMessage(outcome: LaunchWire.deferred);
        expect(await Bugsee.launch('tok'), LaunchResult.deferred);
      });

      test('refusals are typed exceptions with their reason', () async {
        final cases = {
          LaunchWire.invalidToken: LaunchFailure.invalidToken,
          LaunchWire.stopping: LaunchFailure.stopping,
          LaunchWire.failed: LaunchFailure.rejected,
          'something-new': LaunchFailure.rejected,
        };
        for (final entry in cases.entries) {
          native.outcome = refused(entry.key);
          await expectLater(
            Bugsee.launch('tok'),
            throwsA(
              isA<BugseeLaunchException>().having(
                (e) => e.reason,
                'reason',
                entry.value,
              ),
            ),
            reason: entry.key,
          );
        }
        native.outcome = LaunchOutcomeMessage(outcome: LaunchWire.refused);
        await expectLater(
          Bugsee.launch('tok'),
          throwsA(isA<BugseeLaunchException>()),
        );
      });

      test(
        'an outcome this version does not know is an error, not a guess',
        () async {
          native.outcome = LaunchOutcomeMessage(outcome: 'launched-ish');
          await expectLater(
            Bugsee.launch('tok'),
            throwsA(
              isA<BugseeLaunchException>()
                  .having((e) => e.reason, 'reason', LaunchFailure.nativeError)
                  .having(
                    (e) => e.message,
                    'message',
                    contains('launched-ish'),
                  ),
            ),
          );
        },
      );

      test(
        'an exception the SDK threw crosses as a typed exception carrying the cause',
        () async {
          native.launchThrows = PlatformException(
            code: LaunchWire.errorCode,
            message: 'java.lang.IllegalStateException: boom',
          );
          await expectLater(
            Bugsee.launch('tok'),
            throwsA(
              isA<BugseeLaunchException>()
                  .having((e) => e.reason, 'reason', LaunchFailure.nativeError)
                  .having((e) => e.message, 'message', contains('boom'))
                  .having((e) => e.cause, 'cause', isA<PlatformException>()),
            ),
          );
        },
      );
    });

    test(
      'a failure to attach to native is a launch error, nothing is launched, and the next call retries',
      () async {
        native.failAttach = 1;
        await expectLater(
          Bugsee.launch('tok'),
          throwsA(
            isA<BugseeLaunchException>().having(
              (e) => e.reason,
              'reason',
              LaunchFailure.nativeError,
            ),
          ),
        );
        expect(native.calls, isNot(contains('launch')));
        expect(await Bugsee.launch('tok'), LaunchResult.launched);
      },
    );
  });

  group('waitUntilLaunched (the answer to deferred and to launching)', () {
    Future<bool> waitWith(
      List<String> events, {
      String initial = 'stopped',
      Duration timeout = const Duration(seconds: 2),
    }) async {
      native.statusName = initial;
      final f = Bugsee.waitUntilLaunched(timeout: timeout);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      for (final e in events) {
        runtime.bridge.onLifecycleEvent(LifecycleEventMessage(name: e));
      }
      return f;
    }

    test('true at once when the SDK is already launched', () async {
      expect(await waitWith([], initial: 'launched'), isTrue);
    });

    test('true when launching then launched is heard', () async {
      expect(await waitWith(['Launching', 'Launched']), isTrue);
    });

    test(
      'a stopped BEFORE launching (still deferred) is not a failure',
      () async {
        expect(await waitWith(['Stopped', 'Launching', 'Launched']), isTrue);
      },
    );

    test('false when a launch that began goes back to stopped', () async {
      // Settled by the failure itself, not by the (long) timeout.
      expect(
        await waitWith(
          ['Launching', 'Stopped'],
          timeout: const Duration(seconds: 30),
        ).timeout(const Duration(seconds: 2)),
        isFalse,
      );
      // Already launching when asked, then it fails.
      expect(
        await waitWith(
          ['Stopped'],
          initial: 'launching',
          timeout: const Duration(seconds: 30),
        ).timeout(const Duration(seconds: 2)),
        isFalse,
      );
    });

    test('false when nothing happens within the timeout', () async {
      expect(
        await waitWith([], timeout: const Duration(milliseconds: 60)),
        isFalse,
      );
    });
  });

  group('outside the root isolate', () {
    test(
      'a missing binding is a clear BugseeException, not a stray error',
      () async {
        final r = BugseeRuntime(
          host: native,
          platform: () => OptionPlatform.android,
          warn: warnings.add,
          ensureBinding: () =>
              throw StateError('Binding has not yet been initialized'),
        );
        Bugsee.debugSetRuntime(r);
        await expectLater(
          Bugsee.launch('tok'),
          throwsA(
            isA<BugseeLaunchException>().having(
              (e) => e.message,
              'message',
              contains('root isolate'),
            ),
          ),
        );
        await expectLater(
          Bugsee.stop(),
          throwsA(
            isA<BugseeException>().having(
              (e) => e.message,
              'message',
              contains('root isolate'),
            ),
          ),
        );
        // The getters that cannot wait do not throw.
        expect(Bugsee.status, BugseeStatus.stopped);
        await Future<void>.delayed(Duration.zero);
        expect(native.calls, isEmpty, reason: 'nothing native was touched');
      },
    );

    test('a plugin that is not registered is a BugseeException too', () async {
      final r = BugseeRuntime(
        host: _MissingPlugin(),
        platform: () => OptionPlatform.ios,
        warn: warnings.add,
      );
      Bugsee.debugSetRuntime(r);
      await expectLater(
        Bugsee.launch('tok'),
        throwsA(
          isA<BugseeLaunchException>().having(
            (e) => e.message,
            'message',
            contains('not registered'),
          ),
        ),
      );
    });
  });

  group('stop', () {
    test(
      'attaches, stops, and completes when native says it has stopped',
      () async {
        final gate = native.stopGate = Completer<void>();
        var done = false;
        final stopped = Bugsee.stop().then((_) => done = true);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(native.calls, containsAllInOrder(['attach', 'stop']));
        expect(done, isFalse, reason: 'not before the SDK has stopped');
        gate.complete();
        await stopped;
        expect(done, isTrue);
      },
    );

    test(
      'an exception from the SDK is a BugseeException with the cause',
      () async {
        native.stopThrows = PlatformException(
          code: LaunchWire.errorCode,
          message: 'nope',
        );
        await expectLater(
          Bugsee.stop(),
          throwsA(
            isA<BugseeException>().having(
              (e) => e.cause,
              'cause',
              isA<PlatformException>(),
            ),
          ),
        );
      },
    );

    test('launch after stop launches again, with the new options', () async {
      await Bugsee.launch(
        'tok',
        options: const BugseeOptions(configDuration: 30),
      );
      await Bugsee.stop();
      await Bugsee.launch(
        'tok',
        options: const BugseeOptions(configDuration: 90),
      );
      expect(
        [
          for (final l in native.launches)
            l.$2['com.bugsee.option.config.duration'],
        ],
        [30, 90],
      );
    });
  });

  group('status', () {
    test('getStatus reads the SDK by name', () async {
      for (final s in BugseeStatus.values) {
        native.statusName = s.name;
        expect(await Bugsee.getStatus(), s);
      }
      native.statusName = 'launched';
      expect(await Bugsee.isLaunched(), isTrue);
      native.statusName = 'launching';
      expect(
        await Bugsee.isLaunched(),
        isFalse,
        reason: 'false for the whole launch window',
      );
    });

    test(
      'a status this version does not know, or a native failure, is an exception',
      () async {
        native.statusName = 'hibernating';
        await expectLater(Bugsee.getStatus(), throwsA(isA<BugseeException>()));
        native.statusThrows = PlatformException(code: 'x');
        await expectLater(Bugsee.getStatus(), throwsA(isA<BugseeException>()));
      },
    );

    test('statusChanges carries only the four transitions, in order', () async {
      final seen = <BugseeStatus>[];
      final sub = Bugsee.statusChanges.listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      for (final name in [
        'Launching',
        'BlackoutStarted',
        'Launched',
        'RelaunchedAfterCrash',
        'Stopping',
        'Stopped',
      ]) {
        runtime.bridge.onLifecycleEvent(LifecycleEventMessage(name: name));
      }
      await Future<void>.delayed(Duration.zero);
      expect(seen, [
        BugseeStatus.launching,
        BugseeStatus.launched,
        BugseeStatus.stopping,
        BugseeStatus.stopped,
      ]);
      await sub.cancel();
    });

    test('status is the last transition, and stopped before any', () async {
      expect(Bugsee.status, BugseeStatus.stopped);
      runtime.bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Launching'));
      expect(Bugsee.status, BugseeStatus.launching);
      runtime.bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Launched'));
      expect(Bugsee.status, BugseeStatus.launched);
      runtime.bridge.onLifecycleEvent(
        LifecycleEventMessage(name: 'BlackoutStarted'),
      );
      expect(
        Bugsee.status,
        BugseeStatus.launched,
        reason: 'no other event moves it',
      );
    });

    test(
      'reading the status attaches to native, so a launch made natively is heard',
      () async {
        Bugsee.status;
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(native.calls, contains('attach'));
      },
    );

    test('so does subscribing to the transitions', () async {
      final sub = Bugsee.statusChanges.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(native.calls, contains('attach'));
      await sub.cancel();
    });
  });

  group('launch options readback', () {
    test(
      'hidden options are removed whatever native sent, the rest is kept',
      () async {
        native.options = {
          'com.bugsee.option.\$\$ENDPOINT': 'https://x.example',
          'com.bugsee.option.\$\$DEBUG': true,
          'com.bugsee.option.capture.logs': true,
          'com.bugsee.option.capture.video.mode': 20,
          'com.bugsee.option.unknown.future': 1,
        };
        final options = await Bugsee.getLaunchOptions();
        expect(options, {
          'com.bugsee.option.capture.logs': true,
          'com.bugsee.option.capture.video.mode': 20,
          'com.bugsee.option.unknown.future': 1,
        });
        expect(native.lastHostOnly, isFalse);
        expect(() => options['x'] = 1, throwsUnsupportedError);
      },
    );

    test(
      'the host-only variant asks native for only what the app supplied',
      () async {
        await Bugsee.getHostLaunchOptions();
        expect(native.lastHostOnly, isTrue);
      },
    );

    test('a native failure is a BugseeException', () async {
      native.optionsThrows = PlatformException(code: 'x');
      await expectLater(
        Bugsee.getLaunchOptions(),
        throwsA(isA<BugseeException>()),
      );
    });
  });

  group('the bridge vocabulary', () {
    test('LaunchResult and LaunchFailure are what the docs promise', () {
      expect(LaunchResult.values.map((v) => v.name), [
        'launched',
        'alreadyRunning',
        'deferred',
      ]);
      expect(LaunchFailure.values.map((v) => v.name), [
        'invalidToken',
        'stopping',
        'rejected',
        'nativeError',
        'unsupportedPlatform',
      ]);
    });
  });
}
