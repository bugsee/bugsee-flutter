// The iOS half of the harness for a PHYSICAL iPhone: install, launch, crash and read back with
// `devicectl`, against the mock API on the Mac's LAN address (a phone has no loopback to the Mac).
//
//   BUGSEE_VERIFY_MOCK_BIND=<the Mac's LAN address> dart scripts/device/verify.dart ios-device \
//       --udid <device> --scenarios 10 [--reuse] [--allow-dirty]
//
// What a simulator cannot do and this does: the SDK's crash reporter exists only in the device slice
// of Bugsee.xcframework, so a recovered iOS crash report, an uncaught Objective-C exception and a
// Swift trap are only measurable here. The first launch after an install shows iOS's Local Network
// prompt ("Allow"): it cannot be answered by a script, so the first launch waits for it (the run says
// so; `--prompt-wait-minutes N` sets how long, `--keep-install` keeps an install that already has the permission). One scenario only (10, the crash and error matrix); scenarios 1 to 9 are written for the
// simulator and need its filesystem and `simctl`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'core/bundle.dart';
import 'core/crash_kinds.dart';
import 'core/experiment.dart';
import 'core/lan_host.dart';
import 'core/log_parsers.dart';
import 'mock.dart';
import 'report.dart';
import 'shell.dart';
import 'toolchain.dart';

const _bundleId = 'com.bugsee.bugseeFlutterExample';

class IosPhysical {
  IosPhysical(this.tc, this.udid);
  final Toolchain tc;
  final String udid;

  Future<Out> ctl(
    List<String> args, {
    Duration timeout = const Duration(minutes: 5),
  }) => sh(['xcrun', 'devicectl', ...args], timeout: timeout);

  Future<bool> reachable() async =>
      (await ctl(['device', 'info', 'lockState', '--device', udid])).ok;

  Future<String> model() async {
    final out = await ctl(['device', 'info', 'details', '--device', udid]);
    String pick(String key) =>
        RegExp('$key: (.*)').firstMatch(out.text)?.group(1)?.trim() ?? '?';
    return '${pick('marketingName')} ${pick('osVersionNumber')} ${pick('productType')}';
  }

  Future<bool> isInstalled() async => (await ctl([
    'device',
    'info',
    'apps',
    '--device',
    udid,
    '--bundle-id',
    _bundleId,
  ])).text.contains(_bundleId);

  Future<Out> install(String app) =>
      ctl(['device', 'install', 'app', '--device', udid, app]);

  Future<void> uninstall() async =>
      ctl(['device', 'uninstall', 'app', '--device', udid, _bundleId]);

  /// Launches with the process's stdout and stderr attached: the child lives while the app does, so
  /// its exit is the proof the process ended, and it carries the app's `VERIFY|` lines.
  Future<Child> launch() => Child.start([
    'xcrun',
    'devicectl',
    'device',
    'process',
    'launch',
    '--device',
    udid,
    '--terminate-existing',
    '--console',
    _bundleId,
  ]);
}

Future<int> runIosDevice({
  required Toolchain tc,
  required String udid,
  required int port,
  required Set<int>? wanted,
  required bool reuse,
  required bool allowDirty,
  required bool allowNotPossible,
  Duration promptWait = const Duration(minutes: 3),
  bool keepInstall = false,
}) async {
  if (udid.isEmpty) {
    stderr.writeln('--udid <device> is required (the harness never picks one)');
    return 64;
  }
  final hostProblem = lanHostProblem(mockHost);
  if (hostProblem != null) {
    stderr.writeln(
      'BUGSEE_VERIFY_MOCK_BIND must be the Mac\'s LAN IPv4 address for a physical iPhone: $hostProblem',
    );
    return 64;
  }
  final dev = IosPhysical(tc, udid);
  if (!await dev.reachable()) {
    stderr.writeln('$udid is not reachable (unlocked, trusted, on USB?)');
    return 1;
  }
  final gitStart = (await sh([
    'git',
    'status',
    '--porcelain',
    '--untracked-files=all',
  ], cwd: tc.repoRoot)).text;
  if (gitStart.isNotEmpty && !allowDirty) {
    stderr.writeln(
      'the working tree is not clean (or pass --allow-dirty):\n$gitStart',
    );
    return 1;
  }
  final env = <String, String>{
    ...await tc.describe(),
    'device': udid,
    'deviceModel': await dev.model(),
    'mockHost': mockHost,
  };
  final reporter = Reporter(
    'ios-device',
    tc.workDir,
    env,
    tag: wanted == null ? '' : '-${(wanted.toList()..sort()).join('-')}',
    allowNotPossible: allowNotPossible,
  );
  final say = reporter.say;
  // The recovered crash report is ACCEPTED (200): a refused one stays pending in the SDK, and a pending
  // report makes iOS stop a later launch of the same install (CLAUDE.md), which would end every kind
  // after the first as INVALID. The LAN address is passed here only: no other run leaves the loopback.
  final mock = await Mock.start(
    tc.repoRoot,
    tc.workDir,
    port,
    host: mockHost,
    uploadStatus: 200,
  );
  final app = '${tc.repoRoot}/example/build/ios/iphoneos/Runner.app';
  try {
    if (!(reuse && Directory(app).existsSync())) {
      say('building for the device (release, signed with the project team)');
      final b = await sh(
        [
          tc.flutter,
          'build',
          'ios',
          '--release',
          '-t',
          'lib/verify_main.dart',
          '--build-number',
          '1',
          '--build-name',
          '1.0.1',
          '--dart-define=VERIFY_SERVER=$mockHost:$port',
          '--dart-define=BUGSEE_ENDPOINT=http://$mockHost:$port',
        ],
        cwd: '${tc.repoRoot}/example',
        env: tc.buildEnv,
        timeout: const Duration(minutes: 40),
      );
      if (!b.ok) {
        stderr.writeln('flutter build ios failed:\n${b.stdout}\n${b.stderr}');
        return 1;
      }
    }
    final ctx = _Ctx(tc, dev, mock, app, say, promptWait, keepInstall);
    final scenarios = <int, Future<ScenarioResult> Function()>{
      10: ctx.crashMatrix,
    };
    for (final e in scenarios.entries) {
      if (wanted != null && !wanted.contains(e.key)) continue;
      reporter.add(await e.value());
    }
  } finally {
    await mock.stop();
  }
  return reporter.finish();
}

class _Ctx {
  _Ctx(
    this.tc,
    this.dev,
    this.mock,
    this.app,
    this.say,
    this.promptWait,
    this.keepInstall,
  );
  final Toolchain tc;
  final IosPhysical dev;
  final Mock mock;
  final String app;
  final void Function(String) say;

  /// How long the first launch waits for the Local Network prompt (`--prompt-wait-minutes`).
  final Duration promptWait;

  /// `--keep-install`: neither remove the app first nor at the end, so an install that already holds the
  /// Local Network permission keeps it. Off by default: the clean install is the guarded precondition.
  final bool keepInstall;
  final Set<String> _seen = {};
  final List<Child> _live = [];

  /// Stops every console child that is still running and removes the app: a guard that fails in the
  /// middle of the matrix must not leave `devicectl` processes, a running app or an install behind.
  Future<void> cleanup() async {
    for (final c in _live) {
      try {
        await c.stop();
      } on Object {
        // already gone
      }
    }
    _live.clear();
    if (keepInstall) return;
    try {
      await dev.uninstall();
    } on Object {
      // not installed
    }
  }

  Future<Bundle?> newBundle({
    bool Function(Bundle)? where,
    Duration timeout = const Duration(seconds: 90),
  }) => until<Bundle>(
    () async {
      for (final name in mock.storedNames()) {
        final Uint8List? bytes = await mock.plainBundle(name);
        if (bytes == null) continue;
        try {
          final b = Bundle.fromZip('mock:$name', bytes);
          if (_seen.contains('mock:$name')) continue;
          if (where != null && !where(b)) continue;
          _seen.add('mock:$name');
          return b;
        } on Object {
          continue; // still being written
        }
      }
      return null;
    },
    timeout: timeout,
    every: const Duration(seconds: 2),
  );

  Future<VerifyEvent?> waitEvent(
    bool Function(VerifyEvent) test, {
    Duration timeout = const Duration(seconds: 120),
  }) => until<VerifyEvent>(
    () async {
      for (final raw in await mock.events()) {
        final data = raw['data'] ?? raw;
        if (data is Map<String, Object?> && data['kind'] is String) {
          final e = VerifyEvent(data);
          if (test(e)) return e;
        }
      }
      return null;
    },
    timeout: timeout,
    every: const Duration(seconds: 2),
  );

  /// Launches, waits for the SDK to report launched. The first launch after an install waits for the
  /// Local Network prompt to be answered.
  Future<Child> launch(Run run, {required bool first}) async {
    await mock.reset();
    final child = await dev.launch();
    _live.add(child);
    if (first) {
      say(
        '  >>> PROMPT EXPECTED NOW: the iPhone shows "Allow Bugsee... to find devices on your local network": tap ALLOW within ${promptWait.inMinutes} minutes (phone on the same Wi-Fi as the Mac)',
      );
    }
    final launched = await waitEvent(
      (e) => e.kind == 'launch',
      timeout: first ? promptWait : const Duration(minutes: 2),
    );
    run.guard(
      'SDK launched',
      launched == null
          ? [
              'no launch event reached the mock (Local Network not allowed, or the Mac is not on the phone\'s network, or a report still pending from the previous kind stopped this launch); '
                  'the app console says: ${child.output.toString().split('\n').where((l) => l.contains('VERIFY|') || l.contains('Bugsee')).take(12).join(' | ')}',
            ]
          : launched['result'] == 'launched'
          ? []
          : ['launch result ${launched['result']}'],
      'launch -> ${launched?['result']}',
    );
    return child;
  }

  Future<ScenarioResult> crashMatrix() => runScenario(
    10,
    'Crash and error matrix: native signals, Objective-C, Swift, Dart routes',
    say,
    (run) async {
      if (!keepInstall && await dev.isInstalled()) await dev.uninstall();
      final r = await dev.install(app);
      run.guard(
        keepInstall
            ? 'precondition: the release build is installed over the existing install (--keep-install)'
            : 'precondition: the release build is installed on a clean device',
        r.ok ? [] : ['install failed: ${r.stdout}\n${r.stderr}'],
        'devicectl install ${app.split('/').last}',
      );
      try {
        var first = true;
        final seenBanner = <String>{};
        for (final k in crashKindTable.where(
          (k) => k.fatal && k.platforms.contains('ios'),
        )) {
          run.note('--- ${k.name} (${k.layer.name})');
          final c1 = await launch(run, first: first);
          first = false;
          await delay(5);
          await mock.command('crash ${k.name}');
          final code = await c1.process.exitCode.timeout(
            const Duration(seconds: 45),
            onTimeout: () => -999,
          );
          final out = c1.output.toString();
          run.guard(
            'event: the process ended after crash ${k.name}',
            code == -999 ? ['the app is still running after 45 s'] : [],
            'devicectl exit $code; last console lines: ${out.split('\n').where((l) => l.trim().isNotEmpty).toList().reversed.take(3).toList().reversed.join(' | ')}',
          );
          // The kernel's verdict as devicectl prints it: a native kind dies of its own signal; an
          // uncaught Objective-C exception ends in abort (6).
          final died = parseTerminatedSignal(out);
          run.note('[${k.name}] the process died of signal $died');
          if (k.signal != null) {
            run.expect(
              '[${k.name}] the process died of signal ${k.signal}',
              died == k.signal,
              'devicectl: App terminated due to signal $died',
            );
          }
          final banner = parseIosBanner(out);
          if (banner != null) {
            seenBanner.add('${banner.version} ${banner.build}');
          }
          // The build under test is the one the pins name (workbook 9.1.1): a banner of another version
          // or build, or a wrapper that is not this one, makes the experiment INVALID, as on every other path.
          final wrapperLog = parseWrapperLog(out);
          run.guard(
            'build: SDK banner and wrapper identity',
            (await tc.expectation('release')).iosProblems(banner, wrapperLog),
            '$banner; wrapper ${wrapperLog.registered}',
          );
          final c2 = await launch(run, first: false);
          final bundle = await newBundle(
            where: (x) => x.type == 'crash',
            timeout: const Duration(seconds: 120),
          );
          final reportEvidence = bundle == null
              ? 'none in 120 s'
              : '${bundle.source} ${bundle.type} "${bundle.summary}"';
          if (iosKnownNoReport.contains(k.name)) {
            run.knownGap(
              '[${k.name}] the next launch produced the recovered crash report (SDK 7.1.0 records none for this signal)',
              bundle != null,
              reportEvidence,
            );
          } else {
            run.expect(
              '[${k.name}] the next launch produced the recovered crash report',
              bundle != null,
              reportEvidence,
            );
          }
          if (bundle != null) {
            final crash = bundle.crash;
            final text = jsonEncode(crash ?? bundle.request);
            run.note(
              '[${k.name}] crash.json keys ${crash?.keys.toList()}; entries ${bundle.entries.map((e) => e['type']).toList()}',
            );
            run.note(
              '[${k.name}] sdk ${jsonEncode(bundle.sdk)}; summary "${bundle.summary}"; excerpt ${text.substring(0, text.length < 400 ? text.length : 400)}',
            );
            // What iOS records, compactly; the whole crash.json is saved beside the report.
            File('${tc.workDir}/ios-crash-${k.name}.json').writeAsStringSync(
              const JsonEncoder.withIndent('  ')
                  .convert(crash ?? bundle.request),
            );
            run.note(
              '[${k.name}] recorded: ${jsonEncode({
                for (final key in const ['signal', 'exception_type', 'code_type', 'handled', 'exception']) key: crash?[key],
              })}; threads ${(crash?['threads'] as List?)?.length}',
            );
            // Measured on a device (doc/verification.md, 2026-11-18): every kind records the signal it died of
            // by name, as a native exception that nobody handled; the Objective-C kinds record SIGABRT plus
            // an `exception` block whose `reason` is the NSException's reason.
            final reportSignal = (crash?['signal'] as Map?)?['name'];
            final wantSignal = iosReportSignalNames[k.signal ?? 6];
            run.expect(
              '[${k.name}] the report records $wantSignal, exception_type native, not handled',
              reportSignal == wantSignal &&
                  crash?['exception_type'] == 'native' &&
                  crash?['handled'] == false,
              'signal $reportSignal, exception_type ${crash?['exception_type']}, handled ${crash?['handled']}',
            );
            if (k.layer == CrashLayer.platform) {
              final ex = crash?['exception'] as Map?;
              run.expect(
                '[${k.name}] the exception block carries the NSException reason ${k.marker}',
                ex?['reason'] == k.marker,
                'exception name ${ex?['name']}, reason ${ex?['reason']}',
              );
            } else {
              run.expect(
                '[${k.name}] a native signal has no exception block',
                crash?['exception'] == null,
                'exception ${crash?['exception']}',
              );
            }
            if (k.marker != null) {
              run.expect(
                '[${k.name}] the report names ${k.marker}',
                text.contains(k.marker!) ||
                    jsonEncode(bundle.request).contains(k.marker!),
                'looked in crash.json and the request',
              );
            }
          }
          await c2.stop();
          await mock.reset();
          _seen.clear();
        }
        run.note('console banners seen: $seenBanner');
      } finally {
        await cleanup();
      }
      run.result.notCovered.addAll([
        'Dart routes on iOS (run on the simulator by scenarios 4 and 8)',
        'symbolication of the iOS report (needs the dSYM uploaded)',
      ]);
    },
  );
}
