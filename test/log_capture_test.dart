// ignore_for_file: avoid_print
// The log capture hooks: the zone `print`, the chained `debugPrint`, install / uninstall, and what is
// never recorded. The service with a fake native side (`send`) and a fake policy.
import 'dart:async';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/logs/log_capture.dart';
import 'package:bugsee_flutter/src/logs/log_pipeline.dart';
import 'package:bugsee_flutter/src/logs/log_policy.dart';
import 'package:bugsee_flutter/src/logs/log_suppress.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class Rig {
  Rig({this.supported = true, LogPolicy? initial}) {
    policy = initial ?? const LogPolicy(accepting: true);
    service = LogCaptureService(
      send: (batch) async {
        batches.add(batch);
        return batch.length;
      },
      loadPolicy: () async {
        reads++;
        // What the SDK said when it was asked, not when the answer arrived.
        final asked = policy;
        await gate?.future;
        if (readThrows) throw StateError('cannot read');
        return asked;
      },
      ensureAttached: () => attached++,
      statuses: () => statuses.stream,
      supported: () => supported,
      warn: warnings.add,
      pipelineFactory: (send, policyOf) => LogPipeline(
        send: send,
        policy: policyOf,
        limiter: LogRateLimiter(burst: 1 << 20, perSecond: 1 << 20),
        warn: warnings.add,
      ),
    );
  }

  final bool supported;
  late LogPolicy policy;
  late final LogCaptureService service;
  final List<List<LogLineMessage>> batches = [];
  final List<String> warnings = [];
  final StreamController<BugseeStatus> statuses = StreamController.broadcast();
  int attached = 0;
  int reads = 0;
  bool readThrows = false;
  Completer<void>? gate;

  List<LogLineMessage> get sent => [for (final b in batches) ...b];
  List<String> get texts => [for (final m in sent) m.message];

  /// Installs and waits for the policy read.
  Future<void> install({LogLevel level = LogLevel.info}) async {
    expect(service.install(level: level), isTrue);
    await service.refreshPolicy();
  }

  Future<void> drain() => service.pipeline.flush();

  /// Runs [body] in a zone with the capture's `print` hook, the output of which goes to [out].
  R inCaptureZone<R>(R Function() body, {List<String>? out}) {
    final output = out ?? <String>[];
    return runZoned<R>(
      () => runZoned<R>(body, zoneSpecification: service.zoneSpecification),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => output.add(line),
      ),
    );
  }
}

void main() {
  late DebugPrintCallback originalDebugPrint;

  setUp(() => originalDebugPrint = debugPrint);
  tearDown(() => debugPrint = originalDebugPrint);

  group('the zone print hook', () {
    test(
      'the original output happens, unchanged, and the line is recorded as print / info',
      () async {
        final rig = Rig();
        await rig.install();
        final out = <String>[];
        rig.inCaptureZone(() {
          print('hello');
          print('wörld\nsecond line');
        }, out: out);
        await rig.drain();
        expect(out, ['hello', 'wörld\nsecond line']);
        expect(rig.texts, ['hello', 'wörld\nsecond line']);
        expect(rig.sent.map((m) => m.tag).toSet(), {'print'});
        expect(rig.sent.map((m) => m.level).toSet(), {LogLevel.info.value});
      },
    );

    test('the level given to install is the level of print lines', () async {
      final rig = Rig();
      await rig.install(level: LogLevel.debug);
      rig.inCaptureZone(() => print('x'));
      await rig.drain();
      expect(rig.sent.single.level, LogLevel.debug.value);
    });

    test(
      'the original output comes first: the line is already printed when it is recorded',
      () async {
        final rig = Rig();
        await rig.install();
        final order = <String>[];
        rig.service.pipeline.setFilter((e) {
          order.add('filter');
          return e;
        }, const Duration(seconds: 1));
        runZoned(
          () => runZoned(() {
            print('a');
            order.add('after print');
          }, zoneSpecification: rig.service.zoneSpecification),
          zoneSpecification: ZoneSpecification(
            print: (s, p, z, line) => order.add('original'),
          ),
        );
        await rig.drain();
        expect(order, ['original', 'after print', 'filter']);
      },
    );

    test('an app zone around ours sees every line once (chaining)', () async {
      final rig = Rig();
      await rig.install();
      final seen = <String>[];
      runZoned(
        () => runZoned(() {
          print('one');
          print('two');
        }, zoneSpecification: rig.service.zoneSpecification),
        zoneSpecification: ZoneSpecification(
          print: (s, p, z, line) {
            seen.add(line);
            p.print(z, '[app] $line');
          },
        ),
      );
      await rig.drain();
      // The app's handler got the raw line; ours recorded the raw line too.
      expect(seen, ['one', 'two']);
      expect(rig.texts, ['one', 'two']);
    });

    test(
      'an app zone INSIDE ours: what its handler passes on is what is recorded',
      () async {
        final rig = Rig();
        await rig.install();
        final out = <String>[];
        runZoned(
          () => runZoned(
            () {
              print('one');
              print('swallowed');
            },
            zoneSpecification: ZoneSpecification(
              print: (s, p, z, line) {
                if (line == 'swallowed') return;
                p.print(z, '[app] $line');
              },
            ),
          ),
          zoneSpecification: ZoneSpecification.from(
            rig.service.zoneSpecification,
            print: (s, p, z, line) {
              out.add(line);
              rig.service.zoneSpecification.print!(s, p, z, line);
            },
          ),
        );
        await rig.drain();
        expect(out, ['[app] one']);
        expect(rig.texts, ['[app] one']);
      },
    );

    test(
      'the hook twice in one chain (a guarded zone inside a captured one) records once',
      () async {
        final rig = Rig();
        await rig.install();
        final out = <String>[];
        rig.inCaptureZone(() {
          runZoned(
            () => print('x'),
            zoneSpecification: rig.service.zoneSpecification,
          );
        }, out: out);
        await rig.drain();
        expect(out, ['x']);
        expect(rig.texts, ['x']);
      },
    );

    test(
      'a nested capture does not leave the guard set: the next line is recorded too',
      () async {
        final rig = Rig();
        await rig.install();
        rig.inCaptureZone(() {
          runZoned(
            () => print('a'),
            zoneSpecification: rig.service.zoneSpecification,
          );
          print('b');
        });
        await rig.drain();
        expect(rig.texts, ['a', 'b']);
      },
    );

    test(
      'an exception from the app\'s own print handler is the app\'s: it propagates, nothing is recorded',
      () async {
        final rig = Rig();
        await rig.install();
        expect(
          () => runZoned(
            () => runZoned(
              () => print('x'),
              zoneSpecification: rig.service.zoneSpecification,
            ),
            zoneSpecification: ZoneSpecification(
              print: (s, p, z, line) => throw StateError('app handler'),
            ),
          ),
          throwsStateError,
        );
        await rig.drain();
        expect(rig.sent, isEmpty);
        // ... and the guard was released: a later line is recorded.
        rig.inCaptureZone(() => print('after'));
        await rig.drain();
        expect(rig.texts, ['after']);
      },
    );

    test('a failure inside the capture never reaches the app', () async {
      final rig = Rig();
      final throwing = LogCaptureService(
        send: (_) async => 0,
        loadPolicy: () async => const LogPolicy(accepting: true),
        ensureAttached: () {},
        statuses: () => const Stream.empty(),
        supported: () => true,
        pipelineFactory: (send, policy) => LogPipeline(
          send: send,
          policy: () => throw StateError('policy broke'),
          warn: (_) {},
        ),
      );
      throwing.install();
      await throwing.refreshPolicy();
      final out = <String>[];
      runZoned(
        () => runZoned(
          () => print('safe'),
          zoneSpecification: throwing.zoneSpecification,
        ),
        zoneSpecification: ZoneSpecification(print: (s, p, z, l) => out.add(l)),
      );
      expect(out, ['safe']);
      throwing.uninstall();
      expect(rig.sent, isEmpty);
    });

    test(
      'async callbacks that print later are recorded in their own zone',
      () async {
        final rig = Rig();
        await rig.install();
        final out = <String>[];
        final done = Completer<void>();
        rig.inCaptureZone(() {
          Future<void>(() => print('future'));
          scheduleMicrotask(() => print('microtask'));
          Timer(const Duration(milliseconds: 5), () {
            print('timer');
            done.complete();
          });
          Future<void>.delayed(
            const Duration(milliseconds: 1),
          ).then((_) => print('then'));
        }, out: out);
        await done.future;
        await rig.drain();
        expect(out.toSet(), {'future', 'microtask', 'timer', 'then'});
        expect(rig.texts.toSet(), {'future', 'microtask', 'timer', 'then'});
        expect(rig.texts, hasLength(4));
      },
    );

    test(
      'an uncaught async error in the zone does not stop the hook',
      () async {
        final rig = Rig();
        await rig.install();
        final errors = <Object>[];
        final out = <String>[];
        runZonedGuarded(
          () => runZoned(() {
            print('before');
            Future<void>(() => throw StateError('later'));
            Future<void>(() => print('after'));
          }, zoneSpecification: rig.service.zoneSpecification),
          (e, s) => errors.add(e),
          zoneSpecification: ZoneSpecification(
            print: (s, p, z, l) => out.add(l),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await rig.drain();
        expect(errors.single, isA<StateError>());
        expect(out, ['before', 'after']);
        expect(rig.texts, ['before', 'after']);
      },
    );

    test(
      'nothing is recorded while the capture is not installed, and the output still happens',
      () async {
        final rig = Rig();
        final out = <String>[];
        rig.inCaptureZone(() => print('before install'), out: out);
        await rig.install();
        rig.service.uninstall();
        rig.inCaptureZone(() => print('after uninstall'), out: out);
        await rig.drain();
        expect(out, ['before install', 'after uninstall']);
        expect(rig.sent, isEmpty);
      },
    );

    test(
      'print inside a suppressed zone is not recorded (what a filter prints)',
      () async {
        final rig = Rig();
        await rig.install();
        final out = <String>[];
        rig.inCaptureZone(() {
          runSuppressed(() => print('quiet'));
          print('loud');
        }, out: out);
        await rig.drain();
        expect(out, ['quiet', 'loud']);
        expect(rig.texts, ['loud']);
      },
    );

    test('the plugin\'s own diagnostics are never recorded', () async {
      final rig = Rig();
      await rig.install();
      rig.inCaptureZone(() {
        print('bugsee_flutter: the log filter failed');
        print('not bugsee_flutter: this one is the app\'s');
      });
      await rig.drain();
      expect(rig.texts, ['not bugsee_flutter: this one is the app\'s']);
    });
  });

  group('debugPrint', () {
    test(
      'is chained: the previous callback is still called with the same arguments',
      () async {
        final calls = <(String?, int?)>[];
        debugPrint = (message, {wrapWidth}) => calls.add((message, wrapWidth));
        final rig = Rig();
        await rig.install();
        debugPrint('hello', wrapWidth: 40);
        debugPrint(null);
        await rig.drain();
        expect(calls, [('hello', 40), (null, null)]);
        expect(rig.texts, ['hello', 'null']);
        expect(rig.sent.map((m) => m.tag).toSet(), {'debugPrint'});
      },
    );

    test(
      'the real throttled debugPrint prints the same output and is recorded once',
      () async {
        final printed = <String>[];
        final rig = Rig();
        await rig.install();
        // `debugPrintThrottled` wraps long lines and prints them from a timer, later, through `print`.
        final long = List.filled(20, 'word').join(' ');
        runZoned(
          () => runZoned(() {
            debugPrintSynchronously('plain');
            debugPrint(long, wrapWidth: 30);
          }, zoneSpecification: rig.service.zoneSpecification),
          zoneSpecification: ZoneSpecification(
            print: (s, p, z, l) => printed.add(l),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await rig.drain();
        // The output is whatever the framework printed: several wrapped pieces ...
        expect(printed.first, 'plain');
        expect(printed.length, greaterThan(2));
        // ... and the capture holds the debugPrint call once, whole, plus the synchronous one it
        // could see through the zone (it never double counts the wrapped pieces).
        expect(rig.texts.where((t) => t == long), hasLength(1));
        expect(
          rig.texts.where((t) => t.startsWith('word word') && t != long),
          isEmpty,
        );
      },
    );

    test(
      'a debugPrint made while a zone hook is active is recorded exactly once',
      () async {
        final rig = Rig();
        await rig.install();
        final out = <String>[];
        rig.inCaptureZone(() => debugPrint('once'), out: out);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await rig.drain();
        expect(out, ['once']);
        expect(rig.texts, ['once']);
        expect(rig.sent.single.tag, 'debugPrint');
      },
    );

    test('uninstall puts back exactly the callback that was there', () async {
      void previous(String? m, {int? wrapWidth}) {}
      debugPrint = previous;
      final rig = Rig();
      await rig.install();
      expect(identical(debugPrint, previous), isFalse);
      rig.service.uninstall();
      expect(identical(debugPrint, previous), isTrue);
    });

    test(
      'install is idempotent: a second call leaves debugPrint alone',
      () async {
        final rig = Rig();
        await rig.install();
        final installed = debugPrint;
        expect(rig.service.install(), isTrue);
        expect(identical(debugPrint, installed), isTrue);
      },
    );

    test(
      'uninstall without install is harmless, and so is a second uninstall',
      () async {
        final rig = Rig();
        rig.service.uninstall();
        final before = debugPrint;
        await rig.install();
        rig.service.uninstall();
        rig.service.uninstall();
        expect(identical(debugPrint, before), isTrue);
      },
    );

    test(
      'an app that wrapped the hook keeps it in its chain: after uninstall it forwards and records nothing',
      () async {
        final rig = Rig();
        await rig.install();
        final ours = debugPrint;
        final seen = <String?>[];
        debugPrint = (m, {wrapWidth}) {
          seen.add(m);
          ours(m, wrapWidth: wrapWidth);
        };
        final theirs = debugPrint;
        rig.service.uninstall();
        expect(
          identical(debugPrint, theirs),
          isTrue,
          reason: 'not ours to remove',
        );
        final printed = <String>[];
        runZoned(
          () => debugPrint('later'),
          zoneSpecification: ZoneSpecification(
            print: (s, p, z, l) => printed.add(l),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await rig.drain();
        expect(seen, ['later']);
        expect(printed, ['later']);
        expect(rig.sent, isEmpty);
      },
    );

    test(
      'installed again in front of an app that replaced it without chaining: records, and reaches the app\'s callback',
      () async {
        final rig = Rig();
        await rig.install();
        final seen = <String?>[];
        debugPrint = (m, {wrapWidth}) => seen.add(m);
        await rig.install();
        debugPrint('x');
        await rig.drain();
        expect(seen, ['x']);
        expect(rig.texts, ['x']);
      },
    );

    test(
      'installed again in front of an app that WRAPPED the hook: no recursion, recorded once',
      () async {
        final rig = Rig();
        await rig.install();
        final ours = debugPrint;
        final seen = <String?>[];
        debugPrint = (m, {wrapWidth}) {
          seen.add(m);
          ours(m, wrapWidth: wrapWidth);
        };
        await rig.install();
        debugPrint('x');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await rig.drain();
        expect(seen, ['x']);
        expect(rig.texts, ['x']);
      },
    );

    test(
      'a previous callback that throws is the app\'s exception, not swallowed',
      () async {
        debugPrint = (m, {wrapWidth}) => throw StateError('their callback');
        final rig = Rig();
        await rig.install();
        expect(() => debugPrint('x'), throwsStateError);
        await rig.drain();
        // The line was still recorded: it was printed.
        expect(rig.texts, ['x']);
      },
    );

    test(
      'a hot restart: a hook left in debugPrint by the old service records nothing twice',
      () async {
        // The old isolate's statics are gone on a real restart; this is the closest in-process case:
        // two services, the second installed over the first's hook.
        final first = Rig();
        await first.install();
        final second = Rig();
        await second.install();
        debugPrint('x');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await first.drain();
        await second.drain();
        expect(second.texts, ['x']);
        expect(first.texts, isEmpty);
      },
    );
  });

  group('what is never recorded', () {
    test(
      'a FlutterError dump (the diagnostics tree) is not recorded, by the real dumpErrorToConsole',
      () async {
        final rig = Rig();
        await rig.install();
        final out = <String>[];
        final saved = FlutterError.presentError;
        FlutterErrorDetails details() => FlutterErrorDetails(
          exception: StateError('private order 4242'),
          library: 'widgets library',
          context: ErrorDescription('while building Text("card 4111 1111")'),
          informationCollector: () => [
            DiagnosticsNode.message('The widget tree: Text("secret label")'),
          ],
        );
        runZoned(
          () => runZoned(() {
            FlutterError.dumpErrorToConsole(details(), forceReport: true);
          }, zoneSpecification: rig.service.zoneSpecification),
          zoneSpecification: ZoneSpecification(
            print: (s, p, z, l) => out.add(l),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await rig.drain();
        FlutterError.presentError = saved;
        // It was printed (the console is the app's) ...
        expect(out.join('\n'), contains('EXCEPTION CAUGHT'));
        expect(out.join('\n'), contains('secret label'));
        // ... and none of it was recorded.
        expect(rig.sent, isEmpty);
        expect(rig.service.pipeline.stats.droppedErrorDumps, greaterThan(0));
      },
    );

    test(
      'the second error line "Another exception was thrown" is not recorded either',
      () async {
        final rig = Rig();
        await rig.install();
        debugPrint('Another exception was thrown: Bad state: private');
        debugPrint('══╡ EXCEPTION CAUGHT BY X ╞════\nbody');
        debugPrint(
          '════════ Exception caught by widgets library ═══════\nbody',
        );
        debugPrint('an ordinary line');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await rig.drain();
        expect(rig.texts, ['an ordinary line']);
        expect(rig.service.pipeline.stats.droppedErrorDumps, 3);
      },
    );

    test(
      'looksLikeFlutterErrorDump tells the dump headers from ordinary lines',
      () {
        expect(looksLikeFlutterErrorDump('══╡ EXCEPTION CAUGHT'), isTrue);
        expect(looksLikeFlutterErrorDump('\n  ══╡ EXCEPTION CAUGHT'), isTrue);
        expect(
          looksLikeFlutterErrorDump('Another exception was thrown: x'),
          isTrue,
        );
        expect(looksLikeFlutterErrorDump('The ══╡ in the middle'), isFalse);
        expect(looksLikeFlutterErrorDump('an exception was thrown'), isFalse);
        expect(looksLikeFlutterErrorDump(''), isFalse);
      },
    );
  });

  group('forward', () {
    test(
      'records a line from the app\'s own logging with its level and tag',
      () async {
        final rig = Rig();
        await rig.install();
        expect(
          rig.service.forward('from logging', LogLevel.warning, 'net'),
          isTrue,
        );
        await rig.drain();
        expect(rig.sent.single.message, 'from logging');
        expect(rig.sent.single.level, LogLevel.warning.value);
        expect(rig.sent.single.tag, 'net');
      },
    );

    test('is refused while the capture is not installed', () async {
      final rig = Rig();
      expect(rig.service.forward('x', LogLevel.info, null), isFalse);
      await rig.install();
      rig.service.uninstall();
      expect(rig.service.forward('x', LogLevel.info, null), isFalse);
    });

    test('is not recorded from inside a filter', () async {
      final rig = Rig();
      await rig.install();
      runSuppressed(() {
        expect(rig.service.forward('x', LogLevel.info, null), isFalse);
      });
    });
  });

  group('the policy', () {
    test(
      'nothing is sent until the SDK\'s status and options were read',
      () async {
        final rig = Rig()..gate = Completer<void>();
        expect(rig.service.install(), isTrue);
        rig.inCaptureZone(() => print('too early'));
        await rig.drain();
        expect(rig.sent, isEmpty);
        expect(rig.service.pipeline.stats.droppedNotAccepting, 1);
        rig.gate!.complete();
        await rig.service.refreshPolicy();
        rig.inCaptureZone(() => print('now'));
        await rig.drain();
        expect(rig.texts, ['now']);
      },
    );

    test(
      'a status that is not launching or launched stops it at once, before the options are read',
      () async {
        final rig = Rig();
        await rig.install();
        expect(rig.service.policy.accepting, isTrue);
        rig.gate = Completer<void>();
        rig.statuses.add(BugseeStatus.stopping);
        await Future<void>.delayed(Duration.zero);
        expect(rig.service.policy.accepting, isFalse);
        rig.inCaptureZone(() => print('during stop'));
        await rig.drain();
        expect(rig.sent, isEmpty);
      },
    );

    test(
      'launching keeps accepting (both SDKs take a channel line then)',
      () async {
        final rig = Rig();
        await rig.install();
        rig.gate = Completer<void>();
        rig.statuses.add(BugseeStatus.launching);
        await Future<void>.delayed(Duration.zero);
        // Believed only once the read says so; the previous reading is not trusted blindly either.
        expect(rig.service.policy.accepting, isTrue);
      },
    );

    test('a failure to read leaves nothing accepted', () async {
      final rig = Rig();
      await rig.install();
      rig.readThrows = true;
      await rig.service.refreshPolicy();
      expect(rig.service.policy.accepting, isFalse);
    });

    test('a newer read supersedes an older one still in flight', () async {
      final rig = Rig();
      await rig.install();
      final slow = Completer<void>();
      rig.gate = slow;
      rig.policy = const LogPolicy(accepting: true, maxLevel: LogLevel.error);
      final older = rig.service.refreshPolicy();
      rig.gate = null;
      rig.policy = const LogPolicy(accepting: true, maxLevel: LogLevel.debug);
      await rig.service.refreshPolicy();
      slow.complete();
      await older;
      expect(rig.service.policy.maxLevel, LogLevel.debug);
    });

    test('install attaches to native and reads the policy', () async {
      final rig = Rig();
      await rig.install();
      expect(rig.attached, 1);
      expect(rig.reads, greaterThan(0));
    });
  });

  group('install', () {
    test(
      'on a platform with no SDK nothing is installed, and it says so once',
      () {
        final rig = Rig(supported: false);
        final before = debugPrint;
        expect(rig.service.install(), isFalse);
        expect(rig.service.install(), isFalse);
        expect(rig.service.installed, isFalse);
        expect(identical(debugPrint, before), isTrue);
        expect(rig.warnings, hasLength(1));
      },
    );

    test('a filter timeout out of range is an argument error', () {
      final rig = Rig();
      for (final bad in [
        Duration.zero,
        const Duration(seconds: -1),
        const Duration(minutes: 5, milliseconds: 1),
      ]) {
        expect(
          () => rig.service.setFilter((e) => e, bad),
          throwsA(isA<BugseeArgumentException>()),
          reason: '$bad',
        );
      }
      rig.service.setFilter((e) => e, const Duration(minutes: 5));
      rig.service.setFilter(null, const Duration(seconds: 10));
      expect(rig.service.pipeline.filter, isNull);
    });
  });

  test('logLevelForLoggingValue maps package:logging levels by value', () {
    const expected = {
      0: LogLevel.verbose, // ALL
      300: LogLevel.verbose, // FINEST
      400: LogLevel.verbose, // FINER
      500: LogLevel.debug, // FINE
      700: LogLevel.debug, // CONFIG
      800: LogLevel.info, // INFO
      900: LogLevel.warning, // WARNING
      1000: LogLevel.error, // SEVERE
      1200: LogLevel.error, // SHOUT
      2000: LogLevel.error,
      -5: LogLevel.verbose,
      499: LogLevel.verbose,
      799: LogLevel.debug,
      899: LogLevel.info,
      999: LogLevel.warning,
    };
    expected.forEach((value, level) {
      expect(logLevelForLoggingValue(value), level, reason: '$value');
    });
  });
}
