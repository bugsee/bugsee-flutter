// The iOS simulator scenarios. The guards are the same as on Android (build, launch, precondition,
// event); where the simulator cannot do what a scenario needs, the scenario measures that fact (with a
// positive control) and ends as NOT POSSIBLE with the reason, instead of passing on absence (9.2).
import 'dart:convert';
import 'dart:io';

import 'checks.dart';
import 'core/bundle.dart';
import 'core/expectations.dart';
import 'core/experiment.dart';
import 'core/image.dart';
import 'core/log_parsers.dart';
import 'ios_build.dart';
import 'ios_device.dart';
import 'builds.dart';
import 'mock.dart';
import 'report.dart';
import 'shell.dart';
import 'toolchain.dart';

const bundleId = 'com.bugsee.bugseeFlutterExample';

Future<int> runIos(
  Toolchain tc, {
  required String udid,
  required int port,
  Set<int>? wanted,
  bool reuse = false,
  bool allowNotPossible = false,
  bool allowDirty = false,
}) async {
  if (udid.isEmpty) {
    stderr.writeln(
      '--udid <simulator> is required (the harness never uses "booted")',
    );
    return 64;
  }
  final dev = IosDevice(udid, bundleId);
  if (!await dev.isBooted()) {
    stderr.writeln('simulator $udid is not booted');
    return 1;
  }
  final env = <String, String>{
    ...await tc.describe(),
    'simulator': udid,
    'simulatorName': await dev.deviceName(),
    'runtime': await dev.runtime(),
  };
  final reporter = Reporter(
    'ios',
    tc.workDir,
    env,
    allowNotPossible: allowNotPossible,
    tag: wanted == null ? '' : '-${(wanted.toList()..sort()).join('')}',
  );
  final say = reporter.say;
  say('environment: $env');
  // Before anything runs: the tools every pixel check needs, and a clean tree (a scenario asserts it is
  // clean again at its end; --allow-dirty snapshots the dirty tree instead, and says so).
  final missing = await missingImageTools();
  if (missing != null) {
    stderr.writeln(missing);
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
      'the working tree is not clean (a run asserts it is clean at the end of every scenario; commit or stash, or pass --allow-dirty):\n$gitStart',
    );
    return 1;
  }
  final mock = await Mock.start(tc.repoRoot, tc.workDir, port);
  final pins = (await tc.expectation('debug')).pins;
  final builds = <String, IosBuild>{};
  Future<IosBuild> build(String name) async {
    if (builds[name] != null) return builds[name]!;
    final spec = iosBuildSpecs.firstWhere((b) => b.name == name);
    final app = '${tc.workDir}/apps/$name.app';
    if (reuse && Directory(app).existsSync()) {
      return builds[name] = await inspectIos(
        tc,
        name: name,
        mode: spec.mode,
        app: app,
        buildNumber: spec.buildNumber,
        derivedData: '${tc.workDir}/dd-ios',
      );
    }
    return builds[name] = await buildIos(
      tc,
      name: name,
      udid: udid,
      port: port,
      buildNumber: spec.buildNumber,
      extraDefines: spec.defines,
      say: say,
    );
  }

  final ctx = IosCtx(tc, dev, mock, pins, build, say);
  ctx._gitBaseline = gitStart;
  final scenarios = <int, Future<ScenarioResult> Function()>{
    1: ctx.registration,
    2: ctx.nativeCrash,
    3: ctx.handlers,
    4: ctx.dartExceptions,
    5: ctx.releaseModes,
    6: ctx.crashAcrossUpdate,
    7: ctx.secureDensity,
    8: ctx.hotRestart,
  };
  try {
    for (final e in scenarios.entries) {
      if (wanted != null && !wanted.contains(e.key)) continue;
      final r = await e.value();
      await ctx.cleanup(r);
      reporter.add(r);
    }
  } finally {
    await dev.terminate();
    await dev.uninstall();
    await mock.stop();
  }
  return reporter.finish();
}

class IosLaunched {
  IosLaunched(
    this.pid,
    this.since,
    this.log,
    this.events,
    this.banner,
    this.wrapper,
  );
  final int pid;
  final DateTime since;
  final String log;
  final List<VerifyEvent> events;
  final SdkBanner banner;
  final WrapperLog wrapper;
}

class IosCtx {
  IosCtx(this.tc, this.dev, this.mock, this.pins, this.build, this.say);
  final Toolchain tc;
  final IosDevice dev;
  final Mock mock;
  final Pins pins;
  final Future<IosBuild> Function(String) build;
  final void Function(String) say;
  final Set<String> _seen = {};
  String? _gitBaseline;
  final Map<String, BuildExpectation> _exp = {};

  Future<BuildExpectation> expectation(String mode) async =>
      _exp[mode] ??= await tc.expectation(mode);

  Future<void> cleanup(ScenarioResult r) async {
    try {
      await dev.terminate();
      await dev.uninstall();
      await mock.reset();
    } on Object catch (e) {
      r.notes.add('cleanup error: $e');
    }
    final problems = <String>[];
    if (await dev.isInstalled()) problems.add('$bundleId is still installed');
    final git = await sh([
      'git',
      'status',
      '--porcelain',
      '--untracked-files=all',
    ], cwd: tc.repoRoot);
    if (git.text != _gitBaseline) {
      problems.add(
        'git status is ${_gitBaseline!.isEmpty ? 'not clean' : 'not what it was at the start'}:\n${git.text}',
      );
    }
    final c = Check(
      'cleanup: simulator restored, git status clean',
      problems.isEmpty,
      problems.isEmpty
          ? 'app uninstalled, git status ${_gitBaseline!.isEmpty ? 'clean' : 'identical to the (dirty, --allow-dirty) start'}'
          : problems.join('; '),
      guard: true,
    );
    r.checks.add(c);
    say('  ${c.ok ? 'ok  ' : 'FAIL'} ${c.name} -- ${c.evidence}');
    if (!c.ok && r.status != Status.fail && r.status != Status.invalid) {
      r.status = Status.fail;
    }
  }

  // ---- shared guards --------------------------------------------------------------------------

  Future<void> install(Run run, IosBuild b, {bool wipe = true}) async {
    if (wipe) {
      await dev.uninstall();
      run.guard(
        'precondition: app data wiped',
        await dev.isInstalled()
            ? ['$bundleId is still installed after uninstall']
            : [],
        'uninstalled $bundleId',
      );
    }
    final r = await dev.install(b.app);
    final container = await dev.simctl([
      'get_app_container',
      dev.udid,
      bundleId,
    ]);
    String? installedBuild;
    if (container.ok) {
      final p = await sh([
        'plutil',
        '-extract',
        'CFBundleVersion',
        'raw',
        '${container.text}/Info.plist',
      ]);
      installedBuild = p.text;
    }
    run.guard('precondition: ${b.name} installed', [
      if (!r.ok) 'install failed: $r',
      if (installedBuild != '${b.buildNumber}')
        'CFBundleVersion $installedBuild, expected ${b.buildNumber}',
    ], 'CFBundleVersion $installedBuild');
    _seen.clear();
    await mock.reset();
  }

  Future<IosLaunched> launch(
    Run run,
    IosBuild b, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final exp = await expectation(b.mode);
    run.guard('build: artefact set', b.artefactProblems(pins), b.describe());
    await dev.terminate();
    final since = DateTime.now();
    final pid = await dev.launch();
    if (pid == null) {
      run.guard('SDK launched', ['simctl launch returned no pid'], '');
    }
    var log = '';
    var events = <VerifyEvent>[];
    final ok = await until<bool>(
      () async {
        log = await dev.log(since: since);
        events = parseVerifyEvents(log);
        return events.any((e) => e.kind == 'launch') &&
                events.any((e) => e.kind == 'status')
            ? true
            : null;
      },
      timeout: timeout,
      every: const Duration(seconds: 4),
    );
    final banner = parseIosBanner(log);
    final wrapper = parseWrapperLog(log);
    run.guard(
      'build: SDK banner and wrapper identity',
      exp.iosProblems(banner, wrapper),
      '$banner; wrapper registered ${wrapper.registered}, refined ${wrapper.refined} ${wrapper.context}',
    );
    final launch = events.where((e) => e.kind == 'launch').toList();
    final statuses = events
        .where((e) => e.kind == 'status')
        .map((e) => e['status'])
        .toList();
    run.guard(
      'SDK launched',
      [
        if (ok == null) 'no launch and status event within $timeout',
        if (launch.isNotEmpty && launch.first['result'] != 'launched')
          'launch result ${launch.first['result']}',
        if (statuses.isNotEmpty && statuses.last != 'launched')
          'status ${statuses.last}',
      ],
      'launch -> ${launch.isEmpty ? '?' : launch.first['result']}, status ${statuses.isEmpty ? '?' : statuses.last}',
    );
    return IosLaunched(pid!, since, log, events, banner!, wrapper);
  }

  Future<VerifyEvent?> waitEvent(
    DateTime since,
    bool Function(VerifyEvent) test, {
    Duration timeout = const Duration(seconds: 60),
  }) => until<VerifyEvent>(
    () async {
      for (final e in await dev.events(since: since)) {
        if (test(e)) return e;
      }
      return null;
    },
    timeout: timeout,
    every: const Duration(seconds: 4),
  );

  static String _key(Bundle b) =>
      '${b.request['created_on']}|${b.type}|${b.summary}|${jsonEncode(b.manifest['time'])}';

  /// iOS hands the upload to the system and keeps no bundle file: the bundle is what the mock API (which
  /// refuses the upload with 503 and stores the body) received.
  Future<Bundle?> newBundle({
    bool Function(Bundle)? where,
    Duration timeout = const Duration(seconds: 90),
  }) => until<Bundle>(
    () async {
      for (final name in mock.storedNames()) {
        try {
          final bytes = await mock.plainBundle(name);
          if (bytes == null) continue;
          final b = Bundle.fromZip('mock:$name', bytes);
          if (_seen.contains(_key(b))) continue;
          if (where != null && !where(b)) continue;
          _seen.add(_key(b));
          return b;
        } on Object {
          // still being written
        }
      }
      return null;
    },
    timeout: timeout,
    every: const Duration(seconds: 2),
  );

  Future<Bundle> report(
    Run run,
    String command, {
    bool Function(Bundle)? where,
  }) async {
    await mock.command(command);
    final b = await newBundle(where: where);
    run.guard(
      'event: a report was produced for "$command"',
      b == null ? ['no new bundle reached the mock API in 90 s'] : [],
      b == null ? '' : '${b.type} "${b.summary}" ${b.source}',
    );
    return b!;
  }

  /// A report that IS the feature under test: its absence is a failed result, not an invalid experiment.
  Future<Bundle?> product(
    Run run,
    String command, {
    bool Function(Bundle)? where,
  }) async {
    await mock.command(command);
    final b = await newBundle(where: where);
    run.expect(
      'a report was produced for "$command"',
      b != null,
      b == null
          ? 'no new bundle reached the mock API in 90 s'
          : '${b.type} "${b.summary}" ${b.source}',
    );
    return b;
  }

  /// SIGSEGV to the app and proof it died of it (9.1.4): launchd's own account of the exit.
  Future<void> crash(Run run, int pid) async {
    run.guard(
      'precondition: the process to kill is running',
      dev.alive(pid) ? [] : ['pid $pid is not alive'],
      'pid $pid',
    );
    final since = DateTime.now();
    final kill = await dev.killSegv(pid);
    await delay(4);
    final log = await dev.simctl([
      'spawn',
      dev.udid,
      'log',
      'show',
      '--style',
      'compact',
      '--info',
      '--debug',
      '--start',
      _ts(since.subtract(const Duration(seconds: 2))),
    ], timeout: const Duration(minutes: 3));
    final exit = parseIosExit(log.stdout, pid);
    run.guard(
      'event: the process died of signal 11',
      [
        if (!kill.ok) 'kill failed: $kill',
        if (dev.alive(pid)) 'pid $pid is still alive',
        if (exit == null) 'launchd logged no exit for pid $pid',
        if (exit != null && exit.signal != 'SIGSEGV')
          'exited due to ${exit.signal}',
      ],
      'kill -SEGV $pid; launchd_sim: exited due to ${exit?.signal} | sent by ${exit?.sentBy}',
    );
  }

  static String _ts(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // ---- 1 --------------------------------------------------------------------------------------

  Future<ScenarioResult>
  registration() => runScenario(1, 'Registration and artefacts', say, (
    run,
  ) async {
    final b = await build('debug');
    final exp = await expectation('debug');
    await install(run, b);
    final l = await launch(run, b);
    final reg = l.log.indexOf('wrapper registered');
    final banner = l.log.indexOf('Bugsee IOS SDK');
    run.expect(
      'wrapper registered before the SDK started',
      reg >= 0 && banner > reg,
      'log offsets: registered $reg, SDK banner $banner',
    );
    run.expect(
      'the SDK resolved by SwiftPM is the pinned tag at the pinned revision (not a branch or a local path)',
      b.artefactProblems(pins).isEmpty,
      b.describe(),
    );
    run.expect(
      'the feedback add-on registered through its +load',
      l.log.contains('feedback add-on registered'),
      'log line present: ${l.log.contains('feedback add-on registered')}',
    );
    final report = await this.report(run, 'upload s1');
    final problems = exp.wrapperInReport(report.wrapper);
    run.expect(
      'wrapper identity (type, version, Flutter/Dart/engine/build mode) reaches the report environment',
      problems.isEmpty,
      problems.isEmpty ? jsonEncode(report.wrapper) : problems.join('; '),
    );
    run.expect(
      'sdk.version in the report is the banner version',
      report.sdk['version'] == l.banner.version,
      '${report.sdk['version']} [${report.sdk['build']}] vs banner ${l.banner}',
    );
    run.expect(
      'a live report has no identity_source',
      report.identitySource == null,
      '${report.identitySource}',
    );
    run.expect(
      'app identity is the installed build',
      report.app['build'] == '${b.buildNumber}',
      '${report.app['version']} (${report.app['build']})',
    );
    run.note(
      'no manifest and no NDK artefact on iOS: the Android-only checks of this scenario (merged manifest provider, four libbugsee*.so, Gradle plugin) do not apply',
    );
    run.result.notCovered.addAll([
      'release and profile builds (not buildable for a simulator by the Flutter tool: see scenario 5)',
      'a physical iPhone',
    ]);
  });

  // ---- 2 --------------------------------------------------------------------------------------

  Future<ScenarioResult>
  nativeCrash() => runScenario(2, 'Native crash (SIGSEGV), retained bundle, recovered identity', say, (
    run,
  ) async {
    final b = await build('debug');
    await install(run, b);
    final l = await launch(run, b);
    await delay(5);
    // The positive control (9.2): the same setup CAN produce a report.
    final control = await report(run, 'upload control');
    run.expect(
      'control: a live report reaches the mock API in this setup',
      control.summary == 'verify upload control',
      '${control.type} ${control.source}',
    );
    await crash(run, l.pid);
    final l2 = await launch(run, b);
    await delay(20);
    final crashBundle = await newBundle(
      where: (x) => x.type == 'crash',
      timeout: const Duration(seconds: 60),
    );
    final events = await dev.events(since: l2.since);
    // The positive control AFTER the window, from the relaunched process: it CAN upload, so the absence
    // above is the SDK's, not a relaunched process that could not reach the mock (9.2).
    final after = await report(run, 'upload control-after');
    run.expect(
      'control after the window: the RELAUNCHED process uploads a live report',
      after.summary == 'verify upload control-after',
      '${after.type} ${after.source}',
    );
    // And nothing crash-shaped retained on the device side: the SDK keeps the bundles it could not upload
    // under the container's Library/Caches/com.bugsee.data/capture/bundles; their types are read.
    final container = await dev.dataContainer();
    final listing = container == null
        ? ''
        : (await sh([
            'find',
            container,
            '-type',
            'f',
            '(',
            '-iname',
            '*.bundle.zip',
            '-o',
            '-iname',
            '*.dmp',
            '-o',
            '-iname',
            '*.plcrash',
            '-o',
            '-iname',
            '*crash*report*',
            ')',
          ])).text;
    final files = listing.split('\n').where((l) => l.isNotEmpty).toList();
    final types = <String>[];
    for (final f in files.where((f) => f.endsWith('.bundle.zip'))) {
      final r = await sh([
        'python3',
        '-I',
        '-c',
        'import zipfile,json,sys; print(json.loads(zipfile.ZipFile(sys.argv[1]).read("request.json"))["type"])',
        f,
      ]);
      types.add(r.ok ? r.text : 'unreadable');
    }
    final other = files.where((f) => !f.endsWith('.bundle.zip')).toList();
    run.expect(
      'the simulator container retains no crash bundle and no crash file (retained bundles: ${types.length}, types $types)',
      container != null &&
          !types.contains('crash') &&
          !types.contains('unreadable') &&
          other.isEmpty,
      'searched $container: ${files.map((f) => f.split('/').last).toList()}',
    );
    run.expect(
      'no crash report is recovered on the simulator (nothing at the mock API after the relaunch)',
      crashBundle == null,
      crashBundle == null
          ? 'none within 80 s'
          : '${crashBundle.type} ${crashBundle.source}',
    );
    run.expect(
      'no RelaunchedAfterCrash lifecycle event either',
      !events.any(
        (e) =>
            e.kind == 'lifecycle' &&
            '${e['event']}'.contains('RelaunchedAfterCrash'),
      ),
      'lifecycle events: ${events.where((e) => e.kind == 'lifecycle').map((e) => e['event']).toList()}',
    );
    // Why: the simulator slice of the SDK has no crash reporter; the device slice does (the control).
    final xc = await _xcframework();
    final simStrings = await sh([
      'bash',
      '-c',
      "strings '$xc/ios-arm64_x86_64-simulator/Bugsee.framework/Bugsee' | grep -ciE 'BGSCrashManager|PLCrashReporter' || true",
    ]);
    final devStrings = await sh([
      'bash',
      '-c',
      "strings '$xc/ios-arm64/Bugsee.framework/Bugsee' | grep -ciE 'BGSCrashManager|PLCrashReporter' || true",
    ]);
    run.expect(
      'the reason: the simulator slice of the SDK carries no crash reporter symbols, the device slice does',
      simStrings.text == '0' && int.parse(devStrings.text) > 0,
      'ios-arm64_x86_64-simulator: ${simStrings.text} matching strings; ios-arm64: ${devStrings.text}',
    );
    run.result.notCovered.addAll([
      'everything about a RECOVERED iOS crash report: the retained bundle, request.json identity and identity_source on the recovered report, the recovered-report handler dispatch (off-main, bounded cap, late completion re-persist). They need a physical iPhone.',
    ]);
    throw NotPossible(
      'the iOS SDK\'s simulator slice has no crash reporter (measured: a SIGSEGV was proven, the relaunch recovered nothing while a live report arrived; the device slice has the symbols); a physical iPhone is required. airplane mode does not exist on the simulator either (the mock API refusing the upload with 503 is its stand-in)',
    );
  });

  Future<String> _xcframework() async {
    final r = await sh([
      'find',
      '${tc.workDir}/dd-ios/SourcePackages/artifacts',
      '-maxdepth',
      '4',
      '-name',
      'Bugsee.xcframework',
    ]);
    return r.text.split('\n').first;
  }

  // ---- 3 --------------------------------------------------------------------------------------

  Future<ScenarioResult> handlers() => runScenario(
    3,
    'Report handlers (a recovered report is not producible on the simulator: live reports measured)',
    say,
    (run) async {
      final b = await build('debug');
      await install(run, b);
      final l = await launch(run, b);
      await delay(4);
      final since = DateTime.now();
      final live = await report(run, 'upload h3');
      await delay(3);
      final events = await dev.events(since: since);
      final before = events
          .where((e) => e.kind == 'handler' && e['phase'] == 'before')
          .toList();
      final after = events
          .where((e) => e.kind == 'handler' && e['phase'] == 'after')
          .toList();
      run.expect(
        'the Dart handler ran for a live report: before and after, once each',
        before.length == 1 && after.length == 1,
        'before x${before.length}, after x${after.length}',
      );
      run.expect(
        'the report type the handler saw is bug',
        before.isNotEmpty && before.first['type'] == 'bug',
        '${before.map((e) => e['type'])}',
      );
      run.expect(
        'the Dart enrichment landed in the bundle: attribute, label and file',
        live.attributes.containsKey('verify.before') &&
            live.attributes.containsKey('verify.after') &&
            live.labels.contains('verify-after') &&
            live
                .entriesOfType('attachment')
                .any((e) => e['name'] == 'verify-enrichment'),
        'attrs ${live.attributes.keys.toList()}, labels ${live.labels}, attachments ${live.entriesOfType('attachment').map((e) => e['name']).toList()}',
      );
      final log = await dev.log(since: since);
      final lines = RegExp(
        r'Runner\[(\d+):(\w+)\][^\n]*BugseeFlutter\] report handler[^\n]*',
      ).allMatches(log).map((m) => m.group(0)!).toList();
      run.note(
        'native pipeline lines for the live report: ${lines.take(8).toList()}',
      );
      final mainTid = RegExp(
        r'Runner\[(\d+):(\w+)\][^\n]*VERIFY\|\{"kind":"main"',
      ).firstMatch(l.log)?.group(2);
      final handlerTid = RegExp(
        r'Runner\[\d+:(\w+)\][^\n]*VERIFY\|\{"kind":"handler"[^\n]*"phase":"before"',
      ).firstMatch(log)?.group(1);
      run.note(
        'thread of the Dart handler: $handlerTid; thread of main(): $mainTid (the main thread when equal: Dart runs on the platform thread on iOS)',
      );
      run.result.notCovered.addAll([
        'the RECOVERED report path of the workbook table (iOS: dispatched off-main under a bounded cap, a late completion re-persists the report): the simulator cannot produce a recovered crash or exit (scenario 2), so only the live path is measured',
        'iOS recovery of an abnormal exit (watchdog, jetsam): not producible on a simulator',
      ]);
      // The recovered-report half cannot be measured here.
      throw NotPossible(
        'the recovered-report half is NOT POSSIBLE on the simulator (no crash reporter, scenario 2); the live-report half above was measured',
      );
    },
  );

  // ---- 4 --------------------------------------------------------------------------------------

  Future<ScenarioResult> dartExceptions() => runScenario(
    4,
    'Dart exceptions end to end (debug on the simulator)',
    say,
    (run) async {
      final b = await build('debug');
      await install(run, b);
      final l = await launch(run, b);
      await delay(4);
      // The positive control (9.2): a live report reaches the mock API in this setup.
      final control = await report(run, 'upload control4');
      run.expect(
        'control: a live report reaches the mock API in this setup',
        control.summary == 'verify upload control4',
        '${control.type} ${control.source}',
      );
      await mock.command('log-handled h4');
      await mock.command('log-unhandled u4');
      await mock.command('throw-async a4');
      await delay(30);
      final log = await dev.log(since: l.since);
      final refused = RegExp(
        'logged exceptions are not filed on the simulator',
      ).allMatches(log).length;
      final exceptionReports = mock.storedNames();
      final bundles = <Bundle>[];
      for (final n in exceptionReports) {
        final bytes = await mock.plainBundle(n);
        if (bytes != null) bundles.add(Bundle.fromZip(n, bytes));
      }
      final carriers = bundles.where((x) => x.crash != null).toList();
      run.expect(
        'the SDK says it files none: "logged exceptions are not filed on the simulator" once per exception command',
        refused >= 3,
        '$refused log lines',
      );
      run.expect(
        'and none reached the mock API (only the control report did)',
        carriers.isEmpty &&
            bundles.any((x) => x.summary == 'verify upload control4'),
        'bundles: ${bundles.map((x) => '${x.type}:${x.summary}').toList()}',
      );
      final commands = parseVerifyEvents(
        log,
      ).where((e) => e.kind == 'command-error').toList();
      run.expect(
        'the Dart side raised no error handing the exceptions over',
        commands.isEmpty,
        '$commands',
      );
      run.result.notCovered.addAll([
        'what the exception carrier looks like in an iOS bundle (an NSException named FlutterManagedException, internalType in the document), handled, unhandled and async: the iOS SDK does not file logged exceptions on a simulator (Bugsee.m: `#if !TARGET_OS_SIMULATOR`), so no bundle exists to read; a physical iPhone is required',
        'the RELEASE build with --obfuscate --split-debug-info on iOS and its symbolization: Flutter does not build release for a simulator (scenario 5); no obfuscated stack was captured',
        'whether the carrier name survives a release static link on iOS',
      ]);
      throw NotPossible(
        'the iOS SDK files no logged exception on a simulator (measured: its own log line, nothing reached the mock API while a live report did; SDK source `#if !TARGET_OS_SIMULATOR`), so the iOS exception bundle cannot be produced or read here; a physical iPhone is required. The Android side is scenario 4 of the Android run',
      );
    },
  );

  // ---- 5 --------------------------------------------------------------------------------------

  Future<ScenarioResult> releaseModes() => runScenario(
    5,
    'Release and profile behaviour: debug battery on the simulator + the device release link',
    say,
    (run) async {
      final b = await build('debug');
      await install(run, b);
      await launch(run, b);
      await delay(5);
      await mock.command('vh');
      await mock.command('net http://127.0.0.1:${mock.port}/ping?s5');
      await mock.command('print s5');
      await delay(4);
      final plain = await report(run, 'upload plain');
      checkViewHierarchy(run, 'debug', plain, obfuscated: false);
      checkLogs(run, 'debug', plain, 's5');
      checkNetwork(run, 'debug', plain, 's5');
      final withFile = await product(
        run,
        'upload-with-file f5',
        where: (x) => x.summary == 'verify upload-with-file f5',
      );
      if (withFile != null) {
        final fileEntry = withFile
            .entriesOfType('attachment')
            .where((e) => e['name'] == 'from-command');
        run.expect(
          'attachment from the handler: the file is in the bundle with its content',
          fileEntry.isNotEmpty &&
              utf8.decode(withFile.content(fileEntry.first)) ==
                  'attached by a command f5',
          fileEntry.isEmpty
              ? 'absent: ${withFile.entriesOfType('attachment').map((e) => e['name']).toList()}'
              : 'content ok',
        );
      }
      // No filter on the summary: the summary is what is being checked.
      final created = await product(run, 'create-report c5');
      if (created != null) {
        run.expect(
          'createReport: the created report was uploaded with the summary set',
          created.summary == 'verify created c5',
          '${created.type} "${created.summary}"',
        );
      }
      await _deviceRelease(run);
      run.result.notCovered.addAll([
        'release and profile Dart behaviour on iOS (view hierarchy walk, HttpOverrides, log capture, secure regions in an AOT build): the Flutter tool refuses release/profile for a simulator ("Release mode is not supported for simulators") and xcodebuild with -sdk iphonesimulator reaches `aot_assembly_release`, which throws "release/profile builds are only supported for physical devices"; no physical iPhone was available. The Dart code paths are platform-independent and were run in release on Android (scenario 5, Android section)',
      ]);
    },
  );

  /// The iOS feedback add-on dead-strip question: does the add-on's +load registration survive a RELEASE
  /// static link. The device release link is built (`flutter build ios --release --no-codesign`) and its
  /// binary is inspected statically, since it cannot run on a simulator.
  Future<void> _deviceRelease(Run run) async {
    final example = '${tc.repoRoot}/example';
    final symbols = '${tc.workDir}/symbols/ios-release';
    Directory(symbols).createSync(recursive: true);
    final r = await sh(
      [
        tc.flutter,
        'build',
        'ios',
        '--release',
        '--no-codesign',
        '--obfuscate',
        '--split-debug-info=$symbols',
        '-t',
        'lib/verify_main.dart',
        '--dart-define=VERIFY_SERVER=localhost:${mock.port}',
        '--dart-define=BUGSEE_ENDPOINT=http://localhost:${mock.port}',
      ],
      cwd: example,
      env: tc.buildEnv,
      timeout: const Duration(minutes: 40),
    );
    run.expect(
      'the iOS device release build (--obfuscate --split-debug-info) succeeds',
      r.ok,
      r.ok
          ? 'built'
          : '${r.stdout}\n${r.stderr}'
                .split('\n')
                .reversed
                .take(8)
                .toList()
                .reversed
                .join(' | '),
    );
    if (!r.ok) return;
    final app = '$example/build/ios/iphoneos/Runner.app';
    final binary = '$app/Runner';
    run.expect(
      'release symbols were written for the obfuscated build',
      Directory(symbols).listSync().any((f) => f.path.endsWith('.symbols')),
      '${Directory(symbols).listSync().map((f) => f.path.split('/').last).toList()}',
    );
    final nm = await sh(['nm', binary]);
    final nl = await sh([
      'otool',
      '-v',
      '-s',
      '__DATA_CONST',
      '__objc_nlclslist',
      binary,
    ]);
    final withLoad = parseNonLazyClassList(nl.stdout);
    run.note(
      'device release Runner: ${withLoad.length} classes with a +load (the runtime calls them at launch): ${[for (final a in withLoad) '0x${a.toRadixString(16)}']}',
    );
    final settings = await sh([
      'xcodebuild',
      '-workspace',
      'Runner.xcworkspace',
      '-scheme',
      'Runner',
      '-configuration',
      'Release',
      '-sdk',
      'iphoneos',
      '-showBuildSettings',
    ], cwd: '$example/ios');
    final deadStrip = RegExp(
      r'DEAD_CODE_STRIPPING = (\w+)',
    ).firstMatch(settings.stdout)?.group(1);
    run.note(
      'the Release configuration links with DEAD_CODE_STRIPPING = $deadStrip',
    );
    for (final cls in [
      'BugseeFeedbackAutoRegister',
      'BGSFlutterFeedbackRegistrar',
      'BGSFlutterWrapperRegistrar',
    ]) {
      final address = objcClassAddress(nm.stdout, cls);
      run.expect(
        'the +load registrar $cls survives the release static link (dead strip ${deadStrip ?? '?'}): present in the binary and in __objc_nlclslist',
        address != null && withLoad.contains(address),
        address == null
            ? 'no such class symbol in the release binary'
            : 'class at 0x${address.toRadixString(16)}${withLoad.contains(address) ? ', listed as having a +load' : ', NOT in __objc_nlclslist'}',
      );
    }
  }

  // ---- 6 --------------------------------------------------------------------------------------

  Future<ScenarioResult> crashAcrossUpdate() => runScenario(
    6,
    'Crash across an app update (workbook 9.3.4)',
    say,
    (run) async {
      throw NotPossible(
        'the simulator recovers no crash (scenario 2: the SDK\'s simulator slice has no crash reporter), so there is no recovered report whose build could be compared across an update; a physical iPhone is required (and the report-identity spec says the iOS side is not implemented: a crash across an update is discarded by the version gate)',
      );
    },
  );

  // ---- 7 --------------------------------------------------------------------------------------

  Future<ScenarioResult> secureDensity() => runScenario(
    7,
    'Secure rectangles at density != 1 (the simulator is 3x)',
    say,
    (run) async {
      final b = await build('debug');
      await install(run, b);
      await launch(run, b);
      await delay(4);
      final since = DateTime.now();
      await mock.command('geometry');
      final geo = await waitEvent(since, (e) => e.kind == 'geometry');
      run.expect(
        'the app sees a device pixel ratio other than 1',
        geo != null && (geo['devicePixelRatio'] as num) != 1,
        'ratio ${geo?['devicePixelRatio']}, physical ${geo?['physicalWidth']}x${geo?['physicalHeight']}, logical box ${geo?['secureLogical']}',
      );
      // A pair of reports (secured, unsecured). The video's last frame can be a transient one on a loaded
      // host (the first run once read a secured frame that matched the real screen nowhere): the pair is
      // taken again, up to three times, until the secured frame agrees with the unsecured one outside the box;
      // a redaction that blacks out the whole frame does so on every attempt and fails the recorded check.
      Bundle? on, off;
      RawImage? onFrame, offFrame;
      for (var attempt = 1; attempt <= 3; attempt++) {
        await mock.command('secure on');
        await delay(3);
        on = await report(
          run,
          'upload on-ios-$attempt',
          where: (x) => x.summary == 'verify upload on-ios-$attempt',
        );
        await mock.command('secure off');
        await delay(4);
        off = await report(
          run,
          'upload off-ios-$attempt',
          where: (x) => x.summary == 'verify upload off-ios-$attempt',
        );
        final a = await lastVideoFrame(on, tc.workDir, 'ios-on-probe');
        final b = await lastVideoFrame(off, tc.workDir, 'ios-off-probe');
        final box = b?.boundingBoxOf(const Rgb(255, 0, 255));
        final stable =
            a != null &&
            b != null &&
            box != null &&
            a.agreementOutside(b, box.grow(20)) >= 0.95;
        if (stable || attempt == 3) {
          if (attempt > 1) {
            run.note(
              'the secured/unsecured pair was taken $attempt times before the frames agreed outside the box',
            );
          }
          break;
        }
        run.note(
          'attempt $attempt: the secured frame did not agree with the unsecured one outside the box; taking the pair again',
        );
      }
      final offBundle = off!;
      onFrame = await requireVideoFrame(
        run,
        'ios @3x',
        on!,
        tc.workDir,
        'ios-on',
      );
      offFrame = await requireVideoFrame(
        run,
        'ios @3x',
        off,
        tc.workDir,
        'ios-off',
      );
      if (onFrame != null && offFrame != null) {
        final region = checkRedaction(
          run,
          'ios @3x',
          onFrame,
          offFrame,
          evidenceDir: '${tc.workDir}/failed-frames',
        );
        final layout = videoLayout(off);
        if (region != null && geo != null && layout != null) {
          checkRegionPlacement(
            run,
            'ios @3x',
            region,
            layout,
            offFrame,
            (geo['secureLogical'] as Map).cast<String, num>(),
            (geo['devicePixelRatio'] as num).toDouble(),
          );
        } else if (region != null) {
          run.note(
            'the iOS video carries no layout the harness can read (video.aux: ${offBundle.entriesOfType('video.aux').map((e) => utf8.decode(offBundle.content(e)))}): the region placement was not checked, only the redaction',
          );
        }
      }
      await checkScreenshotRedaction(
        run,
        'ios @3x',
        on,
        off,
        tc.workDir,
        expectContent: true,
      );
      run.result.notCovered.addAll([
        'a density change at run time: a simulator\'s scale is fixed by the device model (`wm density` has no iOS equivalent), so the claim that rectangles follow a density change without a republish cannot be exercised here; only the 3x state is measured',
        'an iPhone with a different scale (2x) was not booted',
      ]);
    },
  );

  // ---- 8 --------------------------------------------------------------------------------------

  Future<ScenarioResult> hotRestart() => runScenario(
    8,
    'Hot restart: lifecycle, handlers and the report-handler sweep',
    say,
    (run) async {
      final example = '${tc.repoRoot}/example';
      await dev.terminate();
      await dev.uninstall();
      final since = DateTime.now();
      final child = await Child.start(
        [
          tc.flutter,
          'run',
          '-d',
          dev.udid,
          '-t',
          'lib/verify_main.dart',
          '--dart-define=VERIFY_SERVER=localhost:${mock.port}',
          '--dart-define=BUGSEE_ENDPOINT=http://localhost:${mock.port}',
        ],
        cwd: example,
        env: tc.buildEnv,
      );
      try {
        final up = await child.waitFor(
          'Flutter run key commands',
          timeout: const Duration(minutes: 10),
        );
        run.guard(
          'precondition: flutter run is up with a debug session',
          up
              ? []
              : [
                  'flutter run did not reach the key-commands banner: ${child.output}',
                ],
          'flutter run attached',
        );
        final started = await waitEvent(
          since,
          (e) => e.kind == 'launch',
          timeout: const Duration(seconds: 90),
        );
        run.guard(
          'SDK launched',
          started == null ? ['no launch event'] : [],
          'launch -> ${started?['result']}',
        );
        final beforeLog = await dev.log(since: since);
        final banner = parseIosBanner(beforeLog);
        run.guard(
          'build: SDK banner',
          (await expectation('debug'))
              .iosProblems(banner, parseWrapperLog(beforeLog))
              .where(
                (p) => !p.contains('wrapper refined') && !p.contains('context'),
              )
              .toList(),
          '$banner',
        );
        final mainBefore = parseVerifyEvents(
          beforeLog,
        ).where((e) => e.kind == 'main').toList();
        await mock.command('upload before-restart');
        await newBundle();
        await delay(3);
        final mark = DateTime.now();
        child.write('R');
        final restarted = await child.waitFor(
          'Performing hot restart',
          timeout: const Duration(minutes: 2),
        );
        run.guard(
          'event: a hot restart was performed',
          restarted
              ? []
              : ['flutter run never reported "Performing hot restart"'],
          'flutter run: ${child.output.toString().split('\n').where((x) => x.contains('hot restart')).take(2).join(' | ')}',
        );
        final reMain = await waitEvent(
          mark,
          (e) => e.kind == 'main',
          timeout: const Duration(seconds: 90),
        );
        run.expect(
          'the Dart isolate restarted inside the SAME process (same pid, a new main())',
          reMain != null && reMain['pid'] == mainBefore.last['pid'],
          'before pid ${mainBefore.last['pid']}; after pid ${reMain?['pid']}',
        );
        await delay(6);
        final post = afterLastMain(
          parseVerifyEvents(await dev.log(since: mark)),
        );
        final launchAfter = post.where((e) => e.kind == 'launch').toList();
        run.expect(
          'the SDK was not launched twice: the new isolate finds it running (alreadyRunning)',
          launchAfter.isNotEmpty &&
              launchAfter.every((e) => e['result'] == 'alreadyRunning'),
          '${launchAfter.map((e) => e['result']).toList()}',
        );
        final status = post.where((e) => e.kind == 'status').toList();
        run.expect(
          'the status is replayed to the new isolate: launched',
          status.isNotEmpty && status.last['status'] == 'launched',
          '${status.map((e) => e['status']).toList()}',
        );
        final replayed = [
          for (final e in post)
            if (e.kind == 'lifecycle') '${e['event']}',
        ];
        final sync = post.where((x) => x.kind == 'status-sync').toList();
        run.expect(
          'the new isolate\'s synchronous Bugsee.status is launched (the SDK was launched before the restart)',
          sync.isNotEmpty && sync.last['status'] == 'launched',
          'status-sync after the restart: ${sync.map((x) => x['status']).toList()}; lifecycle events the new isolate saw before any report: $replayed',
        );
        final afterMark = DateTime.now();
        await mock.command('upload after-restart');
        final bundle = await newBundle(
          where: (x) => x.summary == 'verify upload after-restart',
        );
        await delay(3);
        final after = afterLastMain(
          parseVerifyEvents(await dev.log(since: afterMark)),
        );
        final handlers = after.where((e) => e.kind == 'handler').toList();
        run.expect(
          'handlers still flow after the restart, exactly one before and one after (no duplicate registration)',
          handlers.where((e) => e['phase'] == 'before').length == 1 &&
              handlers.where((e) => e['phase'] == 'after').length == 1,
          'before x${handlers.where((e) => e['phase'] == 'before').length}, after x${handlers.where((e) => e['phase'] == 'after').length}',
        );
        final lifecycle = after
            .where((e) => e.kind == 'lifecycle')
            .map((e) => '${e['event']}')
            .toList();
        run.expect(
          'lifecycle events flow after the restart, once each',
          lifecycle.where((e) => e.contains('BeforeReportAssembled')).length ==
              1,
          '$lifecycle',
        );
        run.expect(
          'the report built after the restart carries the Dart enrichment',
          bundle != null && bundle.attributes.containsKey('verify.before'),
          bundle == null ? 'no bundle' : '${bundle.attributes.keys.toList()}',
        );
        final registered = RegExp(
          r'wrapper registered',
        ).allMatches(await dev.log(since: since)).length;
        run.note(
          '"wrapper registered" lines since the session began: $registered (it registers once per process)',
        );
      } finally {
        child.write('q');
        await delay(2);
        await child.stop();
      }
      run.result.notCovered.addAll([
        'hot RELOAD (no isolate restart)',
        'a hot restart while a report handler delivery is in flight',
      ]);
    },
  );
}
