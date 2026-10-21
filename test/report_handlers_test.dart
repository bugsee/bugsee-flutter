// The Dart end of the report handlers (workbook Part 7), over the REAL generated
// channels: a fake native end answers on the pigeon channels with the real codec,
// and pushes deliveries the way native does, so the wire shape is exercised too.
import 'dart:async';
import 'dart:typed_data';

import 'package:bugsee_flutter/src/bridge/bridge.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/errors.dart';
import 'package:bugsee_flutter/src/report/attachments.dart';
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
        // A call with no arguments (resetReportHandlers) sends no payload.
        final args = data == null
            ? const <Object?>[]
            : _codec.decodeMessage(data)! as List<Object?>;
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
    'reportAddAttachment',
    'reportAddAttachmentBytes',
    'reportClearAttachments',
    'reportSetScreenshot',
    'reportRemoveScreenshot',
  ];

  final TestDefaultBinaryMessenger messenger;

  /// Every call, `method(args...)` in order.
  final List<String> calls = [];
  final Set<String> closed = {};
  final Map<String, Object?> summaryOf = {};
  final Map<String, int> severityOf = {};
  final Map<String, List<String>> labelsOf = {};
  final Map<String, Map<String, Object>> attributesOf = {};

  /// What the file operations answer per handle, when it is live (null: applied).
  final Map<String, String> fileFailure = {};
  final Map<String, List<ReportAttachmentMessage>> attachmentsOf = {};
  final Map<String, List<ReportScreenshotMessage>> screenshotsOf = {};
  bool before = false;
  bool after = false;
  int completions = 0;

  /// Native refuses an edit as of now, as when its deadline passed first.
  void closeNow(String handle) => closed.add(handle);

  Object? _handle(String method, List<Object?> args) {
    // Bytes would flood the log: record their length.
    calls.add(
      '$method(${args.map((a) => a is Uint8List ? 'bytes:${a.length}' : a).join(', ')})',
    );
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
          attachments: attachmentsOf[handle] ?? [],
          screenshots: screenshotsOf[handle] ?? [],
        );
      case 'reportAddAttachment':
      case 'reportAddAttachmentBytes':
      case 'reportClearAttachments':
      case 'reportSetScreenshot':
      case 'reportRemoveScreenshot':
        // A file operation answers a code, not a bool: null is "applied".
        if (!live) return 'not-live';
        return fileFailure[handle];
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

    test('an error handler that itself throws does not keep the completion '
        'from running', () async {
      final old = FlutterError.onError;
      FlutterError.onError = (_) => throw StateError('the app handler broke');
      addTearDown(() => FlutterError.onError = old);
      await bridge.setReportHandlers(onBefore: (r) => throw StateError('boom'));
      await native.deliver(handle: 'h1');
      await settle();
      expect(native.completions, 1);
    });

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

  group('attachments and screenshots (Phase 6): path-first, over the real codec', () {
    /// Runs [body] as the onBefore handler of a delivery and waits for it.
    Future<void> inHandler(
      Future<void> Function(ReportProxy r) body, {
      String handle = 'h1',
    }) async {
      await bridge.setReportHandlers(onBefore: body);
      await native.deliver(handle: handle);
      await settle();
    }

    test(
      'a file crosses as its PATH with name, type and move; never bytes',
      () async {
        await inHandler((r) async {
          await r.addAttachment(
            '/data/app/log.txt',
            name: 'log',
            mimeType: 'text/plain',
          );
          await r.addAttachment('/data/app/tmp.db', name: 'db', move: true);
        });
        expect(
          native.calls.where((c) => c.startsWith('reportAddAttachment')),
          [
            'reportAddAttachment(h1, /data/app/log.txt, log, text/plain, false)',
            'reportAddAttachment(h1, /data/app/tmp.db, db, null, true)',
          ],
          reason:
              'copy is the default; move is opt-in; the mime type is optional',
        );
      },
    );

    test('bytes cross as a Uint8List and only up to the cap', () async {
      Object? tooBig;
      await inHandler((r) async {
        await r.addAttachmentBytes(
          Uint8List.fromList([1, 2, 3]),
          name: 'n.bin',
          mimeType: 'application/octet-stream',
        );
        await r.addAttachmentBytes(Uint8List(0), name: 'empty');
        await r.addAttachmentBytes(Uint8List(maxAttachmentBytes), name: 'max');
        try {
          await r.addAttachmentBytes(
            Uint8List(maxAttachmentBytes + 1),
            name: 'over',
          );
        } catch (e) {
          tooBig = e;
        }
      });
      expect(
        native.calls.where((c) => c.startsWith('reportAddAttachmentBytes')),
        [
          'reportAddAttachmentBytes(h1, bytes:3, n.bin, application/octet-stream)',
          'reportAddAttachmentBytes(h1, bytes:0, empty, null)',
          'reportAddAttachmentBytes(h1, bytes:$maxAttachmentBytes, max, null)',
        ],
        reason: 'one byte over the cap never reaches native',
      );
      expect(
        tooBig,
        isA<BugseeArgumentException>().having(
          (e) => e.argument,
          'argument',
          'bytes',
        ),
      );
    });

    test(
      'malformed arguments are refused in Dart, before anything crosses',
      () async {
        final failures = <String>[];
        await inHandler((r) async {
          Future<void> bad(String what, Future<void> Function() call) async {
            try {
              await call();
              failures.add('$what was accepted');
            } on BugseeArgumentException catch (e) {
              if (e.argument.isEmpty) failures.add('$what: no argument named');
            }
          }

          await bad('empty path', () => r.addAttachment('', name: 'n'));
          await bad(
            'relative path',
            () => r.addAttachment('a/b.txt', name: 'n'),
          );
          await bad(
            'file URL',
            () => r.addAttachment('file:///a/b.txt', name: 'n'),
          );
          await bad(
            'content URI',
            () => r.addAttachment('content://x/y', name: 'n'),
          );
          await bad(
            'NUL in path',
            () => r.addAttachment('/a\u0000b', name: 'n'),
          );
          await bad(
            'long path',
            () =>
                r.addAttachment('/${'a' * maxAttachmentPathLength}', name: 'n'),
          );
          await bad('empty name', () => r.addAttachment('/a', name: ''));
          for (final blank in [
            '\u00a0',
            '\u0085',
            '\u3000',
            '\u2003',
            ' \u00a0 ',
            '\t',
          ]) {
            await bad(
              'blank name U+${blank.codeUnitAt(0).toRadixString(16)}',
              () => r.addAttachment('/a', name: blank),
            );
          }
          await bad('blank name', () => r.addAttachment('/a', name: '   '));
          await bad('slash in name', () => r.addAttachment('/a', name: '../x'));
          await bad(
            'backslash in name',
            () => r.addAttachment('/a', name: r'a\b'),
          );
          await bad(
            'newline in name',
            () => r.addAttachment('/a', name: 'a\nb'),
          );
          await bad(
            'long name',
            () => r.addAttachment(
              '/a',
              name: 'n' * (maxAttachmentNameLength + 1),
            ),
          );
          await bad(
            'mime without slash',
            () => r.addAttachment('/a', name: 'n', mimeType: 'text'),
          );
          await bad(
            'mime with parameter',
            () => r.addAttachment(
              '/a',
              name: 'n',
              mimeType: 'text/plain; charset=utf-8',
            ),
          );
          await bad(
            'mime with a space',
            () => r.addAttachment('/a', name: 'n', mimeType: 'text /plain'),
          );
          await bad(
            'empty mime',
            () => r.addAttachment('/a', name: 'n', mimeType: ''),
          );
          await bad('screenshot path', () => r.setScreenshot('x.png'));
          await bad(
            'negative display',
            () => r.setScreenshot('/x.png', displayId: -1),
          );
          await bad(
            'negative display (remove)',
            () => r.removeScreenshot(displayId: -1),
          );
        });
        expect(failures, isEmpty);
        expect(
          native.calls.where(
            (c) => c.startsWith('reportAdd') || c.contains('Screenshot'),
          ),
          isEmpty,
          reason: 'nothing malformed crossed',
        );
      },
    );

    test('well-formed names, types and paths are accepted', () async {
      await inHandler((r) async {
        await r.addAttachment(
          '/a/b c/é.txt',
          name: 'My log (1).txt',
          mimeType: 'application/vnd.api+json',
        );
        await r.addAttachment('/a', name: 'n', mimeType: 'image/svg+xml');
        await r.addAttachment('/a', name: 'n' * maxAttachmentNameLength);
        // Not blank in any of the three languages' shared definition.
        await r.addAttachment('/a', name: '\u200bx');
        await r.addAttachment('/a', name: 'x\u00a0');
        await r.addAttachment('/a', name: '\ufeff');
      });
      expect(
        native.calls.where((c) => c.startsWith('reportAddAttachment(')).length,
        6,
      );
    });

    test(
      'a refusal maps to a typed exception per code and leaves the report live',
      () async {
        final seen = <String, ReportAttachmentFailure>{};
        late ReportProxy kept;
        await inHandler((r) async {
          kept = r;
          for (final entry in ReportWire.failures.entries) {
            native.fileFailure['h1'] = entry.key;
            try {
              await r.addAttachment('/a', name: 'n');
            } on ReportAttachmentException catch (e) {
              seen[entry.key] = e.reason;
            }
          }
          native.fileFailure['h1'] = 'a-code-from-a-newer-native';
          try {
            await r.addAttachment('/a', name: 'n');
          } on ReportAttachmentException catch (e) {
            seen['unknown'] = e.reason;
          }
          native.fileFailure.remove('h1');
          await r.setSummary('still live');
        });
        expect(seen, {
          for (final e in ReportWire.failures.entries) e.key: e.value,
          'unknown': ReportAttachmentFailure.rejected,
        });
        expect(native.summaryOf['h1'], 'still live');
        expect(kept.isLive, isFalse, reason: 'closed by the handler returning');
      },
    );

    test(
      'a handle native reports as not live throws ReportClosedError for every file operation',
      () async {
        final ops = <String, Future<void> Function(ReportProxy)>{
          'addAttachment': (r) => r.addAttachment('/a', name: 'n'),
          'addAttachment (move)': (r) =>
              r.addAttachment('/a', name: 'n', move: true),
          'addAttachmentBytes': (r) =>
              r.addAttachmentBytes(Uint8List(1), name: 'n'),
          'clearAttachments': (r) => r.clearAttachments(),
          'setScreenshot': (r) => r.setScreenshot('/a.png'),
          'removeScreenshot': (r) => r.removeScreenshot(),
        };
        final outcome = <String, Object?>{};
        var n = 0;
        for (final entry in ops.entries) {
          final handle = 'late${n++}';
          await bridge.setReportHandlers(
            onBefore: (r) async {
              // Native completed first (its deadline): the next call is told "not live".
              native.closeNow(handle);
              try {
                await entry.value(r);
                outcome[entry.key] = 'accepted';
              } catch (e) {
                outcome[entry.key] = '${e.runtimeType}, live: ${r.isLive}';
              }
            },
          );
          await native.deliver(handle: handle, reportId: 'r$n');
          await settle();
        }
        expect(outcome, {
          for (final k in ops.keys) k: 'ReportClosedError, live: false',
        });
      },
    );

    test(
      'after the handler returns every file operation fails loudly without reaching native',
      () async {
        late ReportProxy kept;
        await inHandler((r) async => kept = r);
        final before = native.calls.length;
        for (final call in <Future<void> Function()>[
          () => kept.addAttachment('/a', name: 'n', move: true),
          () => kept.addAttachmentBytes(Uint8List(1), name: 'n'),
          () => kept.clearAttachments(),
          () => kept.setScreenshot('/a.png', annotated: true),
          () => kept.removeScreenshot(),
        ]) {
          await expectLater(call(), throwsA(isA<ReportClosedError>()));
        }
        expect(native.calls.length, before);
      },
    );

    test(
      'screenshots cross as a path with the display id and the annotated flag',
      () async {
        await inHandler((r) async {
          await r.setScreenshot('/a/shot.png');
          await r.setScreenshot('/a/edited.png', displayId: 2, annotated: true);
          await r.removeScreenshot(displayId: 2);
          await r.clearAttachments();
        });
        expect(
          native.calls.where(
            (c) => c.contains('Screenshot') || c.contains('Attachments'),
          ),
          [
            'reportSetScreenshot(h1, /a/shot.png, 0, false)',
            'reportSetScreenshot(h1, /a/edited.png, 2, true)',
            'reportRemoveScreenshot(h1, 2)',
            'reportClearAttachments(h1)',
          ],
        );
      },
    );

    test('read lists attachments and screenshots as values', () async {
      native.attachmentsOf['h1'] = [
        ReportAttachmentMessage(
          name: 'log',
          mimeType: 'text/plain',
          fileName: 'app.log',
        ),
        ReportAttachmentMessage(name: 'raw'),
      ];
      native.screenshotsOf['h1'] = [
        ReportScreenshotMessage(displayId: 0, annotated: true),
        ReportScreenshotMessage(displayId: 3, annotated: false),
      ];
      ReportSnapshot? snap;
      await inHandler((r) async => snap = await r.read());
      expect(snap!.attachments.map((a) => (a.name, a.mimeType, a.fileName)), [
        ('log', 'text/plain', 'app.log'),
        ('raw', null, null),
      ]);
      expect(snap!.screenshots.map((s) => (s.displayId, s.annotated)), [
        (0, true),
        (3, false),
      ]);
      expect(
        () => snap!.attachments.add(const ReportAttachment()),
        throwsUnsupportedError,
      );
      expect(
        () => snap!.screenshots.add(
          const ReportScreenshot(displayId: 1, annotated: false),
        ),
        throwsUnsupportedError,
      );
    });
  });
}
