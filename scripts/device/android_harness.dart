// The Android half of the harness: a session on one emulator, with the 9.1 guards built into the only
// way to start the app ([AndroidSession.launch]) and into the only way to crash it
// ([AndroidSession.crash]).
import 'dart:convert';
import 'dart:typed_data';

import 'android_device.dart';
import 'build.dart';
import 'core/bundle.dart';
import 'core/experiment.dart';
import 'core/expectations.dart';
import 'core/log_parsers.dart';
import 'mock.dart';
import 'shell.dart';
import 'toolchain.dart';

/// What a guarded launch learned: the process, the log it was read from.
class Launched {
  Launched(this.pid, this.log, this.events, this.banner, this.wrapper);
  final int pid;
  final String log;
  final List<VerifyEvent> events;
  final SdkBanner banner;
  final WrapperLog wrapper;
}

/// A crash the harness caused and proved: signal 11, from the logcat and from the exit record.
class CrashEvidence {
  CrashEvidence(
    this.pid,
    this.signal,
    this.exit,
    this.method,
    this.handlerPs,
    this.handlerLibs,
  );

  /// The crashpad handler process caught right after the kill (`ps` line) and the libbugsee libraries
  /// in that process's own maps; empty when the race was lost.
  final String? handlerPs;
  final Set<String> handlerLibs;
  final int pid;
  final ({int number, String name, String code}) signal;
  final ExitInfo exit;
  final String method;
}

class AndroidSession {
  AndroidSession(this.tc, this.dev, this.mock, this.pins, this.abi);
  final Toolchain tc;
  final AndroidDevice dev;
  final Mock mock;
  final Pins pins;
  final String abi;

  /// Reports already seen (by [_key]), so a scenario reads only the ones it caused.
  final Set<String> _seen = {};
  final Map<String, BuildExpectation> _expectations = {};

  Future<BuildExpectation> expectation(String mode) async =>
      _expectations[mode] ??= await tc.expectation(mode);

  /// Installs [build] (replacing: data kept) or, with [wipe], from scratch. Asserts what was staged.
  Future<void> install(Run run, AndroidBuild build, {bool wipe = true}) async {
    if (wipe) {
      await dev.uninstall();
      run.guard(
        'precondition: app data wiped',
        await dev.isInstalled()
            ? ['${dev.pkg} is still installed after uninstall']
            : [],
        'uninstalled ${dev.pkg}',
      );
    }
    final r = await dev.install(build.apk);
    final v = await dev.packageVersion();
    run.guard(
      'precondition: ${build.name} installed',
      [
        if (!r.ok || !r.stdout.contains('Success')) 'install failed: $r',
        if (v.code != '${build.buildNumber}')
          'versionCode ${v.code}, expected ${build.buildNumber}',
      ],
      'versionCode ${v.code}, versionName ${v.name}',
    );
    // How the app's private directory is reached: `run-as` for a debuggable build (the workbook recipe),
    // the root shell for a release build, which `run-as` cannot enter.
    dev.useRunAs = await dev.isDebuggable();
    if (!dev.useRunAs && !dev.hasRoot) {
      throw NotPossible(
        '${build.name} is not debuggable and the emulator shell is not root: the app data cannot be read',
      );
    }
    run.guard(
      'access: the app data is readable (${dev.via})',
      (await dev.inApp(['ls', dev.useRunAs ? '.' : dev.dataDir])).ok
          ? []
          : ['cannot list the app data directory via ${dev.via}'],
      '${build.name}: debuggable=${dev.useRunAs}, via ${dev.via}',
    );
    _seen.clear();
    await mock.reset();
  }

  /// Starts the app and does not return until the experiment is proven valid (9.1.1: which build;
  /// 9.1.2: the SDK launched). [expectLaunch] is false only for a scenario that tests a failed launch.
  Future<Launched> launch(
    Run run,
    AndroidBuild build, {
    Duration timeout = const Duration(seconds: 90),
    bool freshLog = true,
    bool restart = true,
    List<String> extras = const [],
  }) async {
    final exp = await expectation(build.mode);
    run.guard(
      'build: artefact set',
      build.artefactProblems(pins, abi),
      build.describe(abi),
    );
    if (freshLog) await dev.clearLogcat();
    // `restart: false` observes a process someone else started (a `flutter run` session).
    if (restart) {
      await dev.forceStop();
      await dev.start(extras: extras);
    }
    final pid = await dev.waitForPid(timeout: const Duration(seconds: 30));
    if (pid == null) {
      run.guard('SDK launched', ['the app process did not start'], '');
    }
    String log = '';
    List<VerifyEvent> events = [];
    final ok = await until<bool>(
      () async {
        log = await dev.logcat();
        events = parseVerifyEvents(log);
        final launch = events.where((e) => e.kind == 'launch').toList();
        final status = events.where((e) => e.kind == 'status').toList();
        return launch.isNotEmpty && status.isNotEmpty ? true : null;
      },
      timeout: timeout,
      every: const Duration(seconds: 2),
    );
    final banner = parseAndroidBanner(log);
    final wrapperLog = parseWrapperLog(log);
    run.guard(
      'build: SDK banner and wrapper identity',
      exp.androidProblems(banner, wrapperLog),
      '$banner; wrapper registered ${wrapperLog.registered}, refined ${wrapperLog.refined} ${wrapperLog.context}',
    );
    final launch = events.where((e) => e.kind == 'launch').toList();
    final statuses = events
        .where((e) => e.kind == 'status')
        .map((e) => e['status'])
        .toList();
    run.guard(
      'SDK launched',
      [
        if (ok == null)
          'no launch and status event within $timeout (the app printed ${events.length} VERIFY lines)',
        if (launch.isNotEmpty && launch.first['result'] != 'launched')
          'launch result ${launch.first['result']}',
        if (statuses.isNotEmpty && statuses.last != 'launched')
          'status ${statuses.last}',
      ],
      'launch -> ${launch.isEmpty ? '?' : launch.first['result']}, status ${statuses.isEmpty ? '?' : statuses.last}',
    );
    return Launched(pid!, log, events, banner!, wrapperLog);
  }

  /// Waits for a VERIFY event satisfying [test] in the log.
  Future<VerifyEvent?> waitEvent(
    bool Function(VerifyEvent) test, {
    Duration timeout = const Duration(seconds: 45),
  }) => until<VerifyEvent>(
    () async {
      for (final e in parseVerifyEvents(await dev.logcat())) {
        if (test(e)) return e;
      }
      return null;
    },
    timeout: timeout,
    every: const Duration(seconds: 2),
  );

  /// Sends a command to the app over the mock API (needs the network: not in airplane mode).
  Future<void> command(String line) => mock.command(line);

  /// Which copy of a bundle this is: the SDK retries an upload, and the mock stores every attempt.
  static String _key(Bundle b) =>
      '${b.request['created_on']}|${b.type}|${b.summary}|${jsonEncode(b.manifest['time'])}';

  /// Waits for a report that was not seen before and returns it. Where a bundle is depends on the build
  /// and on the network (measured: a debug build's upload fails before the request leaves and the SDK
  /// keeps the bundle on the device; the release build's upload reaches the mock, which answers 503 and
  /// stores the body, and the SDK drops its copy), so both places are read.
  Future<Bundle?> newBundle({
    bool Function(Bundle)? where,
    Duration timeout = const Duration(seconds: 60),
  }) => until<Bundle>(
    () async {
      Bundle? take(String source, Uint8List bytes) {
        try {
          final b = Bundle.fromZip(source, bytes);
          if (_seen.contains(_key(b))) return null;
          if (where != null && !where(b)) return null;
          _seen.add(_key(b));
          return b;
        } on Object {
          return null; // still being written, or not a report bundle
        }
      }

      for (final name in await dev.listBundles()) {
        final b = take('device:$name', await dev.readBundle(name));
        if (b != null) return b;
      }
      for (final name in mock.storedNames()) {
        final bytes = await mock.plainBundle(name);
        if (bytes == null) continue;
        final b = take('mock:$name', bytes);
        if (b != null) return b;
      }
      return null;
    },
    timeout: timeout,
    every: const Duration(seconds: 2),
  );

  /// A real SIGSEGV to the running app, and proof it happened (9.1.4): the pid existed, the kernel
  /// logged `Fatal signal 11` for that pid, the process is gone, and the exit record says a native
  /// crash with status 11.
  Future<CrashEvidence> crash(Run run, int pid) async {
    run.guard(
      'precondition: the process to kill is running',
      (await dev.pid()) == pid
          ? []
          : ['pid $pid is not the app process (${await dev.pid()})'],
      'pid $pid',
    );
    final kill = await dev.killSegvProbingHandler(pid);
    final probe = parseHandlerProbe(kill.stdout);
    String log = '';
    ({int number, String name, String code})? signal;
    await until<bool>(
      () async {
        log = await dev.logcat();
        signal = parseFatalSignal(log, pid);
        return signal != null ? true : null;
      },
      timeout: const Duration(seconds: 30),
      every: const Duration(seconds: 1),
    );
    await delay(2);
    final alive = await dev.pid();
    final exit = parseExitInfo(await dev.exitInfo(), pid);
    run.guard(
      'event: the process died of signal 11',
      [
        if (!kill.ok) 'kill failed: $kill',
        if (signal == null) 'logcat has no "Fatal signal" for pid $pid',
        if (signal != null && signal!.number != 11) 'signal ${signal!.number}',
        if (alive == pid) 'pid $pid is still running',
        if (exit == null) 'no ApplicationExitInfo for pid $pid',
        if (exit != null && (!exit.isNativeCrash || exit.status != 11))
          'exit record ${exit.reason} status ${exit.status}',
      ],
      'killed pid $pid via ${dev.via}; logcat: Fatal signal ${signal?.number} (${signal?.name}), code ${signal?.code}; '
          'ApplicationExitInfo: reason=${exit?.reason} status=${exit?.status}',
    );
    return CrashEvidence(pid, signal!, exit!, dev.via, probe.ps, probe.libs);
  }

  /// Airplane mode on, and proof it is on (9.1.3).
  Future<void> airplane(Run run, bool on) async {
    await dev.airplane(on);
    final actual = await dev.airplaneOn();
    run.guard(
      'precondition: airplane mode ${on ? 'on' : 'off'}',
      actual == on ? [] : ['airplane_mode_on is $actual'],
      'settings global airplane_mode_on = ${actual ? 1 : 0}',
    );
  }

  /// The mock API is reachable from the device again (after airplane mode): the command channel works.
  Future<bool> waitCommandChannel({
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final ok = await until<bool>(
      () async {
        await mock.reset();
        await mock.command('status');
        final e = await until<bool>(
          () async {
            final ev = await mock.events();
            return ev.any((x) => x['kind'] == 'status') ? true : null;
          },
          timeout: const Duration(seconds: 6),
          every: const Duration(seconds: 1),
        );
        return e;
      },
      timeout: timeout,
      every: const Duration(seconds: 1),
    );
    return ok ?? false;
  }
}
