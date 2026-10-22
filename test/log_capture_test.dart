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
  Rig({this.supported = true, LogPolicy? initial, bool echoRisk = false}) {
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
      echoRisk: () => echoRisk,
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
  late FlutterExceptionHandler originalPresentError;
  late FlutterExceptionHandler? originalOnError;

  setUp(() {
    originalDebugPrint = debugPrint;
    originalPresentError = FlutterError.presentError;
    originalOnError = FlutterError.onError;
  });
  tearDown(() {
    debugPrint = originalDebugPrint;
    FlutterError.presentError = originalPresentError;
    FlutterError.onError = originalOnError;
  });

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

  group('a repeated install', () {
    test('drops nothing: the policy it had stays in force', () async {
      final rig = Rig();
      await rig.install();
      final ours = debugPrint;
      debugPrint = (m, {wrapWidth}) => ours(m, wrapWidth: wrapWidth);
      // No `await` for the policy read: a repeat install must not make the next line wait for one.
      expect(rig.service.install(), isTrue);
      debugPrint('right after the second install');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await rig.drain();
      expect(rig.texts, ['right after the second install']);
      expect(rig.service.pipeline.stats.droppedNotAccepting, 0);
    });

    test('does not subscribe or attach twice', () async {
      final rig = Rig();
      await rig.install();
      rig.service.install();
      rig.service.install();
      expect(rig.attached, 1);
    });
  });

  group('FlutterError presentation', () {
    FlutterErrorDetails details() => FlutterErrorDetails(
      exception: StateError('user email bob@example.com'),
      library: 'app',
      context: ErrorDescription('while building the profile'),
      informationCollector: () => [
        DiagnosticsNode.message('token=SECRET in the widget tree'),
      ],
    );

    /// What an app's logger package does: its own `debugPrint`, not chained, that splits lines.
    void splittingDebugPrint(String? m, {int? wrapWidth}) {
      for (final l in (m ?? 'null').split('\n')) {
        print(l);
      }
    }

    test(
      'the probe: a non-chaining, line-splitting debugPrint set after the install cannot leak the dump',
      () async {
        final rig = Rig();
        FlutterError.presentError = (d) =>
            FlutterError.dumpErrorToConsole(d, forceReport: true);
        await rig.install();
        debugPrint = splittingDebugPrint;
        final out = <String>[];
        rig.inCaptureZone(() {
          FlutterError.presentError(details());
        }, out: out);
        await rig.drain();
        // It was printed ...
        expect(out.join('\n'), contains('bob@example.com'));
        expect(out.join('\n'), contains('token=SECRET'));
        // ... and not one piece of it was recorded.
        expect(rig.sent, isEmpty);
      },
    );

    test(
      'the same through the framework\'s default onError (dumpErrorToConsole itself)',
      () async {
        final rig = Rig();
        FlutterError.onError = FlutterError.dumpErrorToConsole;
        await rig.install();
        debugPrint = splittingDebugPrint;
        final out = <String>[];
        rig.inCaptureZone(() {
          FlutterError.onError!(details());
        }, out: out);
        await rig.drain();
        expect(out.join('\n'), contains('bob@example.com'));
        expect(rig.sent, isEmpty);
      },
    );

    test(
      'an app\'s own presentError is chained, called with the details, and restored',
      () async {
        final seen = <FlutterErrorDetails>[];
        void apps(FlutterErrorDetails d) => seen.add(d);
        FlutterError.presentError = apps;
        final rig = Rig();
        await rig.install();
        expect(identical(FlutterError.presentError, apps), isFalse);
        final d = details();
        FlutterError.presentError(d);
        expect(seen, [d]);
        rig.service.uninstall();
        expect(identical(FlutterError.presentError, apps), isTrue);
      },
    );

    test('an app\'s own onError is never replaced', () async {
      void apps(FlutterErrorDetails d) {}
      FlutterError.onError = apps;
      final rig = Rig();
      await rig.install();
      expect(identical(FlutterError.onError, apps), isTrue);
    });

    test('the default onError is wrapped and put back', () async {
      FlutterError.onError = FlutterError.dumpErrorToConsole;
      final rig = Rig();
      await rig.install();
      expect(
        identical(FlutterError.onError, FlutterError.dumpErrorToConsole),
        isFalse,
      );
      rig.service.uninstall();
      expect(
        identical(FlutterError.onError, FlutterError.dumpErrorToConsole),
        isTrue,
      );
    });

    test(
      'install twice wraps once; uninstall leaves a handler the app wrapped since',
      () async {
        final rig = Rig();
        await rig.install();
        final ours = FlutterError.presentError;
        rig.service.install();
        expect(identical(FlutterError.presentError, ours), isTrue);
        void wrapped(FlutterErrorDetails d) => ours(d);
        FlutterError.presentError = wrapped;
        rig.service.uninstall();
        expect(identical(FlutterError.presentError, wrapped), isTrue);
      },
    );

    test(
      'after an uninstall the chained handler records nothing and still forwards',
      () async {
        final seen = <FlutterErrorDetails>[];
        FlutterError.presentError = (d) => seen.add(d);
        final rig = Rig();
        await rig.install();
        final hook = FlutterError.presentError;
        rig.service.uninstall();
        hook(details());
        expect(seen, hasLength(1));
      },
    );
  });

  group('a throttled debugPrint whose timer predates the install', () {
    test('is recorded once, not again as print', () async {
      final rig = Rig();
      // Before the install, in a zone that already carries the hook: a throttled debugPrint leaves
      // its timer pending in this zone (a message over the throttle's budget queues the next ones).
      final out = <String>[];
      // (the test binding makes `debugPrint` synchronous; an app runs the throttled one)
      debugPrint = debugPrintThrottled;
      rig.inCaptureZone(() {
        debugPrint('first ' * 3000, wrapWidth: 100);
      }, out: out);
      await rig.install();
      debugPrint('after install');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await rig.drain();
      expect(out, contains('after install'));
      expect(rig.texts.where((t) => t == 'after install'), hasLength(1));
      // (the tail of the message printed BEFORE the install comes out of the same timer, after it:
      // that one was never recorded, so it is the app's output the hook now sees, as print)
      expect(
        rig.sent.where(
          (m) => m.tag == 'print' && m.message.contains('after install'),
        ),
        isEmpty,
      );
    });

    test('a print that merely looks alike, long after, is recorded', () async {
      final rig = Rig();
      await rig.install();
      debugPrint('some words');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      rig.inCaptureZone(() => print('unrelated'));
      await rig.drain();
      expect(rig.texts, ['some words', 'unrelated']);
    });
  });

  group('the Android echo warning', () {
    test(
      'is printed once when a filter is set while the capture accepts',
      () async {
        final rig = Rig(echoRisk: true);
        await rig.install();
        rig.service.setFilter((e) => e, const Duration(seconds: 1));
        rig.service.setFilter((e) => e, const Duration(seconds: 1));
        final echo = rig.warnings.where((w) => w.contains('logcat'));
        expect(echo, hasLength(1));
        expect(echo.single, contains('LogCat'));
      },
    );

    test(
      'also when the filter was set first and the policy read comes later',
      () async {
        final rig = Rig(echoRisk: true);
        rig.service.setFilter((e) => e, const Duration(seconds: 1));
        expect(rig.warnings.where((w) => w.contains('logcat')), isEmpty);
        await rig.install();
        expect(rig.warnings.where((w) => w.contains('logcat')), hasLength(1));
      },
    );

    test('is not printed off Android', () async {
      final rig = Rig();
      await rig.install();
      rig.service.setFilter((e) => e, const Duration(seconds: 1));
      expect(rig.warnings.where((w) => w.contains('logcat')), isEmpty);
    });

    test(
      'is not printed without a filter, or while capture.logs is off',
      () async {
        final rig = Rig(echoRisk: true);
        await rig.install();
        expect(rig.warnings.where((w) => w.contains('logcat')), isEmpty);
        final off = Rig(echoRisk: true, initial: LogPolicy.off);
        off.policy = LogPolicy.off;
        await off.install();
        off.service.setFilter((e) => e, const Duration(seconds: 1));
        expect(off.warnings.where((w) => w.contains('logcat')), isEmpty);
      },
    );

    test('removing the filter prints nothing', () async {
      final rig = Rig(echoRisk: true);
      await rig.install();
      rig.service.setFilter(null, const Duration(seconds: 1));
      expect(rig.warnings.where((w) => w.contains('logcat')), isEmpty);
    });
  });

  group('flushBeforeReport', () {
    test('hands over what was printed a moment ago', () async {
      final rig = Rig();
      await rig.install();
      rig.inCaptureZone(() => print('just before'));
      expect(rig.sent, isEmpty);
      await rig.service.flushBeforeReport();
      expect(rig.texts, ['just before']);
    });

    test('is a no-op when not installed or not accepting', () async {
      final rig = Rig();
      await rig.service.flushBeforeReport();
      final off = Rig(initial: LogPolicy.off);
      off.policy = LogPolicy.off;
      await off.install();
      await off.service.flushBeforeReport();
      expect(off.sent, isEmpty);
    });

    test(
      'never waits longer than its limit, however slow the filter is',
      () async {
        final rig = Rig();
        await rig.install();
        rig.service.setFilter(
          (e) => Completer<BugseeLogEvent?>().future,
          const Duration(seconds: 30),
        );
        rig.inCaptureZone(() => print('stuck behind the filter'));
        final watch = Stopwatch()..start();
        await rig.service.flushBeforeReport();
        expect(watch.elapsedMilliseconds, lessThan(1500));
        expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(150));
      },
    );
  });

  group('flushBeforeReport after an uninstall', () {
    test('does not wait for lines the capture no longer takes', () async {
      final rig = Rig();
      await rig.install();
      rig.service.setFilter(
        (e) => Completer<BugseeLogEvent?>().future,
        const Duration(seconds: 30),
      );
      rig.inCaptureZone(() => print('queued, then uninstalled'));
      rig.service.uninstall();
      final watch = Stopwatch()..start();
      await rig.service.flushBeforeReport();
      expect(watch.elapsedMilliseconds, lessThan(100));
    });
  });

  group('the echo match is narrow', () {
    test(
      'a short print that is a substring of a recent debugPrint is recorded',
      () async {
        final rig = Rig();
        await rig.install();
        debugPrint('Loaded 12 items from the cache');
        rig.inCaptureZone(() {
          print('12');
          print('items');
          print('}');
        });
        await rig.drain();
        expect(rig.texts, [
          'Loaded 12 items from the cache',
          '12',
          'items',
          '}',
        ]);
        expect(rig.service.pipeline.stats.droppedEchoes, 0);
      },
    );

    test(
      'a piece is used up: the same text printed again is a new line',
      () async {
        final rig = Rig();
        await rig.install();
        debugPrint('the quick brown fox jumps');
        rig.inCaptureZone(() {
          print('the quick brown fox jumps'); // the throttle's output of it
          print('the quick brown fox jumps'); // the app printing it again
        });
        await rig.drain();
        expect(rig.texts, [
          'the quick brown fox jumps',
          'the quick brown fox jumps',
        ]);
        expect(rig.sent.map((m) => m.tag), ['debugPrint', 'print']);
        expect(rig.service.pipeline.stats.droppedEchoes, 1);
      },
    );

    test('wrapped pieces of a long message are each recognised once', () async {
      final rig = Rig();
      await rig.install();
      debugPrint('alpha bravo charlie delta echo foxtrot golf hotel india');
      rig.inCaptureZone(() {
        print('alpha bravo charlie delta');
        print('  echo foxtrot golf hotel india');
      });
      await rig.drain();
      expect(rig.sent.map((m) => m.tag), ['debugPrint']);
      expect(rig.service.pipeline.stats.droppedEchoes, 2);
    });

    test('a piece must sit at word boundaries', () async {
      final rig = Rig();
      await rig.install();
      debugPrint('internationalization matters');
      rig.inCaptureZone(() => print('ternationaliza'));
      await rig.drain();
      expect(rig.texts, ['internationalization matters', 'ternationaliza']);
    });

    test('a whole short line of the message is an echo', () async {
      final rig = Rig();
      await rig.install();
      debugPrint('ok');
      rig.inCaptureZone(() => print('ok'));
      await rig.drain();
      expect(rig.texts, ['ok']);
    });

    test('the remembered text is capped like a recorded line', () async {
      final rig = Rig();
      await rig.install();
      debugPrint('x' * 100000);
      rig.inCaptureZone(() => print('after the megabyte'));
      await rig.drain();
      expect(rig.texts.last, 'after the megabyte');
      expect(rig.service.rememberedEchoChars, lessThan(4100));
    });
  });

  group('the echo match needs a boundary on both sides', () {
    test('a suffix of a word is not a piece', () async {
      final rig = Rig();
      await rig.install();
      debugPrint('internationalization matters');
      rig.inCaptureZone(() => print('nternationalization'));
      await rig.drain();
      expect(rig.texts, [
        'internationalization matters',
        'nternationalization',
      ]);
    });

    test('a prefix of a word is not a piece', () async {
      final rig = Rig();
      await rig.install();
      debugPrint('internationalization matters');
      rig.inCaptureZone(() => print('internationaliza'));
      await rig.drain();
      expect(rig.texts, ['internationalization matters', 'internationaliza']);
    });
  });

  group('the echo window', () {
    test(
      'a line that matches an old debugPrint after the window is recorded',
      () async {
        final rig = Rig();
        await rig.install();
        debugPrint('abc def');
        await Future<void>.delayed(const Duration(milliseconds: 3200));
        rig.inCaptureZone(() => print('abc def'));
        await rig.drain();
        expect(rig.texts, ['abc def', 'abc def']);
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
