// ignore_for_file: avoid_print
// Runs on a device or simulator (it needs the native SDKs):
//
//   cd example && flutter test integration_test/logs_test.dart -d <device> \
//       --dart-define=BUGSEE_ENDPOINT=http://<host>:<port> --dart-define=LOGS_HOLD=<seconds>
//
// What the app prints from Dart, through the installed log capture, with the SDK launched against a
// local stand-in for the Bugsee API (support/mock_api.py, which keeps the uploaded bundle), then a
// real report. The bundle's own log.json is the readback (`doc/logs.md`). The test prints one `LOGS:`
// line per fact so a run can be compared with the bundle. Every line the test records carries the
// marker LOGTEST.

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_example/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void say(String line) => debugPrint('LOGS: $line');

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'print, debugPrint and forwarded lines end up in the report with the plugin\'s source',
    (tester) async {
      // The capture is installed by `main` of the example app; the test installs it itself too
      // (idempotent) because it does not run `main`.
      expect(Bugsee.installLogCapture(), isTrue);
      expect(Bugsee.installLogCapture(), isTrue);
      expect(Bugsee.logCaptureInstalled, isTrue);

      // Before launch nothing is recorded: both SDKs drop it, and so does the capture.
      Bugsee.runWithLogCapture(() => print('LOGTEST 00 before launch'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      say('before launch: ${Bugsee.logCaptureStats}');
      expect(Bugsee.logCaptureStats.captured, 0);

      final launch = await Bugsee.launch(
        defaultToken,
        options: exampleOptions(),
      );
      say('launch: $launch');
      expect(await Bugsee.waitUntilLaunched(), isTrue);
      final options = await Bugsee.getLaunchOptions();
      say(
        'options: capture.logs=${options['com.bugsee.option.capture.logs']} '
        'capture.logs.level=${options['com.bugsee.option.capture.logs.level']}',
      );
      await Future<void>.delayed(const Duration(seconds: 2));

      Future<void> settle() async {
        final by = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(by)) {
          final s = Bugsee.logCaptureStats;
          if (s.submittedToSdk +
                  s.droppedByFilter +
                  s.refusedByNative +
                  s.filterFailures +
                  s.sendFailures >=
              s.captured) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      // ---- A. No filter: what the SDK records is what the app printed ------------------------
      Bugsee.runWithLogCapture(() {
        print('LOGTEST A1 print');
        debugPrint('LOGTEST A2 debugPrint');
        print(
          'LOGTEST A3 secret token=abc123 card 4111111111111111 password=hunter2',
        );
        print('LOGTEST A4 ${'long ' * 1200}END');
        print('LOGTEST A5 multi\nline\nmessage');
        print('LOGTEST A6 unicode éè \u{1F600} 中文');
      });
      // The levels of the app's own logging, forwarded; with capture.logs.level = info (the
      // example's option) the debug and verbose ones are not recorded.
      expect(
        Bugsee.forwardLog(
          'LOGTEST A7 forward error',
          level: LogLevel.error,
          tag: 'fwd',
        ),
        isTrue,
      );
      expect(
        Bugsee.forwardLog(
          'LOGTEST A8 forward warning',
          level: LogLevel.warning,
          tag: 'fwd',
        ),
        isTrue,
      );
      expect(
        Bugsee.forwardLog(
          'LOGTEST A9 forward info',
          level: LogLevel.info,
          tag: 'fwd',
        ),
        isTrue,
      );
      expect(
        Bugsee.forwardLog(
          'LOGTEST A10 forward debug (below level)',
          level: LogLevel.debug,
          tag: 'fwd',
        ),
        isTrue,
      );
      expect(
        Bugsee.forwardLog(
          'LOGTEST A11 forward verbose (below level)',
          level: LogLevel.verbose,
          tag: 'fwd',
        ),
        isTrue,
      );
      // The app's own deliberate line: source Bugsee, not the plugin's.
      await Bugsee.log(
        'LOGTEST A12 deliberate Bugsee.log',
        level: LogLevel.warning,
      );
      // The framework's error dump (a diagnostics tree) is never recorded.
      Bugsee.runWithLogCapture(() {
        FlutterError.dumpErrorToConsole(
          FlutterErrorDetails(
            exception: StateError('LOGTEST-TREE-ERROR'),
            library: 'example',
            informationCollector: () => [
              DiagnosticsNode.message('LOGTEST-TREE-SECRET widget text'),
            ],
          ),
          forceReport: true,
        );
      });
      await settle();
      say('A: ${Bugsee.logCaptureStats}');

      // ---- B. A Dart filter: nothing it drops or hides reaches the SDK -----------------------
      Bugsee.setLogFilter((event) {
        if (event.message.contains('internal')) return null;
        event.message = event.message
            .replaceAll(RegExp(r'\d{4,}'), '<digits>')
            .replaceAll('hunter2', '<redacted>');
        return event;
      });
      Bugsee.runWithLogCapture(() {
        print('LOGTEST B1 card 4111111111111111 password=hunter2');
        print('LOGTEST B2 internal host db-7.internal');
        debugPrint('LOGTEST B3 debugPrint pin 987654');
      });
      await settle();
      // A filter that throws drops the line (fail closed).
      Bugsee.setLogFilter((event) => throw StateError('bug in the filter'));
      Bugsee.runWithLogCapture(
        () => print('LOGTEST B4 filter throws, line must not appear'),
      );
      await settle();
      Bugsee.setLogFilter(null);
      say('B: ${Bugsee.logCaptureStats}');

      // ---- C. A flood: rate limited, never blocking ------------------------------------------
      final started = Stopwatch()..start();
      Bugsee.runWithLogCapture(() {
        for (var i = 0; i < 3000; i++) {
          print('LOGTEST C flood $i');
        }
      });
      say(
        'C: 3000 prints took ${started.elapsedMilliseconds} ms on the app\'s side',
      );
      await settle();
      Bugsee.runWithLogCapture(() => print('LOGTEST D after the flood'));
      await settle();

      final stats = Bugsee.logCaptureStats;
      say('stats: $stats');
      expect(stats.captured, greaterThan(20));
      // The burst (1000) fills the queue (1000): a flood of 3000 in one turn is cut by both bounds.
      expect(
        stats.droppedRateLimited + stats.droppedQueueFull,
        greaterThan(1900),
      );
      expect(stats.sendFailures, 0);
      expect(stats.refusedByNative, 0);
      expect(stats.droppedErrorDumps, greaterThanOrEqualTo(1));
      expect(stats.droppedBelowLevel, greaterThanOrEqualTo(2));
      expect(stats.filterFailures, 1);
      expect(stats.droppedByFilter, 1);
      expect(stats.truncated, 1);

      // A report: this is what the bundle (log.json) is read from.
      await Bugsee.upload('log capture test', 'lines printed from Dart');
      say('upload requested');
      await Future<void>.delayed(const Duration(seconds: 12));
      say('done');
      // Time to read the bundle from the device before the harness uninstalls the app (the run is
      // started with --dart-define=LOGS_HOLD=<seconds> for that).
      const hold = int.fromEnvironment('LOGS_HOLD');
      if (hold > 0) {
        say('holding for $hold s');
        await Future<void>.delayed(const Duration(seconds: hold));
      }
      await Bugsee.stop();
    },
  );
}
