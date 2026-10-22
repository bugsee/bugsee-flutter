// The facade methods other than launch/stop/status, against a fake native side: what is
// validated in Dart before anything crosses, what crosses and how it is encoded, and how every
// native failure maps to a BugseeException subclass.
import 'dart:async';
import 'dart:io';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/bugsee.dart' show debugSetBugseeRuntime;
import 'package:bugsee_flutter/src/bugsee_runtime.dart';
import 'package:bugsee_flutter/src/errors.dart';
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/facade_fake.dart';

class _MissingPluginFake extends FacadeFake {
  @override
  Future<void> setAttribute(String name, Object value) async =>
      throw MissingPluginException('no implementation');
}

void _deliver(BugseeRuntime runtime, List<String> seen) =>
    runtime.bridge.onReportHandlerRequest(
      ReportHandlerRequestMessage(
        handle: 'h${seen.length}',
        deliveryId: 'after:r${seen.length}',
        after: true,
        reportId: 'r',
        type: 'bug',
        deadlineMs: 5000,
      ),
    );

class _AttachFails extends FacadeFake {
  @override
  Future<void> attachLifecycle() async =>
      throw PlatformException(code: 'channel-error');
}

/// Fails the test unless [action] throws exactly an [BugseeArgumentException] for [argument], and
/// nothing reached native.
Future<void> expectRefusedInDart(
  FacadeFake native,
  Future<Object?> Function() action, {
  String? argument,
  Matcher? message,
}) async {
  await expectLater(
    action(),
    throwsA(
      isA<BugseeArgumentException>()
          .having((e) => e.argument, 'argument', argument ?? anything)
          .having((e) => e.message, 'message', message ?? isNotEmpty),
    ),
  );
  expect(native.calls, isEmpty, reason: 'nothing may reach native');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FacadeFake native;
  late List<String> warnings;
  late BugseeRuntime runtime;
  OptionPlatform? platform;

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
  });

  group('attributes', () {
    test('every accepted type crosses as itself', () async {
      await Bugsee.setAttribute('s', 'text');
      await Bugsee.setAttribute('b', true);
      await Bugsee.setAttribute('i', 7);
      await Bugsee.setAttribute('d', 0.5);
      expect(native.calls, [
        'setAttribute(s, text)',
        'setAttribute(b, true)',
        'setAttribute(i, 7)',
        'setAttribute(d, 0.5)',
      ]);
      expect(native.last['setAttribute']![1], isA<double>());
    });

    test(
      'a string of exactly 1024 UTF-16 units is accepted, 1025 is not',
      () async {
        await Bugsee.setAttribute('k', 'x' * 1024);
        native.calls.clear();
        await expectLater(
          Bugsee.setAttribute('k', 'x' * 1025),
          throwsA(
            isA<BugseeAttributeException>()
                .having(
                  (e) => e.reason,
                  'reason',
                  AttributeFailure.invalidValue,
                )
                .having((e) => e.argument, 'argument', 'value'),
          ),
        );
        expect(native.calls, isEmpty);
      },
    );

    test(
      'an astral character counts as two units, like the SDKs count',
      () async {
        // 512 emoji are 1024 units; one more is over.
        await Bugsee.setAttribute('k', '😀' * 512);
        native.calls.clear();
        await expectLater(
          Bugsee.setAttribute('k', '😀' * 513),
          throwsA(isA<BugseeAttributeException>()),
        );
        expect(native.calls, isEmpty);
      },
    );

    test(
      'a bad name or value is a BugseeAttributeException before native',
      () async {
        Future<void> bad(
          Object? value,
          AttributeFailure reason, {
          String name = 'k',
        }) async {
          await expectLater(
            runtime.setAttribute(name, value),
            throwsA(
              isA<BugseeAttributeException>().having(
                (e) => e.reason,
                'reason',
                reason,
              ),
            ),
          );
        }

        await bad('v', AttributeFailure.invalidName, name: '');
        await bad(null, AttributeFailure.invalidValue);
        await bad(double.nan, AttributeFailure.invalidValue);
        await bad(double.infinity, AttributeFailure.invalidValue);
        await bad(double.negativeInfinity, AttributeFailure.invalidValue);
        await bad(3.4028234663852886e38, AttributeFailure.invalidValue);
        await bad(-3.5e38, AttributeFailure.invalidValue);
        await bad(<String>['a'], AttributeFailure.invalidValue);
        await bad(<String, String>{}, AttributeFailure.invalidValue);
        await bad(DateTime(2026), AttributeFailure.invalidValue);
        expect(native.calls, isEmpty);
      },
    );

    test('an error message never contains the value', () async {
      try {
        await Bugsee.setAttribute('k', 'secret-' * 300);
        fail('expected a throw');
      } on BugseeAttributeException catch (e) {
        expect(e.toString(), isNot(contains('secret')));
      }
    });

    test(
      'the SDK\'s own rejection is not an argument exception (`on BugseeArgumentException` means refused before the SDK)',
      () async {
        native.failNext = refusal(FacadeWire.attributeRejected);
        Object? caught;
        try {
          await Bugsee.setAttribute('k', 'v');
        } on BugseeArgumentException catch (e) {
          caught = e;
        } on BugseeAttributeException catch (e) {
          expect(e.reason, AttributeFailure.rejected);
        }
        expect(caught, isNull);
        // Dart-side findings are attribute exceptions too, not argument exceptions.
        await expectLater(
          Bugsee.setAttribute('', 'v'),
          throwsA(
            allOf(
              isA<BugseeAttributeException>(),
              isNot(isA<BugseeArgumentException>()),
            ),
          ),
        );
        // Native defending again (invalid-argument) is still an attribute exception.
        native.failNext = refusal(FacadeWire.invalidArgument);
        await expectLater(
          Bugsee.setAttribute('k', 'v'),
          throwsA(
            allOf(
              isA<BugseeAttributeException>().having(
                (e) => e.reason,
                'reason',
                AttributeFailure.invalidValue,
              ),
              isNot(isA<BugseeArgumentException>()),
            ),
          ),
        );
      },
    );

    test(
      'a native rejection (size limit) is BugseeAttributeException(rejected)',
      () async {
        native.failNext = refusal(
          FacadeWire.attributeRejected,
          'over the limit',
        );
        await expectLater(
          Bugsee.setAttribute('k', 'v'),
          throwsA(
            isA<BugseeAttributeException>()
                .having((e) => e.reason, 'reason', AttributeFailure.rejected)
                .having((e) => e.cause, 'cause', isA<PlatformException>()),
          ),
        );
      },
    );

    test(
      'getAttribute normalises what native sends and drops what it cannot hold',
      () async {
        for (final v in <Object>['s', true, 3, 0.25]) {
          native.attributeValue = v;
          expect(await Bugsee.getAttribute('k'), v);
        }
        native.attributeValue = <Object?>['a', 'b'];
        final list = await Bugsee.getAttribute('k') as List<String>;
        expect(list, ['a', 'b']);
        expect(() => list.add('c'), throwsUnsupportedError);
        native.attributeValue = <Object?>['a', 1];
        expect(await Bugsee.getAttribute('k'), isNull);
        native.attributeValue = DateTime(2026);
        expect(await Bugsee.getAttribute('k'), isNull);
        native.attributeValue = null;
        expect(await Bugsee.getAttribute('k'), isNull);
        await expectLater(
          Bugsee.getAttribute(''),
          throwsA(isA<BugseeAttributeException>()),
        );
      },
    );

    test(
      'getAllAttributes is unmodifiable and filtered the same way',
      () async {
        native.allAttributes = {
          'a': 'x',
          'n': 2,
          'bad': DateTime(2026),
          'l': <Object?>['p'],
        };
        final all = await Bugsee.getAllAttributes();
        expect(all, {
          'a': 'x',
          'n': 2,
          'l': ['p'],
        });
        expect(() => all['z'] = 1, throwsUnsupportedError);
      },
    );

    test('clearAttribute and clearAllAttributes cross', () async {
      await Bugsee.clearAttribute('a');
      await Bugsee.clearAllAttributes();
      expect(native.calls, ['clearAttribute(a)', 'clearAllAttributes()']);
      await expectLater(
        Bugsee.clearAttribute(''),
        throwsA(isA<BugseeAttributeException>()),
      );
    });
  });

  group('user identity', () {
    test('set, get and clear', () async {
      await Bugsee.setUserIdentifier('u@example.com');
      native.userIdentifier = 'u@example.com';
      expect(await Bugsee.getUserIdentifier(), 'u@example.com');
      await Bugsee.clearUserIdentifier();
      expect(native.calls, [
        'setUserIdentifier(u@example.com)',
        'getUserIdentifier()',
        'setUserIdentifier(null)',
      ]);
    });

    test('an empty identifier is a clear, on both platforms', () async {
      await Bugsee.setUserIdentifier('');
      expect(native.last['setUserIdentifier'], [null]);
    });
  });

  group('event and trace', () {
    test('an event without params sends null', () async {
      await Bugsee.event('opened');
      expect(native.last['event'], ['opened', null]);
    });

    test(
      'params cross as a copy: nested maps, lists and null survive',
      () async {
        final params = <String, Object?>{
          'a': 1,
          'n': null,
          'list': [1, 'x', null, true, 2.5],
          'map': {
            'deep': {'k': 'v'},
          },
        };
        await Bugsee.event('e', params);
        final sent = native.last['event']![1] as Map<String, Object?>;
        expect(sent, params);
        expect(
          sent.containsKey('n'),
          isTrue,
          reason: 'a null member stays a null member',
        );
        expect(identical(sent, params), isFalse);
        expect(identical(sent['map'], params['map']), isFalse);
        // Changing the original afterwards changes nothing that was sent.
        (params['list'] as List).add('late');
        expect((sent['list'] as List), hasLength(5));
      },
    );

    test('an empty event or trace name is refused before native', () async {
      await expectRefusedInDart(
        native,
        () => Bugsee.event(''),
        argument: 'name',
      );
      await expectRefusedInDart(
        native,
        () => Bugsee.trace('', 1),
        argument: 'name',
      );
    });

    test(
      'params outside the accepted domain are refused with the path of the bad value',
      () async {
        await expectRefusedInDart(
          native,
          () => Bugsee.event('e', {
            'a': {
              'b': [1, DateTime(2026)],
            },
          }),
          argument: 'params.a.b[1]',
        );
        await expectRefusedInDart(
          native,
          () => Bugsee.event('e', {'x': double.nan}),
          argument: 'params.x',
        );
        await expectRefusedInDart(
          native,
          () => Bugsee.event('e', {'x': double.infinity}),
          argument: 'params.x',
        );
        await expectRefusedInDart(
          native,
          () => Bugsee.event('e', {'x': 9.3e18}),
          argument: 'params.x',
        );
        await expectRefusedInDart(
          native,
          () => Bugsee.event('e', {'x': Object()}),
          argument: 'params.x',
        );
        await expectRefusedInDart(
          native,
          () => Bugsee.event('e', {
            'm': <Object?, Object?>{1: 'x'},
          }),
          argument: 'params.m',
        );
      },
    );

    test('a cycle and excessive nesting are refused', () async {
      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      await expectRefusedInDart(
        native,
        () => Bugsee.event('e', cyclic),
        message: contains('contains itself'),
      );
      final list = <Object?>[];
      list.add(list);
      await expectRefusedInDart(native, () => Bugsee.event('e', {'l': list}));

      Object? deep = 'leaf';
      for (var i = 0; i < 17; i++) {
        deep = {'k': deep};
      }
      await expectRefusedInDart(
        native,
        () => Bugsee.event('e', deep as Map<String, Object?>),
        message: contains('deeper than'),
      );
    });

    test(
      '16 levels are accepted, and the same map twice (not a cycle) is too',
      () async {
        Object? deep = 'leaf';
        for (var i = 0; i < 15; i++) {
          deep = {'k': deep};
        }
        await Bugsee.event('e', {'k': deep});
        final shared = {'x': 1};
        await Bugsee.event('e', {'a': shared, 'b': shared});
        expect(native.calls, hasLength(2));
      },
    );

    test('trace crosses each type as itself', () async {
      await Bugsee.trace('t', 'text');
      await Bugsee.trace('t', true);
      await Bugsee.trace('t', 5);
      await Bugsee.trace('t', 1.5);
      expect(native.calls.map((c) => c.split(', ').last), [
        'text)',
        'true)',
        '5)',
        '1.5)',
      ]);
      expect(native.last['trace']![1], isA<double>());
    });

    test(
      'a trace value of another type, or a non-finite one, is refused',
      () async {
        await expectRefusedInDart(
          native,
          () => Bugsee.trace('t', <int>[1]),
          argument: 'value',
        );
        await expectRefusedInDart(
          native,
          () => Bugsee.trace('t', double.nan),
          argument: 'value',
        );
        await expectRefusedInDart(
          native,
          () => Bugsee.trace('t', double.infinity),
        );
        await expectRefusedInDart(native, () => Bugsee.trace('t', 1e19));
      },
    );
  });

  group('log', () {
    test('the level crosses as the SDK integer, default info', () async {
      await Bugsee.log('hello');
      expect(native.last['log'], ['hello', LogLevel.info.value]);
      for (final level in LogLevel.values) {
        await Bugsee.log('m', level: level);
        expect(native.last['log'], ['m', level.value]);
      }
      expect(LogLevel.values.map((l) => l.value), [1, 2, 3, 4, 5]);
    });

    test('a native refusal of the level is an argument exception', () async {
      native.failNext = refusal(FacadeWire.invalidArgument);
      await expectLater(
        Bugsee.log('m'),
        throwsA(
          isA<BugseeArgumentException>().having(
            (e) => e.argument,
            'argument',
            'level',
          ),
        ),
      );
    });
  });

  group('breadcrumbs', () {
    test(
      'crosses with the level NAME and the data copy, and says whether the SDK took it',
      () async {
        final accepted = await Bugsee.addBreadcrumb(
          const BugseeBreadcrumb(
            category: 'nav',
            message: 'opened cart',
            level: BreadcrumbLevel.warning,
            type: 'navigation',
            data: {'items': 3, 'n': null},
          ),
        );
        expect(accepted, isTrue);
        expect(native.last['addBreadcrumb'], [
          'nav',
          'warning',
          'opened cart',
          'navigation',
          {'items': 3, 'n': null},
        ]);
        native.breadcrumbAccepted = false;
        expect(
          await Bugsee.addBreadcrumb(
            const BugseeBreadcrumb(category: 'c', message: 'm'),
          ),
          isFalse,
        );
        expect(native.last['addBreadcrumb'], [
          'c',
          'info',
          'm',
          'default',
          null,
        ]);
      },
    );

    test('every level crosses by name', () async {
      for (final l in BreadcrumbLevel.values) {
        await Bugsee.addBreadcrumb(
          BugseeBreadcrumb(category: 'c', message: 'm', level: l),
        );
        expect(native.last['addBreadcrumb']![1], l.name);
      }
      expect(BreadcrumbLevel.values.map((l) => l.name), [
        'debug',
        'info',
        'warning',
        'error',
        'fatal',
      ]);
    });

    test('data outside the accepted domain is refused', () async {
      await expectRefusedInDart(
        native,
        () => Bugsee.addBreadcrumb(
          BugseeBreadcrumb(category: 'c', message: 'm', data: {'x': Object()}),
        ),
        argument: 'data.x',
      );
    });

    test('fromName is exact', () {
      expect(BreadcrumbLevel.fromName('fatal'), BreadcrumbLevel.fatal);
      expect(BreadcrumbLevel.fromName('FATAL'), isNull);
      expect(BreadcrumbLevel.fromName(null), isNull);
    });
  });

  group('notify', () {
    test(
      'crosses with the severity value, the fields as ordered pairs and urgent',
      () async {
        await Bugsee.notify(
          'Deploy',
          body: 'done',
          severity: ReportSeverity.critical,
          fields: {'z': '1', 'a': '2'},
          urgent: true,
        );
        expect(native.last['relayNotification'], [
          'Deploy',
          'done',
          4,
          ['z', '1', 'a', '2'],
          true,
        ]);
        await Bugsee.notify('Plain');
        expect(native.last['relayNotification'], [
          'Plain',
          null,
          null,
          null,
          false,
        ]);
      },
    );

    test('a blank title is refused before native', () async {
      await expectRefusedInDart(
        native,
        () => Bugsee.notify(''),
        argument: 'title',
      );
      await expectRefusedInDart(
        native,
        () => Bugsee.notify('  \n'),
        argument: 'title',
      );
    });
  });

  group('captureViewHierarchy', () {
    test('reaches the SDK once, with no argument', () async {
      await Bugsee.captureViewHierarchy();
      expect(native.calls, ['captureViewHierarchy()']);
    });
  });

  group('blackout', () {
    test('start, end and read back', () async {
      expect(await Bugsee.isBlackout(), isFalse);
      await Bugsee.startBlackout();
      expect(await Bugsee.isBlackout(), isTrue);
      await Bugsee.endBlackout();
      expect(await Bugsee.isBlackout(), isFalse);
      expect(native.calls, [
        'isBlackout()',
        'startBlackout()',
        'isBlackout()',
        'endBlackout()',
        'isBlackout()',
      ]);
    });

    test('the facade has no pause and no resume', () {
      // The 6.x pause/resume suspended the loggers too; blackout does not. A shim would change what
      // a privacy-motivated call does, so the names must not exist (checked on the API surface test
      // as well).
      final api = File('lib/src/bugsee.dart').readAsStringSync();
      expect(api, isNot(contains('static Future<void> pause')));
      expect(api, isNot(contains('static Future<void> resume')));
    });
  });

  group('reports', () {
    test('upload sends the severity by value and copies the labels', () async {
      final labels = ['a', 'b'];
      await Bugsee.upload(
        's',
        'd',
        severity: ReportSeverity.blocker,
        labels: labels,
      );
      labels.add('late');
      expect(native.last['upload'], [
        's',
        'd',
        5,
        ['a', 'b'],
      ]);
      await Bugsee.upload('s', 'd');
      expect(native.last['upload'], ['s', 'd', null, null]);
    });

    test('showReportDialog sends only what was given', () async {
      await Bugsee.showReportDialog();
      expect(native.last['showReportDialog'], [null, null, null, null]);
      await Bugsee.showReportDialog(
        summary: 's',
        description: 'd',
        severity: ReportSeverity.veryLow,
        labels: ['l'],
      );
      expect(native.last['showReportDialog'], [
        's',
        'd',
        1,
        ['l'],
      ]);
    });

    test('an empty label is refused before native', () async {
      await expectRefusedInDart(
        native,
        () => Bugsee.upload('s', 'd', labels: ['ok', '']),
        argument: 'labels',
      );
      await expectRefusedInDart(
        native,
        () => Bugsee.showReportDialog(labels: ['']),
        argument: 'labels',
      );
    });
  });

  group('error mapping', () {
    test(
      'invalid-argument, sdk-error and not-attached map to BugseeException subclasses',
      () async {
        native.failNext = refusal(FacadeWire.invalidArgument, 'bad');
        await expectLater(
          Bugsee.trace('t', 1),
          throwsA(
            isA<BugseeArgumentException>().having(
              (e) => e.message,
              'message',
              contains('bad'),
            ),
          ),
        );
        native.failNext = refusal(FacadeWire.sdkError, 'SDK threw');
        await expectLater(
          Bugsee.event('e'),
          throwsA(
            isA<BugseeException>()
                .having(
                  (e) => e,
                  'not an argument error',
                  isNot(isA<BugseeArgumentException>()),
                )
                .having((e) => e.message, 'message', contains('SDK threw')),
          ),
        );
        native.failNext = refusal(FacadeWire.notAttached, 'no engine');
        await expectLater(Bugsee.isBlackout(), throwsA(isA<BugseeException>()));
        native.failNext = refusal('something-new');
        await expectLater(
          Bugsee.startBlackout(),
          throwsA(isA<BugseeException>()),
        );
      },
    );

    test('every facade method maps a native failure', () async {
      final calls = <String, Future<Object?> Function()>{
        'setAttribute': () => Bugsee.setAttribute('k', 'v'),
        'getAttribute': () => Bugsee.getAttribute('k'),
        'getAllAttributes': Bugsee.getAllAttributes,
        'clearAttribute': () => Bugsee.clearAttribute('k'),
        'clearAllAttributes': Bugsee.clearAllAttributes,
        'setUserIdentifier': () => Bugsee.setUserIdentifier('u'),
        'getUserIdentifier': Bugsee.getUserIdentifier,
        'trace': () => Bugsee.trace('t', 1),
        'event': () => Bugsee.event('e'),
        'addBreadcrumb': () => Bugsee.addBreadcrumb(
          const BugseeBreadcrumb(category: 'c', message: 'm'),
        ),
        'relayNotification': () => Bugsee.notify('T'),
        'log': () => Bugsee.log('m'),
        'startBlackout': Bugsee.startBlackout,
        'endBlackout': Bugsee.endBlackout,
        'isBlackout': Bugsee.isBlackout,
        'captureViewHierarchy': Bugsee.captureViewHierarchy,
        'showReportDialog': Bugsee.showReportDialog,
        'upload': () => Bugsee.upload('s', 'd'),
      };
      for (final entry in calls.entries) {
        native.failing[entry.key] = refusal(FacadeWire.sdkError, 'boom');
        await expectLater(
          entry.value(),
          throwsA(
            isA<BugseeException>().having(
              (e) => e.cause,
              'cause',
              isA<PlatformException>(),
            ),
          ),
          reason: entry.key,
        );
        native.failing.clear();
      }
      expect(calls.keys.toSet(), hasLength(18));
    });

    test(
      'a missing plugin is a BugseeException, not a MissingPluginException',
      () async {
        debugSetBugseeRuntime(
          BugseeRuntime(
            host: _MissingPluginFake(),
            platform: () => platform,
            warn: warnings.add,
          ),
        );
        await expectLater(
          Bugsee.setAttribute('k', 'v'),
          throwsA(
            isA<BugseeException>().having(
              (e) => e.message,
              'message',
              contains('not registered'),
            ),
          ),
        );
      },
    );

    test(
      'from a background isolate (no binding) it is a BugseeException',
      () async {
        debugSetBugseeRuntime(
          BugseeRuntime(
            host: native,
            platform: () => platform,
            ensureBinding: () => throw StateError(
              'ServicesBinding.defaultBinaryMessenger was accessed',
            ),
          ),
        );
        await expectLater(
          Bugsee.event('e'),
          throwsA(
            isA<BugseeException>().having(
              (e) => e.message,
              'm',
              contains('root isolate'),
            ),
          ),
        );
        expect(native.calls, isEmpty);
      },
    );
  });

  group('attaching and the report handler', () {
    test(
      'the first facade call attaches the plugin, whichever it is',
      () async {
        expect(native.attachCount, 0);
        await Bugsee.isBlackout();
        expect(native.attachCount, 1);
        await Bugsee.event('e');
        expect(native.attachCount, 1, reason: 'once');
      },
    );

    test(
      'a failure to attach is a BugseeException from the call itself',
      () async {
        final failing = _AttachFails();
        debugSetBugseeRuntime(
          BugseeRuntime(host: failing, platform: () => platform),
        );
        await expectLater(Bugsee.event('e'), throwsA(isA<BugseeException>()));
        expect(failing.calls, isNot(contains('event(e, null)')));
      },
    );

    test(
      'overlapping handler changes run in order: a failed first does not undo the second',
      () async {
        final seen = <String>[];
        native.failPhaseCalls.add(1);
        native.firstPhasesGate = Completer<void>();
        final h1 = BugseeReportHandler(
          onAfterReportCreated: (r) async => seen.add('h1'),
        );
        final h2 = BugseeReportHandler(
          onAfterReportCreated: (r) async => seen.add('h2'),
        );
        await Bugsee.isBlackout(); // started, as in an app
        native.phasesArmed = true;
        final first = Bugsee.setReportHandler(h1);
        final firstOutcome = expectLater(
          first,
          throwsA(isA<BugseeException>()),
        );
        final second = Bugsee.setReportHandler(h2);
        await Future<void>.delayed(Duration.zero);
        native.firstPhasesGate!.complete();
        await firstOutcome;
        await second;
        expect(Bugsee.reportHandler, same(h2));
        expect(native.phases.toString(), 'Phases(false, true)');
        _deliver(runtime, seen);
        await Future<void>.delayed(Duration.zero);
        expect(seen, ['h2'], reason: 'Dart and native agree on h2');
      },
    );

    test(
      'overlapping handler changes that both fail leave the old handler in effect',
      () async {
        final seen = <String>[];
        final old = BugseeReportHandler(
          onAfterReportCreated: (r) async => seen.add('old'),
        );
        await Bugsee.setReportHandler(old);
        native.phasesArmed = true;
        native.failPhaseCalls.addAll([1, 2]);
        native.firstPhasesGate = Completer<void>();
        BugseeReportHandler mk(String n) =>
            BugseeReportHandler(onAfterReportCreated: (r) async => seen.add(n));
        final a = expectLater(
          Bugsee.setReportHandler(mk('a')),
          throwsA(isA<BugseeException>()),
        );
        final b = expectLater(
          Bugsee.setReportHandler(mk('b')),
          throwsA(isA<BugseeException>()),
        );
        await Future<void>.delayed(Duration.zero);
        native.firstPhasesGate!.complete();
        await a;
        await b;
        expect(Bugsee.reportHandler, same(old));
        _deliver(runtime, seen);
        await Future<void>.delayed(Duration.zero);
        expect(seen, ['old']);
      },
    );

    test(
      'equal handlers: the first fails, the second succeeds, and it is in effect',
      () async {
        final seen = <String>[];
        final same1 = BugseeReportHandler(
          onAfterReportCreated: (r) async => seen.add('same'),
        );
        await Bugsee.isBlackout();
        native.phasesArmed = true;
        native.failPhaseCalls.add(1);
        native.firstPhasesGate = Completer<void>();
        final a = expectLater(
          Bugsee.setReportHandler(same1),
          throwsA(isA<BugseeException>()),
        );
        final b = Bugsee.setReportHandler(same1);
        await Future<void>.delayed(Duration.zero);
        native.firstPhasesGate!.complete();
        await a;
        await b;
        expect(Bugsee.reportHandler, same(same1));
        _deliver(runtime, seen);
        await Future<void>.delayed(Duration.zero);
        expect(seen, ['same']);
      },
    );

    test(
      'a handler the native call refused is not the handler in effect',
      () async {
        final seen = <String>[];
        final old = BugseeReportHandler(
          onAfterReportCreated: (r) async => seen.add('old'),
        );
        await Bugsee.setReportHandler(old);
        native.phasesArmed = true;
        native.failing['setReportHandlerPhases'] = refusal(FacadeWire.sdkError);
        await expectLater(
          Bugsee.setReportHandler(
            BugseeReportHandler(
              onAfterReportCreated: (r) async => seen.add('new'),
            ),
          ),
          throwsA(isA<BugseeException>()),
        );
        expect(Bugsee.reportHandler, same(old));
        expect(native.phases.toString(), 'Phases(false, true)');
        // A delivery goes to the handler native still believes in.
        runtime.bridge.onReportHandlerRequest(
          ReportHandlerRequestMessage(
            handle: 'h',
            deliveryId: 'after:r',
            after: true,
            reportId: 'r',
            type: 'bug',
            deadlineMs: 5000,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(seen, ['old']);
      },
    );
  });

  group('a platform with no SDK', () {
    setUp(() => platform = null);

    test(
      'calls do nothing and return the neutral value, with one warning',
      () async {
        await Bugsee.setAttribute('k', 'v');
        await Bugsee.event('e');
        await Bugsee.trace('t', 1);
        await Bugsee.log('m');
        await Bugsee.notify('T');
        await Bugsee.startBlackout();
        expect(await Bugsee.isBlackout(), isFalse);
        expect(await Bugsee.getAttribute('k'), isNull);
        expect(await Bugsee.getAllAttributes(), isEmpty);
        expect(await Bugsee.getUserIdentifier(), isNull);
        expect(
          await Bugsee.addBreadcrumb(
            const BugseeBreadcrumb(category: 'c', message: 'm'),
          ),
          isFalse,
        );
        expect(native.calls, isEmpty);
        expect(warnings, hasLength(1));
      },
    );

    test('arguments are still validated', () async {
      await expectRefusedInDart(
        native,
        () => Bugsee.event(''),
        argument: 'name',
      );
    });

    test('launch still throws', () async {
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
    });

    test('a report handler is remembered and native is not touched', () async {
      final handler = BugseeReportHandler(onAfterReportCreated: (_) {});
      await Bugsee.setReportHandler(handler);
      expect(Bugsee.reportHandler, same(handler));
      expect(native.calls, isEmpty);
    });
  });

  group('report handler', () {
    test('set registers the phases, replace and clear update them', () async {
      expect(Bugsee.reportHandler, isNull);
      final first = BugseeReportHandler(onBeforeReportCreated: (_) {});
      await Bugsee.setReportHandler(first);
      expect(Bugsee.reportHandler, same(first));
      expect(native.phases.toString(), 'Phases(true, false)');

      final second = BugseeReportHandler(
        onBeforeReportCreated: (_) {},
        onAfterReportCreated: (_) {},
      );
      await Bugsee.setReportHandler(second);
      expect(Bugsee.reportHandler, same(second));
      expect(native.phases.toString(), 'Phases(true, true)');

      await Bugsee.setReportHandler(null);
      expect(Bugsee.reportHandler, isNull);
      expect(native.phases.toString(), 'Phases(false, false)');
    });

    test('a handler with neither phase is a clear', () async {
      await Bugsee.setReportHandler(
        BugseeReportHandler(onAfterReportCreated: (_) {}),
      );
      await Bugsee.setReportHandler(const BugseeReportHandler());
      expect(Bugsee.reportHandler, isNull);
      expect(native.phases.toString(), 'Phases(false, false)');
    });

    test(
      'a delivery reaches the registered phase handler with a live proxy',
      () async {
        final seen = <String>[];
        await Bugsee.setReportHandler(
          BugseeReportHandler(
            onAfterReportCreated: (report) async {
              seen.add('after:${report.id}:${report.type}:${report.isLive}');
            },
          ),
        );
        runtime.bridge.onReportHandlerRequest(
          ReportHandlerRequestMessage(
            handle: 'h1',
            deliveryId: 'after:r1',
            after: true,
            reportId: 'r1',
            type: 'crash',
            deadlineMs: 5000,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(seen, ['after:r1:ReportType.crash:true']);
      },
    );
  });

  group('lifecycle events', () {
    test('every event is public, unknown names preserved as raw', () async {
      final runtime = BugseeRuntime(host: native, platform: () => platform);
      debugSetBugseeRuntime(runtime);
      final seen = <LifecycleEvent>[];
      final sub = Bugsee.lifecycleEvents.listen(seen.add);
      runtime.bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Launched'));
      runtime.bridge.onLifecycleEvent(
        LifecycleEventMessage(name: 'AfterReportUploaded', reportId: 'r9'),
      );
      runtime.bridge.onLifecycleEvent(
        LifecycleEventMessage(name: 'SomethingNewerSdksSend', data: {'k': 'v'}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen.map((e) => e.name), [
        'Launched',
        'AfterReportUploaded',
        'SomethingNewerSdksSend',
      ]);
      expect(seen[1].reportId, 'r9');
      expect(seen[2].data, {'k': 'v'});
      await sub.cancel();
    });

    test(
      'the first access attaches the plugin, so earlier events are replayed',
      () async {
        debugSetBugseeRuntime(
          BugseeRuntime(host: native, platform: () => platform),
        );
        expect(native.attachCount, 0);
        Bugsee.lifecycleEvents;
        await Future<void>.delayed(Duration.zero);
        expect(native.attachCount, 1);
      },
    );

    test('the stream is a broadcast stream (many listeners)', () {
      debugSetBugseeRuntime(
        BugseeRuntime(host: native, platform: () => platform),
      );
      expect(Bugsee.lifecycleEvents.isBroadcast, isTrue);
    });
  });
}
