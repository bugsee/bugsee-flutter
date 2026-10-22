// The managed view hierarchy builder: what is in the tree, in which space, in which order, what is
// cut and what fails closed. Privacy has its own file (view_hierarchy_privacy_test.dart).
import 'dart:convert';

import 'package:bugsee_flutter/src/secure/bugsee_secure_view.dart';
import 'package:bugsee_flutter/src/view_hierarchy/hierarchy_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Json = Map<String, Object?>;

/// A clock that never advances: the 12 ms walk budget cannot expire on a loaded machine, so the
/// node counts a test asserts do not depend on how fast the runner is. Only the test of the time
/// cut supplies a clock that moves.
Duration frozenClock() => Duration.zero;

HierarchySnapshot snapshot({
  HierarchyLimits limits = const HierarchyLimits(),
  Duration Function()? clock,
}) {
  final s = buildViewHierarchy(limits: limits, clock: clock ?? frozenClock);
  expect(s, isNotNull, reason: 'a snapshot was expected');
  return s!;
}

/// The payload as native would serve it at ratio 1 (logical pixels), parsed.
Json payload(HierarchySnapshot s, {int ageMs = 0}) =>
    jsonDecode(s.render(ageMs: ageMs)) as Json;

Iterable<Json> walk(Json node) sync* {
  yield node;
  for (final c in (node['subitems'] as List<Object?>?) ?? const <Object?>[]) {
    yield* walk(c! as Json);
  }
}

List<Json> named(Json root, String className) => [
  for (final n in walk(root))
    if (n['class_name'] == className) n,
];

/// `[x, y, w, h]` of a node.
List<num> boxOf(Json node) => (node['bounds']! as List<Object?>).cast<num>();

Json? optionsOf(Json node) => node['options'] as Json?;

/// A widget with a class name of its own, so a test can find it.
class Marker extends StatelessWidget {
  const Marker({super.key, this.width = 10, this.height = 10, this.child});
  final double width;
  final double height;
  final Widget? child;
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: width, height: height, child: child);
}

class OtherMarker extends Marker {
  const OtherMarker({super.key, super.width, super.height, super.child});
}

Widget host(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

Widget at(double x, double y, Widget child) => Stack(
  children: [Positioned(left: x, top: y, child: child)],
);

void main() {
  group('shape of the payload', () {
    testWidgets('one JSON object rooted at the Flutter view', (tester) async {
      await tester.pumpWidget(host(const Marker(width: 100, height: 50)));
      final s = snapshot();
      final root = payload(s);
      expect(root['class_name'], viewNodeClassName);
      expect(root['id'], '0');
      final options = optionsOf(root)!;
      expect(options['age_ms'], 0);
      expect(options['device_pixel_ratio'], tester.view.devicePixelRatio);
      expect(options.containsKey('obfuscated'), isFalse);
      expect(options.containsKey('truncated'), isFalse);
      // The view: its logical size, 800 x 600 here.
      expect(boxOf(root), [0, 0, 800, 600]);
    });

    testWidgets(
      'segments and boxes agree: one box per node, two more segments',
      (tester) async {
        await tester.pumpWidget(
          host(
            Column(
              children: const [Marker(), Marker(), OtherMarker(), Marker()],
            ),
          ),
        );
        final s = snapshot();
        final nodes = walk(payload(s)).length;
        expect(s.nodeCount, nodes);
        expect(s.bounds.length, nodes * 4);
        expect(s.segments.length, nodes + 2);
      },
    );

    testWidgets('ids are unique and follow document order', (tester) async {
      await tester.pumpWidget(
        host(Column(children: const [Marker(), Marker(), Marker()])),
      );
      final ids = [for (final n in walk(payload(snapshot()))) n['id']];
      expect(ids, [for (var i = 0; i < ids.length; i++) '$i']);
    });

    testWidgets('a type is named without generic arguments', (tester) async {
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<String>(
            valueListenable: ValueNotifier<String>('x'),
            builder: (_, _, _) => const Marker(),
          ),
        ),
      );
      final names = [
        for (final n in walk(payload(snapshot()))) n['class_name'],
      ];
      expect(names, contains('ValueListenableBuilder'));
      expect(names.where((n) => (n! as String).contains('<')), isEmpty);
    });

    testWidgets('an unchanged tree builds the same payload', (tester) async {
      await tester.pumpWidget(host(Column(children: const [Marker()])));
      expect(snapshot().sameContent(snapshot()), isTrue);
    });

    testWidgets('a changed tree is a different payload', (tester) async {
      await tester.pumpWidget(host(at(10, 10, const Marker())));
      final before = snapshot();
      await tester.pumpWidget(host(at(11, 10, const Marker())));
      expect(snapshot().sameContent(before), isFalse);
      await tester.pumpWidget(host(at(10, 10, const OtherMarker())));
      expect(snapshot().sameContent(before), isFalse);
    });

    testWidgets('nothing to describe: no snapshot', (tester) async {
      // No view in the tree at all.
      expect(
        buildViewHierarchy(
          root: _EmptyElement(const Marker()),
          clock: frozenClock,
        ),
        isNull,
      );
    });

    testWidgets('a view id that is not in the tree has no snapshot', (
      tester,
    ) async {
      await tester.pumpWidget(host(const Marker()));
      expect(buildViewHierarchy(viewId: 99, clock: frozenClock), isNull);
      expect(buildViewHierarchy(viewId: 0, clock: frozenClock), isNotNull);
    });
  });

  group('geometry', () {
    testWidgets('boxes are in the views logical pixels, origin top-left', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(at(20, 30, const Marker(width: 100, height: 50))),
      );
      final marker = named(payload(snapshot()), 'Marker').single;
      expect(boxOf(marker), [20, 30, 100, 50]);
      // Raw numbers, in the order native consumes them: l, t, r, b.
      final s = snapshot();
      final nodes = walk(payload(s)).toList();
      final i = nodes.indexWhere((n) => n['class_name'] == 'Marker');
      expect(s.bounds.sublist(i * 4, i * 4 + 4), [20, 30, 120, 80]);
    });

    testWidgets('the device pixel ratio does not scale the boxes', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 2.5;
      tester.view.physicalSize = const Size(2000, 1500); // 800 x 600 logical
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        host(at(20, 30, const Marker(width: 100, height: 50))),
      );
      final s = snapshot();
      expect(s.devicePixelRatio, 2.5);
      expect(boxOf(named(payload(s), 'Marker').single), [20, 30, 100, 50]);
      expect(boxOf(payload(s)), [0, 0, 800, 600]);
    });

    testWidgets('a transformed widget is its bounding box on the screen', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          at(
            100,
            100,
            Transform.scale(
              scale: 2,
              alignment: Alignment.topLeft,
              child: const Marker(width: 40, height: 20),
            ),
          ),
        ),
      );
      final marker = named(payload(snapshot()), 'Marker').single;
      expect(boxOf(marker), [100, 100, 80, 40]);
    });

    testWidgets('a rotated widget is reported by its axis-aligned box', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          at(
            100,
            100,
            Transform.rotate(
              angle: 3.14159265358979 / 2,
              alignment: Alignment.topLeft,
              child: const Marker(width: 40, height: 20),
            ),
          ),
        ),
      );
      final box = boxOf(named(payload(snapshot()), 'Marker').single);
      // A quarter turn about the top-left: x spans [80, 100], y spans [100, 140].
      expect(box[0], closeTo(80, 1e-6));
      expect(box[1], closeTo(100, 1e-6));
      expect(box[2], closeTo(20, 1e-6));
      expect(box[3], closeTo(40, 1e-6));
    });

    testWidgets('a scrolled list is placed where it is on the screen', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(
          ListView(
            controller: controller,
            children: [
              for (var i = 0; i < 40; i++)
                Marker(width: 800, height: 100 + (i == 5 ? 1 : 0)),
            ],
          ),
        ),
      );
      controller.jumpTo(320);
      await tester.pump();
      final boxes = [
        for (final n in named(payload(snapshot()), 'Marker')) boxOf(n),
      ];
      // The first visible item starts above the top edge (item 3 spans 300..400 -> -20).
      expect(boxes.first[1], -20);
      expect(boxes.map((b) => b[1]), everyElement(lessThan(600)));
    });
  });

  group('what is on stage', () {
    testWidgets(
      'Offstage, an invisible Visibility and zero Opacity are absent',
      (tester) async {
        await tester.pumpWidget(
          host(
            Column(
              children: const [
                Offstage(offstage: true, child: Marker(width: 11)),
                Visibility(visible: false, child: Marker(width: 12)),
                Opacity(opacity: 0, child: Marker(width: 13)),
                Marker(width: 14),
              ],
            ),
          ),
        );
        final widths = [
          for (final n in named(payload(snapshot()), 'Marker')) boxOf(n)[2],
        ];
        expect(widths, [14]);
      },
    );

    testWidgets('only the shown child of an IndexedStack', (tester) async {
      await tester.pumpWidget(
        host(
          const IndexedStack(
            index: 1,
            children: [Marker(width: 21), Marker(width: 22), Marker(width: 23)],
          ),
        ),
      );
      final widths = [
        for (final n in named(payload(snapshot()), 'Marker')) boxOf(n)[2],
      ];
      expect(widths, [22]);
    });

    testWidgets('a half transparent widget carries its alpha', (tester) async {
      await tester.pumpWidget(
        host(const Opacity(opacity: 0.5, child: Marker(width: 15))),
      );
      final opacity = named(payload(snapshot()), 'Opacity').single;
      expect(optionsOf(opacity)!['alpha'], 0.5);
    });

    testWidgets('list items scrolled out of the viewport are absent', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          ListView(
            children: [
              for (var i = 0; i < 100; i++) Marker(width: 800, height: 100),
            ],
          ),
        ),
      );
      // 600 / 100 = 6 on screen; the cache extent keeps a few more in the tree.
      final onScreen = named(payload(snapshot()), 'Marker');
      expect(onScreen.length, 6);
      expect(
        find.byType(Marker, skipOffstage: false).evaluate().length,
        greaterThan(6),
      );
      for (final n in onScreen) {
        expect(boxOf(n)[1], lessThan(600));
      }
    });

    testWidgets('a node wholly outside the screen is absent', (tester) async {
      await tester.pumpWidget(
        host(
          Stack(
            clipBehavior: Clip.none,
            children: const [
              Positioned(left: 5000, top: 5000, child: Marker(width: 31)),
              Positioned(left: 10, top: 10, child: Marker(width: 32)),
              Positioned(left: -500, top: 10, child: Marker(width: 33)),
              Positioned(left: -5, top: 10, child: Marker(width: 34)),
            ],
          ),
        ),
      );
      final widths = [
        for (final n in named(payload(snapshot()), 'Marker')) boxOf(n)[2],
      ];
      // 34 hangs 5 pixels off the left edge: partly on screen, so present.
      expect(widths, [32, 34]);
    });

    testWidgets('an opaque route hides the page below it, a dialog does not', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(
            body: Align(alignment: Alignment.topLeft, child: Marker(width: 41)),
          ),
        ),
      );
      List<Object?> widths() => [
        for (final n in named(payload(snapshot()), 'Marker')) boxOf(n)[2],
      ];
      expect(widths(), [41]);

      // A dialog is a transparent route: the page stays on stage under it.
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(
          content: Align(
            alignment: Alignment.topLeft,
            child: Marker(width: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(widths(), containsAll([41, 42]));
      expect(named(payload(snapshot()), 'AlertDialog'), hasLength(1));
      // The dialog is later in paint order than the page: on top of it.
      final order = [
        for (final n in walk(payload(snapshot())))
          if (n['class_name'] == 'Marker') boxOf(n)[2],
      ];
      expect(order.indexOf(41), lessThan(order.indexOf(42)));
      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      // A full page route covers it: the page below is off stage.
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: Align(alignment: Alignment.topLeft, child: Marker(width: 43)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(widths(), [43]);
    });

    testWidgets('an Overlay entry above the page is on stage and last', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (_) => const Align(
                  alignment: Alignment.topLeft,
                  child: Marker(width: 51),
                ),
              ),
              OverlayEntry(
                builder: (_) => const Align(
                  alignment: Alignment.topLeft,
                  child: Marker(width: 52),
                ),
              ),
            ],
          ),
        ),
      );
      final widths = [
        for (final n in named(payload(snapshot()), 'Marker')) boxOf(n)[2],
      ];
      expect(widths, [51, 52]);
    });
  });

  group('more of what is on stage', () {
    testWidgets('a list in a small viewport shows only what the viewport shows', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          at(
            0,
            0,
            SizedBox(
              width: 200,
              height: 100,
              child: ListView(
                children: [
                  for (var i = 0; i < 20; i++) Marker(width: 200, height: 50),
                ],
              ),
            ),
          ),
        ),
      );
      // The cache extent keeps more in the tree, all inside the 800 x 600 screen, none visible.
      expect(
        find.byType(Marker, skipOffstage: false).evaluate().length,
        greaterThan(2),
      );
      expect(named(payload(snapshot()), 'Marker'), hasLength(2));
    });

    testWidgets('what an ancestor clips away is absent even on screen', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          at(
            0,
            0,
            SizedBox(
              width: 100,
              height: 100,
              child: ClipRect(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: const [
                    Positioned(
                      left: 10,
                      top: 10,
                      child: Marker(width: 21, height: 10),
                    ),
                    Positioned(
                      left: 10,
                      top: 300,
                      child: Marker(width: 22, height: 10),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(named(payload(snapshot()), 'Marker').map((n) => boxOf(n)[2]), [
        21,
      ]);
    });

    testWidgets('a node with no area is absent', (tester) async {
      await tester.pumpWidget(
        host(
          Column(
            children: const [
              Marker(width: 0, height: 10),
              Marker(width: 10, height: 0),
              Marker(width: 7, height: 7),
            ],
          ),
        ),
      );
      expect(named(payload(snapshot()), 'Marker').map((n) => boxOf(n)[2]), [7]);
    });

    testWidgets('a provider of data is not a node, its subtree still is', (
      tester,
    ) async {
      await tester.pumpWidget(host(const Marker(width: 9, height: 9)));
      final names = [
        for (final n in walk(payload(snapshot()))) n['class_name'],
      ];
      expect(names, isNot(contains('Directionality')));
      expect(names, contains('Marker'));
    });

    testWidgets('an obfuscated build says so', (tester) async {
      await tester.pumpWidget(host(const Marker()));
      final s = buildViewHierarchy(obfuscated: true, clock: frozenClock)!;
      expect(optionsOf(payload(s))!['obfuscated'], isTrue);
      expect(
        optionsOf(payload(snapshot()))!.containsKey('obfuscated'),
        isFalse,
      );
    });
  });

  group('what a real screen costs', () {
    Widget stockScreen() => MaterialApp(
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Inbox'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'One'),
                Tab(text: 'Two'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              ListView(
                children: [
                  for (var i = 0; i < 40; i++)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.mail),
                        title: Text('Message $i'),
                        trailing: Checkbox(value: false, onChanged: (_) {}),
                      ),
                    ),
                ],
              ),
              const SizedBox(),
            ],
          ),
        ),
      ),
    );

    testWidgets('a stock Material screen is not cut at the documented limits', (
      tester,
    ) async {
      await tester.pumpWidget(stockScreen());
      final s = snapshot();
      final whole = snapshot(
        limits: const HierarchyLimits(
          maxNodes: 1 << 20,
          maxDepth: 1 << 20,
          maxBytes: 1 << 30,
          budget: Duration(minutes: 1),
        ),
      );
      debugPrint(
        'stock screen: ${s.nodeCount} nodes, ${s.render().length} bytes',
      );
      expect(s.truncated, isFalse);
      expect(s.nodeCount, whole.nodeCount);
      expect(s.nodeCount, greaterThan(300));
      // The documented limits are 2000 nodes / 256 KiB: this screen is nowhere near them.
      expect(s.nodeCount, lessThan(const HierarchyLimits().maxNodes ~/ 2));
      expect(
        s.render().length,
        lessThan(const HierarchyLimits().maxBytes ~/ 2),
      );
    });

    testWidgets('providers of data do not count as levels, real levels do', (
      tester,
    ) async {
      Widget deep = const Marker(width: 5, height: 5);
      for (var i = 0; i < 400; i++) {
        deep = Directionality(textDirection: TextDirection.ltr, child: deep);
      }
      await tester.pumpWidget(host(deep));
      final s = snapshot(limits: const HierarchyLimits(maxDepth: 20));
      expect(s.truncated, isFalse, reason: '400 providers are not 400 levels');
      expect(named(payload(s), 'Marker'), hasLength(1));
      Widget paddings = const Marker(width: 5, height: 5);
      for (var i = 0; i < 60; i++) {
        paddings = Padding(padding: const EdgeInsets.all(0.1), child: paddings);
      }
      await tester.pumpWidget(host(paddings));
      expect(
        snapshot(limits: const HierarchyLimits(maxDepth: 20)).truncated,
        isTrue,
      );
    });

    testWidgets(
      'the byte cap is reached near the real size, not at half of it',
      (tester) async {
        await tester.pumpWidget(
          host(
            Stack(
              children: [
                for (var i = 0; i < 3000; i++)
                  Positioned(
                    left: (i % 700).toDouble(),
                    top: (i ~/ 700) * 10.0,
                    child: const Marker(width: 1, height: 1),
                  ),
              ],
            ),
          ),
        );
        const limits = HierarchyLimits(maxNodes: 1 << 20, maxBytes: 100 * 1024);
        final s = snapshot(limits: limits);
        expect(s.truncated, isTrue);
        final size = s.render().length;
        // Cut by the byte cap, close to it: not at half, not over.
        expect(size, lessThanOrEqualTo(limits.maxBytes));
        expect(size, greaterThan(limits.maxBytes * 7 ~/ 10));
      },
    );
  });

  group('a render parent that is not the element parent', () {
    testWidgets(
      'an OverlayPortal child under a small clip is not clipped by its anchor',
      (tester) async {
        final controller = OverlayPortalController();
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 100,
                height: 20,
                child: ClipRect(
                  child: OverlayPortal(
                    controller: controller,
                    overlayChildBuilder: (_) => const Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: EdgeInsets.only(top: 400),
                        child: Marker(width: 61, height: 10),
                      ),
                    ),
                    child: const Align(
                      alignment: Alignment.topLeft,
                      child: Marker(width: 62, height: 10),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        controller.show();
        await tester.pump();
        final markers = named(payload(snapshot()), 'Marker');
        final widths = markers.map((n) => boxOf(n)[2]).toList();
        expect(widths, containsAll([61, 62]));
        expect(
          boxOf(markers.firstWhere((n) => boxOf(n)[2] == 61))[1],
          400,
          reason: 'where it paints, on the screen',
        );
        expect(
          widths.indexOf(61),
          greaterThan(widths.indexOf(62)),
          reason: 'above its anchor',
        );
      },
    );

    testWidgets(
      'an OverlayPortal child is listed after everything else in its overlay',
      (tester) async {
        final controller = OverlayPortalController();
        await tester.pumpWidget(
          MaterialApp(
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
          ),
        );
        controller.show();
        await tester.pump();
        final widths = [
          for (final n in named(payload(snapshot()), 'Marker')) boxOf(n)[2],
        ];
        // The anchor comes first in the element tree, but its overlay child paints in the theater,
        // on top of what the theater holds: it is last.
        expect(widths, [64, 61]);
      },
    );

    testWidgets('an OverlayPortal child of a hidden anchor is not walked', (
      tester,
    ) async {
      final controller = OverlayPortalController();
      await tester.pumpWidget(
        MaterialApp(
          home: Offstage(
            child: OverlayPortal(
              controller: controller,
              overlayChildBuilder: (_) => const Marker(width: 63, height: 10),
              child: const SizedBox(),
            ),
          ),
        ),
      );
      controller.show();
      await tester.pump();
      final widths = [
        for (final n in named(payload(snapshot()), 'Marker')) boxOf(n)[2],
      ];
      // The element walk does not enter an Offstage, so what the overlay paints for a hidden anchor
      // is not described either (a gap in the description, never a leak).
      expect(widths, isEmpty);
    });

    testWidgets(
      'a child translated onto the screen from a parent off it is kept',
      (tester) async {
        await tester.pumpWidget(
          host(
            const Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 900,
                  top: 10,
                  child: FractionalTranslation(
                    translation: Offset(-1.5, 0),
                    child: Marker(width: 100, height: 10),
                  ),
                ),
              ],
            ),
          ),
        );
        final marker = named(payload(snapshot()), 'Marker').single;
        expect(boxOf(marker)[0], 750);
      },
    );

    testWidgets(
      'what a clip hides stays hidden even when its box is off screen',
      (tester) async {
        await tester.pumpWidget(
          host(
            const Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 900,
                  top: 10,
                  child: SizedBox(
                    width: 100,
                    height: 100,
                    child: ClipRect(
                      child: OverflowBox(
                        maxWidth: 1000,
                        alignment: Alignment.centerRight,
                        child: Marker(width: 1000, height: 10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        expect(named(payload(snapshot()), 'Marker'), isEmpty);
      },
    );

    testWidgets('a secure view off screen is never walked into', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 900,
                top: 10,
                child: BugseeSecureView(
                  child: FractionalTranslation(
                    translation: Offset(-1.5, 0),
                    child: Marker(width: 100, height: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      final names = [
        for (final n in walk(payload(snapshot()))) n['class_name'],
      ];
      expect(names, isNot(contains('Marker')));
      expect(names, isNot(contains('FractionalTranslation')));
    });
  });

  group('type names are identifiers whatever runtimeType says', () {
    test('a name that is not an identifier is replaced', () {
      expect(debugTypeName(_FreeText()), 'Widget');
      expect(
        debugTypeName(_FreeText(), fallback: 'RenderObject'),
        'RenderObject',
      );
      expect(debugTypeName(const Marker()), 'Marker');
      expect(debugTypeName(ValueNotifier<int>(1)), 'ValueNotifier');
    });
  });

  group('order, flags and kinds', () {
    testWidgets('subitems are in paint order, back to front', (tester) async {
      await tester.pumpWidget(
        host(
          Stack(
            children: const [
              Positioned(left: 0, top: 0, child: Marker(width: 61)),
              Positioned(left: 0, top: 0, child: Marker(width: 62)),
              Positioned(left: 0, top: 0, child: Marker(width: 63)),
            ],
          ),
        ),
      );
      final widths = [
        for (final n in named(payload(snapshot()), 'Marker')) boxOf(n)[2],
      ];
      expect(widths, [61, 62, 63]);
    });

    testWidgets('a tappable widget is clickable, a plain one is not', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          Column(
            children: [
              GestureDetector(onTap: () {}, child: const Marker(width: 71)),
              GestureDetector(
                onLongPress: () {},
                child: const Marker(width: 72),
              ),
              const Marker(width: 73),
            ],
          ),
        ),
      );
      final root = payload(snapshot());
      bool hasClickable(Json n) =>
          walk(n).any((c) => optionsOf(c)?['clickable'] == true);
      final detectors = named(root, 'GestureDetector');
      expect(detectors, hasLength(2));
      expect(detectors.every(hasClickable), isTrue);
      expect(hasClickable(named(root, 'Marker').last), isFalse);
      expect(boxOf(named(root, 'Marker').last)[2], 73);
    });

    testWidgets('a button is clickable, a disabled one is not', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  onPressed: () {},
                  child: const Marker(width: 81),
                ),
                const ElevatedButton(onPressed: null, child: Marker(width: 82)),
              ],
            ),
          ),
        ),
      );
      final root = payload(snapshot());
      final buttons = named(root, 'ElevatedButton');
      expect(buttons, hasLength(2));
      bool hasClickable(Json n) =>
          walk(n).any((c) => optionsOf(c)?['clickable'] == true);
      expect(hasClickable(buttons[0]), isTrue);
      expect(hasClickable(buttons[1]), isFalse);
    });

    testWidgets('an image says pixels are here and nothing about them', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          Image.memory(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
            ),
            width: 10,
            height: 10,
          ),
        ),
      );
      await tester.pump();
      final kinds = [
        for (final n in walk(payload(snapshot())))
          if (optionsOf(n)?['content_kind'] != null)
            optionsOf(n)!['content_kind'],
      ];
      expect(kinds, ['image']);
    });

    testWidgets('a render object is the base class name', (tester) async {
      await tester.pumpWidget(
        host(const Padding(padding: EdgeInsets.all(3), child: Marker())),
      );
      final padding = named(payload(snapshot()), 'Padding').single;
      expect(padding['base_class_name'], 'RenderPadding');
      // A composite has no render object of its own.
      expect(
        named(
          payload(snapshot()),
          'Marker',
        ).single.containsKey('base_class_name'),
        isFalse,
      );
    });
  });

  group('secure views are redacted whole', () {
    testWidgets('the region is one node with its box and nothing below it', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          at(
            20,
            30,
            const BugseeSecureView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 100,
                    child: OtherMarker(width: 100, height: 20),
                  ),
                  Marker(width: 100, height: 20),
                ],
              ),
            ),
          ),
        ),
      );
      final root = payload(snapshot());
      expect(named(root, 'Marker'), isEmpty);
      expect(named(root, 'OtherMarker'), isEmpty);
      expect(named(root, 'Column'), isEmpty);
      final secure = [
        for (final n in walk(root))
          if (optionsOf(n)?['secure'] == true) n,
      ];
      expect(secure, hasLength(1));
      expect(secure.single['class_name'], secureNodeClassName);
      expect(boxOf(secure.single), [20, 30, 100, 40]);
      expect(secure.single.containsKey('subitems'), isFalse);
      expect(secure.single.containsKey('base_class_name'), isFalse);
    });

    testWidgets(
      'a secure node has exactly the keys id, class_name, options, bounds',
      (tester) async {
        await tester.pumpWidget(
          host(const BugseeSecureView(child: Marker(width: 10, height: 10))),
        );
        final secure = [
          for (final n in walk(payload(snapshot())))
            if (optionsOf(n)?['secure'] == true) n,
        ].single;
        expect(secure.keys.toSet(), {'id', 'class_name', 'options', 'bounds'});
        expect(optionsOf(secure), {'secure': true});
      },
    );

    testWidgets('the box is the one the secure rectangle measures', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          at(
            20,
            30,
            const BugseeSecureView(
              child: SizedBox(
                width: 100,
                height: 10,
                child: OverflowBox(
                  maxWidth: 300,
                  alignment: Alignment.topLeft,
                  child: Marker(width: 300, height: 10),
                ),
              ),
            ),
          ),
        ),
      );
      final secure = [
        for (final n in walk(payload(snapshot())))
          if (optionsOf(n)?['secure'] == true) n,
      ].single;
      // The child paints 300 wide outside a smaller box; the video masks that too, and so does this.
      expect(boxOf(secure)[2], 300);
    });

    testWidgets('a disabled secure view is an ordinary subtree', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BugseeSecureView(
            enabled: false,
            child: Marker(width: 16, height: 16),
          ),
        ),
      );
      final root = payload(snapshot());
      expect(named(root, 'Marker'), hasLength(1));
      expect([
        for (final n in walk(root))
          if (optionsOf(n)?['secure'] == true) n,
      ], isEmpty);
    });

    testWidgets('a hidden secure view is absent like any hidden node', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const Offstage(
            child: BugseeSecureView(child: Marker(width: 16, height: 16)),
          ),
        ),
      );
      final root = payload(snapshot());
      expect([
        for (final n in walk(root))
          if (optionsOf(n)?['secure'] == true) n,
      ], isEmpty);
    });

    testWidgets('siblings of a secure view are described as usual', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          Column(
            children: const [
              Marker(width: 17, height: 17),
              BugseeSecureView(child: Marker(width: 18, height: 18)),
              OtherMarker(width: 19, height: 19),
            ],
          ),
        ),
      );
      final root = payload(snapshot());
      expect(named(root, 'Marker').map((n) => boxOf(n)[2]), [17]);
      expect(named(root, 'OtherMarker'), hasLength(1));
    });

    testWidgets('a secure view inside a secure view is still one node', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BugseeSecureView(
            child: BugseeSecureView(child: Marker(width: 18, height: 18)),
          ),
        ),
      );
      final secure = [
        for (final n in walk(payload(snapshot())))
          if (optionsOf(n)?['secure'] == true) n,
      ];
      expect(secure, hasLength(1));
    });
  });

  group('caps', () {
    // n tiny widgets, all on screen (a scrolled-out one is not counted at all).
    Widget wide(int n) => host(
      Stack(
        children: [
          for (var i = 0; i < n; i++)
            Positioned(
              left: (i % 700).toDouble(),
              top: (i ~/ 700) * 10.0,
              child: const Marker(width: 1, height: 1),
            ),
        ],
      ),
    );

    testWidgets('over the node cap the walk stops and says so', (tester) async {
      await tester.pumpWidget(wide(300));
      final s = snapshot(limits: const HierarchyLimits(maxNodes: 50));
      expect(s.truncated, isTrue);
      expect(s.nodeCount, lessThanOrEqualTo(50));
      final root = payload(s);
      expect(optionsOf(root)!['truncated'], isTrue);
      expect(
        walk(root).where((n) => n['truncated'] == true),
        isNotEmpty,
        reason: 'the node whose children were cut is marked',
      );
      expect(
        walk(root).length,
        s.nodeCount,
        reason: 'the payload is still whole',
      );
    });

    testWidgets('a tree inside the caps is not marked', (tester) async {
      await tester.pumpWidget(wide(10));
      final s = snapshot();
      expect(s.truncated, isFalse);
      expect(walk(payload(s)).where((n) => n['truncated'] == true), isEmpty);
    });

    testWidgets('over the depth cap the walk stops and says so', (
      tester,
    ) async {
      Widget deep = const Marker(width: 5, height: 5);
      for (var i = 0; i < 60; i++) {
        deep = Padding(padding: const EdgeInsets.all(0.1), child: deep);
      }
      await tester.pumpWidget(host(deep));
      final s = snapshot(limits: const HierarchyLimits(maxDepth: 20));
      expect(s.truncated, isTrue);
      expect(named(payload(s), 'Marker'), isEmpty);
      // And the default cap is deep enough for a real tree this deep.
      final whole = snapshot();
      expect(whole.truncated, isFalse);
      expect(named(payload(whole), 'Marker'), hasLength(1));
    });

    test(
      'the production walk budget stays 12 ms (the tests freeze the clock)',
      () {
        expect(
          const HierarchyLimits().budget,
          const Duration(milliseconds: 12),
        );
      },
    );

    testWidgets(
      'over the time budget the rest is cut and the answer stays valid',
      (tester) async {
        await tester.pumpWidget(wide(200));
        // Every read of the clock costs 10 ms against a 5 ms budget; it is read every 32 steps.
        var t = 0;
        final s = snapshot(
          limits: const HierarchyLimits(budget: Duration(milliseconds: 5)),
          clock: () => Duration(milliseconds: t += 10),
        );
        expect(s.truncated, isTrue);
        expect(s.nodeCount, lessThan(100));
        expect(walk(payload(s)).length, s.nodeCount);
      },
    );

    testWidgets('a template over the byte cap is dropped, not trimmed', (
      tester,
    ) async {
      await tester.pumpWidget(wide(100));
      expect(
        buildViewHierarchy(
          limits: const HierarchyLimits(maxBytes: 100),
          clock: frozenClock,
        ),
        isNull,
      );
    });

    testWidgets('the default caps hold on a huge screen', (tester) async {
      await tester.pumpWidget(wide(3000));
      final s = snapshot();
      expect(s.truncated, isTrue);
      expect(s.nodeCount, lessThanOrEqualTo(const HierarchyLimits().maxNodes));
      expect(
        s.render().length,
        lessThanOrEqualTo(const HierarchyLimits().maxBytes),
      );
      jsonDecode(s.render()); // valid
    });
  });

  group('fail closed', () {
    testWidgets('an error anywhere in the walk is no snapshot at all', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          Column(
            children: const [
              Marker(width: 1),
              _Exploding(child: Marker(width: 2)),
              Marker(width: 3),
            ],
          ),
        ),
      );
      expect(buildViewHierarchy(clock: frozenClock), isNull);
    });

    testWidgets('a box that is not finite is left out, never written', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          Column(
            children: [
              const Marker(width: 91),
              Transform(
                transform: Matrix4.identity()..setEntry(0, 0, double.nan),
                child: const Marker(width: 92),
              ),
            ],
          ),
        ),
      );
      final s = snapshot();
      expect(s.bounds.every((v) => v.isFinite), isTrue);
      jsonDecode(s.render());
    });
  });
}

/// A widget whose render object throws when its parent places it: the walk must not survive it.
class _Exploding extends SingleChildRenderObjectWidget {
  const _Exploding({super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderExploding();
}

class _RenderExploding extends RenderProxyBox {
  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    throw StateError('boom');
  }
}

class _EmptyElement extends StatelessElement {
  _EmptyElement(super.widget);
}

class _FreeText {
  @override
  Type get runtimeType => _FreeTextType();
}

class _FreeTextType implements Type {
  @override
  String toString() => 'alice@example.com and a card 4242';
}
