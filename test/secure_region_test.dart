// Secure regions (workbook Part 5, Dart side): what is measured, when it is
// published, and that every ambiguous case covers more, never less.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data' show ByteData;

import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/secure/secure_region.dart';
// `cacheExtent` is deprecated on stable, but the floor (3.41.0) has no
// `scrollCacheExtent` yet.
// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

/// Stands in for native: records every message, optionally failing.
class Recorder {
  final List<SecureRectanglesMessage> sent = [];
  final List<Completer<bool>> pending = [];
  int failNext = 0;
  bool hold = false;

  Future<bool> call(SecureRectanglesMessage m) {
    sent.add(m);
    if (failNext > 0) {
      failNext--;
      return Future<bool>.error(PlatformException(code: 'channel-error'));
    }
    if (hold) {
      final c = Completer<bool>();
      pending.add(c);
      return c.future;
    }
    return Future<bool>.value(true);
  }

  /// The latest message as `{viewId: [l, t, r, b, ...]}`.
  Map<int, List<double>> get latest => {
    for (final v in sent.last.views) v.viewId: v.rectangles,
  };
}

SecureRegionRegistry registryFor(Recorder r, {Duration? retry}) =>
    SecureRegionRegistry(publish: r.call, epoch: 7, retryDelay: retry);

Widget app(SecureRegionRegistry registry, Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

Widget region(
  SecureRegionRegistry registry, {
  double w = 100,
  double h = 50,
  bool enabled = true,
}) => BugseeSecureRegion(
  registry: registry,
  enabled: enabled,
  child: SizedBox(width: w, height: h),
);

/// Places a [w] x [h] region at ([x], [y]) in the view.
Widget at(
  SecureRegionRegistry registry,
  double x,
  double y, {
  double w = 100,
  double h = 50,
}) => Stack(
  children: [
    Positioned(
      left: x,
      top: y,
      child: region(registry, w: w, h: h),
    ),
  ],
);

void main() {
  late Recorder native;
  late SecureRegionRegistry registry;

  setUp(() {
    native = Recorder();
    registry = registryFor(native);
  });
  tearDown(() => registry.dispose());

  group('what is published', () {
    testWidgets('a region is published in logical pixels, once', (
      tester,
    ) async {
      await tester.pumpWidget(app(registry, at(registry, 10, 20)));
      expect(native.sent, hasLength(1));
      expect(native.sent.single.epoch, 7);
      expect(native.sent.single.sequence, 1);
      expect(native.latest, {
        0: [10.0, 20.0, 110.0, 70.0],
      });
    });

    testWidgets('the device pixel ratio does not change the logical rect', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(registry, at(registry, 10.5, 20.25)));
      expect(native.latest, {
        0: [10.5, 20.25, 110.5, 70.25],
      });
    });

    testWidgets('several regions are sent together, in a canonical order', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          registry,
          Stack(
            children: [
              Positioned(left: 200, top: 0, child: region(registry)),
              Positioned(left: 0, top: 100, child: region(registry)),
              Positioned(left: 0, top: 0, child: region(registry)),
            ],
          ),
        ),
      );
      expect(native.sent, hasLength(1));
      expect(native.latest[0], [
        0, 0, 100, 50, //
        0, 100, 100, 150, //
        200, 0, 300, 50,
      ]);
    });

    testWidgets('a zero-area region is not published', (tester) async {
      await tester.pumpWidget(
        app(registry, Stack(children: [region(registry, w: 0, h: 50)])),
      );
      expect(native.sent, isEmpty);
    });
  });

  group('coalescing and no-ops', () {
    testWidgets('many changes inside one frame are one publish', (
      tester,
    ) async {
      final x = ValueNotifier<double>(0);
      await tester.pumpWidget(
        app(
          registry,
          ValueListenableBuilder<double>(
            valueListenable: x,
            builder: (_, v, _) => Stack(
              children: [
                Positioned(left: v, top: 0, child: region(registry)),
                Positioned(left: 0, top: v, child: region(registry)),
              ],
            ),
          ),
        ),
      );
      expect(native.sent, hasLength(1));
      x.value = 5;
      x.value = 6;
      x.value = 7;
      await tester.pump();
      expect(native.sent, hasLength(2));
      expect(native.latest[0], [0, 7, 100, 57, 7, 0, 107, 50]);
    });

    testWidgets('frames that change nothing publish nothing', (tester) async {
      await tester.pumpWidget(app(registry, at(registry, 10, 20)));
      expect(native.sent, hasLength(1));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // A rebuild with an equal tree, and a relayout, are not changes either.
      await tester.pumpWidget(app(registry, at(registry, 10, 20)));
      await tester.pumpWidget(app(registry, at(registry, 10, 20)));
      expect(native.sent, hasLength(1));
    });

    testWidgets('reordering regions is not a change', (tester) async {
      Widget two(bool flip) => Stack(
        children: [
          Positioned(
            key: ValueKey(flip ? 'b' : 'a'),
            left: 0,
            top: 0,
            child: region(registry),
          ),
          Positioned(
            key: ValueKey(flip ? 'a' : 'b'),
            left: 200,
            top: 0,
            child: region(registry),
          ),
        ],
      );
      await tester.pumpWidget(app(registry, two(false)));
      await tester.pumpWidget(app(registry, two(true)));
      expect(native.sent, hasLength(1));
    });

    testWidgets('a real change is published with a larger sequence', (
      tester,
    ) async {
      await tester.pumpWidget(app(registry, at(registry, 10, 20)));
      await tester.pumpWidget(app(registry, at(registry, 11, 20)));
      expect(native.sent.map((m) => m.sequence), [1, 2]);
      expect(native.latest[0], [11, 20, 111, 70]);
    });

    testWidgets('a changed size is a change', (tester) async {
      await tester.pumpWidget(app(registry, at(registry, 10, 20)));
      await tester.pumpWidget(app(registry, at(registry, 10, 20, w: 101)));
      expect(native.sent, hasLength(2));
      expect(native.latest[0], [10, 20, 111, 70]);
    });
  });

  group('transforms', () {
    testWidgets('Transform.translate moves the rect', (tester) async {
      await tester.pumpWidget(
        app(
          registry,
          Align(
            alignment: Alignment.topLeft,
            child: Transform.translate(
              offset: const Offset(30, 40),
              child: region(registry),
            ),
          ),
        ),
      );
      expect(native.latest[0], [30, 40, 130, 90]);
    });

    testWidgets('Transform.scale reports the scaled box', (tester) async {
      await tester.pumpWidget(
        app(
          registry,
          Align(
            alignment: Alignment.topLeft,
            child: Transform.scale(
              scale: 2,
              alignment: Alignment.topLeft,
              child: region(registry),
            ),
          ),
        ),
      );
      expect(native.latest[0], [0, 0, 200, 100]);
    });

    testWidgets('a rotated region is reported as its bounding box (larger)', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          registry,
          Align(
            alignment: Alignment.topLeft,
            child: Transform.rotate(
              angle: math.pi / 4,
              child: region(registry, w: 100, h: 100),
            ),
          ),
        ),
      );
      final r = native.latest[0]!;
      // The 100x100 box rotated 45 degrees about its centre (50, 50): its
      // bounding box is 141.42 wide, centred on the same point.
      final half = 50 * math.sqrt2;
      expect(r[0], closeTo(50 - half, 1e-9));
      expect(r[1], closeTo(50 - half, 1e-9));
      expect(r[2], closeTo(50 + half, 1e-9));
      expect(r[3], closeTo(50 + half, 1e-9));
      // Never less than the region itself.
      expect(r[0] <= 0 && r[1] <= 0 && r[2] >= 100 && r[3] >= 100, isTrue);
    });

    testWidgets('RotatedBox swaps the extent', (tester) async {
      await tester.pumpWidget(
        app(
          registry,
          Align(
            alignment: Alignment.topLeft,
            child: RotatedBox(
              quarterTurns: 1,
              child: region(registry, w: 100, h: 30),
            ),
          ),
        ),
      );
      final r = native.latest[0]!;
      expect(r[0], closeTo(0, 1e-9));
      expect(r[1], closeTo(0, 1e-9));
      expect(r[2], closeTo(30, 1e-9));
      expect(r[3], closeTo(100, 1e-9));
    });

    for (final broken in ['nan', 'throws']) {
      testWidgets('an unmeasurable region ($broken) covers the whole view', (
        tester,
      ) async {
        await tester.pumpWidget(
          app(
            registry,
            Align(
              alignment: Alignment.topLeft,
              child: BrokenRegion(registry: registry, mode: broken),
            ),
          ),
        );
        final view = tester.view;
        expect(native.latest[0], [
          0,
          0,
          view.physicalSize.width / view.devicePixelRatio,
          view.physicalSize.height / view.devicePixelRatio,
        ]);
      });
    }
  });

  group('clipping and scrolling', () {
    testWidgets('a clipped region is reported whole, never less', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          registry,
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 40,
              height: 20,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  maxWidth: 100,
                  maxHeight: 50,
                  child: region(registry),
                ),
              ),
            ),
          ),
        ),
      );
      expect(native.latest[0], [0, 0, 100, 50]);
    });

    testWidgets('a scrolling region follows, leaves, and comes back', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        app(
          registry,
          SizedBox(
            width: 400,
            height: 300,
            child: ListView(
              controller: controller,
              cacheExtent: 0,
              children: [
                const SizedBox(height: 100),
                Align(
                  alignment: Alignment.topLeft,
                  child: region(registry, h: 100),
                ),
                const SizedBox(height: 1000),
              ],
            ),
          ),
        ),
      );
      expect(native.latest[0], [0, 100, 100, 200]);
      final before = native.sent.length;

      controller.jumpTo(30);
      await tester.pump();
      expect(native.sent.length, before + 1);
      expect(native.latest[0], [0, 70, 100, 170]);

      // Scrolled out of the viewport: not painted, so not reported, and no
      // stale position stays behind.
      controller.jumpTo(500);
      await tester.pump();
      expect(native.sent.last.views, isEmpty);

      controller.jumpTo(0);
      await tester.pump();
      expect(native.latest[0], [0, 100, 100, 200]);
    });

    testWidgets('scrolling inside a repaint boundary is still tracked', (
      tester,
    ) async {
      // ListView wraps every child in a RepaintBoundary: scrolling re-composites
      // cached layers without painting the region again.
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        app(
          registry,
          SizedBox(
            width: 400,
            height: 300,
            child: ListView.builder(
              controller: controller,
              itemCount: 20,
              itemExtent: 100,
              itemBuilder: (_, i) => i == 1
                  ? Align(
                      alignment: Alignment.topLeft,
                      child: region(registry, w: 50, h: 100),
                    )
                  : const SizedBox(),
            ),
          ),
        ),
      );
      expect(native.latest[0], [0, 100, 50, 200]);
      for (var i = 1; i <= 4; i++) {
        controller.jumpTo(i * 10.0);
        await tester.pump();
        expect(native.latest[0], [0, 100.0 - i * 10, 50, 200.0 - i * 10]);
      }
    });
  });

  group('page transitions keep the region covered (pixels are on screen)', () {
    Future<void> run(
      WidgetTester tester,
      PageTransitionsBuilder? builder, {
      bool hero = false,
    }) async {
      final navigator = GlobalKey<NavigatorState>();
      Widget page(String label) => Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: 10,
              top: 20,
              child: hero
                  ? Hero(tag: 'h', child: region(registry))
                  : region(registry),
            ),
            Text(label),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: builder == null
              ? ThemeData(platform: TargetPlatform.iOS) // the platform default
              : ThemeData(
                  pageTransitionsTheme: PageTransitionsTheme(
                    builders: {
                      for (final p in TargetPlatform.values) p: builder,
                    },
                  ),
                ),
          home: page('one'),
        ),
      );
      void expectCovered(String when) {
        final state = registry.measure();
        expect(state[0], isNotNull, reason: 'nothing covered $when');
        expect(state[0]!.rects, isNotEmpty, reason: 'nothing covered $when');
      }

      expectCovered('before the push');
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => page('two')),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        expectCovered('during the push, frame $i');
      }
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        expectCovered('during the pop, frame $i');
      }
      await tester.pumpAndSettle();
      expectCovered('after the pop');
    }

    testWidgets('Zoom (a SnapshotWidget: the region paints into a temporary '
        'layer)', (tester) async {
      await run(tester, const ZoomPageTransitionsBuilder());
    });
    testWidgets('FadeForwards', (tester) async {
      await run(tester, const FadeForwardsPageTransitionsBuilder());
    });
    testWidgets('the iOS default (Cupertino)', (tester) async {
      await run(tester, null);
    });
    testWidgets('Hero in flight', (tester) async {
      await run(tester, const FadeUpwardsPageTransitionsBuilder(), hero: true);
    });
  });

  group('what is hidden is hidden on positive evidence only', () {
    testWidgets('a dialog over the page leaves the page covered', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(body: at(registry, 10, 20)),
        ),
      );
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(title: Text('modal')),
      );
      await tester.pumpAndSettle();
      expect(registry.measure()[0]!.rects, hasLength(1));
    });

    testWidgets('a disabled TickerMode (an inactive route or overlay entry) '
        'hides it; enabling brings it back', (tester) async {
      Widget tree(bool on) =>
          TickerMode(enabled: on, child: at(registry, 5, 5));
      await tester.pumpWidget(app(registry, tree(true)));
      expect(native.latest[0], [5, 5, 105, 55]);
      await tester.pumpWidget(app(registry, tree(false)));
      expect(native.sent.last.views, isEmpty);
      await tester.pumpWidget(app(registry, tree(true)));
      expect(native.latest[0], [5, 5, 105, 55]);
    });

    testWidgets('IndexedStack: only the shown child is covered', (
      tester,
    ) async {
      Widget stack(int index) => IndexedStack(
        index: index,
        alignment: Alignment.topLeft,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: region(registry, w: 11, h: 11),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 100),
            child: region(registry, w: 22, h: 22),
          ),
        ],
      );
      await tester.pumpWidget(app(registry, stack(0)));
      expect(native.latest[0], [10, 0, 21, 11]);
      await tester.pumpWidget(app(registry, stack(1)));
      expect(native.latest[0], [100, 0, 122, 22]);
    });

    testWidgets('Visibility without maintaining state hides it, with '
        'maintainState it too, shown it is covered', (tester) async {
      Widget vis(bool visible) => Visibility(
        visible: visible,
        maintainState: true,
        child: at(registry, 5, 5),
      );
      await tester.pumpWidget(app(registry, vis(true)));
      expect(native.latest[0], [5, 5, 105, 55]);
      await tester.pumpWidget(app(registry, vis(false)));
      expect(native.sent.last.views, isEmpty);
      await tester.pumpWidget(app(registry, vis(true)));
      expect(native.latest[0], [5, 5, 105, 55]);
    });

    testWidgets('a child kept in the cache extent but scrolled out of a '
        'clipping viewport is hidden; a partly visible one is covered whole', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        app(
          registry,
          Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 200),
              child: SizedBox(
                width: 400,
                height: 300,
                child: ListView(
                  controller: controller,
                  cacheExtent: 1000,
                  children: [
                    Align(
                      alignment: Alignment.topLeft,
                      child: region(registry, h: 100),
                    ),
                    const SizedBox(height: 1000),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(native.latest[0], [0, 200, 100, 300]);
      controller.jumpTo(50); // half of it is above the viewport top (200)
      await tester.pump();
      expect(native.latest[0], [0, 150, 100, 250]);
      controller.jumpTo(150); // wholly above the viewport, still built
      await tester.pump();
      expect(native.sent.last.views, isEmpty);
    });

    testWidgets('paint outside the region box is covered too', (tester) async {
      await tester.pumpWidget(
        app(
          registry,
          Align(
            alignment: Alignment.topLeft,
            child: BugseeSecureRegion(
              registry: registry,
              child: SizedBox(
                width: 100,
                height: 50,
                child: Transform.translate(
                  offset: const Offset(200, 0),
                  child: const SizedBox(width: 100, height: 50),
                ),
              ),
            ),
          ),
        ),
      );
      expect(native.latest[0], [0, 0, 300, 50]);
    });
  });

  group('ratio and epoch', () {
    testWidgets('the ratio travels with the rectangles and a ratio change is '
        'republished even though no rectangle moved', (tester) async {
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      Widget tree() => Align(
        alignment: Alignment.topLeft,
        child: region(registry, w: 10, h: 10),
      );
      await tester.pumpWidget(app(registry, tree()));
      expect(native.sent.last.views.single.devicePixelRatio, 3);
      expect(native.latest[0], [0, 0, 10, 10]);
      tester.view.devicePixelRatio = 2;
      await tester.pumpWidget(app(registry, tree()));
      expect(native.sent, hasLength(2));
      expect(native.sent.last.views.single.devicePixelRatio, 2);
      expect(native.latest[0], [0, 0, 10, 10]);
    });

    test('the epoch is random, never zero and not a clock', () {
      final a = SecureRegionRegistry(publish: (m) async => true);
      final b = SecureRegionRegistry(publish: (m) async => true);
      expect(a.epoch, isNot(b.epoch));
      expect(a.epoch, greaterThan(0));
      final now = DateTime.now().microsecondsSinceEpoch;
      expect(
        (a.epoch - now).abs() > 1000000 || (b.epoch - now).abs() > 1000000,
        isTrue,
      );
    });
  });

  group('lifecycle', () {
    testWidgets('disposing the region clears it, once, then goes quiet', (
      tester,
    ) async {
      await tester.pumpWidget(app(registry, at(registry, 10, 20)));
      expect(registry.regionCount, 1);
      await tester.pumpWidget(app(registry, const SizedBox()));
      expect(registry.regionCount, 0);
      expect(native.sent, hasLength(2));
      expect(native.sent.last.views, isEmpty);
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(native.sent, hasLength(2));
    });

    testWidgets('enabled: false removes the region, true brings it back', (
      tester,
    ) async {
      Widget build(bool on) => Stack(
        children: [
          Positioned(left: 5, top: 5, child: region(registry, enabled: on)),
        ],
      );
      await tester.pumpWidget(app(registry, build(true)));
      expect(native.latest[0], [5, 5, 105, 55]);
      await tester.pumpWidget(app(registry, build(false)));
      expect(native.sent.last.views, isEmpty);
      await tester.pumpWidget(app(registry, build(true)));
      expect(native.latest[0], [5, 5, 105, 55]);
    });

    testWidgets('an offstage region is not reported, and returns when shown', (
      tester,
    ) async {
      Widget build(bool hidden) =>
          Offstage(offstage: hidden, child: at(registry, 10, 20));
      await tester.pumpWidget(app(registry, build(false)));
      expect(native.latest[0], [10, 20, 110, 70]);
      await tester.pumpWidget(app(registry, build(true)));
      expect(native.sent.last.views, isEmpty);
      await tester.pumpWidget(app(registry, build(false)));
      expect(native.latest[0], [10, 20, 110, 70]);
    });

    testWidgets('a hidden route does not leave a ghost over the next page', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(body: at(registry, 10, 20)),
        ),
      );
      expect(native.latest[0], isNotNull);
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      expect(native.sent.last.views, isEmpty);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(native.latest[0], [10, 20, 110, 70]);
    });

    testWidgets('moving the same region between parents is one region', (
      tester,
    ) async {
      final key = GlobalKey();
      Widget build(bool left) => Stack(
        children: [
          Positioned(
            left: left ? 0 : 200,
            top: 0,
            child: BugseeSecureRegion(
              key: key,
              registry: registry,
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        ],
      );
      await tester.pumpWidget(app(registry, build(true)));
      await tester.pumpWidget(app(registry, build(false)));
      expect(registry.regionCount, 1);
      expect(native.latest[0], [200, 0, 210, 10]);
    });
  });

  group('view changes', () {
    testWidgets('a resize that re-lays-out the region is published', (
      tester,
    ) async {
      Widget fill() => Align(
        alignment: Alignment.bottomRight,
        child: region(registry, w: 100, h: 50),
      );
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(registry, fill()));
      expect(native.latest[0], [800, 550, 900, 600]);
      // Orientation change.
      tester.view.physicalSize = const Size(600, 900);
      await tester.pump();
      expect(native.latest[0], [500, 850, 600, 900]);
    });

    testWidgets('a pixel-ratio change with no relayout republishes nothing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(registry, at(registry, 10, 20)));
      expect(native.sent, hasLength(1));
      // Logical rects are unchanged by the ratio; native rescales them with its
      // own, per-call, scale.
      tester.view.devicePixelRatio = 1;
      await tester.pump();
      expect(native.sent, hasLength(1));
    });

    testWidgets('regions in two views are published per view', (tester) async {
      final second = OtherView(tester);
      await tester.pumpWidget(
        ViewCollection(
          views: [
            View(view: tester.view, child: app(registry, at(registry, 1, 2))),
            View(
              view: second,
              child: app(registry, at(registry, 30, 40, w: 10, h: 10)),
            ),
          ],
        ),
        wrapWithView: false,
      );
      expect(native.latest[tester.view.viewId], [1, 2, 101, 52]);
      expect(native.latest[second.viewId], [30, 40, 40, 50]);
      // Removing the second view removes only its rectangles.
      await tester.pumpWidget(
        ViewCollection(
          views: [
            View(view: tester.view, child: app(registry, at(registry, 1, 2))),
          ],
        ),
        wrapWithView: false,
      );
      expect(native.latest.keys, [tester.view.viewId]);
    });
  });

  group('over the real channel', () {
    testWidgets('the process-wide registry sends the pigeon message natively '
        'decodes, and handles a refusal of an old message', (tester) async {
      const channel =
          'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeHostApi.setSecureRectangles';
      final codec = BugseeBridgeHostApi.pigeonChannelCodec;
      final received = <SecureRectanglesMessage>[];
      var answer = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler(channel, (ByteData? data) async {
        final args = codec.decodeMessage(data) as List<Object?>;
        received.add(args[0]! as SecureRectanglesMessage);
        return codec.encodeMessage(<Object?>[answer]);
      });
      addTearDown(() => messenger.setMockMessageHandler(channel, null));

      final real = SecureRegionRegistry.instance;
      await tester.pumpWidget(
        app(
          real,
          Stack(
            children: [
              Positioned(
                left: 4,
                top: 8,
                child: BugseeSecureRegion(
                  child: const SizedBox(width: 10, height: 20),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(received, hasLength(1));
      expect(received.single.epoch, real.epoch);
      expect(received.single.sequence, greaterThan(0));
      expect(received.single.views.single.viewId, tester.view.viewId);
      expect(received.single.views.single.rectangles, [4, 8, 14, 28]);

      // A "not applied" answer (an older message) is not an error: no retry storm.
      answer = false;
      await tester.pumpWidget(app(real, const SizedBox()));
      await tester.pump();
      expect(received.last.views, isEmpty);
      final before = received.length;
      await tester.pump(const Duration(seconds: 2));
      expect(received, hasLength(before));
      expect(real.lastError, isNull);
    });
  });

  group('publishing', () {
    testWidgets('a failed publish is retried and then goes quiet', (
      tester,
    ) async {
      registry.dispose();
      registry = registryFor(native, retry: const Duration(milliseconds: 100));
      native.failNext = 1;
      await tester.pumpWidget(app(registry, at(registry, 10, 20)));
      await tester.pump(); // deliver the failure
      expect(native.sent, hasLength(1));
      await tester.pump(const Duration(milliseconds: 150)); // retry timer
      await tester.pump();
      expect(native.sent, hasLength(2));
      expect(native.sent.last.sequence, 2);
      expect(native.latest[0], [10, 20, 110, 70]);
      await tester.pump(const Duration(seconds: 1));
      expect(native.sent, hasLength(2));
    });

    testWidgets('a failed clear is sent again, even though it is empty', (
      tester,
    ) async {
      registry.dispose();
      registry = registryFor(native, retry: const Duration(milliseconds: 100));
      await tester.pumpWidget(app(registry, at(registry, 10, 20)));
      native.failNext = 1;
      await tester.pumpWidget(app(registry, const SizedBox()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(native.sent, hasLength(3));
      expect(native.sent.last.views, isEmpty);
    });

    testWidgets('sequences only ever grow, one per publish', (tester) async {
      native.hold = true; // nothing is acknowledged
      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(app(registry, at(registry, i * 1.0, 0)));
      }
      final seq = native.sent.map((m) => m.sequence).toList();
      expect(seq, [1, 2, 3, 4, 5]);
      expect(native.sent.map((m) => m.epoch).toSet(), {7});
    });
  });
}

/// A second view, with an id of its own, sharing the test view's geometry.
class OtherView extends TestFlutterView {
  OtherView(WidgetTester tester)
    : super(
        view: tester.view,
        platformDispatcher: tester.platformDispatcher,
        display: tester.view.display,
      );

  @override
  int get viewId => 99;
}

/// A region whose measurement goes wrong, to prove the failure covers more.
class BrokenRegion extends SingleChildRenderObjectWidget {
  const BrokenRegion({super.key, required this.registry, required this.mode});
  final SecureRegionRegistry registry;
  final String mode;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBroken(mode, registry);
}

class _RenderBroken extends RenderSecureRegion {
  _RenderBroken(this.mode, SecureRegionRegistry registry)
    : super(enabled: true, registry: registry);
  final String mode;

  @override
  void performLayout() {
    size = const Size(100, 50);
  }

  @override
  Matrix4 getTransformTo(RenderObject? target) {
    if (mode == 'throws') throw StateError('measurement failed');
    return Matrix4.diagonal3Values(double.nan, 1, 1);
  }
}
