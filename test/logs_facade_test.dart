// ignore_for_file: avoid_print
// `Bugsee.installLogCapture` and friends through the real runtime with a fake native side: what the
// app prints ends up as `addLogLines` batches, under the SDK's gates.
import 'dart:async';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/bugsee.dart' show debugSetBugseeRuntime;
import 'package:bugsee_flutter/src/bugsee_runtime.dart';
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHost extends BugseeBridgeHostApi {
  String statusName = 'launched';
  Map<String, Object> options = {};
  final List<List<LogLineMessage>> batches = [];
  final List<(String, int)> appLogs = [];
  bool addThrows = false;

  /// Every call that matters for ordering: `lines:<n>` and the report calls.
  final List<String> calls = [];

  List<LogLineMessage> get sent => [for (final b in batches) ...b];

  @override
  Future<void> attachLifecycle() async {}
  @override
  Future<void> resetReportHandlers() async {}
  @override
  Future<void> setReportHandlerPhases(bool before, bool after) async {}
  @override
  Future<void> setWrapperIdentity(WrapperIdentityMessage identity) async {}

  @override
  Future<LaunchOutcomeMessage> launch(
    String token,
    Map<String, Object> options,
  ) async {
    statusName = 'launched';
    return LaunchOutcomeMessage(outcome: 'launched');
  }

  @override
  Future<void> stop() async => statusName = 'stopped';

  @override
  Future<String> status() async => statusName;

  @override
  Future<Map<String, Object>> launchOptions(bool hostOnly) async => options;

  @override
  Future<void> log(String message, int level) async =>
      appLogs.add((message, level));

  @override
  Future<int> addLogLines(List<LogLineMessage> lines) async {
    if (addThrows) throw StateError('native down');
    batches.add(lines);
    calls.add('lines:${lines.length}');
    return lines.length;
  }

  @override
  Future<void> upload(
    String summary,
    String description,
    int? severity,
    List<String>? labels,
  ) async => calls.add('upload');

  @override
  Future<void> showReportDialog(
    String? summary,
    String? description,
    int? severity,
    List<String>? labels,
  ) async => calls.add('dialog');

  @override
  Future<bool> logException(
    String payload,
    bool handled,
    String? domain,
  ) async {
    calls.add('exception');
    return true;
  }

  @override
  Future<String?> createReport(int timeToLiveMs) async {
    calls.add('createReport');
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHost host;
  late BugseeRuntime runtime;
  late List<String> warnings;
  late DebugPrintCallback savedDebugPrint;
  OptionPlatform? platform;
  var binding = true;

  Future<void> settle() => runtime.logs.pipeline.flush();

  setUp(() {
    savedDebugPrint = debugPrint;
    host = FakeHost();
    warnings = [];
    platform = OptionPlatform.android;
    binding = true;
    runtime = BugseeRuntime(
      host: host,
      platform: () => platform,
      warn: warnings.add,
      ensureBinding: () {
        if (!binding) throw StateError('no binding in this isolate');
      },
    );
    debugSetBugseeRuntime(runtime);
  });

  tearDown(() {
    Bugsee.uninstallLogCapture();
    debugPrint = savedDebugPrint;
  });

  Future<void> install({LogLevel level = LogLevel.info}) async {
    expect(Bugsee.installLogCapture(level: level), isTrue);
    await runtime.logs.refreshPolicy();
  }

  test(
    'installs, and print inside runWithLogCapture ends up at native',
    () async {
      expect(Bugsee.logCaptureInstalled, isFalse);
      await install();
      expect(Bugsee.logCaptureInstalled, isTrue);
      final out = <String>[];
      runZoned(
        () => Bugsee.runWithLogCapture(() {
          print('hello from dart');
        }),
        zoneSpecification: ZoneSpecification(print: (s, p, z, l) => out.add(l)),
      );
      await settle();
      expect(out, ['hello from dart']);
      expect(host.sent.single.message, 'hello from dart');
      expect(host.sent.single.level, LogLevel.info.value);
      expect(host.sent.single.tag, 'print');
      expect(Bugsee.logCaptureStats.submittedToSdk, 1);
    },
  );

  test('runWithLogCapture returns the body\'s value', () {
    expect(Bugsee.runWithLogCapture(() => 42), 42);
  });

  test(
    'runGuarded records print too, and its error handling is unchanged',
    () async {
      await install();
      final errors = <Object>[];
      final out = <String>[];
      runZoned(
        () => Bugsee.runGuarded(() {
          print('inside guarded');
          Future<void>(() => throw StateError('boom'));
        }, onError: (e, s) => errors.add(e)),
        zoneSpecification: ZoneSpecification(print: (s, p, z, l) => out.add(l)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await settle();
      expect(out, ['inside guarded']);
      expect(host.sent.map((m) => m.message), ['inside guarded']);
      expect(errors.single, isA<StateError>());
    },
  );

  test('debugPrint is recorded with its own tag', () async {
    await install();
    debugPrint('framework says');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await settle();
    expect(host.sent.single.tag, 'debugPrint');
    expect(host.sent.single.message, 'framework says');
  });

  test('the level given to install applies to print lines', () async {
    await install(level: LogLevel.warning);
    Bugsee.runWithLogCapture(() => print('x'));
    await settle();
    expect(host.sent.single.level, LogLevel.warning.value);
  });

  group('the SDK\'s gates', () {
    test('before launch: dropped, counted', () async {
      host.statusName = 'stopped';
      await install();
      Bugsee.runWithLogCapture(() => print('early'));
      await settle();
      expect(host.sent, isEmpty);
      expect(Bugsee.logCaptureStats.droppedNotAccepting, 1);
    });

    test('launching: accepted (both SDKs take it)', () async {
      host.statusName = 'launching';
      await install();
      Bugsee.runWithLogCapture(() => print('while launching'));
      await settle();
      expect(host.sent.single.message, 'while launching');
    });

    test('after stop: dropped, and a launch makes it accept again', () async {
      await install();
      await Bugsee.stop();
      Bugsee.runWithLogCapture(() => print('stopped'));
      await settle();
      expect(host.sent, isEmpty);
      await Bugsee.launch('token');
      // launch refreshes the policy by itself (nothing here asks for it)
      await Future<void>.delayed(const Duration(milliseconds: 30));
      Bugsee.runWithLogCapture(() => print('launched again'));
      await settle();
      expect(host.sent.map((m) => m.message), ['launched again']);
    });

    test('capture.logs off: nothing is sent', () async {
      host.options = {'com.bugsee.option.capture.logs': false};
      await install();
      Bugsee.runWithLogCapture(() => print('x'));
      await settle();
      expect(host.sent, isEmpty);
    });

    test('capture.logs on, explicitly, or absent: sent', () async {
      host.options = {'com.bugsee.option.capture.logs': true};
      await install();
      Bugsee.runWithLogCapture(() => print('x'));
      await settle();
      expect(host.sent, hasLength(1));
    });

    test(
      'capture.logs.level: lines more verbose than it are not sent',
      () async {
        host.options = {
          'com.bugsee.option.capture.logs.level': LogLevel.warning.value,
        };
        await install(level: LogLevel.info);
        Bugsee.runWithLogCapture(() => print('info line'));
        Bugsee.forwardLog('warn line', level: LogLevel.warning);
        Bugsee.forwardLog('error line', level: LogLevel.error);
        await settle();
        expect(host.sent.map((m) => m.message), ['warn line', 'error line']);
        expect(Bugsee.logCaptureStats.droppedBelowLevel, 1);
      },
    );

    test('the level option may arrive by name', () async {
      host.options = {'com.bugsee.option.capture.logs.level': 'Error'};
      await install();
      Bugsee.forwardLog('w', level: LogLevel.warning);
      Bugsee.forwardLog('e', level: LogLevel.error);
      await settle();
      expect(host.sent.map((m) => m.message), ['e']);
    });
  });

  group('app-level Bugsee.log is another route', () {
    test(
      'Bugsee.log goes to the SDK as before and is not captured, filtered or counted',
      () async {
        await install();
        var filtered = 0;
        Bugsee.setLogFilter((e) {
          filtered++;
          return e;
        });
        await Bugsee.log('deliberate', level: LogLevel.warning);
        await settle();
        expect(host.appLogs, [('deliberate', LogLevel.warning.value)]);
        expect(host.sent, isEmpty);
        expect(filtered, 0);
        expect(Bugsee.logCaptureStats.captured, 0);
      },
    );

    test('a printed line does not call the app-level log', () async {
      await install();
      Bugsee.runWithLogCapture(() => print('printed'));
      await settle();
      expect(host.appLogs, isEmpty);
      expect(host.sent, hasLength(1));
    });
  });

  group('what was printed just before a report is in it', () {
    Future<void> printed() async {
      await install();
      Bugsee.runWithLogCapture(() => print('parsing the order'));
    }

    test('upload', () async {
      await printed();
      await Bugsee.upload('s', 'd');
      expect(host.calls, ['lines:1', 'upload']);
    });

    test('showReportDialog', () async {
      await printed();
      await Bugsee.showReportDialog();
      expect(host.calls, ['lines:1', 'dialog']);
    });

    test('createReport', () async {
      await printed();
      await Bugsee.createReport();
      expect(host.calls, ['lines:1', 'createReport']);
    });

    test(
      'logException, reportException and the installed error handler path',
      () async {
        await printed();
        await Bugsee.logException(StateError('boom'), StackTrace.current);
        expect(host.calls, ['lines:1', 'exception']);
        host.calls.clear();
        Bugsee.runWithLogCapture(() => print('and again'));
        await Bugsee.reportException(StateError('boom2'));
        expect(host.calls, ['lines:1', 'exception']);
      },
    );

    test(
      'a hung filter holds the report back for a fraction of a second, no more',
      () async {
        await install();
        Bugsee.setLogFilter(
          (e) => Completer<BugseeLogEvent?>().future,
          timeout: const Duration(seconds: 30),
        );
        Bugsee.runWithLogCapture(() => print('behind a hung filter'));
        final watch = Stopwatch()..start();
        await Bugsee.upload('s', 'd');
        // A ceiling, not a measurement: far under the filter's 30 s timeout the hold-back must
        // not wait for (the hold-back itself is bounded by LogCapture.flushLimit, 200 ms).
        expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
        expect(host.calls, ['upload']);
      },
    );

    test(
      'without the capture installed a report is not delayed or changed',
      () async {
        await Bugsee.upload('s', 'd');
        expect(host.calls, ['upload']);
      },
    );
  });

  group('forwardLog', () {
    test('records at info by default', () async {
      await install();
      Bugsee.forwardLog('plain');
      await settle();
      expect(host.sent.single.level, LogLevel.info.value);
      expect(host.sent.single.tag, isNull);
    });

    test('is refused before install, taken after', () async {
      expect(Bugsee.forwardLog('x'), isFalse);
      await install();
      expect(
        Bugsee.forwardLog('from logging', level: LogLevel.debug, tag: 'net'),
        isTrue,
      );
      await settle();
      expect(host.sent.single.level, LogLevel.debug.value);
      expect(host.sent.single.tag, 'net');
    });
  });

  group('the filter', () {
    test('redacts before native sees anything', () async {
      await install();
      Bugsee.setLogFilter((e) {
        e.message = e.message.replaceAll(RegExp(r'\d{4}'), '####');
        return e;
      });
      expect(Bugsee.logFilter, isNotNull);
      Bugsee.runWithLogCapture(() => print('card 4111 and pin 1234'));
      await settle();
      expect(host.sent.single.message, 'card #### and pin ####');
    });

    test('fails closed through the whole stack', () async {
      await install();
      Bugsee.setLogFilter((e) => throw StateError('bug'));
      Bugsee.runWithLogCapture(() => print('secret'));
      await settle();
      expect(host.sent, isEmpty);
      expect(Bugsee.logCaptureStats.filterFailures, 1);
    });

    test('a timeout out of range is a BugseeArgumentException', () {
      expect(
        () => Bugsee.setLogFilter((e) => e, timeout: Duration.zero),
        throwsA(isA<BugseeArgumentException>()),
      );
      expect(
        () =>
            Bugsee.setLogFilter((e) => e, timeout: const Duration(minutes: 6)),
        throwsA(isA<BugseeArgumentException>()),
      );
    });

    test('a print made by the filter is not recorded', () async {
      await install();
      Bugsee.setLogFilter((e) {
        print('filter saw ${e.message}');
        return e;
      });
      Bugsee.runWithLogCapture(() => print('real'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await settle();
      expect(host.sent.map((m) => m.message), ['real']);
    });
  });

  group('failures', () {
    test(
      'a native failure is counted and the app\'s print is untouched',
      () async {
        await install();
        host.addThrows = true;
        final out = <String>[];
        runZoned(
          () => Bugsee.runWithLogCapture(() => print('x')),
          zoneSpecification: ZoneSpecification(
            print: (s, p, z, l) => out.add(l),
          ),
        );
        await settle();
        expect(out, ['x']);
        expect(Bugsee.logCaptureStats.sendFailures, 1);
        expect(
          warnings.where((w) => w.contains('could not be handed')),
          hasLength(1),
        );
      },
    );

    test('from a background isolate it is a BugseeException', () {
      binding = false;
      expect(Bugsee.installLogCapture, throwsA(isA<BugseeException>()));
    });

    test('on a platform with no SDK it installs nothing and returns false', () {
      platform = null;
      final before = debugPrint;
      expect(Bugsee.installLogCapture(), isFalse);
      expect(Bugsee.logCaptureInstalled, isFalse);
      expect(identical(debugPrint, before), isTrue);
    });
  });

  test(
    'the capture is isolate-local state: a fresh runtime starts clean',
    () async {
      await install();
      Bugsee.runWithLogCapture(() => print('x'));
      await settle();
      final fresh = BugseeRuntime(
        host: FakeHost(),
        platform: () => OptionPlatform.android,
        ensureBinding: () {},
      );
      expect(fresh.logCaptureInstalled, isFalse);
      expect(fresh.logCaptureStats.captured, 0);
    },
  );
}
