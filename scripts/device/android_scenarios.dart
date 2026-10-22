// The Android scenarios (PLAN.md Phase 7). Each runs through [runScenario] and the guards of
// [AndroidSession], so none can reach a measurement without having proved the build, the launch, the
// staged precondition and the event (workbook 9.1). Numbering follows the task list; doc/verification.md
// quotes the evidence.
import 'dart:convert';
import 'dart:io';

import 'android_device.dart';
import 'android_harness.dart';
import 'build.dart';
import 'builds.dart';
import 'checks.dart';
import 'core/bundle.dart';
import 'core/experiment.dart';
import 'core/expectations.dart';
import 'core/log_parsers.dart';
import 'core/symbols.dart';
import 'mock.dart';
import 'report.dart';
import 'shell.dart';
import 'toolchain.dart';

const pkg = 'com.bugsee.bugsee_flutter_example';

Future<int> runAndroid(
  Toolchain tc, {
  required String serial,
  required int port,
  Set<int>? wanted,
  bool reuse = false,
  bool allowNotPossible = false,
  bool allowDirty = false,
}) async {
  if (serial.isEmpty) {
    stderr.writeln(
      '--serial <emulator-NNNN> is required (the harness never picks a device)',
    );
    return 64;
  }
  final dev = AndroidDevice(tc, serial, pkg);
  if (!await dev.isBooted()) {
    stderr.writeln('$serial is not booted');
    return 1;
  }
  final rooted = await dev.enableRoot();
  final abi = await dev.abi();
  final env = <String, String>{
    ...await tc.describe(),
    'device': serial,
    'apiLevel': await dev.prop('ro.build.version.sdk'),
    'androidRelease': await dev.prop('ro.build.version.release'),
    'image': await dev.prop('ro.build.fingerprint'),
    'abi': abi,
    'density': '${await dev.currentDensity()}',
    'root': '$rooted',
  };
  final reporter = Reporter(
    'android',
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
  if (!await dev.reverse(port)) {
    stderr.writeln('adb reverse tcp:$port failed');
    await mock.stop();
    return 1;
  }
  final pins = (await tc.expectation('debug')).pins;
  final s = AndroidSession(tc, dev, mock, pins, abi);
  final builds = <String, AndroidBuild>{};
  Future<AndroidBuild> build(String name) async {
    if (builds[name] != null) return builds[name]!;
    final spec = androidBuildSpecs.firstWhere((b) => b.name == name);
    final apk = '${tc.workDir}/apks/$name.apk';
    if (reuse && File(apk).existsSync()) {
      return builds[name] = await inspectAndroid(
        tc,
        name: name,
        mode: spec.mode,
        apk: apk,
        buildNumber: spec.buildNumber,
        obfuscated: spec.obfuscate,
        symbolsDir: spec.obfuscate ? '${tc.workDir}/symbols/$name' : null,
        mapping: File('${tc.workDir}/apks/$name.mapping.txt').existsSync()
            ? '${tc.workDir}/apks/$name.mapping.txt'
            : null,
      );
    }
    return builds[name] = await buildAndroid(
      tc,
      name: name,
      mode: spec.mode,
      port: port,
      buildNumber: spec.buildNumber,
      obfuscate: spec.obfuscate,
      extraDefines: spec.defines,
      say: say,
    );
  }

  final ctx = AndroidCtx(tc, dev, mock, s, build, say, reporter);
  ctx._gitBaseline = gitStart;
  final scenarios = <int, Future<ScenarioResult> Function()>{
    1: () => ctx.registration(),
    2: () => ctx.nativeCrash(),
    3: () => ctx.handlers(),
    4: () => ctx.dartExceptions(),
    5: () => ctx.releaseModes(),
    6: () => ctx.crashAcrossUpdate(),
    7: () => ctx.secureDensity(),
    8: () => ctx.hotRestart(),
    9: () => ctx.screenshotGap(),
  };
  try {
    for (final e in scenarios.entries) {
      if (wanted != null && !wanted.contains(e.key)) continue;
      final r = await e.value();
      await ctx.cleanup(r);
      reporter.add(r);
    }
  } finally {
    await dev.airplane(false);
    await dev.density(null);
    await dev.uninstall();
    await dev.unreverse(port);
    await mock.stop();
  }
  return reporter.finish();
}

class AndroidCtx {
  AndroidCtx(
    this.tc,
    this.dev,
    this.mock,
    this.s,
    this.build,
    this.say,
    this.reporter,
  );
  final Toolchain tc;
  final AndroidDevice dev;
  final Mock mock;
  final AndroidSession s;
  final Future<AndroidBuild> Function(String) build;
  final void Function(String) say;
  final Reporter reporter;
  String? _gitBaseline;

  /// The cycle of scenario 2 is also the subject of scenario 3: measured once per build.
  final Map<String, CrashCycle> _cycles = {};

  /// After every scenario: nothing left behind (the device, the repo), asserted.
  Future<void> cleanup(ScenarioResult r) async {
    try {
      await dev.airplane(false);
      await dev.density(null);
      await dev.forceStop();
      await dev.uninstall();
      await mock.reset();
    } on Object catch (e) {
      r.notes.add('cleanup error: $e');
    }
    final problems = <String>[];
    if (await dev.airplaneOn()) problems.add('airplane mode is still on');
    if (await dev.isInstalled()) problems.add('${dev.pkg} is still installed');
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
      'cleanup: device restored, git status clean',
      problems.isEmpty,
      problems.isEmpty
          ? 'airplane off, app uninstalled, git status ${_gitBaseline!.isEmpty ? 'clean' : 'identical to the (dirty, --allow-dirty) start'}'
          : problems.join('; '),
      guard: true,
    );
    r.checks.add(c);
    say('  ${c.ok ? 'ok  ' : 'FAIL'} ${c.name} -- ${c.evidence}');
    if (!c.ok && r.status == Status.pass) r.status = Status.fail;
  }

  Future<Bundle> _report(
    Run run,
    String command, {
    bool Function(Bundle)? where,
  }) async {
    await s.command(command);
    final b = await s.newBundle(where: where);
    run.guard(
      'event: a report was produced for "$command"',
      b == null ? ['no new bundle appeared in 60 s'] : [],
      b == null ? '' : '${b.type} "${b.summary}" ${b.source}',
    );
    return b!;
  }

  /// A report that IS the feature under test (an exception report, a created report, a file attached
  /// from the handler): its absence is a failed result, not an invalid experiment.
  Future<Bundle?> _product(
    Run run,
    String label,
    String command, {
    bool Function(Bundle)? where,
  }) async {
    await s.command(command);
    final b = await s.newBundle(where: where);
    run.expect(
      '[$label] a report was produced for "$command"',
      b != null,
      b == null
          ? 'no new bundle appeared in 60 s'
          : '${b.type} "${b.summary}" ${b.source}',
    );
    return b;
  }

  // ---- 1 --------------------------------------------------------------------------------------

  Future<ScenarioResult>
  registration() => runScenario(1, 'Registration and artefacts', say, (
    run,
  ) async {
    for (final name in ['debug', 'releaseA']) {
      final b = await build(name);
      run.note('--- $name');
      final exp = await s.expectation(b.mode);
      await s.install(run, b);
      final l = await s.launch(run, b);
      // The wrapper registered BEFORE the SDK printed its banner (it launches from its own provider).
      final reg = l.log.indexOf('wrapper registered');
      final banner = l.log.indexOf('Bugsee Android SDK');
      run.expect(
        '[$name] wrapper registered before the SDK started',
        reg >= 0 && banner > reg,
        'log offsets: registered $reg, SDK banner $banner',
      );
      final providers = parseProviders(b.manifestXml);
      final wp = providers
          .where(
            (p) => p.name == 'com.bugsee.flutter.FlutterWrapperInitProvider',
          )
          .toList();
      run.expect(
        '[$name] wrapper provider present in the merged manifest with initOrder 200',
        wp.isNotEmpty && wp.first.initOrder == 200,
        wp.isEmpty ? 'absent' : '${wp.first.attributes}',
      );
      run.expect(
        '[$name] NDK artefact and Gradle plugin as pinned',
        b.artefactProblems(s.pins, s.abi).isEmpty,
        b.describe(s.abi),
      );
      run.expect(
        '[$name] the Gradle plugin stamped a build id into the APK',
        b.buildUuid != null,
        '${b.buildUuid}',
      );
      // Capture >= 30 s (the crashpad handler is a separate process and logs later than the app).
      await delay(32);
      final log = await dev.logcat();
      final plain = distinctBugseeLibs(log);
      final mapped = mappedBugseeLibs(
        await dev.maps(l.pid),
        b.entries,
        s.abi,
        apkPath: await dev.apkPath(),
      );
      final union = {...plain, ...mapped};
      run.note(
        '[$name] workbook measure (logcat grep, >=30 s): ${plain.length} distinct $plain',
      );
      run.note(
        '[$name] /proc/${l.pid}/maps resolved against the APK: ${mapped.length} in-process $mapped',
      );
      run.expect(
        '[$name] libbugsee-native and libbugsee-crashcp are mapped into the app process',
        mapped.containsAll({'libbugsee-native.so', 'libbugsee-crashcp.so'}),
        '$mapped',
      );
      run.note(
        '[$name] distinct libbugsee*.so seen on a cold start (logcat union maps): ${union.length} $union (logcat names only libraries executed from files in the data directory; scenario 2 measures the crashpad pair in the handler process)',
      );
      // The identity reaches a report.
      final report = await _report(run, 'upload s1-$name');
      final problems = exp.wrapperInReport(report.wrapper);
      run.expect(
        '[$name] wrapper identity (type, version, Flutter/Dart/engine/build mode) reaches the report environment',
        problems.isEmpty,
        problems.isEmpty ? jsonEncode(report.wrapper) : problems.join('; '),
      );
      run.expect(
        '[$name] sdk.version and sdk.build in the report match the banner',
        report.sdk['version'] == l.banner.version &&
            report.sdk['build'] == l.banner.build,
        '${report.sdk['version']} [${report.sdk['build']}]',
      );
      run.expect(
        '[$name] a live report has no identity_source',
        report.identitySource == null,
        '${report.identitySource}',
      );
      run.expect(
        '[$name] app identity is the installed build',
        report.app['build'] == '${b.buildNumber}' &&
            report.app['version'] == '1.0.${b.buildNumber}',
        '${report.app['version']} (${report.app['build']})',
      );
      await dev.uninstall();
    }
    run.result.notCovered.addAll([
      'x86_64 / armeabi-v7a ABIs (arm64 emulator only)',
      'Gradle plugin 4.0.6 failure (the broken arm of the experiment) was not reproduced; only the fixed arm is measured',
    ]);
  });

  // ---- 2 / 3: one crash cycle per build --------------------------------------------------------

  Future<CrashCycle> _cycle(Run run, String name) async {
    final b = await build(name);
    if (_cycles[name] != null) return _cycles[name]!;
    final exp = await s.expectation(b.mode);
    await s.install(run, b);
    final l = await s.launch(run, b);
    await delay(6);
    final bundlesBefore = await dev.clearBundles();
    run.guard(
      'precondition: no retained bundle before the crash',
      bundlesBefore.isEmpty ? [] : ['still there: $bundlesBefore'],
      'files/bugsee_data/bundles is empty (via ${dev.via})',
    );
    final coldLog = await dev.logcat();
    final mapped = mappedBugseeLibs(
      await dev.maps(l.pid),
      b.entries,
      s.abi,
      apkPath: await dev.apkPath(),
    );
    // The crashpad handler is a separate process (not in this process's maps): the SDK extracts the
    // trampoline and the handler into the app's no_backup directory and execs the trampoline.
    final extractedDir = dev.useRunAs
        ? 'no_backup/bugsee_crashpad_handler'
        : '${dev.dataDir}/no_backup/bugsee_crashpad_handler';
    final extracted = distinctBugseeLibs(
      (await dev.inApp(['sh', '-c', "'ls $extractedDir/*'"])).stdout,
    );
    final crash = await s.crash(run, l.pid);
    final crashLog = await dev.logcat();
    await s.airplane(run, true);
    final l2 = await s.launch(run, b);
    final bundle = await s.newBundle(
      where: (x) => x.type == 'crash' && x.crash?['ndkCrash'] == true,
      timeout: const Duration(seconds: 90),
    );
    await delay(3);
    final afterLog = await dev.logcat();
    await s.airplane(run, false);
    final cycle = CrashCycle(
      b,
      exp,
      l,
      crash,
      l2,
      bundle,
      coldLog + crashLog + afterLog,
      mapped,
      extracted,
    );
    _cycles[name] = cycle;
    return cycle;
  }

  Future<ScenarioResult> nativeCrash() => runScenario(
    2,
    'Native crash (SIGSEGV), retained bundle, recovered identity',
    say,
    (run) async {
      for (final name in ['debug', 'releaseA']) {
        final c = await _cycle(run, name);
        run.note('--- $name (${c.crash.method})');
        final bundle = c.bundle;
        run.expect(
          '[$name] a bundle was retained and produced by the relaunch',
          bundle != null,
          bundle == null
              ? 'none after 90 s'
              : '${bundle.source} ${bundle.type}',
        );
        if (bundle == null) continue;
        final crash = bundle.crash;
        final types = bundle.entries.map((e) => e['type']).toList();
        run.expect(
          '[$name] the crash entry and the minidump are in the manifest',
          types.contains('crash') && types.contains('minidump'),
          '$types',
        );
        final signal = crash?['signal'] as Map?;
        run.expect(
          '[$name] crash.json records SIGSEGV 11, native',
          crash?['ndkCrash'] == true &&
              signal?['number'] == 11 &&
              signal?['name'] == 'SIGSEGV' &&
              crash?['exception_type'] == 'native',
          'ndkCrash=${crash?['ndkCrash']} signal=$signal exception_type=${crash?['exception_type']}',
        );
        run.expect(
          '[$name] crash.json uuid is the Gradle plugin build id of THIS apk',
          crash?['uuid'] == c.build.buildUuid,
          'bundle ${crash?['uuid']} apk ${c.build.buildUuid}',
        );
        final problems = c.exp.wrapperInReport(bundle.wrapper);
        run.expect(
          '[$name] sdk.wrapper identity is on the RECOVERED report (the "fails only on a relaunch after a crash" trap)',
          problems.isEmpty,
          problems.isEmpty ? jsonEncode(bundle.wrapper) : problems.join('; '),
        );
        run.expect(
          '[$name] identity_source marker (specs/sdk/report-identity)',
          bundle.identitySource == 'session',
          'environment.identity_source = ${bundle.identitySource}',
        );
        run.expect(
          '[$name] report type crash, severity from the option',
          bundle.type == 'crash' && bundle.request['severity'] == 4,
          'type ${bundle.type}, severity ${bundle.request['severity']}',
        );
        run.expect(
          '[$name] app build on the recovered report is the crashed build',
          bundle.app['build'] == '${c.build.buildNumber}',
          '${bundle.app['version']} (${bundle.app['build']})',
        );
        final plain = distinctBugseeLibs(c.allLogs);
        final pair = {
          'libbugsee-crashpad-trampoline.so',
          'libbugsee-crashpad-handler.so',
        };
        final inProcess = {'libbugsee-native.so', 'libbugsee-crashcp.so'};
        final ranHandler = bundle.entriesOfType('minidump').isNotEmpty;
        final handlerMeasured = c.crash.handlerLibs.containsAll(pair);
        run.note(
          '[$name] workbook measure (logcat grep over cold start + crash + relaunch): ${plain.length} distinct $plain. It can only ever see libraries executed from FILES in the app data directory (an `avc: granted { execute }` audit line names the path); libraries mapped from base.apk are never named in logcat, so it cannot reach four on this setup',
        );
        run.expect(
          '[$name] MEASURED: libbugsee-native.so and libbugsee-crashcp.so are mapped into the app process (/proc/PID/maps resolved against the APK)',
          c.mapped.containsAll(inProcess),
          '${c.mapped}',
        );
        run.expect(
          '[$name] the crashpad pair: ${handlerMeasured ? 'MEASURED in the handler process\'s own maps' : 'INFERRED (the handler process was not caught): extracted next to the app and its minidump is in the bundle'}',
          handlerMeasured || (c.extracted.containsAll(pair) && ranHandler),
          'handler process: ${c.crash.handlerPs ?? 'not caught'}; its maps: ${c.crash.handlerLibs}; extracted: ${c.extracted}; minidump in bundle: $ranHandler',
        );
        run.note(
          '[$name] four distinct libbugsee*.so: ${{...c.mapped, ...(handlerMeasured ? c.crash.handlerLibs : c.extracted)}.length} (${handlerMeasured ? 'all four measured' : '2 measured + 2 inferred'})',
        );
      }
      run.result.notCovered.addAll([
        'a native crash while the app is in the background, or during launch (early crash)',
        'a crash with the SDK stopped',
      ]);
    },
  );

  Future<ScenarioResult>
  handlers() => runScenario(3, 'Report handlers on a recovered report', say, (
    run,
  ) async {
    for (final name in ['debug', 'releaseA']) {
      final c = await _cycle(run, name);
      run.note('--- $name');
      final ev = {
        ...c.relaunch.events
            .where((e) => e.kind == 'handler')
            .map((e) => e['phase']),
      };
      final fullLog = parseVerifyEvents(
        c.allLogs,
      ).where((e) => e.kind == 'handler').toList();
      final before = fullLog.where((e) => e['phase'] == 'before').toList();
      final after = fullLog.where((e) => e['phase'] == 'after').toList();
      run.expect(
        '[$name] the Dart handler ran for the recovered report: before and after',
        before.isNotEmpty && after.isNotEmpty,
        'before x${before.length}, after x${after.length}; phases seen at relaunch: $ev',
      );
      run.expect(
        '[$name] the report type the handler saw is crash',
        before.isNotEmpty && before.first['type'] == 'crash',
        '${before.map((e) => e['type'])}',
      );
      final ids = {
        ...before.map((e) => e['deliveryId']),
        ...after.map((e) => e['deliveryId']),
      };
      run.expect(
        '[$name] one delivery id per phase (not delivered twice)',
        ids.length == 2,
        '$ids',
      );
      // Timing and thread, from the wrapper's own log lines (threadtime: pid tid).
      final threadLines = RegExp(
        r'(\d+)\s+(\d+) \w BugseeFlutter: report handler (rh-\d+) (phase=\w+|delivery gap=[^\n]*|completed by=\w+)',
      ).allMatches(c.allLogs).toList();
      for (final m in threadLines) {
        run.note(
          '[$name] BugseeFlutter pid=${m.group(1)} tid=${m.group(2)} ${m.group(3)} ${m.group(4)}${m.group(1) == m.group(2) ? ' (main thread)' : ' (non-main thread)'}',
        );
      }
      final phaseThread = threadLines.where(
        (m) => m.group(4)!.startsWith('phase='),
      );
      run.expect(
        '[$name] the SDK called the native handler off the main thread (measured; the workbook table says main for Android)',
        phaseThread.isNotEmpty &&
            phaseThread.every((m) => m.group(1) != m.group(2)),
        phaseThread
            .map((m) => 'tid ${m.group(2)} vs pid ${m.group(1)}')
            .join(', '),
      );
      final windows = RegExp(
        r'report handler rh-\d+ phase=\w+ deadline=(\d+)',
      ).allMatches(c.allLogs).map((m) => int.parse(m.group(1)!)).toList();
      run.expect(
        '[$name] the wrapper gave the recovered report the LIVE window (20 s), which it grants only to the SDK\'s BugseeReportHandlerThread: a native-crash report recovered after a normal session is dispatched like a live one, not on the bounded early-crash thread',
        windows.isNotEmpty && windows.every((w) => w == 20000),
        'windows $windows ms',
      );
      run.expect(
        '[$name] every handler completed by Dart, none by the deadline',
        RegExp(r'completed by=dart').allMatches(c.allLogs).length >= 2 &&
            !c.allLogs.contains('completed by=deadline'),
        'completions: ${RegExp(r'completed by=(\w+)').allMatches(c.allLogs).map((m) => m.group(1)).toList()}',
      );
      if (before.isNotEmpty && after.isNotEmpty) {
        run.note(
          '[$name] Dart-side: before at ${before.first['ms']} ms, after at ${after.first['ms']} ms since main() of the relaunched process; launch result at ${c.relaunch.events.firstWhere((e) => e.kind == 'launch', orElse: () => VerifyEvent({'ms': -1}))['ms']} ms',
        );
      }
      final b = c.bundle;
      if (b != null) {
        run.expect(
          '[$name] the Dart enrichment landed in the recovered bundle: attribute, label and file',
          b.attributes.containsKey('verify.before') &&
              b.attributes.containsKey('verify.after') &&
              b.labels.contains('verify-after') &&
              b
                  .entriesOfType('attachment')
                  .any((e) => e['name'] == 'verify-enrichment'),
          'attrs ${b.attributes.keys.toList()}, labels ${b.labels}, attachments ${b.entriesOfType('attachment').map((e) => e['name']).toList()}',
        );
        final att = b
            .entriesOfType('attachment')
            .where((e) => e['name'] == 'verify-enrichment');
        if (att.isNotEmpty) {
          run.expect(
            '[$name] the attached file has the content the handler wrote',
            utf8
                .decode(b.content(att.first))
                .startsWith('enrichment from the Dart handler'),
            utf8.decode(b.content(att.first)),
          );
        }
      }
    }
    run.note(
      'isTerminating is not exposed to the Dart handler (ReportProxy has no such field by design); that the Dart handler ran at all is the observable: the wrapper completes isTerminating=true deliveries natively without Dart.',
    );
    run.result.notCovered.addAll([
      'a recovered report whose handler overruns the SDK deadline (a slow handler); only the prompt case is measured',
      'Android recovery before the Flutter engine exists (the early-crash path never reaches Dart: documented, not provoked here)',
    ]);
  });

  // ---- 4 --------------------------------------------------------------------------------------

  Future<ScenarioResult> dartExceptions() => runScenario(
    4,
    'Dart exceptions end to end (debug; release with R8 and --obfuscate)',
    say,
    (run) async {
      final symbolsOf = <String, String>{};
      for (final name in ['debug', 'releaseA']) {
        final b = await build(name);
        run.note('--- $name');
        await s.install(run, b);
        await s.launch(run, b);
        await delay(4);
        final handled = await _product(
          run,
          name,
          'log-handled h4',
          where: (x) => x.crash != null && x.type == 'error',
        );
        final unhandled = await _product(
          run,
          name,
          'log-unhandled u4',
          where: (x) =>
              x.crash != null &&
              x.type == 'crash' &&
              x.crash?['handled'] == false,
        );
        final asyncErr = await _product(
          run,
          name,
          'throw-async a4',
          where: (x) =>
              x.crash != null &&
              x.crash?['handled'] == true &&
              x.crash.toString().contains('a4'),
        );
        for (final e in {
          'handled': handled,
          'unhandled': unhandled,
          'async': asyncErr,
        }.entries) {
          if (e.value == null) continue;
          checkExceptionReport(
            run,
            '$name/${e.key}',
            e.value!,
            carrierName: 'com.bugsee.flutter.FlutterManagedException',
            unhandled: e.key == 'unhandled',
          );
          final crash = e.value!.crash!;
          run.note(
            '[$name/${e.key}] crash.json obfuscated=${crash['obfuscated']}; exception.frames[0]=${((crash['exception'] as Map)['frames'] as List?)?.first is Map ? (((crash['exception'] as Map)['frames'] as List).first as Map)['trace'] : null}',
          );
        }
        if (unhandled == null) {
          await dev.uninstall();
          continue;
        }
        if (b.obfuscated) {
          symbolsOf[name] = b.symbolsDir!;
          // The carrier is kept by the consumer rule: in the exact build's own mapping, not a rebuild (9.3.5).
          final mapping = File(b.mappingFile ?? '/nonexistent');
          run.expect(
            '[$name] R8 ran (a mapping file exists)',
            mapping.existsSync(),
            '${b.mappingFile}',
          );
          if (mapping.existsSync()) {
            final text = mapping.readAsStringSync();
            final kept = RegExp(
              r'^com\.bugsee\.flutter\.FlutterManagedException -> (\S+):',
              multiLine: true,
            ).firstMatch(text)?.group(1);
            run.expect(
              '[$name] mapping.txt keeps com.bugsee.flutter.FlutterManagedException',
              kept == 'com.bugsee.flutter.FlutterManagedException',
              'mapped to $kept',
            );
            final ops = RegExp(
              r'^com\.bugsee\.flutter\.ExceptionOps -> (\S+):',
              multiLine: true,
            ).firstMatch(text)?.group(1);
            run.note(
              '[$name] for contrast, com.bugsee.flutter.ExceptionOps -> $ops (the other classes are free to be renamed; only the carrier is routed on)',
            );
          }
          // Symbolize the obfuscated Dart stack with THIS build's symbols; fail with another build's.
          final doc = parseManagedDocument(
            ((unhandled.crash!['exception'] as Map)['reason']) as String,
          )!;
          final stack = doc['originalStackTrace'] as String;
          run.expect(
            '[$name] the Dart stack in the report is non-symbolic (build_id, abs addresses)',
            stack.contains('build_id') && stack.contains(' abs '),
            stack.split('\n').take(4).join(' | '),
          );
          final entry = File('${tc.workDir}/entry-$name.json')
            ..writeAsStringSync(
              jsonEncode({'exception': unhandled.crash!['exception']}),
            );
          final own = await _symbolize(
            b.symbolsDir!,
            entry.path,
            expect: const ['_command', 'verify_main.dart'],
          );
          run.expect(
            '[$name] scripts/verify_symbolization.dart resolves the app frames with this build\'s symbols',
            own.ok,
            own.text.split('\n').take(8).join(' | ') + own.stderr,
          );
          final other = await build('releaseB');
          final wrong = await _symbolize(
            other.symbolsDir!,
            entry.path,
            expect: const ['_command'],
          );
          run.expect(
            '[$name] and FAILS with another build\'s symbols (the negative arm: the check can fail)',
            !wrong.ok && (wrong.stderr + wrong.stdout).contains('not in'),
            (wrong.stderr + wrong.stdout)
                .trim()
                .split('\n')
                .take(2)
                .join(' | '),
          );
          // Java side: retrace with the exact mapping (9.3.5).
          final javaFrames =
              ((unhandled.crash!['exception'] as Map)['frames'] as List)
                  .map((f) => (f as Map)['trace'])
                  .take(6)
                  .toList();
          run.note('[$name] Java frames as reported: $javaFrames');
          if (mapping.existsSync()) {
            final trace = File('${tc.workDir}/java-$name.txt')
              ..writeAsStringSync(
                '${((unhandled.crash!['exception'] as Map)['frames'] as List).map((f) => 'at ${(f as Map)['trace']}').join('\n')}\n',
              );
            final r = await sh([
              tc.apkanalyzer.replaceAll('apkanalyzer', 'retrace'),
              b.mappingFile!,
              trace.path,
            ], env: tc.buildEnv);
            run.note(
              '[$name] retrace of the Java frames with the exact mapping: ${r.text.split('\n').take(4).join(' | ')} ${r.stderr.split('\n').first}',
            );
          }
        }
        await dev.uninstall();
      }
      run.result.notCovered.addAll([
        'unhandled exception reported AS A CRASH by the zone (installErrorHandlers(reportAsCrash: true)) in a release build',
        'errors thrown in a spawned isolate',
        'Dart stack symbolization through the real backend worker (the offline `flutter symbolize` and dart_symbolize decode the same format; the worker itself was not run)',
      ]);
    },
  );

  Future<Out> _symbolize(
    String symbolsDir,
    String entry, {
    List<String> expect = const [],
  }) {
    final file = Directory(symbolsDir).listSync().whereType<File>().firstWhere(
      (f) => f.path.endsWith('.symbols'),
    );
    return sh(
      [
        tc.flutter.replaceAll('/flutter', '/dart'),
        'scripts/device/../verify_symbolization.dart',
        '--symbols',
        file.path,
        '--entry',
        entry,
        '--expect',
        expect.join(','),
      ],
      cwd: tc.repoRoot,
      env: tc.buildEnv,
      timeout: const Duration(minutes: 3),
    );
  }

  // ---- 5 --------------------------------------------------------------------------------------

  Future<ScenarioResult> releaseModes() => runScenario(
    5,
    'Release and profile behaviour of the features first run in debug',
    say,
    (run) async {
      for (final name in ['releaseA', 'profile', 'debug']) {
        final b = await build(name);
        run.note('--- $name');
        await s.install(run, b);
        await s.launch(run, b);
        await delay(5);
        // The features, each staged then asked of one report.
        await s.command('vh');
        await s.command('net http://127.0.0.1:${mock.port}/ping?s5');
        await s.command('print s5');
        await delay(4);
        final plain = await _report(run, 'upload plain-$name');
        checkViewHierarchy(run, name, plain, obfuscated: b.obfuscated);
        checkLogs(run, name, plain, 's5');
        checkNetwork(run, name, plain, 's5');
        // Secure regions: the video frame, secure on then off.
        await _secureComparison(run, name, b, plain);
        // Attachments from the handler path and createReport.
        final withFile = await _product(
          run,
          name,
          'upload-with-file f5',
          where: (x) => x.summary == 'verify upload-with-file f5',
        );
        if (withFile != null) {
          final fileEntry = withFile
              .entriesOfType('attachment')
              .where((e) => e['name'] == 'from-command');
          run.expect(
            '[$name] attachment from the handler: the file is in the bundle with its content',
            fileEntry.isNotEmpty &&
                utf8.decode(withFile.content(fileEntry.first)) ==
                    'attached by a command f5',
            fileEntry.isEmpty
                ? 'absent: ${withFile.entriesOfType('attachment').map((e) => e['name']).toList()}'
                : 'content ok',
          );
        }
        // No filter on the summary: the summary is what is being checked.
        final created = await _product(run, name, 'create-report c5');
        if (created != null) {
          run.expect(
            '[$name] createReport: the created report was uploaded with the summary set',
            created.summary == 'verify created c5',
            '${created.type} "${created.summary}"',
          );
        }
        await dev.uninstall();
      }
      run.result.notCovered.addAll([
        'network capture of bodies and of redirects in release (the unit and debug integration tests cover them; release shows presence only)',
        'view hierarchy walk on a device with secure fields marked (privacy filter) in release',
      ]);
    },
  );

  /// Secure on then off: the redacted box must be the region's box (physical pixels), at this density.
  Future<void> _secureComparison(
    Run run,
    String name,
    AndroidBuild b,
    Bundle onBundle,
  ) async {
    final on = await requireVideoFrame(
      run,
      name,
      onBundle,
      tc.workDir,
      'on-$name',
    );
    await s.command('secure off');
    await delay(4);
    final off = await _report(
      run,
      'upload plain-off-$name',
      where: (x) => x.summary == 'verify upload plain-off-$name',
    );
    final offFrame = await requireVideoFrame(
      run,
      name,
      off,
      tc.workDir,
      'off-$name',
    );
    if (on != null && offFrame != null) checkRedaction(run, name, on, offFrame);
    await s.command('secure on');
    await delay(3);
  }

  // ---- 6 --------------------------------------------------------------------------------------

  Future<ScenarioResult>
  crashAcrossUpdate() => runScenario(6, 'Crash across an app update (workbook 9.3.4)', say, (
    run,
  ) async {
    final a = await build('releaseA');
    final bb = await build('releaseB');
    final shaA = a.apkBytes.length, shaB = bb.apkBytes.length;
    run.guard(
      'precondition: the two builds differ',
      [
        if (a.buildNumber == bb.buildNumber) 'same versionCode',
        if (_sameBytes(a.apkBytes, bb.apkBytes))
          'the two APKs are byte-identical',
      ],
      'N: versionCode ${a.buildNumber} ($shaA bytes); N+1: versionCode ${bb.buildNumber} ($shaB bytes)',
    );
    run.note(
      'the Gradle build id is ${a.buildUuid == bb.buildUuid ? 'the SAME' : 'different'} for the two builds (${a.buildUuid} / ${bb.buildUuid}): it identifies the compiled Java/Kotlin code, which these two builds share, so it cannot tell them apart; the app build (versionCode) does',
    );
    await s.install(run, a);
    final l = await s.launch(run, a);
    await delay(6);
    await dev.clearBundles();
    await s.crash(run, l.pid);
    // Update WITHOUT wiping data.
    await s.install(run, bb, wipe: false);
    final ndk = (await dev.inApp([
      'ls',
      dev.useRunAs
          ? 'files/bugsee_data/ndk'
          : '${dev.dataDir}/files/bugsee_data/ndk',
    ])).stdout.trim();
    run.guard(
      'precondition: the crash data of build N survived the update',
      ndk.isEmpty
          ? ['files/bugsee_data/ndk is empty: the update wiped data']
          : [],
      'ndk dir: $ndk',
    );
    await s.airplane(run, true);
    final l2 = await s.launch(run, bb);
    final recovered = await s.newBundle(
      where: (x) => x.type == 'crash',
      timeout: const Duration(seconds: 90),
    );
    run.expect(
      '[N crash -> N+1 relaunch] a recovered report was produced',
      recovered != null,
      recovered == null ? 'none' : recovered.source,
    );
    await s.airplane(run, false);
    if (recovered != null) {
      run.expect(
        'the recovered report carries build N (the crashed build), not N+1',
        recovered.app['build'] == '${a.buildNumber}' &&
            recovered.app['version'] == '1.0.${a.buildNumber}',
        'app ${recovered.app['version']} (${recovered.app['build']}); installed now: ${bb.buildNumber}',
      );
      run.expect(
        'identity_source is "session" (the persisted identity of the producing session)',
        recovered.identitySource == 'session',
        '${recovered.identitySource}',
      );
      run.note(
        'crash.json uuid ${recovered.crash?['uuid']} (N ${a.buildUuid}, N+1 ${bb.buildUuid}): the two builds share it, so it cannot discriminate here; app.build does',
      );
      final wp = (await s.expectation(
        'release',
      )).wrapperInReport(recovered.wrapper);
      run.expect(
        'sdk.wrapper identity is on the recovered report',
        wp.isEmpty,
        wp.isEmpty ? jsonEncode(recovered.wrapper) : wp.join('; '),
      );
    }
    await s.waitCommandChannel();
    final live = await _report(
      run,
      'upload live-n1',
      where: (x) => x.summary == 'verify upload live-n1',
    );
    run.expect(
      'a live report of N+1 carries build N+1 and no identity_source (the two halves differ)',
      live.app['build'] == '${bb.buildNumber}' && live.identitySource == null,
      'app ${live.app['version']} (${live.app['build']}) identity_source ${live.identitySource}',
    );
    run.note('process of N+1: pid ${l2.pid}');
    run.result.notCovered.addAll([
      'iOS: crash -> update -> relaunch (see the iOS section: the SDK discards or restamps; spec says the iOS side is not implemented)',
      'an update that ALSO changes the SDK version (both builds pin the same SDK here)',
    ]);
  });

  // ---- 7 --------------------------------------------------------------------------------------

  Future<ScenarioResult>
  secureDensity() => runScenario(7, 'Secure rectangles at density != 1', say, (
    run,
  ) async {
    for (final name in ['debug', 'releaseA']) {
      final b = await build(name);
      run.note('--- $name');
      await s.install(run, b);
      await s.launch(run, b);
      final base = await dev.currentDensity();
      for (final dpi in [base, 320, 560]) {
        if (dpi != base) {
          await dev.density(dpi);
          run.guard(
            'precondition: wm density is $dpi',
            (await dev.currentDensity()) == dpi
                ? []
                : ['wm density reports ${await dev.currentDensity()}'],
            'wm density = $dpi (default $base)',
          );
        }
        await delay(4);
        // Asked again until the app reports the new ratio: a density change makes the activity lay out
        // again, and a loaded emulator can take a while.
        VerifyEvent? geo;
        // Two tries at the density itself: if the app never sees the new ratio the second try resets and
        // sets it again (the screen is woken first: a sleeping display stops the activity).
        for (var round = 0; round < 2 && geo == null; round++) {
          if (round == 1 && dpi != base) {
            await dev.density(null);
            await dev.density(dpi);
          }
          await dev.wake();
          for (var attempt = 0; attempt < 6 && geo == null; attempt++) {
            await s.command('geometry');
            geo = await s.waitEvent(
              (e) =>
                  e.kind == 'geometry' &&
                  (e['devicePixelRatio'] as num).toDouble() == dpi / 160.0,
              timeout: const Duration(seconds: 8),
            );
          }
        }
        run.expect(
          '[$name @${dpi}dpi] the app sees devicePixelRatio ${dpi / 160}',
          geo != null,
          geo == null
              ? 'no geometry event with that ratio; ratios the app reported: ${{for (final e in parseVerifyEvents(await dev.logcat()))
                  if (e.kind == 'geometry') e['devicePixelRatio']}}; wm density: ${(await dev.shell('wm density')).trim().replaceAll('\n', ' / ')}'
              : '${geo['devicePixelRatio']}, logical box ${geo['secureLogical']}',
        );
        if (geo == null) continue;
        await s.command('secure on');
        await delay(3);
        final on = await _report(
          run,
          'upload on-$name-$dpi',
          where: (x) => x.summary == 'verify upload on-$name-$dpi',
        );
        final onFrame = await requireVideoFrame(
          run,
          '$name @${dpi}dpi',
          on,
          tc.workDir,
          'd-on-$name-$dpi',
        );
        await s.command('secure off');
        await delay(4);
        final off = await _report(
          run,
          'upload off-$name-$dpi',
          where: (x) => x.summary == 'verify upload off-$name-$dpi',
        );
        final offFrame = await requireVideoFrame(
          run,
          '$name @${dpi}dpi',
          off,
          tc.workDir,
          'd-off-$name-$dpi',
        );
        if (onFrame == null || offFrame == null) {
          await s.command('secure on');
          continue;
        }
        final region = checkRedaction(
          run,
          '$name @${dpi}dpi',
          onFrame,
          offFrame,
        );
        final layout = videoLayout(off);
        if (region != null && layout != null) {
          checkRegionPlacement(
            run,
            '$name @${dpi}dpi',
            region,
            layout,
            offFrame,
            (geo['secureLogical'] as Map).cast<String, num>(),
            dpi / 160.0,
          );
        } else if (region != null) {
          run.note(
            '[$name @$dpi] the video carries no layout (video.aux): placement not checked',
          );
        }
        await checkScreenshotRedaction(
          run,
          '$name @${dpi}dpi',
          on,
          off,
          tc.workDir,
          expectContent: false,
        );
        await s.command('secure on');
      }
      await dev.density(null);
      await dev.uninstall();
    }
    run.result.notCovered.addAll([
      'the instant between a density change and Dart\'s republish (the native whole-display cover); only the settled state is sampled',
      'a second display, rotation, split screen',
    ]);
  });

  // ---- 9 --------------------------------------------------------------------------------------

  /// The report screenshot by Flutter render mode. In the default SurfaceView mode the SDK's screenshot
  /// is all black (a KNOWN-GAP: the SDK skips SurfaceViews for screenshots, `ScreenCaptureScreenshot` /
  /// `ScreenCapturePixelCopyShared`, v7.4.2); in TextureView mode (`background_mode: transparent`) it has
  /// the content, and the redaction works in it. A fix in the SDK flips the first arm to a pass.
  Future<ScenarioResult> screenshotGap() => runScenario(
    9,
    'Report screenshot content by render mode (KNOWN-GAP in the default SurfaceView mode)',
    say,
    (run) async {
      final b = await build('debug');
      await s.install(run, b);
      for (final texture in [false, true]) {
        final mode = texture ? 'texture' : 'surface';
        run.note('--- render mode: $mode');
        await s.launch(
          run,
          b,
          extras: texture
              ? const ['--es', 'background_mode', 'transparent']
              : const [],
        );
        await delay(4);
        final hasSurface = await dev.hasSurfaceViewLayer();
        run.guard(
          'precondition: the app renders in $mode mode',
          hasSurface == !texture
              ? []
              : [
                  'SurfaceFlinger ${hasSurface ? 'has' : 'has no'} a SurfaceView layer for the app',
                ],
          'SurfaceView layer present: $hasSurface',
        );
        // The device's own screen has content (the screenshot cannot be black because the screen is).
        final cap = await decodeStill(await dev.screencap(), tc.workDir, 'png');
        run.guard(
          'precondition: the display itself is not flat (adb screencap)',
          cap != null && !cap.isUniform()
              ? []
              : ['screencap is flat or undecodable'],
          cap == null ? '' : '${cap.width}x${cap.height}',
        );
        final on = await _report(run, 'upload on-$mode');
        await s.command('secure off');
        await delay(4);
        final off = await _report(
          run,
          'upload off-$mode',
          where: (x) => x.summary == 'verify upload off-$mode',
        );
        final a = await screenshotOf(on, tc.workDir);
        final c = await screenshotOf(off, tc.workDir);
        run.expect(
          '[$mode] the report has a screenshot that decodes',
          a != null && c != null,
          'entries: ${on.entries.map((e) => e['type']).toList()}',
        );
        if (a == null || c == null) continue;
        final flat = a.isUniform() && c.isUniform();
        if (!texture) {
          run.knownGap(
            '[surface] the report screenshot has content in the default (SurfaceView) render mode',
            !flat,
            '${a.width}x${a.height}${flat ? ', ONE FLAT COLOUR ${a.at(0, 0)} with the region secured and unsecured; the display is not flat. SDK v7.4.2 ScreenCaptureScreenshot.captureWithPixelCopy passes null as the SurfaceView capture manager and ScreenCapturePixelCopyShared.fillRenderLayerSurfaceViews skips SurfaceViews then' : ', has content (the gap is closed)'}',
          );
        } else {
          run.expect(
            '[texture] the report screenshot has content',
            !flat,
            '${a.width}x${a.height}',
          );
          if (!flat) {
            checkRedaction(run, 'texture screenshot', a, c);
          }
          final onFrame = await requireVideoFrame(
            run,
            'texture',
            on,
            tc.workDir,
            'tex-on',
          );
          final offFrame = await requireVideoFrame(
            run,
            'texture',
            off,
            tc.workDir,
            'tex-off',
          );
          if (onFrame != null && offFrame != null) {
            checkRedaction(run, 'texture video', onFrame, offFrame);
          }
        }
        await s.command('secure on');
      }
      run.result.notCovered.addAll([
        'a physical device: the SurfaceView gap is read from SDK source and reproduced on the emulator only',
        'platform views and scrolling content in TextureView mode (Flutter documents TextureView as slower to present and with different platform-view compositing); only the verification app\'s static content was captured',
      ]);
    },
  );

  // ---- 8 --------------------------------------------------------------------------------------

  Future<ScenarioResult>
  hotRestart() => runScenario(8, 'Hot restart: lifecycle, handlers and the report-handler sweep', say, (
    run,
  ) async {
    final b = await build('debug');
    await s.install(run, b);
    await dev.clearLogcat();
    // `flutter run` installs and launches its own debug build of the same source.
    final example = '${tc.repoRoot}/example';
    final run1 = await Child.start(
      [
        tc.flutter,
        'run',
        '-d',
        dev.serial,
        '-t',
        'lib/verify_main.dart',
        '--dart-define=VERIFY_SERVER=10.0.2.2:${mock.port}',
        '--dart-define=BUGSEE_ENDPOINT=http://10.0.2.2:${mock.port}',
      ],
      cwd: example,
      env: tc.buildEnv,
    );
    try {
      final up = await run1.waitFor(
        'Flutter run key commands',
        timeout: const Duration(minutes: 8),
      );
      run.guard(
        'precondition: flutter run is up with a debug session',
        up
            ? []
            : ['flutter run did not reach the key-commands banner: ${run1.output}'],
        'flutter run attached',
      );
      // The artefact guard looks at the APK that RUNS (the one `flutter run` installed), pulled from the
      // device, not at the pre-built one it replaced.
      final runningApk = '${tc.workDir}/apks/flutter-run.apk';
      final pulled = await dev.adb(['pull', await dev.apkPath(), runningApk]);
      run.guard(
        'precondition: the running APK was pulled from the device',
        pulled.ok ? [] : ['adb pull failed: $pulled'],
        'flutter run\'s own install of ${dev.pkg}',
      );
      final running = await inspectAndroid(
        tc,
        name: 'flutter-run',
        mode: 'debug',
        apk: runningApk,
        buildNumber: b.buildNumber,
        obfuscated: false,
      );
      final l = await s.launch(run, running, freshLog: false, restart: false);
      final mainEvents1 = l.events.where((e) => e.kind == 'main').toList();
      await s.command('upload before-restart');
      await s.newBundle();
      final before = parseVerifyEvents(await dev.logcat());
      final handlersBefore = before.where((e) => e.kind == 'handler').length;
      run.guard(
        'precondition: a handler pair ran before the restart',
        handlersBefore == 2
            ? []
            : ['expected 2 handler events before the restart, saw $handlersBefore'],
        '$handlersBefore handler events',
      );
      final mainsBefore = parseVerifyEvents(
        await dev.logcat(),
      ).where((e) => e.kind == 'main').length;
      run1.write('R');
      final restarted = await run1.waitFor(
        'Performing hot restart',
        timeout: const Duration(minutes: 2),
      );
      run.guard(
        'event: a hot restart was performed',
        restarted
            ? []
            : ['flutter run never reported "Performing hot restart"'],
        'flutter run: ${run1.output.toString().split('\n').where((x) => x.contains('hot restart')).take(2).join(' | ')}',
      );
      // The restarted isolate prints a new `main` event (its clock restarts too): what follows the LAST
      // `main` in the log is what the new isolate did.
      final reMain = await until<VerifyEvent>(
        () async {
          final mains = parseVerifyEvents(
            await dev.logcat(),
          ).where((e) => e.kind == 'main').toList();
          return mains.length > mainsBefore ? mains.last : null;
        },
        timeout: const Duration(seconds: 60),
        every: const Duration(seconds: 2),
      );
      run.expect(
        'the Dart isolate restarted inside the SAME process (same pid, a new main())',
        reMain != null && reMain['pid'] == mainEvents1.last['pid'],
        'main before: pid ${mainEvents1.last['pid']}; after: pid ${reMain?['pid']}',
      );
      await delay(6);
      final post = afterLastMain(parseVerifyEvents(await dev.logcat()));
      final launchAfter = post.where((e) => e.kind == 'launch').toList();
      run.expect(
        'the SDK was not launched twice: the new isolate finds it running (alreadyRunning)',
        launchAfter.isNotEmpty &&
            launchAfter.every((e) => e['result'] == 'alreadyRunning'),
        'launch events after the restart: ${launchAfter.map((e) => e['result']).toList()}',
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
      await s.command('upload after-restart');
      final bundle = await s.newBundle(
        where: (x) => x.summary == 'verify upload after-restart',
      );
      await delay(3);
      final after = afterLastMain(parseVerifyEvents(await dev.logcat()));
      final handlers = after.where((e) => e.kind == 'handler').toList();
      run.expect(
        'handlers still flow after the restart, exactly one before and one after (no duplicate registration)',
        handlers.where((e) => e['phase'] == 'before').length == 1 &&
            handlers.where((e) => e['phase'] == 'after').length == 1,
        'before x${handlers.where((e) => e['phase'] == 'before').length}, after x${handlers.where((e) => e['phase'] == 'after').length}',
      );
      final lifecycle = after
          .where((e) => e.kind == 'lifecycle')
          .map((e) => e['event'])
          .toList();
      run.expect(
        'lifecycle events flow after the restart (assembled, uploaded) to the new isolate once each',
        lifecycle.where((e) => '$e'.contains('BeforeReportAssembled')).length ==
            1,
        '$lifecycle',
      );
      run.expect(
        'the report built after the restart carries the Dart enrichment',
        bundle != null && bundle.attributes.containsKey('verify.before'),
        bundle == null ? 'no bundle' : '${bundle.attributes.keys.toList()}',
      );
      final log = await dev.logcat();
      run.note(
        'native report-handler log after the restart: ${RegExp(r'BugseeFlutter: report handler[^\n]*').allMatches(log).map((m) => m.group(0)).take(8).toList()}',
      );
      run.note(
        'registrations in the process log since the restart: "wrapper registered" x${'wrapper registered'.allMatches(log).length} (it registers once per process, before launch)',
      );
    } finally {
      run1.write('q');
      await delay(2);
      await run1.stop();
    }
    run.result.notCovered.addAll([
      'hot RELOAD (no isolate restart); only restart is exercised',
      'a hot restart while a report handler delivery is in flight (the sweep of outstanding deliveries is unit-tested; not provoked on a device)',
      'iOS hot restart is covered by the iOS run',
    ]);
  });
}

bool _sameBytes(List<int> x, List<int> y) {
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

class CrashCycle {
  CrashCycle(
    this.build,
    this.exp,
    this.first,
    this.crash,
    this.relaunch,
    this.bundle,
    this.allLogs,
    this.mapped,
    this.extracted,
  );
  final AndroidBuild build;
  final BuildExpectation exp;
  final Launched first;
  final CrashEvidence crash;
  final Launched relaunch;
  final Bundle? bundle;

  /// The libbugsee libraries mapped into the app process before the crash (from /proc/PID/maps).
  final Set<String> mapped;

  /// The libbugsee libraries the SDK extracted for the crashpad handler process (a directory listing).
  final Set<String> extracted;

  /// Cold start + crash + relaunch logcat, concatenated.
  final String allLogs;
}
