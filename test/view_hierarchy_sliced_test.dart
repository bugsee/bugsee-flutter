// The sliced walk (issue #28): the same payload as the walk in one piece, a slice at a time, and
// what happens when the tree changes between two slices.
//
// The oracle is test/helpers/reference_hierarchy_builder.dart: the recursive, unsliced walker as it
// was before slicing, frozen. Every payload the sliced walk makes must equal what it makes, for the
// same tree, whatever the slice length, with caps carried across slices, with the skip of
// off-screen boxes on and off. A tree that changes between two slices is the publisher's contract
// (strict: a frame abandons the walk), tested through the publisher at the end.
import 'dart:async';

import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/secure/bugsee_secure_view.dart';
import 'package:bugsee_flutter/src/view_hierarchy/hierarchy_builder.dart';
import 'package:bugsee_flutter/src/view_hierarchy/publisher.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/reference_hierarchy_builder.dart' as ref;

class Marker extends StatelessWidget {
  const Marker({super.key, this.width = 10, this.height = 10, this.child});
  final double width;
  final double height;
  final Widget? child;
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: width, height: height, child: child);
}

Widget host(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

/// A slice timer that waits for the test to run it, so a test can look between two slices.
class HeldTimer implements Timer {
  HeldTimer(this.run);
  final void Function() run;
  bool cancelled = false;
  bool fired = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled && !fired;
  @override
  int get tick => 0;
}

/// A clock that moves one microsecond per read, so a slice ends after a number of reads and not
/// after a time the machine decides.
class TickClock {
  TickClock([this.tick = const Duration(microseconds: 1)]);
  final Duration tick;
  Duration _t = Duration.zero;
  int reads = 0;
  Duration call() {
    reads++;
    return _t += tick;
  }
}

const HierarchyLimits generous = HierarchyLimits(budget: Duration(hours: 1));

/// What the reference walker and the sliced one say about [limits], compared with every field.
void expectSame(
  HierarchySnapshot? actual,
  ref.HierarchySnapshot? expected, {
  String? reason,
}) {
  if (expected == null) {
    expect(actual, isNull, reason: reason);
    return;
  }
  expect(actual, isNotNull, reason: reason);
  expect(actual!.render(), expected.render(), reason: reason);
  expect(actual.bounds, expected.bounds, reason: reason);
  expect(actual.nodeCount, expected.nodeCount, reason: reason);
  expect(actual.truncated, expected.truncated, reason: reason);
  expect(actual.viewId, expected.viewId, reason: reason);
  expect(actual.devicePixelRatio, expected.devicePixelRatio, reason: reason);
}

/// Walks the current tree in slices of [slice] reads of a ticking clock and returns the result.
HierarchySnapshot? sliced(
  Duration slice, {
  HierarchyLimits limits = generous,
  bool skipContained = true,
  void Function(int step)? between,
  int? slices,
}) {
  final clock = TickClock();
  final HierarchyWalk? walk = HierarchyWalk.start(
    limits: limits,
    clock: clock.call,
    skipContained: skipContained,
  );
  if (walk == null) return null;
  var n = 0;
  while (!walk.step(slice)) {
    n++;
    between?.call(n);
    if (n > 100000) fail('the walk never finished');
  }
  if (slices != null) expect(n, greaterThanOrEqualTo(slices));
  return walk.result;
}

Widget screen(Widget Function(int i) row, {int rows = 40, bool eager = true}) =>
    host(
      MediaQuery(
        data: const MediaQueryData(size: Size(300, 400)),
        child: Column(
          children: [
            Expanded(
              child: eager
                  ? SingleChildScrollView(
                      child: Column(
                        children: [for (var i = 0; i < rows; i++) row(i)],
                      ),
                    )
                  : ListView.builder(
                      itemCount: rows,
                      itemBuilder: (_, i) => row(i),
                    ),
            ),
            const Marker(width: 20, height: 20),
          ],
        ),
      ),
    );

Widget row(int i) => Padding(
  padding: const EdgeInsets.all(2),
  child: Card(
    child: ListTile(
      leading: const Icon(Icons.star),
      title: Text('row $i'),
      trailing: Checkbox(value: i.isEven, onChanged: (_) {}),
    ),
  ),
);

Widget portal(OverlayPortalController controller) => MaterialApp(
  home: Stack(
    children: [
      OverlayPortal(
        controller: controller,
        overlayChildBuilder: (_) => const Align(
          alignment: Alignment.topLeft,
          child: Marker(width: 61, height: 10),
        ),
        child: const SizedBox(),
      ),
      const Align(
        alignment: Alignment.topLeft,
        child: Marker(width: 64, height: 10),
      ),
    ],
  ),
);

void main() {
  // Slice lengths in clock reads: from "yield at every chance" to "never".
  const slices = <Duration>[
    Duration(microseconds: 1),
    Duration(microseconds: 5),
    Duration(microseconds: 40),
    Duration(microseconds: 300),
    Duration(hours: 1),
  ];

  group('a sliced walk is the walk in one piece', () {
    Future<void> check(
      WidgetTester tester,
      Widget w, {
      HierarchyLimits limits = generous,
      ref.HierarchyLimits? refLimits,
    }) async {
      await tester.pumpWidget(w);
      final expected = ref.referenceBuildViewHierarchy(
        clock: () => Duration.zero,
        limits:
            refLimits ??
            ref.HierarchyLimits(
              maxNodes: limits.maxNodes,
              maxDepth: limits.maxDepth,
              maxBytes: limits.maxBytes,
              budget: limits.budget,
            ),
      );
      expect(expected, isNotNull);
      // One step, as buildViewHierarchy does it.
      expectSame(
        buildViewHierarchy(limits: limits, clock: TickClock().call),
        expected,
        reason: 'one piece',
      );
      for (final Duration slice in slices) {
        for (final bool skip in const [true, false]) {
          expectSame(
            sliced(slice, limits: limits, skipContained: skip),
            expected,
            reason: 'slice $slice, skipContained $skip',
          );
        }
      }
      // The smallest slice really is many slices (the test would prove nothing otherwise).
      sliced(slices.first, limits: limits, slices: 5);
    }

    testWidgets('a lazy Material list', (tester) async {
      await check(
        tester,
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [for (var i = 0; i < 30; i++) row(i)]),
          ),
        ),
      );
    });

    testWidgets('an eager list, most of it off screen', (tester) async {
      await check(tester, screen(row, rows: 120));
    });

    testWidgets('a lazy builder list', (tester) async {
      await check(tester, screen(row, rows: 200, eager: false));
    });

    testWidgets('a secure view is one node, and nothing below it', (
      tester,
    ) async {
      await check(
        tester,
        screen(
          (i) => i % 7 == 0
              ? const BugseeSecureView(child: Marker(width: 60, height: 20))
              : row(i),
          rows: 30,
        ),
      );
    });

    testWidgets('an OverlayPortal child is listed last in its overlay', (
      tester,
    ) async {
      final controller = OverlayPortalController();
      await tester.pumpWidget(portal(controller));
      controller.show();
      await tester.pump();
      final expected = ref.referenceBuildViewHierarchy(
        clock: () => Duration.zero,
      );
      for (final Duration slice in slices) {
        expectSame(sliced(slice), expected, reason: '$slice');
      }
    });

    testWidgets('transforms, clips, opacity, offstage, stacks', (tester) async {
      await check(
        tester,
        host(
          Stack(
            children: [
              Positioned(
                left: 10,
                top: 10,
                child: Transform.rotate(
                  angle: 0.3,
                  child: const Marker(width: 80, height: 40),
                ),
              ),
              Positioned(
                left: -500,
                top: 0,
                child: Transform.translate(
                  offset: const Offset(520, 20),
                  child: const Marker(width: 50, height: 50),
                ),
              ),
              const Positioned(
                left: 1000,
                top: 1000,
                child: Marker(width: 50, height: 50, child: Marker()),
              ),
              ClipRect(
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: OverflowBox(
                    maxWidth: 500,
                    child: Row(
                      children: [
                        for (var i = 0; i < 10; i++) const Marker(width: 30),
                      ],
                    ),
                  ),
                ),
              ),
              const Offstage(child: Marker()),
              const Opacity(opacity: 0, child: Marker(width: 9, height: 9)),
              Opacity(
                opacity: 0.5,
                child: IndexedStack(
                  index: 1,
                  children: const [Marker(width: 5), Marker(width: 6)],
                ),
              ),
            ],
          ),
        ),
      );
    });

    testWidgets('an off-screen box too large to scan in one go', (
      tester,
    ) async {
      // 2500 children inside one off-screen box: well over the scan limit, so the shortcut is
      // given up and the subtree is walked the ordinary way.
      final Widget tree = host(
        Stack(
          children: [
            const Marker(width: 40, height: 40),
            Positioned(
              left: 1000,
              top: 1000,
              child: SizedBox(
                width: 50,
                height: 50,
                child: Stack(
                  children: [
                    for (var i = 0; i < 2500; i++)
                      const Positioned(
                        left: 0,
                        top: 0,
                        width: 1,
                        height: 1,
                        child: Marker(width: 1, height: 1),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
      await check(tester, tree);
      // The slice length does not change the answer, near a cap either: the limit on the scan is a
      // count, not a time.
      for (final limits in const [
        HierarchyLimits(maxNodes: 9, budget: Duration(hours: 1)),
        HierarchyLimits(maxDepth: 3, budget: Duration(hours: 1)),
        HierarchyLimits(maxBytes: 2000, budget: Duration(hours: 1)),
      ]) {
        final one = buildViewHierarchy(limits: limits, clock: TickClock().call);
        for (final Duration slice in slices) {
          final HierarchySnapshot? got = sliced(slice, limits: limits);
          expect(got?.render(), one?.render(), reason: '$slice');
          expect(got?.truncated, one?.truncated, reason: '$slice');
        }
      }
    });

    testWidgets(
      'the scan limit is really taken: a big box is walked, a small one skipped',
      (tester) async {
        Widget tree(int n) => host(
          Stack(
            children: [
              const SizedBox(width: 40, height: 40),
              Positioned(
                left: 1000,
                top: 1000,
                child: SizedBox(
                  width: 50,
                  height: 50,
                  child: Stack(
                    children: [
                      for (var i = 0; i < n; i++)
                        const Positioned(
                          left: 0,
                          top: 0,
                          width: 1,
                          height: 1,
                          child: SizedBox(width: 1, height: 1),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
        // A depth cap that admits the off-screen anchor and cuts what is below it: when the contained
        // subtree is skipped nothing below is visited (not truncated); when the scan gives up
        // (above 2000 elements) it is walked the ordinary way and the cap cuts it.
        const limits = HierarchyLimits(maxDepth: 8, budget: Duration(hours: 1));
        for (final Duration slice in slices) {
          await tester.pumpWidget(tree(100));
          final small = sliced(slice, limits: limits);
          expect(small, isNotNull);
          expect(
            small!.truncated,
            isFalse,
            reason: 'small box skipped, $slice',
          );
          await tester.pumpWidget(tree(2500));
          final big = sliced(slice, limits: limits);
          expect(big, isNotNull);
          expect(big!.truncated, isTrue, reason: 'big box walked, $slice');
        }
      },
    );

    testWidgets('a deep tree', (tester) async {
      Widget deep(int n) => n == 0
          ? const Marker()
          : Padding(padding: const EdgeInsets.all(0.5), child: deep(n - 1));
      await check(tester, host(deep(150)));
    });

    testWidgets('caps are carried across slices: nodes, depth, bytes', (
      tester,
    ) async {
      await tester.pumpWidget(screen(row, rows: 150));
      for (final limits in const [
        HierarchyLimits(maxNodes: 40, budget: Duration(hours: 1)),
        HierarchyLimits(maxNodes: 7, budget: Duration(hours: 1)),
        HierarchyLimits(maxDepth: 12, budget: Duration(hours: 1)),
        HierarchyLimits(maxBytes: 9000, budget: Duration(hours: 1)),
        HierarchyLimits(maxBytes: 100, budget: Duration(hours: 1)),
      ]) {
        final expected = ref.referenceBuildViewHierarchy(
          clock: () => Duration.zero,
          limits: ref.HierarchyLimits(
            maxNodes: limits.maxNodes,
            maxDepth: limits.maxDepth,
            maxBytes: limits.maxBytes,
            budget: limits.budget,
          ),
        );
        for (final Duration slice in slices) {
          expectSame(
            sliced(slice, limits: limits),
            expected,
            reason:
                '${limits.maxNodes}/${limits.maxDepth}/${limits.maxBytes} $slice',
          );
        }
      }
      // And the caps really did cut something (truncation flags crossed the slices).
      expect(
        sliced(
          const Duration(microseconds: 5),
          limits: const HierarchyLimits(maxNodes: 40),
        )!.truncated,
        isTrue,
      );
    });

    testWidgets('the time budget counts the time IN slices, not between them', (
      tester,
    ) async {
      await tester.pumpWidget(screen(row, rows: 120));
      // A clock that jumps a day whenever a step ends and nothing else: the gaps between slices
      // must not be charged to the walk.
      var t = Duration.zero;
      var inStep = false;
      Duration clock() {
        if (!inStep) t += const Duration(days: 1);
        return t += const Duration(microseconds: 1);
      }

      final walk = HierarchyWalk.start(
        limits: const HierarchyLimits(budget: Duration(milliseconds: 50)),
        clock: clock,
      )!;
      var steps = 0;
      while (true) {
        inStep = true;
        final bool done = walk.step(const Duration(microseconds: 20));
        inStep = false;
        steps++;
        if (done) break;
        t += const Duration(days: 1); // the gap
      }
      expect(steps, greaterThan(3));
      expect(walk.result, isNotNull);
      expect(walk.result!.truncated, isFalse, reason: 'a gap is not walk time');
      // The same walk with a budget of the time it actually spent in slices is cut.
      final cut = sliced(
        const Duration(microseconds: 20),
        limits: const HierarchyLimits(budget: Duration(microseconds: 300)),
      )!;
      expect(cut.truncated, isTrue);
    });
  });

  group('a walk whose tree changed gives nothing', () {
    testWidgets('a level that was unmounted between two slices is invalid', (
      tester,
    ) async {
      await tester.pumpWidget(screen(row, rows: 40));
      final walk = HierarchyWalk.start(
        limits: generous,
        clock: TickClock().call,
      )!;
      expect(walk.step(const Duration(microseconds: 20)), isFalse);
      // The screen is replaced by one with other elements: what the walk holds is gone.
      await tester.pumpWidget(host(const Marker(width: 5)));
      expect(walk.step(const Duration(microseconds: 20)), isTrue);
      expect(walk.invalid, isTrue);
      expect(walk.result, isNull);
      expect(walk.step(null), isTrue, reason: 'finished stays finished');
    });

    testWidgets('a walk that is not disturbed is not invalid', (tester) async {
      await tester.pumpWidget(screen(row, rows: 10));
      final walk = HierarchyWalk.start(
        limits: generous,
        clock: TickClock().call,
      )!;
      while (!walk.step(const Duration(microseconds: 20))) {}
      expect(walk.invalid, isFalse);
      expect(walk.result, isNotNull);
    });

    testWidgets('an error in a step is no snapshot and never throws', (
      tester,
    ) async {
      await tester.pumpWidget(screen(row, rows: 10));
      var calls = 0;
      final walk = HierarchyWalk.start(
        limits: generous,
        clock: () {
          if (++calls > 12) throw StateError('boom');
          return Duration.zero;
        },
      )!;
      expect(() {
        while (!walk.step(const Duration(microseconds: 1))) {}
      }, returnsNormally);
      expect(walk.finished, isTrue);
      expect(walk.result, isNull);
    });
  });

  group('the publisher slices a walk after a quiet stretch', () {
    late List<ViewHierarchyMessage> sent;
    late ViewHierarchyPublisher publisher;
    late TickClock ticks;
    late List<SchedulerPhase> phases;
    late DateTime start;
    HierarchyWalk? lastWalk;
    bool pending = false;
    Completer<bool>? hold;
    final List<HeldTimer> held_ = [];

    /// Runs the next slice, if one is waiting (the timer the publisher would have had fire).
    bool runSlice() {
      while (held_.isNotEmpty) {
        final HeldTimer t = held_.removeAt(0);
        if (t.cancelled) continue;
        t.fired = true;
        t.run();
        return true;
      }
      return false;
    }

    Future<void> rig(
      WidgetTester tester, {
      Duration frameInterval = const Duration(microseconds: 16667),
      int maxAbandons = 3,
    }) async {
      sent = [];
      phases = [];
      pending = false;
      hold = null;
      held_.clear();
      lastWalk = null;
      start = tester.binding.clock.now();
      ticks = TickClock(const Duration(microseconds: 250));
      // The publisher's time is the test's; a walk's own clock ticks (and records where it runs), so
      // a slice ends after a number of reads, not after a time the machine decides.
      Duration clock() => tester.binding.clock.now().difference(start);
      Duration walkClock() {
        phases.add(SchedulerBinding.instance.schedulerPhase);
        return ticks.call();
      }

      publisher = ViewHierarchyPublisher(
        send: (m) async {
          sent.add(m);
          final Completer<bool>? h = hold;
          if (h != null) {
            hold = null;
            return h.future;
          }
          return true;
        },
        epoch: 3,
        busyGap: const Duration(milliseconds: 100),
        minInterval: const Duration(milliseconds: 300),
        frameInterval: () => frameInterval,
        framePending: () => pending,
        maxAbandons: maxAbandons,
        limits: generous,
        slicedBudget: const Duration(hours: 1),
        sliceScheduler: (run) {
          final t = HeldTimer(run);
          held_.add(t);
          return t;
        },
        clock: clock,
        walkStarter: (limits, now) =>
            lastWalk = HierarchyWalk.start(limits: limits, clock: walkClock),
      );
      addTearDown(publisher.dispose);
    }

    /// The payload of what native would hold now, or null.
    String? held() => sent.isEmpty
        ? null
        : HierarchySnapshot(
            viewId: sent.last.viewId,
            devicePixelRatio: sent.last.devicePixelRatio,
            segments: sent.last.segments.cast<String>(),
            bounds: sent.last.bounds.cast<double>(),
            nodeCount: sent.last.bounds.length ~/ 4,
            truncated: false,
          ).render();

    String? expectedNow() => buildViewHierarchy(
      limits: generous,
      clock: () => Duration.zero,
    )?.render();

    /// Brings the publisher to a state where it holds a snapshot of the first tree.
    Future<void> firstSnapshot(WidgetTester tester, Widget w) async {
      await tester.pumpWidget(w);
      publisher.activate();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(sent, hasLength(1), reason: 'the first snapshot is taken at once');
      expect(publisher.walking, isFalse);
      expect(
        lastWalk,
        isNull,
        reason: 'the first snapshot is in one piece: nothing is held yet',
      );
    }

    /// A change, then the quiet stretch: the walk that follows starts sliced.
    Future<void> changeAndGoQuiet(WidgetTester tester, Widget w) async {
      await tester.pumpWidget(w);
      // No frame from here: 100 ms of quiet arms the walk. `elapse` runs timers, draws nothing.
      await tester.binding.delayed(const Duration(milliseconds: 450));
    }

    testWidgets(
      'a walk runs in several slices, each from a timer, outside a frame',
      (tester) async {
        await rig(tester);
        await firstSnapshot(tester, screen(row, rows: 150));
        phases.clear();
        await changeAndGoQuiet(tester, screen(row, rows: 151));
        expect(
          publisher.walking,
          isTrue,
          reason: 'one slice did not finish it',
        );
        var slicesTaken = 1;
        while (publisher.walking) {
          expect(runSlice(), isTrue);
          slicesTaken++;
          if (slicesTaken > 5000) fail('never finished');
        }
        expect(slicesTaken, greaterThan(2));
        await tester.idle();
        expect(sent, hasLength(2));
        expect(
          held(),
          expectedNow(),
          reason: 'the payload is the unsliced one',
        );
        expect(
          phases.where(
            (p) =>
                p != SchedulerPhase.idle &&
                p != SchedulerPhase.postFrameCallbacks,
          ),
          isEmpty,
          reason: 'no slice ran inside a frame',
        );
      },
    );

    testWidgets(
      'a frame during the walk abandons it, and a mixed tree is never sent',
      (tester) async {
        await rig(tester);
        await firstSnapshot(tester, screen(row, rows: 150));
        await changeAndGoQuiet(tester, screen(row, rows: 151));
        expect(publisher.walking, isTrue);
        final int sentBefore = sent.length;
        // The tree changes under the walk: a frame draws it.
        await tester.pumpWidget(screen(row, rows: 9));
        expect(
          publisher.walking,
          isFalse,
          reason: 'the frame abandoned the walk',
        );
        expect(
          sent,
          hasLength(sentBefore),
          reason: 'nothing of the old walk is sent',
        );
        // After the next quiet stretch the walk starts over, on the new tree.
        await tester.binding.delayed(const Duration(milliseconds: 450));
        expect(publisher.walking, isTrue);
        for (var i = 0; publisher.walking && i < 10000; i++) {
          runSlice();
        }
        expect(publisher.walking, isFalse);
        await tester.idle();
        expect(sent, hasLength(sentBefore + 1));
        expect(held(), expectedNow(), reason: 'the new tree, whole');
      },
    );

    testWidgets('a frame that is due abandons the walk at its next slice', (
      tester,
    ) async {
      await rig(tester);
      await firstSnapshot(tester, screen(row, rows: 150));
      await changeAndGoQuiet(tester, screen(row, rows: 151));
      expect(publisher.walking, isTrue);
      pending = true; // an input arrived and a frame is scheduled
      runSlice();
      expect(publisher.walking, isFalse);
      pending = false;
    });

    testWidgets(
      'walks that frames keep abandoning give way to one in a piece',
      (tester) async {
        await rig(tester, maxAbandons: 2);
        await firstSnapshot(tester, screen(row, rows: 150));
        for (var round = 0; round < 2; round++) {
          await changeAndGoQuiet(tester, screen(row, rows: 61 + round));
          expect(publisher.walking, isTrue, reason: 'round $round is sliced');
          await tester.pump(); // a frame: abandoned
          expect(publisher.walking, isFalse);
        }
        final int before = sent.length;
        lastWalk = null;
        await tester.pumpWidget(screen(row, rows: 70));
        await tester.binding.delayed(const Duration(milliseconds: 450));
        expect(publisher.walking, isFalse, reason: 'taken in one piece');
        expect(lastWalk, isNull, reason: 'no sliced walk was started');
        await tester.idle();
        expect(sent, hasLength(before + 1), reason: 'and it landed');
        expect(held(), expectedNow());
        // A completed walk starts the count over: the next quiet walk is sliced again.
        await changeAndGoQuiet(tester, screen(row, rows: 71));
        expect(publisher.walking, isTrue);
      },
    );

    testWidgets('an explicit capture replaces the walk under way', (
      tester,
    ) async {
      await rig(tester);
      await firstSnapshot(tester, screen(row, rows: 150));
      await changeAndGoQuiet(tester, screen(row, rows: 151));
      expect(publisher.walking, isTrue);
      final Future<void> flushed = publisher.flush();
      await tester.pump(const Duration(milliseconds: 50));
      await flushed;
      expect(publisher.walking, isFalse);
      expect(held(), expectedNow());
    });

    testWidgets(
      'a send that fails drops the walk that would finish into its backoff',
      (tester) async {
        await rig(tester);
        await firstSnapshot(tester, screen(row, rows: 150));
        // A send that is still in flight when the next walk starts...
        final inFlight = Completer<bool>();
        hold = inFlight;
        await changeAndGoQuiet(tester, screen(row, rows: 151));
        for (var i = 0; publisher.walking && i < 10000; i++) {
          runSlice();
        }
        await tester.idle();
        expect(sent, hasLength(2), reason: 'the second snapshot is on its way');
        await tester.pumpWidget(screen(row, rows: 152));
        await tester.binding.delayed(const Duration(seconds: 6));
        expect(
          publisher.walking,
          isTrue,
          reason: 'a sliced walk, send in flight',
        );
        // ...fails: the walk must not finish and send before the backoff ends.
        inFlight.completeError(StateError("channel"));
        await tester.idle();
        expect(publisher.walking, isFalse, reason: 'dropped with the failure');
        expect(sent, hasLength(2), reason: 'nothing was sent into the backoff');
        // The retry is the next walk, in one piece, when the backoff is over.
        await tester.binding.delayed(const Duration(seconds: 2));
        await tester.idle();
        expect(sent, hasLength(3));
        expect(
          held(),
          expectedNow(),
          reason: 'the retry carries the current tree',
        );
      },
    );

    testWidgets('stopping drops the walk and sends none of it', (tester) async {
      await rig(tester);
      await firstSnapshot(tester, screen(row, rows: 150));
      await changeAndGoQuiet(tester, screen(row, rows: 151));
      expect(publisher.walking, isTrue);
      await publisher.deactivate();
      expect(publisher.walking, isFalse);
      await tester.idle();
      expect(sent.last.segments, isEmpty, reason: 'native was told to clear');
      expect(publisher.walking, isFalse);
    });
  });

  group('the slice follows the display', () {
    for (final (double hz, int micros) in const [
      (30.0, 4000),
      (60.0, 2000),
      (90.0, 1333),
      (120.0, 1000),
      (240.0, 1000),
    ]) {
      test('${hz.toInt()} Hz', () {
        final p = ViewHierarchyPublisher(
          send: (_) async => true,
          frameInterval: () => Duration(microseconds: (1e6 / hz).round()),
        );
        addTearDown(p.dispose);
        expect(p.sliceLengthForTest.inMicroseconds, closeTo(micros, 20));
      });
    }
  });
}
