// The PUBLIC widget, `BugseeSecureView`, end to end through the real process-wide registry and the
// real generated bridge, with only the platform channel mocked: mounting it registers a region,
// unmounting or disabling it unregisters, and what native receives is the whole set each time.
// (The measuring rules themselves are tested in secure_region_test.dart.)
import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel =
    'dev.flutter.pigeon.bugsee_flutter.BugseeBridgeHostApi.setSecureRectangles';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final received = <SecureRectanglesMessage>[];

  setUp(() {
    received.clear();
    binding.defaultBinaryMessenger.setMockMessageHandler(_channel, (
      ByteData? message,
    ) async {
      final args =
          BugseeBridgeHostApi.pigeonChannelCodec.decodeMessage(message)!
              as List<Object?>;
      received.add(args.single! as SecureRectanglesMessage);
      return BugseeBridgeHostApi.pigeonChannelCodec.encodeMessage(<Object?>[
        true,
      ]);
    });
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMessageHandler(_channel, null);
  });

  Widget host(Widget child) => Directionality(
    textDirection: TextDirection.ltr,
    child: Align(alignment: Alignment.topLeft, child: child),
  );

  /// The rectangles of the latest message, flat.
  List<double> latest() => [
    for (final v in received.last.views) ...v.rectangles,
  ];

  testWidgets('mounting registers the region, unmounting unregisters it', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const BugseeSecureView(child: SizedBox(width: 100, height: 50))),
    );
    await tester.pump();
    expect(received, isNotEmpty, reason: 'the region was published');
    expect(latest(), [0, 0, 100, 50]);

    final publishedBefore = received.length;
    await tester.pumpWidget(host(const SizedBox(width: 100, height: 50)));
    await tester.pump();
    expect(received.length, greaterThan(publishedBefore));
    expect(
      received.last.views.expand((v) => v.rectangles),
      isEmpty,
      reason: 'the whole set is published again, now with no region',
    );
  });

  testWidgets('the child is still shown', (tester) async {
    await tester.pumpWidget(
      host(const BugseeSecureView(child: Text('secret'))),
    );
    expect(find.text('secret'), findsOneWidget);
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pump();
  });

  testWidgets('enabled: false removes the redaction, true restores it', (
    tester,
  ) async {
    Widget view(bool enabled) => host(
      BugseeSecureView(
        enabled: enabled,
        child: const SizedBox(width: 40, height: 20),
      ),
    );
    await tester.pumpWidget(view(true));
    await tester.pump();
    expect(latest(), [0, 0, 40, 20]);

    await tester.pumpWidget(view(false));
    await tester.pump();
    expect(received.last.views.expand((v) => v.rectangles), isEmpty);

    await tester.pumpWidget(view(true));
    await tester.pump();
    expect(latest(), [0, 0, 40, 20]);

    await tester.pumpWidget(host(const SizedBox()));
    await tester.pump();
  });

  testWidgets('two views are two rectangles; removing one keeps the other', (
    tester,
  ) async {
    Widget two({required bool second}) => host(
      SizedBox(
        width: 200,
        height: 200,
        child: Stack(
          children: [
            const Positioned(
              left: 0,
              top: 0,
              child: BugseeSecureView(child: SizedBox(width: 10, height: 10)),
            ),
            if (second)
              const Positioned(
                left: 30,
                top: 40,
                child: BugseeSecureView(child: SizedBox(width: 20, height: 20)),
              ),
          ],
        ),
      ),
    );

    /// The rectangles as a set of `[l, t, r, b]`, whatever order native got them in.
    Set<String> rects() {
      final flat = latest();
      return {
        for (var i = 0; i < flat.length; i += 4)
          flat.sublist(i, i + 4).join(','),
      };
    }

    await tester.pumpWidget(two(second: true));
    await tester.pump();
    expect(rects(), {'0.0,0.0,10.0,10.0', '30.0,40.0,50.0,60.0'});

    await tester.pumpWidget(two(second: false));
    await tester.pump();
    expect(rects(), {'0.0,0.0,10.0,10.0'});

    await tester.pumpWidget(host(const SizedBox()));
    await tester.pump();
  });

  testWidgets('it is public API: only package:bugsee_flutter is needed', (
    tester,
  ) async {
    // This file reaches the widget through the public library; the registry it uses is the
    // process-wide one (no test-only injection), so a regression that wired the public widget
    // to a private registry would publish nothing above.
    expect(const BugseeSecureView(child: SizedBox()), isA<StatelessWidget>());
  });
}
