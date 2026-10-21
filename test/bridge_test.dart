// The Dart end of the bridge, against mocked channels: stream, status, unknown
// names, ordering around attach, and the identity that gets sent.

import 'package:bugsee_flutter/src/bridge/bridge.dart';
import 'package:bugsee_flutter/src/bridge/lifecycle.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/bridge/runtime_facts.dart';
import 'package:bugsee_flutter/src/wrapper_identity.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

const _facts = RuntimeFacts(
  flutterVersion: '3.41.0',
  dartVersion: '3.11.0',
  engineRevision: 'abc123',
  buildMode: BuildMode.debug,
);

/// A native end that records calls, and can push events when asked to attach.
class FakeHost extends BugseeBridgeHostApi {
  final List<String> calls = [];
  final List<WrapperIdentityMessage> identities = [];
  Future<void> Function()? onAttach;
  int failAttach = 0;
  int failIdentity = 0;

  @override
  Future<void> attachLifecycle() async {
    calls.add('attach');
    if (failAttach > 0) {
      failAttach--;
      throw PlatformException(code: 'channel-error');
    }
    await onAttach?.call();
  }

  int resets = 0;
  final List<(bool, bool)> phases = [];

  int failReset = 0;

  @override
  Future<void> resetReportHandlers() async {
    calls.add('reset');
    if (failReset > 0) {
      failReset--;
      throw PlatformException(code: 'channel-error');
    }
    resets++;
  }

  int failPhases = 0;

  @override
  Future<void> setReportHandlerPhases(bool before, bool after) async {
    calls.add('phases');
    if (failPhases > 0) {
      failPhases--;
      throw PlatformException(code: 'channel-error');
    }
    phases.add((before, after));
  }

  @override
  Future<void> setWrapperIdentity(WrapperIdentityMessage identity) async {
    calls.add('identity');
    if (failIdentity > 0) {
      failIdentity--;
      throw PlatformException(code: 'channel-error');
    }
    identities.add(identity);
  }
}

/// Delivers one native -> Dart message over the real channel, as native would.
Future<void> nativeSends(
  TestDefaultBinaryMessenger messenger,
  LifecycleEventMessage event,
) async {
  const channel =
      'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeFlutterApi.onLifecycleEvent';
  final codec = BugseeBridgeFlutterApi.pigeonChannelCodec;
  await messenger.handlePlatformMessage(
    channel,
    codec.encodeMessage(<Object?>[event]),
    (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late FakeHost host;
  late BugseeBridge bridge;
  setUp(() {
    host = FakeHost();
    bridge = BugseeBridge(host: host);
  });
  tearDown(() => BugseeBridgeFlutterApi.setUp(null));

  group('lifecycle stream', () {
    test('delivers every event in order, over the real channel', () async {
      await bridge.start(facts: _facts);
      final seen = <LifecycleEvent>[];
      bridge.lifecycleEvents.listen(seen.add);
      await nativeSends(messenger, LifecycleEventMessage(name: 'Launching'));
      await nativeSends(messenger, LifecycleEventMessage(name: 'Launched'));
      await nativeSends(
        messenger,
        LifecycleEventMessage(name: 'BlackoutStarted'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen.map((e) => e.name), [
        'Launching',
        'Launched',
        'BlackoutStarted',
      ]);
    });

    test('an unrecognised name reaches subscribers unchanged', () async {
      await bridge.start(facts: _facts);
      final seen = <LifecycleEvent>[];
      bridge.lifecycleEvents.listen(seen.add);
      await nativeSends(
        messenger,
        LifecycleEventMessage(name: 'SomeFutureEvent', data: {'k': 'v'}),
      );
      await nativeSends(
        messenger,
        LifecycleEventMessage(name: 'com.bugsee.lifecycle.NotStrippedHere'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(2));
      expect(seen[0].name, 'SomeFutureEvent');
      expect(seen[0].data, {'k': 'v'});
      // Dart never strips: the prefix is stripped once, natively.
      expect(seen[1].name, 'com.bugsee.lifecycle.NotStrippedHere');
    });

    test('a report id is carried through untouched', () async {
      await bridge.start(facts: _facts);
      final seen = <LifecycleEvent>[];
      bridge.lifecycleEvents.listen(seen.add);
      await nativeSends(
        messenger,
        LifecycleEventMessage(name: 'AfterReportUploaded', reportId: 'r-9'),
      );
      await nativeSends(messenger, LifecycleEventMessage(name: 'Launched'));
      await Future<void>.delayed(Duration.zero);
      expect(seen[0].reportId, 'r-9');
      expect(seen[1].reportId, isNull);
      expect(seen[1].data, isEmpty);
    });

    test('is a broadcast stream: several listeners all see events', () async {
      await bridge.start(facts: _facts);
      final a = <String>[];
      final b = <String>[];
      bridge.lifecycleEvents.listen((e) => a.add(e.name));
      bridge.lifecycleEvents.listen((e) => b.add(e.name));
      bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Launched'));
      await Future<void>.delayed(Duration.zero);
      expect(a, ['Launched']);
      expect(b, ['Launched']);
    });
  });

  group('status', () {
    test('only Launching/Launched/Stopping/Stopped are transitions', () async {
      final statuses = <SdkStatus>[];
      bridge.statusChanges.listen(statuses.add);
      for (final n in [
        'Launching',
        'Launched',
        'BlackoutStarted',
        'BlackoutEnded',
        'RelaunchedAfterCrash',
        'BeforeReportShown',
        'AfterReportShown',
        'BeforeReportAssembled',
        'AfterReportUploaded',
        'ReportUploadFailed',
        'BeforeFeedbackShown',
        'SomeFutureEvent',
        '', // not a transition either
        'launched', // names are case-sensitive
        'Stopping',
        'Stopped',
      ]) {
        bridge.onLifecycleEvent(LifecycleEventMessage(name: n));
      }
      await Future<void>.delayed(Duration.zero);
      expect(statuses, [
        SdkStatus.launching,
        SdkStatus.launched,
        SdkStatus.stopping,
        SdkStatus.stopped,
      ]);
    });

    test('statusForEvent is null for a non-transition, never a default', () {
      expect(
        statusForEvent(const LifecycleEvent('RelaunchedAfterCrash')),
        isNull,
      );
      expect(statusForEvent(const LifecycleEvent('Nope')), isNull);
      expect(
        statusForEvent(const LifecycleEvent('Launching')),
        SdkStatus.launching,
      );
    });

    test('the latest status is kept even with nobody listening', () {
      expect(bridge.status, isNull, reason: 'unknown, not stopped');
      bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Launching'));
      bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Launched'));
      bridge.onLifecycleEvent(LifecycleEventMessage(name: 'BlackoutStarted'));
      expect(bridge.status, SdkStatus.launched);
    });

    test('an event is never taken as proof that a report exists (4.7)', () async {
      // RelaunchedAfterCrash fires whether or not a crash report was produced:
      // the bridge hands on an event with no report id and no status, nothing more.
      final events = <LifecycleEvent>[];
      bridge.lifecycleEvents.listen(events.add);
      bridge.onLifecycleEvent(
        LifecycleEventMessage(name: 'RelaunchedAfterCrash'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events.single.reportId, isNull);
      expect(statusForEvent(events.single), isNull);
      expect(bridge.status, isNull);
    });
  });

  group('start', () {
    test('registers the handler before native is told to flush', () async {
      final seen = <String>[];
      bridge.lifecycleEvents.listen((e) => seen.add(e.name));
      // Native flushes what it buffered from inside attachLifecycle.
      host.onAttach = () async {
        await nativeSends(messenger, LifecycleEventMessage(name: 'Launching'));
        await nativeSends(messenger, LifecycleEventMessage(name: 'Launched'));
      };
      await bridge.start(facts: _facts);
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['Launching', 'Launched']);
      expect(bridge.status, SdkStatus.launched);
    });

    test('attaches, then sends the identity, once', () async {
      await bridge.start(facts: _facts);
      await bridge.start(facts: _facts);
      await bridge.start();
      expect(host.calls, ['attach', 'reset', 'phases', 'identity']);
      // A new isolate has no report handler yet: native must not wait on one.
      expect(host.phases, [(false, false)]);
    });

    test('handlers registered BEFORE start still sweep the old isolate, once, '
        'before any phase registration', () async {
      await bridge.setReportHandlers(onBefore: (_) {});
      await bridge.start(facts: _facts);
      expect(host.resets, 1);
      expect(
        host.calls.indexOf('reset'),
        lessThan(host.calls.indexOf('phases')),
        reason: 'the sweep also clears native phases: it must come first',
      );
      expect(host.calls.where((c) => c == 'reset'), hasLength(1));
      // The handler registered before start() is what native was told.
      expect(host.phases.last, (true, false));
    });

    test('handlers registered AFTER start() do not sweep again', () async {
      await bridge.start(facts: _facts);
      await bridge.setReportHandlers(onAfter: (_) {});
      expect(host.resets, 1);
      expect(host.phases, [(false, false), (false, true)]);
    });

    test('a failed sweep is not cached: the next registration repeats it, '
        'before its phases', () async {
      host.failReset = 1;
      await expectLater(
        bridge.setReportHandlers(onBefore: (_) {}),
        throwsA(isA<PlatformException>()),
      );
      expect(host.calls, ['reset']);
      await bridge.setReportHandlers(onBefore: (_) {});
      expect(host.calls, ['reset', 'reset', 'phases']);
    });

    test('start() and setReportHandlers racing sweep once', () async {
      await Future.wait([
        bridge.setReportHandlers(onBefore: (_) {}),
        bridge.start(facts: _facts),
      ]);
      expect(host.resets, 1);
      expect(
        host.calls.indexOf('reset'),
        lessThan(host.calls.indexOf('phases')),
      );
    });

    test(
      'a failed attach still sends the identity, and start() can be retried',
      () async {
        host.failAttach = 1;
        await expectLater(
          bridge.start(facts: _facts),
          throwsA(isA<PlatformException>()),
        );
        expect(host.calls, ['attach', 'reset', 'phases', 'identity']);
        expect(host.identities, hasLength(1));
        // Not cached: the next call tries again, repeating only the failed step
        // (the identity already went through).
        await bridge.start(facts: _facts);
        expect(host.calls, ['attach', 'reset', 'phases', 'identity', 'attach']);
        // And now it is cached.
        await bridge.start(facts: _facts);
        expect(host.calls, hasLength(5));
      },
    );

    test('a failed identity does not stop events, and is retried', () async {
      host.failIdentity = 1;
      final seen = <String>[];
      bridge.lifecycleEvents.listen((e) => seen.add(e.name));
      await expectLater(
        bridge.start(facts: _facts),
        throwsA(isA<PlatformException>()),
      );
      await nativeSends(messenger, LifecycleEventMessage(name: 'Launched'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['Launched']);
      await bridge.start(facts: _facts);
      expect(host.identities, hasLength(1));
      // Attach had succeeded: the retry must not attach again (native would replay
      // events this bridge already received).
      expect(host.calls, ['attach', 'reset', 'phases', 'identity', 'identity']);
    });

    test('the identity carries versions, engine and build mode', () async {
      await bridge.start(facts: _facts, build: '42');
      final id = host.identities.single;
      expect(id.type, wrapperType);
      expect(id.version, wrapperVersion);
      expect(id.build, '42');
      expect(id.context, {
        'flutter': '3.41.0',
        'dart': '3.11.0',
        'flutter-engine': 'abc123',
        'build-configuration': 'debug',
      });
    });

    test('talks to the expected host channels', () async {
      final calls = <String>[];
      messenger.setMockMessageHandler(
        'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeHostApi.attachLifecycle',
        (m) async {
          calls.add('attach');
          return BugseeBridgeHostApi.pigeonChannelCodec.encodeMessage(<Object?>[
            null,
          ]);
        },
      );
      messenger.setMockMessageHandler(
        'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeHostApi.setWrapperIdentity',
        (m) async {
          final args =
              BugseeBridgeHostApi.pigeonChannelCodec.decodeMessage(m)!
                  as List<Object?>;
          calls.add((args.single! as WrapperIdentityMessage).type);
          return BugseeBridgeHostApi.pigeonChannelCodec.encodeMessage(<Object?>[
            null,
          ]);
        },
      );
      messenger.setMockMessageHandler(
        'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeHostApi.resetReportHandlers',
        (m) async {
          calls.add('reset');
          return BugseeBridgeHostApi.pigeonChannelCodec.encodeMessage(<Object?>[
            null,
          ]);
        },
      );
      messenger.setMockMessageHandler(
        'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeHostApi.setReportHandlerPhases',
        (m) async {
          calls.add('phases');
          return BugseeBridgeHostApi.pigeonChannelCodec.encodeMessage(<Object?>[
            null,
          ]);
        },
      );
      addTearDown(() {
        messenger.setMockMessageHandler(
          'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeHostApi.resetReportHandlers',
          null,
        );
        messenger.setMockMessageHandler(
          'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeHostApi.setReportHandlerPhases',
          null,
        );
        messenger.setMockMessageHandler(
          'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeHostApi.attachLifecycle',
          null,
        );
        messenger.setMockMessageHandler(
          'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeHostApi.setWrapperIdentity',
          null,
        );
      });
      await BugseeBridge().start(facts: _facts);
      expect(calls, ['attach', 'reset', 'phases', 'flutter']);
    });
  });

  group('runtime facts', () {
    test('missing facts are "unknown", never empty', () {
      final id = WrapperIdentity.from(
        const RuntimeFacts(flutterVersion: '', buildMode: BuildMode.release),
      );
      expect(id.context, {
        'flutter': 'unknown',
        'dart': 'unknown',
        'flutter-engine': 'unknown',
        'build-configuration': 'release',
      });
    });

    test('build mode names are debug / profile / release', () {
      expect(BuildMode.values.map((m) => m.name), [
        'debug',
        'profile',
        'release',
      ]);
      // flutter test runs in debug mode.
      expect(BuildMode.current, BuildMode.debug);
    });

    test('the current runtime has a Dart version at least', () {
      final facts = RuntimeFacts.current();
      expect(facts.dartVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
    });
  });
}
