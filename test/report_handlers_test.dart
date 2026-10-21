// The Dart end of the report handlers (workbook Part 7), over the REAL generated
// channels: a fake native end answers on the pigeon channels with the real codec,
// and pushes deliveries the way native does, so the wire shape is exercised too.
import 'dart:async';

import 'package:bugsee_flutter/src/bridge/bridge.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/report/report_enums.dart';
import 'package:bugsee_flutter/src/report/report_proxy.dart';
import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

const _host = 'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeHostApi';
const _dart = 'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeFlutterApi';
final _codec = BugseeBridgeHostApi.pigeonChannelCodec;

/// Native's side of the report channels: a live report per handle, the calls it
/// received in order, and the rule that a completed handle refuses every edit.
class FakeNative {
  FakeNative(this.messenger) {
    for (final method in _methods) {
      messenger.setMockMessageHandler('$_host.$method', (data) async {
        final args = _codec.decodeMessage(data)! as List<Object?>;
        try {
          return _codec.encodeMessage(<Object?>[_handle(method, args)]);
        } on PlatformException catch (e) {
          return _codec.encodeMessage(<Object?>[e.code, e.message, e.details]);
        }
      });
    }
  }

  static const _methods = [
    'resetReportHandlers',
    'setReportHandlerPhases',
    'completeReportHandler',
    'reportRead',
    'reportSetSummary',
    'reportSetDescription',
    'reportSetEmail',
    'reportSetSeverity',
    'reportReplaceLabels',
    'reportAddLabels',
    'reportClearLabels',
    'reportSetAttribute',
    'reportRemoveAttribute',
    'reportClearAttributes',
  ];

  final TestDefaultBinaryMessenger messenger;

  /// Every call, `method(args...)` in order.
  final List<String> calls = [];
  final Set<String> closed = {};
  final Map<String, Object?> summaryOf = {};
  final Map<String, int> severityOf = {};
  final Map<String, List<String>> labelsOf = {};
  final Map<String, Map<String, Object>> attributesOf = {};
  bool before = false;
  bool after = false;
  int completions = 0;

  /// Native refuses an edit as of now, as when its deadline passed first.
  void closeNow(String handle) => closed.add(handle);

  Object? _handle(String method, List<Object?> args) {
    calls.add('$method(${args.join(', ')})');
    if (method == 'resetReportHandlers') {
      before = after = false;
      return null;
    }
    if (method == 'setReportHandlerPhases') {
      before = args[0]! as bool;
      after = args[1]! as bool;
      return null;
    }
    final handle = args[0]! as String;
    if (method == 'completeReportHandler') {
      completions++;
      closed.add(handle);
      return null;
    }
    final live = !closed.contains(handle);
    switch (method) {
      case 'reportRead':
        if (!live) return null;
        return ReportSnapshotMessage(
          id: 'r-$handle',
          type: 'crash',
          summary: summaryOf[handle] as String?,
          severity: severityOf[handle],
          labels: labelsOf[handle] ?? [],
          attributes: attributesOf[handle] ?? {},
        );
      case 'reportSetSeverity':
        final v = args[1]! as int;
        if (v < 1 || v > 5) {
          throw PlatformException(code: 'invalid-argument');
        }
        if (live) severityOf[handle] = v;
      case 'reportSetSummary':
        if (live) summaryOf[handle] = args[1];
      case 'reportReplaceLabels':
        if (live) labelsOf[handle] = List<String>.from(args[1]! as List);
      case 'reportSetAttribute':
        if (live) {
          (attributesOf[handle] ??= {})[args[1]! as String] = args[2]!;
        }
      default:
        break;
    }
    return live;
  }

  /// Native pushes one delivery to Dart, as `BugseeFlutterPlugin` does.
  Future<void> deliver({
    required String handle,
    String? deliveryId,
    bool after = false,
    String reportId = 'r1',
    String type = 'bug',
    int deadlineMs = 25000,
  }) async {
    await messenger.handlePlatformMessage(
      '$_dart.onReportHandlerRequest',
      _codec.encodeMessage(<Object?>[
        ReportHandlerRequestMessage(
          handle: handle,
          deliveryId: deliveryId ?? '${after ? 'after' : 'before'}:$reportId',
          after: after,
          reportId: reportId,
          type: type,
          deadlineMs: deadlineMs,
        ),
      ]),
      (_) {},
    );
  }

  void dispose() {
    for (final method in _methods) {
      messenger.setMockMessageHandler('$_host.$method', null);
    }
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late FakeNative native;
  late BugseeBridge bridge;
  setUp(() {
    native = FakeNative(messenger);
    bridge = BugseeBridge();
  });
  tearDown(() {
    native.dispose();
    BugseeBridgeFlutterApi.setUp(null);
  });

  group('registration', () {
    test('tells native which phases have a Dart handler', () async {
      await bridge.setReportHandlers(onBefore: (_) {});
      expect([native.before, native.after], [true, false]);
      await bridge.setReportHandlers(onAfter: (_) {});
      expect([native.before, native.after], [false, true]);
      await bridge.setReportHandlers();
      expect([native.before, native.after], [false, false]);
    });

    test(
      'a request for a phase with no handler is completed at once',
      () async {
        await bridge.setReportHandlers(onBefore: (_) {});
        await native.deliver(handle: 'h1', after: true);
        await settle();
        expect(native.completions, 1);
        expect(native.closed, {'h1'});
        expect(native.calls.where((c) => c.startsWith('reportSet')), isEmpty);
      },
    );

    test(
      'with no handler at all every request is completed, never run',
      () async {
        await bridge.setReportHandlers();
        await native.deliver(handle: 'h1');
        await native.deliver(handle: 'h2', after: true);
        await settle();
        expect(native.completions, 2);
      },
    );
  });

  group('delivery and the proxy', () {
    test('the handler gets a proxy of the report, not a copy', () async {
      ReportProxy? seen;
      await bridge.setReportHandlers(onBefore: (r) => seen = r);
      await native.deliver(handle: 'h1', reportId: 'abc', type: 'crash');
      await settle();
      expect(seen, isNotNull);
      expect(seen!.id, 'abc');
      expect(seen!.type, ReportType.crash);
      expect(seen!.typeName, 'crash');
      expect(seen!.deliveryId, 'before:abc');
    });

    test('a type this version does not know is kept as text', () async {
      ReportProxy? seen;
      await bridge.setReportHandlers(onBefore: (r) => seen = r);
      await native.deliver(handle: 'h1', type: 'anr');
      await settle();
      expect(seen!.type, isNull);
      expect(seen!.typeName, 'anr');
    });

    test(
      'edits cross as operations on the handle, severity by value',
      () async {
        await bridge.setReportHandlers(
          onBefore: (r) async {
            await r.setSummary('s');
            await r.setSeverity(ReportSeverity.critical);
            await r.replaceLabels(['a', 'b']);
            await r.setAttribute('k', 3);
            await r.setAttribute('b', true);
            await r.setAttribute('d', 1.5);
            await r.setAttribute('t', 'x');
          },
        );
        await native.deliver(handle: 'h1');
        await settle();
        expect(native.summaryOf['h1'], 's');
        // Critical is index 3 and value 4: the value crosses.
        expect(native.severityOf['h1'], 4);
        expect(native.labelsOf['h1'], ['a', 'b']);
        expect(native.attributesOf['h1'], {
          'k': 3,
          'b': true,
          'd': 1.5,
          't': 'x',
        });
        expect(
          native.calls.where((c) => c.contains('Labels')),
          ['reportReplaceLabels(h1, [a, b])'],
          reason: 'labels are replaced in ONE operation, never clear then add',
        );
      },
    );

    test('read returns the live report', () async {
      ReportSnapshot? snap;
      native.severityOf['h1'] = 5;
      native.labelsOf['h1'] = ['l'];
      native.attributesOf['h1'] = {'a': 'b'};
      await bridge.setReportHandlers(
        onBefore: (r) async => snap = await r.read(),
      );
      await native.deliver(handle: 'h1');
      await settle();
      expect(snap!.severity, ReportSeverity.blocker);
      expect(snap!.labels, ['l']);
      expect(snap!.attributes, {'a': 'b'});
      expect(snap!.type, ReportType.crash);
      expect(() => snap!.labels.add('x'), throwsUnsupportedError);
    });

    test(
      'an iOS severity of "never set" reads as null, not as a level',
      () async {
        ReportSnapshot? snap;
        await bridge.setReportHandlers(
          onBefore: (r) async => snap = await r.read(),
        );
        await native.deliver(handle: 'h1');
        await settle();
        expect(snap!.severity, isNull);
        expect(ReportSeverity.fromValue(0), isNull);
        expect(ReportSeverity.fromValue(6), isNull);
      },
    );

    test(
      'an attribute value both SDKs cannot carry is refused before it crosses',
      () async {
        Object? failure;
        await bridge.setReportHandlers(
          onBefore: (r) async {
            for (final bad in <Object>[
              double.nan,
              double.infinity,
              <String>['x'],
              {'a': 1},
              Object(),
            ]) {
              expect(() => r.setAttribute('k', bad), throwsArgumentError);
            }
            expect(() => r.setAttribute('', 'v'), throwsArgumentError);
            failure = 'ran';
          },
        );
        await native.deliver(handle: 'h1');
        await settle();
        expect(failure, 'ran');
        expect(
          native.calls.where((c) => c.startsWith('reportSetAttribute')),
          isEmpty,
        );
      },
    );

    test(
      'native refusing an argument is an error, and the report stays live',
      () async {
        Object? error;
        bool? live;
        await bridge.setReportHandlers(
          onBefore: (r) async {
            try {
              // Not reachable through the typed API; this is native's own guard.
              await BugseeBridgeHostApi().reportSetSeverity('h1', 9);
            } on PlatformException catch (e) {
              error = e.code;
            }
            live = r.isLive;
          },
        );
        await native.deliver(handle: 'h1');
        await settle();
        expect(error, 'invalid-argument');
        expect(live, isTrue);
      },
    );
  });

  group('the report is live only until the completion runs (7.3.4)', () {
    test('the completion is sent once, when the handler returns', () async {
      final gate = Completer<void>();
      await bridge.setReportHandlers(onBefore: (r) => gate.future);
      await native.deliver(handle: 'h1');
      await settle();
      expect(native.completions, 0);
      gate.complete();
      await settle();
      expect(native.completions, 1);
    });

    test('a late mutation throws, loudly, and nothing is sent', () async {
      late ReportProxy kept;
      await bridge.setReportHandlers(onBefore: (r) async => kept = r);
      await native.deliver(handle: 'h1');
      await settle();
      expect(kept.isLive, isFalse);
      final callsBefore = native.calls.length;
      await expectLater(
        kept.setSummary('late'),
        throwsA(isA<ReportClosedError>()),
      );
      await expectLater(
        kept.setSeverity(ReportSeverity.high),
        throwsA(isA<StateError>()),
      );
      await expectLater(kept.replaceLabels(['x']), throwsStateError);
      await expectLater(kept.setAttribute('a', 1), throwsStateError);
      await expectLater(kept.read(), throwsStateError);
      expect(
        native.calls.length,
        callsBefore,
        reason: 'no late edit reached native',
      );
      expect(native.summaryOf['h1'], isNull);
    });

    test(
      'an edit an unawaited continuation makes after the return fails loudly',
      () async {
        final errors = <Object>[];
        await runZonedGuarded(() async {
          await bridge.setReportHandlers(
            onBefore: (r) {
              // Forgot to await: runs after the handler has returned.
              Future<void>.delayed(
                const Duration(milliseconds: 60),
                () => r.setSummary('late'),
              );
            },
          );
          await native.deliver(handle: 'h1');
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }, (e, s) => errors.add(e));
        expect(errors.single, isA<ReportClosedError>());
        expect(native.summaryOf['h1'], isNull);
      },
    );

    test(
      'native completing first (its deadline) turns the next edit into an error',
      () async {
        final gate = Completer<void>();
        Object? caught;
        await bridge.setReportHandlers(
          onBefore: (r) async {
            await r.setSummary('early');
            native.closeNow('h1');
            try {
              await r.setSummary('late');
            } catch (e) {
              caught = e;
            }
            expect(r.isLive, isFalse);
            await gate.future;
          },
        );
        await native.deliver(handle: 'h1');
        await settle();
        expect(caught, isA<ReportClosedError>());
        expect(native.summaryOf['h1'], 'early');
        gate.complete();
        await settle();
      },
    );

    test('Dart closes the proxy itself when the deadline passes', () async {
      final gate = Completer<void>();
      Object? caught;
      int? callsWhenClosed;
      await bridge.setReportHandlers(
        onBefore: (r) async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          callsWhenClosed = native.calls.length;
          try {
            await r.setSummary('late');
          } catch (e) {
            caught = e;
          }
          await gate.future;
        },
      );
      await native.deliver(handle: 'h1', deadlineMs: 30);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(caught, isA<ReportClosedError>());
      expect(
        native.calls.length,
        callsWhenClosed,
        reason: 'refused without a round trip',
      );
      gate.complete();
      await settle();
    });

    test(
      'a handler that throws is reported, and the report still proceeds',
      () async {
        final reported = <FlutterErrorDetails>[];
        final old = FlutterError.onError;
        FlutterError.onError = reported.add;
        addTearDown(() => FlutterError.onError = old);
        await bridge.setReportHandlers(
          onBefore: (r) => throw StateError('boom'),
        );
        await native.deliver(handle: 'h1');
        await settle();
        expect(reported.single.exception, isA<StateError>());
        expect(native.completions, 1);
      },
    );

    test('an asynchronous failure in the handler also completes', () async {
      final old = FlutterError.onError;
      FlutterError.onError = (_) {};
      addTearDown(() => FlutterError.onError = old);
      await bridge.setReportHandlers(
        onAfter: (r) async {
          await Future<void>.delayed(Duration.zero);
          throw ArgumentError('late failure');
        },
      );
      await native.deliver(handle: 'h1', after: true);
      await settle();
      expect(native.completions, 1);
    });
  });

  group('the budget', () {
    test(
      'a handler that overruns it is reported even if it edits nothing more',
      () async {
        final reported = <FlutterErrorDetails>[];
        final old = FlutterError.onError;
        FlutterError.onError = reported.add;
        addTearDown(() => FlutterError.onError = old);
        await bridge.setReportHandlers(
          onBefore: (r) async {
            await r.setSummary('early');
            await Future<void>.delayed(const Duration(milliseconds: 120));
            // No further edit: nothing else would say that the handler ran long.
          },
        );
        await native.deliver(handle: 'h1', deadlineMs: 40);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(reported, hasLength(1));
        expect(
          reported.single.exception.toString(),
          contains('ran past its 40 ms budget'),
        );
        expect(native.completions, 1);
      },
    );

    test('a handler inside the budget is not reported', () async {
      final reported = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = old);
      await bridge.setReportHandlers(onBefore: (r) => r.setSummary('x'));
      await native.deliver(handle: 'h1', deadlineMs: 5000);
      await settle();
      expect(reported, isEmpty);
    });
  });

  group('delivery is not once (7.2)', () {
    test(
      'onAfter delivered twice for one report runs the handler once',
      () async {
        var runs = 0;
        await bridge.setReportHandlers(onAfter: (r) async => runs++);
        await native.deliver(handle: 'h1', after: true, reportId: 'r1');
        await settle();
        await native.deliver(handle: 'h2', after: true, reportId: 'r1');
        await settle();
        expect(runs, 1);
        expect(native.completions, 2, reason: 'the SDK is never left waiting');
      },
    );

    test(
      'a concurrent re-delivery is completed, not run in parallel',
      () async {
        var runs = 0;
        final gate = Completer<void>();
        await bridge.setReportHandlers(
          onAfter: (r) async {
            runs++;
            await gate.future;
          },
        );
        await native.deliver(handle: 'h1', after: true);
        await native.deliver(handle: 'h2', after: true);
        await settle();
        expect(runs, 1);
        expect(
          native.completions,
          1,
          reason: 'the duplicate completed at once',
        );
        gate.complete();
        await settle();
        expect(native.completions, 2);
      },
    );

    test('other reports and the other phase are not duplicates', () async {
      final ran = <String>[];
      await bridge.setReportHandlers(
        onBefore: (r) => ran.add('b:${r.id}'),
        onAfter: (r) => ran.add('a:${r.id}'),
      );
      await native.deliver(handle: 'h1', reportId: 'r1');
      await native.deliver(handle: 'h2', reportId: 'r1', after: true);
      await native.deliver(handle: 'h3', reportId: 'r2');
      await native.deliver(handle: 'h4', reportId: 'r2', after: true);
      await settle();
      expect(ran, ['b:r1', 'a:r1', 'b:r2', 'a:r2']);
    });

    test(
      'a re-delivery is recognised by the stable id, not the handle',
      () async {
        var runs = 0;
        await bridge.setReportHandlers(onAfter: (r) async => runs++);
        for (var i = 0; i < 3; i++) {
          await native.deliver(
            handle: 'h$i',
            after: true,
            deliveryId: 'after:same',
          );
          await settle();
        }
        expect(runs, 1);
      },
    );

    test('only the most recent ids are remembered', () async {
      var runs = 0;
      await bridge.setReportHandlers(onAfter: (r) async => runs++);
      const n = BugseeBridge.deliveredCapacity;
      for (var i = 0; i < n + 1; i++) {
        await native.deliver(handle: 'h$i', after: true, reportId: 'r$i');
      }
      await settle();
      expect(runs, n + 1);
      // The newest is still remembered; the oldest has been forgotten.
      await native.deliver(handle: 'x1', after: true, reportId: 'r$n');
      await native.deliver(handle: 'x2', after: true, reportId: 'r0');
      await settle();
      expect(runs, n + 2);
    });
  });
}
