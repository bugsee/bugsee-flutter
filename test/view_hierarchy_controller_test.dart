// When the managed view hierarchy is published at all: the SDK launched, its own capture option on,
// the app in the foreground. And that the runtime wires the gate to the SDK's status.
import 'dart:async';

import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/bugsee_runtime.dart';
import 'package:bugsee_flutter/src/options/endpoint.dart';
import 'package:bugsee_flutter/src/options/launch_options.dart';
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:bugsee_flutter/src/status.dart';
import 'package:bugsee_flutter/src/view_hierarchy/controller.dart';
import 'package:bugsee_flutter/src/view_hierarchy/hierarchy_builder.dart';
import 'package:bugsee_flutter/src/view_hierarchy/publisher.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

HierarchySnapshot fake(String tag) => HierarchySnapshot(
  viewId: 0,
  devicePixelRatio: 3,
  segments: [tag, ''],
  bounds: const [],
  nodeCount: 1,
  truncated: false,
);

class Rig {
  Rig({bool foreground = true}) {
    publisher = ViewHierarchyPublisher(
      send: (m) async {
        sent.add(m);
        return true;
      },
      epoch: 1,
      builder: (limits, now) {
        builds++;
        return fake('A');
      },
    );
    controller = ViewHierarchyController(
      publisher: publisher,
      foreground: foreground,
      readOption: () async {
        reads++;
        final gate = optionGate;
        if (gate != null) await gate.future;
        if (optionError != null) throw optionError!;
        return option;
      },
    );
  }

  late final ViewHierarchyPublisher publisher;
  late final ViewHierarchyController controller;
  final List<ViewHierarchyMessage> sent = [];
  int builds = 0;
  int reads = 0;
  bool option = true;
  Object? optionError;
  Completer<void>? optionGate;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<void> withRig(
  WidgetTester tester,
  Future<void> Function(Rig rig) body, {
  bool foreground = true,
}) async {
  await tester.pumpWidget(const SizedBox());
  final rig = Rig(foreground: foreground);
  await body(rig);
  await rig.publisher.deactivate();
  rig.publisher.dispose();
}

/// A native end that only answers what the runtime asks while attaching and gating.
class FakeHost extends BugseeBridgeHostApi {
  Map<String, Object> options = {viewHierarchyOptionKey: true};
  PlatformException? optionsThrow;
  int optionReads = 0;

  /// Shared with the publisher's sender, so the order of the two kinds of call is visible.
  final List<String> order = [];

  @override
  Future<void> captureViewHierarchy() async => order.add('capture');

  @override
  Future<void> attachLifecycle() async {}
  @override
  Future<void> resetReportHandlers() async {}
  @override
  Future<void> setReportHandlerPhases(bool before, bool after) async {}
  @override
  Future<void> setWrapperIdentity(WrapperIdentityMessage identity) async {}
  @override
  Future<Map<String, Object>> launchOptions(bool hostOnly) async {
    optionReads++;
    if (optionsThrow != null) throw optionsThrow!;
    return options;
  }
}

void main() {
  group('the three conditions', () {
    testWidgets('nothing is published before the SDK is launched', (
      tester,
    ) async {
      await withRig(tester, (r) async {
        await r.settle(tester);
        expect(r.publisher.active, isFalse);
        expect(r.controller.wanted, isFalse);
        r.controller.onStatus(BugseeStatus.launching);
        await r.settle(tester);
        expect(r.publisher.active, isFalse);
        expect(r.reads, 0, reason: 'the option is read once launched');
      });
    });

    testWidgets('launched, option on, foreground: published', (tester) async {
      await withRig(tester, (r) async {
        r.controller.onStatus(BugseeStatus.launched);
        await r.settle(tester);
        expect(r.reads, 1);
        expect(r.publisher.active, isTrue);
        expect(r.builds, 1);
        expect(r.sent, hasLength(1));
      });
    });

    testWidgets('with the SDKs own switch off nothing is built or sent', (
      tester,
    ) async {
      await withRig(tester, (r) async {
        r.option = false;
        r.controller.onStatus(BugseeStatus.launched);
        await r.settle(tester);
        expect(r.publisher.active, isFalse);
        expect(r.builds, 0);
        expect(r.sent, isEmpty);
      });
    });

    testWidgets('an option that cannot be read counts as off', (tester) async {
      await withRig(tester, (r) async {
        r.optionError = PlatformException(code: 'sdk-error');
        r.controller.onStatus(BugseeStatus.launched);
        await r.settle(tester);
        expect(r.publisher.active, isFalse);
        expect(r.builds, 0);
      });
    });

    testWidgets('a stop switches it off and takes back what native held', (
      tester,
    ) async {
      await withRig(tester, (r) async {
        r.controller.onStatus(BugseeStatus.launched);
        await r.settle(tester);
        expect(r.sent, hasLength(1));
        r.controller.onStatus(BugseeStatus.stopping);
        await r.settle(tester);
        expect(r.publisher.active, isFalse);
        expect(r.sent, hasLength(2));
        expect(r.sent.last.segments, isEmpty);
        r.controller.onStatus(BugseeStatus.stopped);
        await r.settle(tester);
        expect(r.sent, hasLength(2));
        expect(r.publisher.active, isFalse);
      });
    });

    testWidgets('a launch after a stop reads the option again', (tester) async {
      await withRig(tester, (r) async {
        r.controller.onStatus(BugseeStatus.launched);
        await r.settle(tester);
        r.controller.onStatus(BugseeStatus.stopped);
        await r.settle(tester);
        r.option = false;
        r.controller.onStatus(BugseeStatus.launched);
        await r.settle(tester);
        expect(r.reads, 2);
        expect(
          r.publisher.active,
          isFalse,
          reason: 'the new launch has it off',
        );
      });
    });

    testWidgets('a stop while the option is being read wins over the read', (
      tester,
    ) async {
      await withRig(tester, (r) async {
        r.optionGate = Completer<void>();
        r.controller.onStatus(BugseeStatus.launched);
        await r.settle(tester);
        r.controller.onStatus(BugseeStatus.stopped);
        r.optionGate!.complete();
        await r.settle(tester);
        expect(r.publisher.active, isFalse);
        expect(r.builds, 0);
      });
    });
  });

  group('foreground', () {
    testWidgets('the background switches it off and clears native', (
      tester,
    ) async {
      await withRig(tester, (r) async {
        r.controller.onStatus(BugseeStatus.launched);
        await r.settle(tester);
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.detached,
        ]) {
          r.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await r.settle(tester);
          expect(r.publisher.active, isTrue, reason: 'resumed');
          final before = r.sent.length;
          r.controller.didChangeAppLifecycleState(state);
          await r.settle(tester);
          expect(r.publisher.active, isFalse, reason: '$state');
          expect(r.sent.length, before + 1, reason: '$state clears');
          expect(r.sent.last.segments, isEmpty);
        }
      });
    });

    testWidgets('coming back publishes again', (tester) async {
      await withRig(tester, (r) async {
        r.controller.onStatus(BugseeStatus.launched);
        await r.settle(tester);
        r.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        await r.settle(tester);
        final before = r.sent.length;
        r.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await r.settle(tester);
        expect(r.publisher.active, isTrue);
        expect(r.sent.length, before + 1);
        expect(r.sent.last.segments, isNotEmpty);
      });
    });

    testWidgets(
      'inactive (a system dialog over a visible app) stays published',
      (tester) async {
        await withRig(tester, (r) async {
          r.controller.onStatus(BugseeStatus.launched);
          await r.settle(tester);
          r.controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
          await r.settle(tester);
          expect(r.publisher.active, isTrue);
        });
      },
    );

    testWidgets(
      'launched in the background publishes nothing until foreground',
      (tester) async {
        await withRig(tester, foreground: false, (r) async {
          r.controller.onStatus(BugseeStatus.launched);
          await r.settle(tester);
          expect(r.publisher.active, isFalse);
          expect(r.builds, 0);
          r.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await r.settle(tester);
          expect(r.publisher.active, isTrue);
        });
      },
    );
  });

  group('following the status', () {
    testWidgets('attach takes the current status, then the changes', (
      tester,
    ) async {
      await withRig(tester, (r) async {
        final changes = StreamController<BugseeStatus>.broadcast();
        addTearDown(changes.close);
        r.controller.attach(BugseeStatus.launched, changes.stream);
        await r.settle(tester);
        expect(r.publisher.active, isTrue);
        changes.add(BugseeStatus.stopped);
        await r.settle(tester);
        expect(r.publisher.active, isFalse);
        changes.add(BugseeStatus.launched);
        await r.settle(tester);
        expect(r.publisher.active, isTrue);
      });
    });

    testWidgets(
      'attaching again replaces the subscription, it does not double it',
      (tester) async {
        await withRig(tester, (r) async {
          final changes = StreamController<BugseeStatus>.broadcast();
          addTearDown(changes.close);
          r.controller.attach(null, changes.stream);
          r.controller.attach(null, changes.stream);
          expect(changes.hasListener, isTrue);
          changes.add(BugseeStatus.launched);
          await r.settle(tester);
          expect(r.reads, 1);
        });
      },
    );

    testWidgets('an unknown current status publishes nothing', (tester) async {
      await withRig(tester, (r) async {
        r.controller.attach(null, const Stream.empty());
        await r.settle(tester);
        expect(r.publisher.active, isFalse);
      });
    });
  });

  group('the SDKs option', () {
    test('is the key both SDKs register, a boolean that defaults to on', () {
      final spec = optionSpecForKey(viewHierarchyOptionKey);
      expect(spec, isNotNull, reason: 'in the generated registry');
      expect(spec!.type, OptionType.boolean);
      expect(spec.hidden, isFalse);
      expect(spec.android?.defaultValue, isTrue);
      expect(spec.ios?.defaultValue, isTrue);
    });
  });

  group('wired to the runtime', () {
    testWidgets('launch turns it on and stop turns it off', (tester) async {
      await tester.pumpWidget(const SizedBox());
      final host = FakeHost();
      final rig = Rig();
      final runtime = BugseeRuntime(host: host, viewHierarchy: rig.controller);
      await runtime.ensureStarted();
      expect(rig.publisher.active, isFalse);

      runtime.bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Launching'));
      runtime.bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Launched'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(rig.reads, 1);
      expect(rig.publisher.active, isTrue);
      expect(rig.sent, hasLength(1));

      runtime.bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Stopped'));
      await tester.pump(const Duration(milliseconds: 10));
      expect(rig.publisher.active, isFalse);
      expect(rig.sent.last.segments, isEmpty);

      await rig.publisher.deactivate();
      rig.publisher.dispose();
    });

    testWidgets(
      'an SDK that is already launched when Dart attaches is picked up',
      (tester) async {
        await tester.pumpWidget(const SizedBox());
        final rig = Rig();
        final runtime = BugseeRuntime(
          host: FakeHost(),
          viewHierarchy: rig.controller,
        );
        // Native replays the latest status to a new receiver: it is in the bridge before the
        // runtime looks, and no further event comes.
        runtime.bridge.onLifecycleEvent(
          LifecycleEventMessage(name: 'Launched'),
        );
        await runtime.ensureStarted();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));
        expect(rig.publisher.active, isTrue);
        await rig.publisher.deactivate();
        rig.publisher.dispose();
      },
    );

    testWidgets('the runtime attaches the gate once however often it is used', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final rig = Rig();
      final runtime = BugseeRuntime(
        host: FakeHost(),
        viewHierarchy: rig.controller,
      );
      await runtime.ensureStarted();
      await runtime.ensureStarted();
      await runtime.ensureStarted();
      runtime.bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Launched'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(rig.reads, 1, reason: 'one subscription, one option read');
      await rig.publisher.deactivate();
      rig.publisher.dispose();
    });

    testWidgets(
      'the real option read goes through launchOptions, hidden keys removed',
      (tester) async {
        await tester.pumpWidget(const SizedBox());
        final host = FakeHost()
          ..options = {viewHierarchyOptionKey: false, endpointOptionKey: 'x'};
        final runtime = BugseeRuntime(host: host);
        final read = (await runtime.launchOptions(
          hostOnly: false,
        ))[viewHierarchyOptionKey];
        expect(read, isFalse);
        expect(host.optionReads, 1);
      },
    );
  });
}
