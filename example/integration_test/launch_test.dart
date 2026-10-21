// Runs on a device or simulator (it needs the native SDKs):
//
//   cd example && flutter test integration_test/launch_test.dart -d <device>
//
// The same sequence on Android and iOS: launch through the public API with a real-looking option
// set and a placeholder token, watch the status go Launching -> Launched, read the options back
// from the SDK, launch again (the SDK is already running), stop, and launch once more.

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_example/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('launch, read the options back, launch again, stop, relaunch', (
    tester,
  ) async {
    final android = defaultTargetPlatform == TargetPlatform.android;
    final seen = <BugseeStatus>[];
    final sub = Bugsee.statusChanges.listen((s) {
      debugPrint('integration: status -> ${s.name}');
      seen.add(s);
    });

    expect(await Bugsee.getStatus(), BugseeStatus.stopped);
    expect(
      await Bugsee.getLaunchOptions(),
      containsPair('com.bugsee.option.config.duration', 60),
      reason: 'before a launch the SDK reports its defaults',
    );
    expect(await Bugsee.getHostLaunchOptions(), isEmpty);

    // A blank token never reaches the SDK.
    await expectLater(
      Bugsee.launch(' '),
      throwsA(
        isA<BugseeLaunchException>().having(
          (e) => e.reason,
          'reason',
          LaunchFailure.invalidToken,
        ),
      ),
    );

    final result = await Bugsee.launch(defaultToken, options: exampleOptions());
    debugPrint('integration: launch -> $result');
    expect(result, LaunchResult.launched);
    expect(await Bugsee.getStatus(), BugseeStatus.launched);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(seen, containsAllInOrder([BugseeStatus.launched]));

    // What the SDK applied: ours merged over its defaults, enums as internal integers.
    final options = await Bugsee.getLaunchOptions();
    final host = await Bugsee.getHostLaunchOptions();
    debugPrint('integration: options = $options');
    debugPrint('integration: host options = $host');
    expect(options['com.bugsee.option.config.duration'], 45);
    expect(
      options['com.bugsee.option.capture.logs.level'],
      LogLevel.info.value,
    );
    expect(
      options['com.bugsee.option.capture.video.frame-rate'],
      FrameRate.medium.value,
    );
    expect(
      options['com.bugsee.option.reporting.defaults.crash-priority'],
      ReportSeverity.critical.value,
    );
    expect(options['com.bugsee.option.detect.hang'], true);
    expect(host['com.bugsee.option.config.duration'], 45);
    // The two SDKs differ on what a host option is: Android reports everything the app passed,
    // iOS only what differs from its default (`captureVideo: true` is iOS's default).
    expect(
      host.containsKey('com.bugsee.option.capture.video'),
      android,
      reason: 'documented on Bugsee.getHostLaunchOptions',
    );
    expect(
      options.keys.where((k) => k.contains(r'$$')),
      isEmpty,
      reason: 'hidden options are never handed back',
    );
    if (android) {
      expect(
        options['com.bugsee.option.capture.video.mode'],
        VideoMode.v2.value,
      );
      expect(
        options.containsKey('com.bugsee.option.capture.avplayer'),
        isFalse,
      );
    } else {
      expect(options['com.bugsee.option.capture.avplayer'], true);
      expect(
        options.containsKey('com.bugsee.option.capture.video.mode'),
        isFalse,
      );
    }

    // Launching again: already running, options not applied.
    expect(
      await Bugsee.launch(
        defaultToken,
        options: const BugseeOptions(configDuration: 20),
      ),
      LaunchResult.alreadyRunning,
    );
    expect(
      (await Bugsee.getLaunchOptions())['com.bugsee.option.config.duration'],
      45,
    );

    await Bugsee.stop();
    expect(await Bugsee.getStatus(), BugseeStatus.stopped);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      seen,
      containsAllInOrder([
        BugseeStatus.launched,
        BugseeStatus.stopping,
        BugseeStatus.stopped,
      ]),
    );

    // Launch after stop applies the new options.
    expect(
      await Bugsee.launch(
        defaultToken,
        options: const BugseeOptions(configDuration: 20),
      ),
      LaunchResult.launched,
    );
    expect(
      (await Bugsee.getLaunchOptions())['com.bugsee.option.config.duration'],
      20,
    );
    await Bugsee.stop();

    debugPrint(
      'integration: transitions = ${seen.map((s) => s.name).join(', ')}',
    );
    await sub.cancel();
  });
}
