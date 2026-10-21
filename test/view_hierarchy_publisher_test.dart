// When the managed view hierarchy is built and sent: throttling, cost, change detection, the
// gate, failures. The tree itself is faked here (view_hierarchy_test.dart has the real one); time
// is the test binding's fake clock plus the cost a fake build claims to have had.
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/view_hierarchy/hierarchy_builder.dart';
import 'package:bugsee_flutter/src/view_hierarchy/publisher.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

HierarchySnapshot fake(String tag, {double ratio = 3}) => HierarchySnapshot(
  viewId: 0,
  devicePixelRatio: ratio,
  segments: [tag, ''],
  bounds: const [],
  nodeCount: 1,
  truncated: false,
);

const Duration ms = Duration(milliseconds: 1);

class Rig {
  Rig(
    this.tester, {
    Duration minInterval = const Duration(milliseconds: 300),
    Duration maxInterval = const Duration(seconds: 5),
  }) {
    _start = tester.binding.clock.now();
    publisher = ViewHierarchyPublisher(
      send: _send,
      epoch: 7,
      minInterval: minInterval,
      maxInterval: maxInterval,
      clock: () => tester.binding.clock.now().difference(_start) + _cost,
      builder: (limits, now) {
        builds++;
        phases.add(SchedulerBinding.instance.schedulerPhase);
        _cost += buildCost;
        if (throwOnBuild) throw StateError('boom');
        return result;
      },
    );
  }

  final WidgetTester tester;
  late final DateTime _start;
  late final ViewHierarchyPublisher publisher;
  final List<ViewHierarchyMessage> sent = [];
  final List<SchedulerPhase> phases = [];
  int builds = 0;
  int failSends = 0;
  bool throwOnBuild = false;
  Duration buildCost = Duration.zero;
  Duration _cost = Duration.zero;
  HierarchySnapshot? result = fake('A');

  Future<bool> _send(ViewHierarchyMessage m) async {
    sent.add(m);
    if (failSends > 0) {
      failSends--;
      throw PlatformException(code: 'channel-error');
    }
    return true;
  }

  /// One frame, `by` later. A frame is only made when something schedules one (the test binding
  /// does not make idle frames), as a change on a real screen does.
  Future<void> frame([Duration by = Duration.zero]) {
    tester.binding.scheduleFrame();
    return tester.pump(by);
  }

  List<String> get tags => [for (final m in sent) m.segments.join()];
}

/// A test with a rig; the publisher is shut down at the end (a pending timer fails a widget test).
void rigTest(String name, Future<void> Function(WidgetTester, Rig) body) {
  testWidgets(name, (tester) async {
    await tester.pumpWidget(const SizedBox());
    final r = Rig(tester);
    await body(tester, r);
    await r.publisher.deactivate();
    r.publisher.dispose();
  });
}

void main() {
  group('only while active', () {
    rigTest('nothing is built or sent before it is activated', (
      tester,
      r,
    ) async {
      await r.frame();
      await r.frame(const Duration(seconds: 2));
      expect(r.builds, 0);
      expect(r.sent, isEmpty);
      expect(r.publisher.active, isFalse);
    });

    rigTest('activating takes the first snapshot on the next frame', (
      tester,
      r,
    ) async {
      r.publisher.activate();
      expect(r.builds, 0, reason: 'not inside the call');
      await r.frame();
      expect(r.builds, 1);
      expect(r.sent, hasLength(1));
      final m = r.sent.single;
      expect(m.epoch, 7);
      expect(m.sequence, 1);
      expect(m.viewId, 0);
      expect(m.devicePixelRatio, 3);
      expect(m.segments, ['A', '']);
      expect(m.bounds, isEmpty);
    });

    rigTest('deactivating stops the building', (tester, r) async {
      r.publisher.activate();
      await r.frame();
      await r.publisher.deactivate();
      final before = r.builds;
      await r.frame(const Duration(seconds: 1));
      await r.frame(const Duration(seconds: 1));
      expect(r.builds, before);
      expect(r.publisher.active, isFalse);
    });

    rigTest('deactivating clears what native holds, once', (tester, r) async {
      r.publisher.activate();
      await r.frame();
      expect(r.sent, hasLength(1));
      await r.publisher.deactivate();
      expect(r.sent, hasLength(2));
      expect(r.sent.last.segments, isEmpty, reason: 'empty segments clear');
      expect(r.sent.last.sequence, 2);
      await r.publisher.deactivate();
      expect(r.sent, hasLength(2), reason: 'nothing left to clear');
    });

    rigTest('deactivating when nothing was ever sent sends nothing', (
      tester,
      r,
    ) async {
      await r.publisher.deactivate();
      r.publisher.activate();
      await r.publisher.deactivate();
      await r.frame();
      expect(r.sent, isEmpty);
    });

    rigTest('after a deactivation the same tree is sent again', (
      tester,
      r,
    ) async {
      r.publisher.activate();
      await r.frame();
      await r.publisher.deactivate();
      r.publisher.activate();
      await r.frame();
      expect(r.tags, ['A', '', 'A']);
      expect(r.sent.last.sequence, 3);
    });
  });

  group('change detection', () {
    rigTest('a frame that changed nothing sends nothing', (tester, r) async {
      r.publisher.activate();
      await r.frame();
      for (var i = 0; i < 5; i++) {
        await r.frame(const Duration(milliseconds: 400));
      }
      expect(r.builds, greaterThan(1), reason: 'it did look');
      expect(r.sent, hasLength(1));
    });

    rigTest('a changed tree is sent, in order', (tester, r) async {
      r.publisher.activate();
      await r.frame();
      r.result = fake('B');
      await r.frame(const Duration(milliseconds: 400));
      r.result = fake('C');
      await r.frame(const Duration(milliseconds: 400));
      expect(r.tags, ['A', 'B', 'C']);
      expect([for (final m in r.sent) m.sequence], [1, 2, 3]);
      expect({for (final m in r.sent) m.epoch}, {7});
    });

    rigTest('a change of device pixel ratio alone is a change', (
      tester,
      r,
    ) async {
      r.publisher.activate();
      await r.frame();
      r.result = fake('A', ratio: 2);
      await r.frame(const Duration(milliseconds: 400));
      expect(r.sent, hasLength(2));
      expect(r.sent.last.devicePixelRatio, 2);
    });
  });

  group('throttle', () {
    rigTest('frames inside the interval cause one trailing build', (
      tester,
      r,
    ) async {
      r.publisher.activate();
      await r.frame();
      expect(r.builds, 1);
      // A burst: a frame every 20 ms for 200 ms, the tree changing throughout.
      for (var i = 0; i < 10; i++) {
        r.result = fake('burst$i');
        await r.frame(const Duration(milliseconds: 20));
      }
      expect(
        r.builds,
        1,
        reason: 'inside the 300 ms interval: nothing built yet',
      );
      // The trailing build lands once the interval has passed, with the LATEST tree.
      await r.frame(const Duration(milliseconds: 150));
      expect(r.builds, 2);
      expect(r.tags.last, 'burst9');
    });

    rigTest('never more than one build per interval, however many frames', (
      tester,
      r,
    ) async {
      r.publisher.activate();
      await r.frame();
      // 60 frames of 16 ms is about a second.
      for (var i = 0; i < 60; i++) {
        r.result = fake('t$i');
        await r.frame(const Duration(milliseconds: 16));
      }
      // 960 ms with a 300 ms interval: the first, plus at most three more.
      expect(r.builds, inInclusiveRange(2, 4));
    });

    rigTest('a build is never made inside a frame', (tester, r) async {
      r.publisher.activate();
      await r.frame();
      for (var i = 0; i < 10; i++) {
        r.result = fake('p$i');
        await r.frame(const Duration(milliseconds: 100));
      }
      expect(r.phases, isNotEmpty);
      // Not while the framework builds, lays out or paints: after the frame, or between frames.
      expect(
        r.phases.toSet().difference({
          SchedulerPhase.postFrameCallbacks,
          SchedulerPhase.idle,
        }),
        isEmpty,
        reason: 'built in ${r.phases.toSet()}',
      );
    });

    rigTest('an idle app costs nothing: no frame is ever scheduled by it', (
      tester,
      r,
    ) async {
      r.publisher.activate();
      await r.frame();
      expect(tester.binding.hasScheduledFrame, isFalse);
      final builds = r.builds;
      // Time passes with no frame at all: a timer must not wake the publisher into building.
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      expect(r.builds, builds, reason: 'no frame, no build');
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('trailing build', () {
    rigTest(
      'a throttled change is built by a timer when no further frame comes',
      (tester, r) async {
        r.publisher.activate();
        await r.frame();
        expect(r.builds, 1);
        r.result = fake('late');
        await r.frame(
          const Duration(milliseconds: 100),
        ); // throttled: arms the timer
        expect(r.builds, 1);
        // No frame from here on, only time.
        await tester.pump(const Duration(milliseconds: 400));
        expect(r.builds, 2);
        expect(r.tags.last, 'late');
      },
    );
  });

  group('cost', () {
    rigTest('a slow build spaces the next ones out by 20 times its cost', (
      tester,
      r,
    ) async {
      r.buildCost = const Duration(milliseconds: 50); // x20 = 1 s
      r.publisher.activate();
      await r.frame();
      expect(r.builds, 1);
      r.result = fake('B');
      await r.frame(const Duration(milliseconds: 400));
      expect(r.builds, 1, reason: '400 ms later: still inside 1 s');
      await r.frame(const Duration(milliseconds: 400));
      expect(r.builds, 1, reason: '800 ms later');
      await r.frame(const Duration(milliseconds: 400));
      expect(r.builds, 2, reason: '1.2 s later');
      expect(r.tags.last, 'B');
    });

    rigTest('a cheap build keeps the minimum interval', (tester, r) async {
      r.buildCost = const Duration(milliseconds: 1); // x20 = 20 ms < 300 ms
      r.publisher.activate();
      await r.frame();
      r.result = fake('B');
      await r.frame(const Duration(milliseconds: 310));
      expect(r.builds, 2);
    });

    rigTest('the spacing is capped', (tester, r) async {
      r.buildCost = const Duration(seconds: 2); // x20 = 40 s, capped at 5 s
      r.publisher.activate();
      await r.frame();
      r.result = fake('B');
      await r.frame(const Duration(seconds: 4));
      expect(r.builds, 1);
      await r.frame(const Duration(seconds: 2));
      expect(r.builds, 2);
    });
  });

  group('failures never reach the app', () {
    rigTest('a builder that throws sends nothing as a hierarchy', (
      tester,
      r,
    ) async {
      r.throwOnBuild = true;
      r.publisher.activate();
      await r.frame();
      await r.frame(const Duration(seconds: 1));
      expect(r.builds, greaterThan(0));
      expect(r.sent, isEmpty);
    });

    rigTest('a builder that stops working takes back what native held', (
      tester,
      r,
    ) async {
      r.publisher.activate();
      await r.frame();
      expect(r.sent, hasLength(1));
      r.throwOnBuild = true;
      await r.frame(const Duration(seconds: 1));
      expect(r.sent, hasLength(2));
      expect(r.sent.last.segments, isEmpty);
      await r.frame(const Duration(seconds: 1));
      expect(r.sent, hasLength(2), reason: 'cleared once, not every frame');
    });

    rigTest('no snapshot (no view) is the same as an error', (tester, r) async {
      r.publisher.activate();
      await r.frame();
      r.result = null;
      await r.frame(const Duration(seconds: 1));
      expect(r.sent.last.segments, isEmpty);
    });

    rigTest('a send that fails is retried with a growing delay, never flooding', (
      tester,
      r,
    ) async {
      r.failSends = 1 << 30; // down for good
      r.publisher.activate();
      await r.frame();
      // Frames every 16 ms for 5 s, as an animation would.
      for (var i = 0; i < 300; i++) {
        await r.frame(const Duration(milliseconds: 16));
      }
      // 300 ms, 600 ms, 1.2 s, 2.4 s, ...: a handful, not one per frame.
      expect(r.sent.length, lessThan(10));
      expect(r.sent.length, greaterThan(2));
      // And it never gives up: a minute later it is still trying, at most every 30 s.
      final at5s = r.sent.length;
      await tester.pump(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 60));
      expect(r.sent.length, greaterThan(at5s));
      expect(r.sent.length - at5s, lessThan(8));
    });

    rigTest('after a failed send the next success resends the same tree', (
      tester,
      r,
    ) async {
      r.failSends = 1;
      r.publisher.activate();
      await r.frame();
      expect(r.sent, hasLength(1));
      // No new frame: the retry comes from the backoff timer.
      await tester.pump(const Duration(seconds: 1));
      expect(r.sent.length, greaterThanOrEqualTo(2));
      expect(r.tags.last, 'A');
      // And now that it landed, nothing more is sent for the same tree.
      final n = r.sent.length;
      await r.frame(const Duration(seconds: 1));
      await r.frame(const Duration(seconds: 1));
      expect(r.sent.length, n);
    });

    rigTest('a clear that failed is retried even though it is empty', (
      tester,
      r,
    ) async {
      r.publisher.activate();
      await r.frame();
      r.failSends = 2;
      await r.publisher.deactivate();
      expect(r.sent, hasLength(2));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 2));
      expect(r.sent.length, greaterThanOrEqualTo(3));
      expect(r.sent.last.segments, isEmpty);
      final n = r.sent.length;
      await tester.pump(const Duration(seconds: 60));
      expect(r.sent.length, n, reason: 'stops once the clear landed');
    });

    rigTest('sequences only ever grow, one per message', (tester, r) async {
      r.failSends = 2;
      r.publisher.activate();
      await r.frame();
      r.result = fake('B');
      await r.frame(const Duration(seconds: 1));
      await r.frame(const Duration(seconds: 3));
      final seq = [for (final m in r.sent) m.sequence];
      expect(seq, [for (var i = 1; i <= seq.length; i++) i]);
    });
  });

  group('flush', () {
    rigTest('builds now, inside the throttle, and completes when sent', (
      tester,
      r,
    ) async {
      r.publisher.activate();
      await r.frame();
      r.result = fake('B');
      expect(r.builds, 1);
      await r.publisher.flush();
      expect(r.builds, 2);
      expect(r.tags.last, 'B');
    });

    rigTest('does nothing while not active', (tester, r) async {
      await r.publisher.flush();
      expect(r.builds, 0);
      expect(r.sent, isEmpty);
    });
  });
}
