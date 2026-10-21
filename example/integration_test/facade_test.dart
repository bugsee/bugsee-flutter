// Runs on a device or simulator (it needs the native SDKs):
//
//   cd example && flutter test integration_test/facade_test.dart -d <device>
//
// Exercises the rest of the public API against the real SDKs, with a placeholder token: what the
// SDK keeps and answers (attributes, user identifier, blackout) is read back from it; what it only
// takes (events, traces, logs, breadcrumbs, notifications) is shown by the calls completing and by
// the SDK's own behaviour (a breadcrumb is accepted only once launched, `upload` makes the SDK run
// the report handler and raise its lifecycle events). Android and iOS run the same file; the
// differences the two SDKs have are asserted per platform and listed in doc/api-surface.md.

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_example/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void say(String line) => debugPrint('integration: $line');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final android = defaultTargetPlatform == TargetPlatform.android;

  testWidgets('attributes and identity work before launch, and persist', (
    tester,
  ) async {
    await Bugsee.clearAllAttributes();
    await Bugsee.clearUserIdentifier();
    expect(await Bugsee.getStatus(), BugseeStatus.stopped);

    // Every accepted type, read back as the type it went in as.
    await Bugsee.setAttribute('s', 'text');
    await Bugsee.setAttribute('b', true);
    await Bugsee.setAttribute('i', 7);
    await Bugsee.setAttribute('big', 1 << 40);
    await Bugsee.setAttribute('d', 0.5);
    expect(await Bugsee.getAttribute('s'), 'text');
    expect(await Bugsee.getAttribute('b'), true);
    expect(await Bugsee.getAttribute('i'), 7);
    expect(await Bugsee.getAttribute('big'), 1 << 40);
    expect(await Bugsee.getAttribute('d'), 0.5);
    expect(await Bugsee.getAttribute('absent'), isNull);
    final all = await Bugsee.getAllAttributes();
    say('attributes = $all');
    expect(all, {'s': 'text', 'b': true, 'i': 7, 'big': 1 << 40, 'd': 0.5});
    // A bool stays a bool and an int an int across the channel (not 1 and 7.0).
    expect(all['b'], isA<bool>());
    expect(all['i'], isA<int>());
    expect(all['d'], isA<double>());

    // A non-integer: Android stores a 32-bit float, iOS keeps the double.
    await Bugsee.setAttribute('pi', 3.141592653589793);
    final pi = await Bugsee.getAttribute('pi') as double;
    say('pi read back = $pi');
    expect(pi, android ? 3.1415927 : 3.141592653589793);
    await Bugsee.setAttribute('tenth', 0.1);
    expect(await Bugsee.getAttribute('tenth'), 0.1);

    // Replace, clear one, clear all.
    await Bugsee.setAttribute('s', 'replaced');
    expect(await Bugsee.getAttribute('s'), 'replaced');
    await Bugsee.clearAttribute('s');
    expect(await Bugsee.getAttribute('s'), isNull);
    await Bugsee.clearAttribute('s'); // no-op
    await Bugsee.clearAllAttributes();
    expect(await Bugsee.getAllAttributes(), isEmpty);

    // Dart refuses what no SDK stores; nothing reaches the SDK.
    await expectLater(
      Bugsee.setAttribute('k', 'x' * 1025),
      throwsA(isA<BugseeAttributeException>()),
    );
    await expectLater(
      Bugsee.setAttribute('', 'v'),
      throwsA(isA<BugseeAttributeException>()),
    );

    // The limit (1024 UTF-16 units): Android keeps it; iOS limits the archive to 1124 bytes, so a
    // 1024-character string is the SDK's call, and the answer is reported, not swallowed.
    Future<bool> kept(String value) async {
      try {
        await Bugsee.setAttribute('limit', value);
      } on BugseeAttributeException catch (e) {
        say('limit(${value.length}) -> ${e.reason.name}');
        expect(e.reason, AttributeFailure.rejected);
        return false;
      }
      expect(await Bugsee.getAttribute('limit'), value);
      return true;
    }

    expect(await kept('x' * 700), isTrue);
    final at1024 = await kept('y' * 1024);
    say('1024-char attribute kept: $at1024');
    if (android) expect(at1024, isTrue);
    // A rejected value leaves the previous one.
    if (!at1024) expect(await Bugsee.getAttribute('limit'), 'x' * 700);

    // The total limit: keep adding until the SDK says no; earlier values are untouched.
    await Bugsee.clearAllAttributes();
    var rejected = 0;
    var stored = 0;
    for (var i = 0; i < 80 && rejected == 0; i++) {
      try {
        await Bugsee.setAttribute('bulk$i', '$i${'z' * 600}');
        stored++;
      } on BugseeAttributeException catch (e) {
        expect(e.reason, AttributeFailure.rejected);
        rejected++;
      }
    }
    say('total limit: $stored stored before the first rejection');
    expect(rejected, 1, reason: 'the SDK has a total size limit');
    expect((await Bugsee.getAllAttributes()).length, stored);
    expect(await Bugsee.getAttribute('bulk0'), '0${'z' * 600}');
    // A rejected OVERWRITE keeps the old value on both platforms (iOS deletes the key it was
    // overwriting when the total overflows, so the plugin writes it back). 'cart' is small, the
    // attributes are full, and the new value does not fit.
    await Bugsee.clearAllAttributes();
    await Bugsee.setAttribute('cart', 'small');
    for (var i = 0; i < 200; i++) {
      try {
        await Bugsee.setAttribute('fill$i', 'z' * 600);
      } on BugseeAttributeException {
        break;
      }
    }
    await expectLater(
      Bugsee.setAttribute('cart', 'y' * 700),
      throwsA(
        isA<BugseeAttributeException>().having(
          (e) => e.reason,
          'reason',
          AttributeFailure.rejected,
        ),
      ),
    );
    expect(await Bugsee.getAttribute('cart'), 'small');
    say('rejected overwrite kept the previous value');
    await Bugsee.clearAllAttributes();

    // A whole double stays a double (Android may persist it as a float: it must not come back as an
    // int, and must not be reported as rejected).
    for (final whole in [0.0, 1.0, 3.0, -2.0, 1e10]) {
      await Bugsee.setAttribute('whole', whole);
      final back = await Bugsee.getAttribute('whole');
      expect(back, whole);
      expect(back, isA<double>(), reason: 'whole double $whole');
      expect((await Bugsee.getAllAttributes())['whole'], isA<double>());
    }
    await Bugsee.setAttribute('whole', 3); // and an int stays an int
    expect(await Bugsee.getAttribute('whole'), isA<int>());
    await Bugsee.clearAllAttributes();

    // Both getters answer the same for a double (Android persists a float, so it narrows).
    await Bugsee.setAttribute('pi2', 3.141592653589793);
    expect(
      (await Bugsee.getAllAttributes())['pi2'],
      await Bugsee.getAttribute('pi2'),
    );
    say('pi both getters = ${await Bugsee.getAttribute('pi2')}');
    await Bugsee.clearAllAttributes();

    // User identifier.
    expect(await Bugsee.getUserIdentifier(), isNull);
    await Bugsee.setUserIdentifier('user@example.com');
    expect(await Bugsee.getUserIdentifier(), 'user@example.com');
    await Bugsee.setUserIdentifier('');
    expect(
      await Bugsee.getUserIdentifier(),
      isNull,
      reason: 'empty clears on both',
    );
    await Bugsee.setUserIdentifier('u2');
    await Bugsee.clearUserIdentifier();
    expect(await Bugsee.getUserIdentifier(), isNull);
  });

  testWidgets('blackout is held before launch and read back', (tester) async {
    expect(await Bugsee.isBlackout(), isFalse);
    await Bugsee.startBlackout();
    expect(await Bugsee.isBlackout(), isTrue);
    await Bugsee.endBlackout();
    expect(await Bugsee.isBlackout(), isFalse);
  });

  testWidgets('before launch the SDKs drop data calls, and nothing throws', (
    tester,
  ) async {
    await Bugsee.event('before-launch', {'a': 1});
    await Bugsee.trace('before-launch', 1);
    await Bugsee.log('before launch');
    await Bugsee.notify('before launch');
    await Bugsee.upload('s', 'd');
    await Bugsee.showReportDialog(summary: 's');
    expect(
      await Bugsee.addBreadcrumb(
        const BugseeBreadcrumb(category: 'c', message: 'before launch'),
      ),
      isFalse,
      reason: 'breadcrumb capture is off until the SDK is launched with it on',
    );
  });

  testWidgets(
    'launched: report handler around upload, breadcrumb, data calls, blackout, secure view',
    (tester) async {
      final events = <LifecycleEvent>[];
      final sub = Bugsee.lifecycleEvents.listen(events.add);
      final deliveries = <String>[];
      final snapshots = <ReportSnapshot>[];

      await Bugsee.setReportHandler(
        BugseeReportHandler(
          onBeforeReportCreated: (report) async {
            deliveries.add('before:${report.type?.name}');
            await report.setAttribute('example.phase', 'before');
          },
          onAfterReportCreated: (report) async {
            deliveries.add('after:${report.type?.name}');
            await report.replaceLabels(['flutter-example']);
            await report.setAttribute('example.phase', 'after');
            snapshots.add(await report.read());
          },
        ),
      );
      expect(Bugsee.reportHandler, isNotNull);

      final result = await Bugsee.launch(
        defaultToken,
        options: exampleOptions(),
      );
      say('launch -> $result');
      expect(await Bugsee.waitUntilLaunched(), isTrue);

      // iOS stops the SDK on its own after the first upload that the server refuses (a placeholder
      // token: ReportUploadFailedWithFutureRetry, then Stopping, Stopped), so everything that needs
      // a launched SDK comes first and what could not be verified is reported, not skipped silently.
      // Android keeps running.
      await Bugsee.setAttribute('plan', 'pro');
      await Bugsee.setUserIdentifier('integration@example.com');

      // upload(): the SDK builds a report, runs the registered handler around it and says so.
      await Bugsee.upload(
        'Integration report',
        'made by facade_test',
        severity: ReportSeverity.critical,
        labels: ['from-test'],
      );
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline) &&
          !deliveries.any((d) => d.startsWith('after'))) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      say('deliveries = $deliveries');
      say(
        'report events = ${events.where((e) => e.reportId != null).map((e) => '${e.name}:${e.reportId}').toList()}',
      );
      expect(deliveries, containsAll(['before:bug', 'after:bug']));
      expect(
        snapshots.single.labels,
        contains('flutter-example'),
        reason: 'what the handler set is on the live report',
      );
      expect(snapshots.single.attributes['example.phase'], 'after');
      expect(snapshots.single.severity, ReportSeverity.critical);
      expect(
        snapshots.single.attributes['plan'],
        'pro',
        reason: 'the global attribute travels with the report',
      );

      final stillLaunched = await Bugsee.isLaunched();
      say('still launched after the report: $stillLaunched');

      // The SDK was launched with breadcrumb capture on, so it takes the crumb (while launched).
      for (final level in BreadcrumbLevel.values) {
        final taken = await Bugsee.addBreadcrumb(
          BugseeBreadcrumb(
            category: 'integration',
            message: 'crumb ${level.name}',
            level: level,
            type: 'user',
            data: const {'k': 'v', 'n': null},
          ),
        );
        say('breadcrumb ${level.name} taken: $taken');
        if (stillLaunched) expect(taken, isTrue, reason: level.name);
      }

      await Bugsee.event('opened', {
        'screen': 'facade',
        'n': null,
        'nested': {
          'list': [1, 'two', null, true],
        },
      });
      await Bugsee.event('plain');
      await Bugsee.trace('taps', 3);
      await Bugsee.trace('mode', 'fast');
      await Bugsee.trace('flag', true);
      await Bugsee.trace('ratio', 0.25);
      for (final level in LogLevel.values) {
        await Bugsee.log('integration log ${level.name}', level: level);
      }
      await Bugsee.notify(
        'Integration',
        body: 'body',
        severity: ReportSeverity.high,
        fields: {'b': '2', 'a': '1'},
        urgent: true,
      );

      // Blackout while running, with the lifecycle events the SDK raises for it.
      await Bugsee.startBlackout();
      expect(await Bugsee.isBlackout(), isTrue);
      await Bugsee.endBlackout();
      expect(await Bugsee.isBlackout(), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      say('events = ${events.map((e) => e.name).toList()}');
      expect(
        events.map((e) => e.name),
        containsAllInOrder(['Launching', 'Launched']),
      );
      expect(
        events.map((e) => e.name),
        containsAllInOrder(['BlackoutStarted', 'BlackoutEnded']),
      );

      // The public secure widget, mounted while launched.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BugseeSecureView(child: TextField(key: Key('card'))),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(milliseconds: 200));

      // Replacing and clearing the handler.
      await Bugsee.setReportHandler(null);
      expect(Bugsee.reportHandler, isNull);

      // Attributes and identity are still there, and read back.
      expect(await Bugsee.getAttribute('plan'), 'pro');
      expect(await Bugsee.getUserIdentifier(), 'integration@example.com');

      await Bugsee.stop();
      expect(await Bugsee.getStatus(), BugseeStatus.stopped);
      // After stop the SDK drops a breadcrumb, so the answer is false though capture is configured on.
      expect(
        await Bugsee.addBreadcrumb(
          const BugseeBreadcrumb(category: 'c', message: 'after stop'),
        ),
        isFalse,
      );
      // They persist across a stop.
      expect(await Bugsee.getAttribute('plan'), 'pro');
      await Bugsee.clearAllAttributes();
      await Bugsee.clearUserIdentifier();
      await sub.cancel();
    },
  );
}
