// Frame timing of the view-hierarchy walk in one piece against the same walk in slices (issue #28).
// A measurement, not a pass/fail test: it prints `BENCH ...` lines. Run it on a device in a PROFILE
// build (a debug build is several times slower and says nothing about frames):
//
//   cd example && flutter drive --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/view_hierarchy_slicing_timing_test.dart -d <device>
//
// It needs no native SDK: the publisher sends to a fake. Per scenario (a lazy list, an eager
// 1000-row list) and round, three modes run in turn, with the publisher doing real walks in all:
//
//   one-piece-12ms  what shipped before slicing: one piece, the 12 ms budget (cuts the eager list)
//   one-piece-100ms one piece with the sliced walk's 100 ms budget: the same work as the slices
//   sliced          the sliced walk (the defaults)
//
// Each cycle scrolls the list, waits for the publisher's next walk, and at the moment the walk starts
// schedules an "input" 1 ms later (a scroll jump, which draws a frame). How late that timer runs is
// how long the walk held the isolate's event loop: the delay an input would have had. Frames are
// the engine's FrameTiming (vsync to vsync interval, build + raster span) over the whole trial.
import 'dart:async';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/view_hierarchy/hierarchy_builder.dart';
import 'package:bugsee_flutter/src/view_hierarchy/publisher.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

void say(String line) => debugPrint('BENCH $line');

Widget row(int i) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
  child: Card(
    margin: EdgeInsets.zero,
    child: ListTile(
      dense: true,
      leading: const Icon(Icons.star),
      title: Text('row $i'),
      subtitle: Text('detail $i'),
      trailing: Checkbox(value: i.isEven, onChanged: (_) {}),
    ),
  ),
);

Widget lazy(ScrollController c) => MaterialApp(
  home: Scaffold(
    body: ListView.builder(
      controller: c,
      itemCount: 3000,
      itemBuilder: (_, i) => row(i),
    ),
  ),
);

Widget eager(ScrollController c) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      controller: c,
      child: Column(children: [for (var i = 0; i < 1000; i++) row(i)]),
    ),
  ),
);

double pct(List<num> v, double p) {
  if (v.isEmpty) return double.nan;
  final s = [...v]..sort();
  return s[((s.length - 1) * p).round()].toDouble();
}

String f(double d) => d.isNaN ? 'n/a' : d.toStringAsFixed(1);

class Trial {
  final List<double> lateMs = [];
  final List<double> vsyncMs = [];
  final List<double> spanMs = [];
  int walks = 0;
  int sent = 0;
  int nodes = 0;
  double walkMs = 0;
  double frameMs = 16.7;
}

enum Mode { onePiece12, onePiece100, sliced }

Future<Trial> trial(
  WidgetTester tester,
  Widget Function(ScrollController) screen,
  Mode mode,
) async {
  final c = ScrollController();
  await tester.pumpWidget(screen(c));
  await tester.pump(const Duration(milliseconds: 300));
  final t = Trial();
  final watch = Stopwatch()..start();
  bool armed = false;
  var dir = 1.0;

  void input() {
    // The "input": a scroll jump, which draws a frame.
    final due = Duration(milliseconds: 1);
    final scheduledAt = watch.elapsed;
    Timer(due, () {
      t.lateMs.add((watch.elapsed - scheduledAt - due).inMicroseconds / 1000);
      dir = -dir;
      if (c.hasClients) {
        c.jumpTo((c.offset + 37 * dir).clamp(0.0, c.position.maxScrollExtent));
      }
    });
  }

  void onWalkStart() {
    t.walks++;
    if (armed) {
      armed = false;
      input();
    }
  }

  const big = HierarchyLimits(budget: Duration(milliseconds: 100));
  final HierarchyLimits limits = mode == Mode.onePiece12
      ? const HierarchyLimits()
      : big;
  final publisher = ViewHierarchyPublisher(
    send: (ViewHierarchyMessage m) async {
      t.sent++;
      t.nodes = m.bounds.length ~/ 4;
      return true;
    },
    epoch: 1,
    limits: limits,
    builder: mode == Mode.sliced
        ? null
        : (l, now) {
            onWalkStart();
            final s = Stopwatch()..start();
            final r = buildViewHierarchy(limits: l, clock: now);
            t.walkMs += s.elapsedMicroseconds / 1000;
            return r;
          },
    walkStarter: mode == Mode.sliced
        ? (l, now) {
            onWalkStart();
            return HierarchyWalk.start(limits: l, clock: now);
          }
        : null,
  );
  final List<FrameTiming> frames = [];
  void onTimings(List<FrameTiming> ts) => frames.addAll(ts);
  SchedulerBinding.instance.addTimingsCallback(onTimings);
  publisher.activate();
  await Future<void>.delayed(
    const Duration(seconds: 2),
  ); // first snapshot, settle

  for (var cycle = 0; cycle < 14; cycle++) {
    armed = true;
    // A scroll: a few hundred milliseconds of frames.
    if (c.hasClients) {
      final target = (c.offset + 700).clamp(0, c.position.maxScrollExtent);
      unawaited(
        c.animateTo(
          target.toDouble(),
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
        ),
      );
    }
    // Until the next walk has started and the input after it has drawn its frame, at most 4 s.
    final until = watch.elapsed + const Duration(seconds: 4);
    while (armed && watch.elapsed < until) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (c.hasClients && c.offset > c.position.maxScrollExtent - 800) {
      c.jumpTo(0);
    }
  }
  await Future<void>.delayed(const Duration(seconds: 1));
  await publisher.deactivate();
  publisher.dispose();
  SchedulerBinding.instance.removeTimingsCallback(onTimings);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  frames.sort(
    (a, b) => a
        .timestampInMicroseconds(FramePhase.vsyncStart)
        .compareTo(b.timestampInMicroseconds(FramePhase.vsyncStart)),
  );
  for (var i = 0; i < frames.length; i++) {
    t.spanMs.add(frames[i].totalSpan.inMicroseconds / 1000);
    if (i > 0) {
      t.vsyncMs.add(
        (frames[i].timestampInMicroseconds(FramePhase.vsyncStart) -
                frames[i - 1].timestampInMicroseconds(FramePhase.vsyncStart)) /
            1000,
      );
    }
  }
  return t;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('view hierarchy slicing, frame timing', (tester) async {
    final refresh = tester.view.display.refreshRate;
    say(
      'device refresh ${refresh.toStringAsFixed(1)} Hz, ratio ${tester.view.devicePixelRatio}',
    );
    // What one walk costs here, in one piece, and how many nodes it describes.
    for (final (String name, Widget Function(ScrollController) screen) in [
      ('lazy', lazy),
      ('eager', eager),
    ]) {
      await tester.pumpWidget(screen(ScrollController()));
      await tester.pump(const Duration(milliseconds: 300));
      final w = <double>[];
      var nodes = 0, truncated = false;
      for (var i = 0; i < 25; i++) {
        final s = Stopwatch()..start();
        final r = buildViewHierarchy(
          limits: const HierarchyLimits(budget: Duration(seconds: 1)),
        );
        w.add(s.elapsedMicroseconds / 1000);
        nodes = r?.nodeCount ?? 0;
        truncated = r?.truncated ?? false;
      }
      say(
        '$name: one walk in one piece median ${f(pct(w, .5))} ms, $nodes nodes, truncated=$truncated',
      );
    }

    for (var round = 0; round < 3; round++) {
      for (final (String name, Widget Function(ScrollController) screen) in [
        ('lazy', lazy),
        ('eager', eager),
      ]) {
        for (final mode in Mode.values) {
          final t = await trial(tester, screen, mode);
          say(
            'round=$round scenario=$name mode=${mode.name} walks=${t.walks} sent=${t.sent} nodes=${t.nodes} '
            'inputs=${t.lateMs.length} late_ms p50=${f(pct(t.lateMs, .5))} p90=${f(pct(t.lateMs, .9))} max=${f(pct(t.lateMs, 1))} '
            'frames=${t.spanMs.length} vsync_ms p50=${f(pct(t.vsyncMs, .5))} p99=${f(pct(t.vsyncMs, .99))} max=${f(pct(t.vsyncMs, 1))} '
            'span_ms p50=${f(pct(t.spanMs, .5))} p99=${f(pct(t.spanMs, .99))} max=${f(pct(t.spanMs, 1))} '
            'slow_vsync(>${(1.5 * 1000 / refresh).toStringAsFixed(1)}ms)=${t.vsyncMs.where((v) => v > 1.5 * 1000 / refresh).length} '
            'lateRaw=${t.lateMs.map((v) => v.toStringAsFixed(1)).join(",")}',
          );
        }
      }
    }
    say('done');
  }, timeout: const Timeout(Duration(minutes: 40)));
}
