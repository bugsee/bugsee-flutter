// End-to-end symbolication against the REAL Bugsee backend, on a physical device (doc/verification.md,
// "End-to-end symbolication"). No mock: the default endpoint, the real app token.
//
//   BUGSEE_IOS_TOKEN=... dart scripts/device/e2e_symbolication.dart ios --udid <UDID>
//   BUGSEE_ANDROID_TOKEN=... dart scripts/device/e2e_symbolication.dart android --serial <adb serial>
//
// Device lock: optional. `--devlock <script>` or E2E_DEVLOCK names a script taking `acquire|release <device> ...`;
// without either the run takes no lock (and says so); `--no-lock` skips it even when configured.
// `--reuse-build` re-runs an already built run and needs `--run-id` (the staged build of that run is used).
//
// Reading the result back needs a credential an app token is not: the organisation's SERVER token of the
// public API (`x-auth-servertoken`) and the application's id:
//   BUGSEE_SERVER_TOKEN=... BUGSEE_IOS_APP_ID=... (or BUGSEE_ANDROID_APP_ID=...)
// Without them the run still builds, uploads, runs and crashes, and ends UNVERIFIED (exit 3): it never
// passes without having read the backend's symbolicated frames.
//
// What one run does:
//   1. a unique build string (`9.YYMMDD.HHMMSS`, the run id), a release build with `--obfuscate --split-debug-info`
//      of example/lib/e2e_main.dart, staged into the run's work directory (the app, the APK, the dSYMs: install and
//      upload use the staged copy only); guards: the symbols are the platform's format, the app's own function
//      names are NOT in the shipped binary (obfuscation took place; iOS: App.framework/App, Android: libapp.so of the APK)
//   2. uploads: the Dart symbols with the pinned symbols.py (HTTP statuses recorded), the native symbols
//      (iOS: the dSYM with bugsee-cli; Android: the Bugsee Gradle plugin during the release build)
//   3. installs, launches 4 times (doc: example/lib/e2e_main.dart): Dart errors; a native-signal crash;
//      a platform-language crash; the upload of the last recovered report
//   4. reads the backend (until the expected content is there or the deadline): the issues whose versions contain
//      the run id, their crash reports; expects the app's readable function names in symbolicated FRAMES, a native
//      frame of the ffi crash and one of the platform crash, each in a report of its own, and NO raw frame anywhere
//
// Exit: 0 verified, 3 UNVERIFIED (everything ran, nothing could be read back), 1 INVALID or FAILED, 64 usage.
// No token is ever printed or saved: every line goes through `redact`.
//
// This is a RUN with its own verdict, not a scenario of the harness (`Run.guard` / `Run.expect`): it ends in a
// verdict and exit code (0/1/3) that a scenario has no place for. Its checks are the pure functions of
// core/e2e.dart, each tested in test/device_harness_test.dart. A failed check throws `HarnessFailure`; `main`
// unwinds through the `finally` blocks (console save, uninstall, restoring example/android/bugsee.properties,
// the device lock) BEFORE exiting; an unexpected exception is printed through `redact` (`FAILED: ...`) and also
// cleans up. A signal (Ctrl-C, kill) runs ONLY the synchronous subset: it kills the active devicectl child,
// restores bugsee.properties, releases the lock and writes e2e-run.log. It does NOT uninstall the app, does NOT save
// console.txt, and a `flutter build` already running keeps running (orphaned). SIGKILL runs nothing: a
// token-bearing example/android/bugsee.properties can stay, and the next run saves it as "the developer's own"
// and restores it; delete it by hand.
//
// The read-back keeps only the recordings of THIS run (each recording's own app version/build, else its creation
// time), because an issue spans runs of the same error.
//
// ALL of the checks below the first run (the read-back, the Android pid and logcat evidence, the iOS signal 6 /
// exit-code rule, the libapp.so guard, the staging, the properties guard) have never run on a device or a backend.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'core/e2e.dart';
import 'shell.dart';
import 'toolchain.dart';

const _symbolsPy =
    'https://raw.githubusercontent.com/bugsee/bugsee-flutter/9bc0f8645755114491235dc68fec84fdc5671755/scripts/symbols.py';
const _symbolsPySha =
    'ef2ed4c25b87da764fd5b70238a41d776f6aa88b5e3174faa4e33de2f08453f7';
const _iosBundle = 'com.bugsee.bugseeFlutterExample';
const _androidPackage = 'com.bugsee.bugsee_flutter_example';

/// The lock script (`--devlock` or E2E_DEVLOCK); empty = no lock.
String _devlock = '';

const _expectedDart = [
  'e2eHandledSite',
  'e2eUnhandledSite',
  'e2eUncaughtThrower',
];

List<String> _secrets = [];
final _log = StringBuffer();

void say(String s) {
  final line = redact(s, _secrets);
  stdout.writeln(line);
  _log.writeln(line);
}

/// The device this process holds the lock of; `exit` skips `finally`, so every exit path releases it here.
String? _lockedDevice;

void _unlock() {
  final d = _lockedDevice;
  if (d == null) return;
  _lockedDevice = null;
  try {
    Process.runSync(_devlock, ['release', d, 'claude-e2e-symbolication']);
  } on Object {
    // best effort
  }
}

/// A check of the run failed: unwinds to `main`, which cleans up and exits 1.
class HarnessFailure implements Exception {
  HarnessFailure(this.why);
  final String why;
  @override
  String toString() => why;
}

Never invalid(String why) => throw HarnessFailure(why);

/// Everything the process must undo however it ends. Synchronous, idempotent: `main`'s `finally` and the
/// signal handlers both call it.
Child? _activeChild;
_PropsGuard? _propsGuard;
void _cleanupSync() {
  _activeChild?.process.kill(ProcessSignal.sigterm);
  _propsGuard?.restore();
  _unlock();
  _save();
}

/// Writes the Gradle plugin's `bugsee.properties` (the app token) for one build and puts back what was there.
/// A developer's own file is copied to the work directory first (private mode) and restored byte for byte; a
/// file this run created is deleted. The file is created private BEFORE the token is written.
class _PropsGuard {
  _PropsGuard(this.file, this.backup);
  final File file;
  final File backup;
  bool _active = false;
  List<int>? _original;
  String? _originalMode;

  static void _private(File f) {
    if (!f.existsSync()) f.createSync();
    Process.runSync('chmod', ['600', f.path]);
  }

  /// The octal permission bits of [f] (`stat -f %Lp` on macOS, `stat -c %a` on Linux), or null.
  static String? _mode(File f) {
    for (final args in [
      ['-f', '%Lp', f.path],
      ['-c', '%a', f.path],
    ]) {
      final r = Process.runSync('stat', args);
      final out = '${r.stdout}'.trim();
      if (r.exitCode == 0 && RegExp(r'^[0-7]{3,4}$').hasMatch(out)) return out;
    }
    return null;
  }

  /// Registered BEFORE anything is touched (the caller assigns the guard first), so a failure at any step,
  /// including a write that truncated the file, still restores. The original's mode is narrowed to 600 before
  /// the run token is written into it and put back by [restore].
  void install(String content) {
    _active = true;
    if (file.existsSync()) {
      _original = file.readAsBytesSync();
      _originalMode = _mode(file);
      _private(backup);
      backup.writeAsBytesSync(_original!);
      _private(file); // narrow BEFORE the token goes in, whatever mode the developer's file had
      say(
        'example/android/bugsee.properties exists: its content is saved to ${backup.path} and restored after the build',
      );
    } else {
      _private(file);
    }
    file.writeAsStringSync(content);
  }

  void restore() {
    if (!_active) return;
    _active = false;
    try {
      final original = _original;
      if (original == null) {
        if (file.existsSync()) file.deleteSync();
      } else {
        file.writeAsBytesSync(original);
        final mode = _originalMode;
        if (mode != null) Process.runSync('chmod', [mode, file.path]);
        if (backup.existsSync()) backup.deleteSync();
      }
    } on Object {
      stderr.writeln(
        'WARNING: could not restore ${file.path}; it may still hold the run token (a saved copy of the original is ${backup.path})',
      );
    }
  }
}

late String _workDir;
void _save() {
  try {
    File('$_workDir/e2e-run.log').writeAsStringSync(_log.toString());
  } on Object {
    // best effort
  }
}

Future<void> main(List<String> args) async {
  final signals = [
    for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm])
      sig.watch().listen((_) {
        _cleanupSync();
        exit(130);
      }),
  ];
  var code = 1;
  try {
    code = await _run(args);
  } on HarnessFailure catch (e) {
    say('INVALID: ${e.why}');
  } on Object catch (e) {
    // anything unexpected (a ProcessException carries the whole command line, `-t <token>` included)
    say('FAILED: ${failureText(e, _secrets)}');
  } finally {
    _cleanupSync();
    for (final s in signals) {
      await s.cancel();
    }
  }
  exit(code);
}

Future<int> _run(List<String> args) async {
  if (args.isEmpty || !{'ios', 'android'}.contains(args.first)) {
    stderr.writeln(
      'usage: e2e_symbolication.dart ios --udid <UDID> | android --serial <serial> '
      '[--run-id <id>] [--reuse-build (needs --run-id)] [--devlock <script> | --no-lock] [--readback-wait-minutes N]',
    );
    exit(64);
  }
  final platform = args.first;
  String? opt(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final env = Platform.environment;
  final token =
      env[platform == 'ios' ? 'BUGSEE_IOS_TOKEN' : 'BUGSEE_ANDROID_TOKEN'] ??
      '';
  final serverToken = env['BUGSEE_SERVER_TOKEN'] ?? '';
  final appId =
      env[platform == 'ios' ? 'BUGSEE_IOS_APP_ID' : 'BUGSEE_ANDROID_APP_ID'] ??
      '';
  _secrets = [token, serverToken];
  if (token.isEmpty) {
    stderr.writeln(
      'BUGSEE_${platform == 'ios' ? 'IOS' : 'ANDROID'}_TOKEN is not set',
    );
    exit(64);
  }
  final device = opt(platform == 'ios' ? '--udid' : '--serial') ?? '';
  if (device.isEmpty) {
    stderr.writeln('the device is required (the run never picks one)');
    exit(64);
  }
  final reuse = args.contains('--reuse-build');
  if (reuse && opt('--run-id') == null) {
    stderr.writeln(
      '--reuse-build needs --run-id <the id of the run whose staged build is reused>',
    );
    exit(64);
  }
  final noLock = args.contains('--no-lock');
  _devlock = opt('--devlock') ?? env['E2E_DEVLOCK'] ?? '';
  if (!noLock && _devlock.isNotEmpty && !File(_devlock).existsSync()) {
    stderr.writeln(
      'the device lock script "$_devlock" does not exist: fix --devlock / E2E_DEVLOCK, or pass --no-lock to run without a lock',
    );
    exit(64);
  }
  final repo = Directory.current.path.endsWith('/scripts/device')
      ? Directory.current.parent.parent.path
      : Directory.current.path;
  final runId = opt('--run-id') ?? runIdFor(DateTime.now());
  final workDir =
      '${env['E2E_WORK_DIR'] ?? '${Directory.systemTemp.path}/bugsee-e2e'}/$platform-$runId';
  if (!reuse && Directory(workDir).existsSync()) {
    stderr.writeln(
      'the work directory $workDir already exists: a fresh run needs a build id of its own (another --run-id, or --reuse-build to re-run that build)',
    );
    exit(64);
  }
  _workDir = workDir;
  Directory(_workDir).createSync(recursive: true);
  final tc = Toolchain.detect(repo, _workDir);
  say('run $runId on $platform $device, work dir $_workDir');
  say('flutter ${(await tc.describe())['flutter']}, java ${tc.javaHome}');
  final job = _Job(tc, platform, device, token, runId, reuse);

  var locked = false;
  if (noLock) {
    say('no device lock (--no-lock)');
  } else if (_devlock.isEmpty) {
    say(
      'no device lock: neither --devlock nor E2E_DEVLOCK is set; make sure nothing else uses $device',
    );
  } else {
    final r = await sh([
      _devlock,
      'acquire',
      device,
      'claude-e2e-symbolication',
      'e2e symbolication run $runId',
      '600',
    ]);
    if (!r.ok) invalid('the device lock is not ours: ${r.text}');
    locked = true;
    _lockedDevice = device;
  }
  try {
    await job.build();
    await job.uploadDartSymbols();
    await job.runOnDevice();
  } finally {
    if (locked) _unlock();
  }
  return job.readBack(
    serverToken,
    appId,
    Duration(minutes: int.tryParse(opt('--readback-wait-minutes') ?? '') ?? 15),
  );
}

class _Job {
  _Job(this.tc, this.platform, this.device, this.token, this.runId, this.reuse);
  final Toolchain tc;
  final String platform;
  final String device;
  final String token;
  final String runId;
  final bool reuse;

  /// When this process started: the floor for a recording's creation time when it carries no app version.
  final DateTime startedAt = DateTime.now();
  bool get ios => platform == 'ios';

  /// `BUGSEE_ENDPOINT` (a version-less base such as https://apidev.bugsee.com): empty means the default,
  /// production, endpoint everywhere (SDK, symbols.py, bugsee-cli, Gradle plugin). The same value goes to all.
  String get endpoint => (Platform.environment['BUGSEE_ENDPOINT'] ?? '')
      .replaceAll(RegExp(r'/+$'), '');
  String get symbolsDir => '$_workDir/symbols';
  String get buildNumber => runId.split('.').last; // HHMMSS

  String get example => '${tc.repoRoot}/example';

  List<String> get _buildArgs => [
    '--release',
    '--obfuscate',
    '--split-debug-info=$symbolsDir',
    '-t',
    'lib/e2e_main.dart',
    '--build-name',
    runId,
    '--build-number',
    buildNumber,
    '--dart-define=E2E_RUN=$runId',
    if (endpoint.isNotEmpty) '--dart-define=BUGSEE_ENDPOINT=$endpoint',
    // No per-launch environment reaches the app (devicectl's did not, measured): the token is compiled into this LOCAL build only.
    '--dart-define=BUGSEE_E2E_TOKEN=$token',
  ];

  /// Where this run's build is kept: install and upload read ONLY from here, so another build of the same
  /// checkout (the shared `example/build`) cannot change what this run installs. The copy is taken right after
  /// the build; two runs must still not BUILD in one checkout at the same time.
  String get stage => '$_workDir/stage';
  String get stagedApp => '$stage/Runner.app';
  String get stagedApk => '$stage/app-release.apk';
  String get stagedDsyms => '$_workDir/dsyms';

  String get _identityFile => '$stage/identity.json';

  /// What the staged build was made for. The app token is compiled into it, so a reused build must be run with
  /// the same app and endpoint. Only a SHA-256 of the token is kept (never the token or a prefix).
  Future<Map<String, Object?>> _identity() async {
    final h = await sh(['shasum', '-a', '256'], stdin: token);
    if (!h.ok) invalid('could not fingerprint the app token: ${h.stderr}');
    return {
      'platform': platform,
      'endpoint': endpoint,
      'app': h.text.split(' ').first,
    };
  }

  Future<void> build() async {
    Directory(symbolsDir).createSync(recursive: true);
    if (!reuse) {
      final bugseeProps = File('$example/android/bugsee.properties');
      try {
        if (!ios) {
          // The Gradle plugin reads the app token here (gitignored) and uploads the native libraries' symbols
          // when the release variant is assembled. A developer's own file is saved and restored, never lost;
          // the guard is registered first and also undone by every exit path (`_cleanupSync`).
          final guard = _propsGuard = _PropsGuard(
            bugseeProps,
            File('$_workDir/bugsee.properties.original'),
          );
          guard.install(
            'app_token=$token\n${endpoint.isEmpty ? '' : 'plugin.endpoint=$endpoint\n'}',
          );
        }
        say(
          'building ${ios ? 'ios' : 'apk'} release (obfuscated), build $runId',
        );
        await sh([tc.flutter, 'pub', 'get'], cwd: example, env: tc.buildEnv);
        final b = await sh(
          [tc.flutter, 'build', if (ios) 'ios' else 'apk', ..._buildArgs],
          cwd: example,
          env: tc.buildEnv,
          timeout: const Duration(minutes: 45),
        );
        File('$_workDir/build.log')
            .writeAsStringSync(redact('${b.stdout}\n${b.stderr}', _secrets));
        if (!b.ok) {
          invalid(
            'flutter build failed (see $_workDir/build.log): ${redact(b.stderr, _secrets)}',
          );
        }
        if (!ios) {
          final up = RegExp(
            r'^.*(?:[Bb]ugsee).*(?:upload|symbol).*$',
            multiLine: true,
          ).allMatches(b.stdout + b.stderr).map((m) => m[0]!).toList();
          say(
            'Gradle plugin lines about uploads: ${up.isEmpty ? 'NONE (see build.log; native symbols were probably not uploaded)' : up.join(' | ')}',
          );
          if (up.isEmpty) nativeUploadSeen = false;
        }
      } finally {
        _propsGuard?.restore();
      }
      await _stageBuild();
      File(_identityFile).writeAsStringSync(jsonEncode(await _identity()));
    } else {
      if (!Directory(stage).existsSync() || !File(_identityFile).existsSync()) {
        invalid(
          '--reuse-build: there is no staged build (with its identity) in $stage',
        );
      }
      final recorded = jsonDecode(File(_identityFile).readAsStringSync());
      final bad = reuseIdentityProblems(
        (recorded as Map).cast<String, Object?>(),
        await _identity(),
      );
      if (bad.isNotEmpty) invalid('--reuse-build: ${bad.join('; ')}');
    }
    // guard: the symbols are the platform's format
    final files = Directory(symbolsDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.symbols'))
        .toList();
    if (files.isEmpty) {
      invalid(
        'no .symbols file in $symbolsDir: --split-debug-info did not write any',
      );
    }
    for (final f in files) {
      final fmt = symbolsFormat(f.openSync().readSync(8));
      final want = ios ? 'macho' : 'elf';
      if (fmt != want) invalid('${f.path} is $fmt, expected $want');
      say('symbols: ${f.path.split('/').last} ($fmt, ${f.lengthSync()} bytes)');
    }
    await _obfuscationGuard();
  }

  /// Copies what the run installs and uploads out of the shared build tree.
  Future<void> _stageBuild() async {
    Directory(stage).createSync(recursive: true);
    if (ios) {
      final src = '$example/build/ios/iphoneos/Runner.app';
      if (!Directory(src).existsSync()) invalid('the build left no $src');
      final c = await sh(['cp', '-R', src, stagedApp]);
      if (!c.ok) invalid('staging Runner.app failed: ${c.text}');
      final dsyms = Directory('$example/build/ios')
          .listSync(recursive: true)
          .whereType<Directory>()
          .where((d) => d.path.endsWith('.dSYM'))
          .map((d) => d.path)
          .toList();
      say('dSYMs of the build: $dsyms');
      if (dsyms.isEmpty) {
        invalid(
          'no .dSYM was produced by the release build: the native iOS frames cannot be symbolicated',
        );
      }
      Directory(stagedDsyms).createSync(recursive: true);
      for (final d in dsyms) {
        final c = await sh(['cp', '-R', d, stagedDsyms]);
        if (!c.ok) invalid('staging $d failed: ${c.text}');
      }
    } else {
      final src = '$example/build/app/outputs/flutter-apk/app-release.apk';
      if (!File(src).existsSync()) invalid('the build left no $src');
      File(src).copySync(stagedApk);
    }
  }

  /// guard: obfuscation took place: the app's own function name is not in the shipped binary (staged copy).
  /// Without obfuscation the VM prints readable names itself and a readable backend name would prove nothing.
  Future<void> _obfuscationGuard() async {
    String binary;
    if (ios) {
      binary = '$stagedApp/Frameworks/App.framework/App';
    } else {
      binary = '$stage/libapp.so';
      if (!File(binary).existsSync()) {
        final u = await sh([
          'unzip',
          '-o',
          '-j',
          stagedApk,
          'lib/arm64-v8a/libapp.so',
          '-d',
          stage,
        ]);
        if (!u.ok) {
          invalid(
            'could not read lib/arm64-v8a/libapp.so of the APK: ${u.text}',
          );
        }
      }
    }
    final s = await sh([
      'strings',
      '-a',
      binary,
    ], timeout: const Duration(minutes: 3));
    if (!s.ok) {
      invalid(
        '`strings` failed on $binary, the obfuscation guard proves nothing: ${s.text}',
      );
    }
    if (s.stdout.contains('e2eHandledSite')) {
      invalid(
        'the shipped ${binary.split('/').last} still contains "e2eHandledSite": not obfuscated, a readable backend name would prove nothing',
      );
    }
    say(
      'obfuscation guard: "e2eHandledSite" is not in the shipped ${binary.split('/').last}',
    );
  }

  bool nativeUploadSeen = true;

  Future<void> uploadDartSymbols() async {
    final py = '$_workDir/symbols.py';
    final dl = await sh(['curl', '-fsSL', _symbolsPy, '-o', py]);
    if (!dl.ok) invalid('could not fetch symbols.py: ${dl.text}');
    final sha = (await sh(['shasum', '-a', '256', py])).text.split(' ').first;
    if (sha != _symbolsPySha) {
      invalid('symbols.py sha256 is $sha, pinned $_symbolsPySha');
    }
    final venv = Platform.environment['E2E_PYTHON'] ?? 'python3';
    say(
      'uploading the Dart symbols with the pinned symbols.py (-t <token> -d <dir> -v $runId, default endpoint)',
    );
    final r = await sh([
      venv,
      '${tc.repoRoot}/scripts/device/symbols_logged.py',
      py,
      '-t',
      token,
      '-v',
      runId,
      '-d',
      symbolsDir,
      if (endpoint.isNotEmpty) ...['-e', '$endpoint/v2/'],
    ], timeout: const Duration(minutes: 10));
    final out = redact('${r.stdout}\n${r.stderr}', _secrets);
    say(out.trim());
    final problems = symbolsUploadProblems(out, r.code);
    if (problems.isNotEmpty) {
      invalid('the Dart symbols upload: ${problems.join('; ')}');
    }
    say('Dart symbols uploaded (POST and PUT both 2xx)');

    if (ios) {
      // The native side: the dSYM of this build, with bugsee-cli (docs: /cli/xcode, /cli/debug-files).
      final cli = Platform.environment['BUGSEE_CLI'] ?? 'bugsee-cli';
      final dir = stagedDsyms;
      final up = await sh(
        [
          cli,
          'debug-files',
          'upload',
          dir,
          '--type',
          'dsym',
          '--version',
          runId,
          '--build',
          buildNumber,
        ],
        env: {
          ...Platform.environment,
          'BUGSEE_APP_TOKEN': token,
          if (endpoint.isNotEmpty) 'BUGSEE_ENDPOINT': endpoint,
        },
        timeout: const Duration(minutes: 15),
      );
      say(
        'bugsee-cli debug-files upload (dsym): exit ${up.code}\n${redact('${up.stdout}\n${up.stderr}', _secrets).trim()}',
      );
      if (!up.ok) invalid('the dSYM upload failed (exit ${up.code})');
    } else if (!nativeUploadSeen) {
      say(
        'WARNING: the Gradle plugin printed nothing about an upload; the native Android symbols may be missing',
      );
    }
  }

  // ---- the device -------------------------------------------------------------------------------

  String get consoleFile => '$_workDir/console.txt';

  Future<void> runOnDevice() async {
    if (ios) {
      await _runIos();
    } else {
      await _runAndroid();
    }
  }

  Future<Child> _iosLaunch() => Child.start([
    'xcrun',
    'devicectl',
    'device',
    'process',
    'launch',
    '--device',
    device,
    '--terminate-existing',
    '--console',

    _iosBundle,
  ]);

  Future<void> _runIos() async {
    final ctl = ['xcrun', 'devicectl'];
    final app = stagedApp;
    await sh([
      ...ctl,
      'device',
      'uninstall',
      'app',
      '--device',
      device,
      _iosBundle,
    ]);
    final inst = await sh([
      ...ctl,
      'device',
      'install',
      'app',
      '--device',
      device,
      app,
    ], timeout: const Duration(minutes: 5));
    if (!inst.ok) invalid('install failed: ${redact(inst.text, _secrets)}');
    say('installed $_iosBundle build $runId');
    final all = StringBuffer();
    try {
      for (var phase = 0; phase < 4; phase++) {
        say('launch ${phase + 1} of 4 (phase $phase)');
        final c = await _iosLaunch();
        _activeChild = c;
        try {
          final wantsExit = phase == 1 || phase == 2;
          final marker = wantsExit
              ? '"kind":"crashing"'
              : '"kind":"phase-done"';
          final ok = await c.waitFor(
            marker,
            timeout: const Duration(minutes: 5),
          );
          if (!ok) {
            invalid(
              'phase $phase never reached ${wantsExit ? 'its crash' : 'its end'}:\n${redact(c.output.toString(), _secrets)}',
            );
          }
          if (wantsExit) {
            final code = await c.process.exitCode.timeout(
              const Duration(seconds: 90),
              onTimeout: () => -999,
            );
            await c.drained();
            if (code == -999) {
              invalid(
                'phase $phase announced a crash and the process did not end within 90 s',
              );
            }
            say('phase $phase: the process ended (devicectl exit $code)');
            final kind = phase == 1 ? 'ffi-segv' : 'objc-main';
            final bad = iosCrashExitProblems(kind, c.output.toString(), code);
            if (bad.isNotEmpty) {
              invalid('phase $phase: ${bad.join('; ')}');
            }
          } else {
            await c.stop();
            // Stopping the console child makes devicectl terminate the app it launched, and not at once: the next
            // launch of the run was found killed by that SIGTERM 0.2 s after it started (run 7). Let it finish.
            await delay(10);
          }
        } finally {
          // the output of this launch is saved whichever way it ended, the child never outlives it
          all.writeln(redact(c.output.toString(), _secrets));
          await c.stop();
          _activeChild = null;
        }
      }
    } finally {
      _saveConsole(all);
      await sh([
        ...ctl,
        'device',
        'uninstall',
        'app',
        '--device',
        device,
        _iosBundle,
      ]);
    }
    _checkEvents('ios');
  }

  Future<void> _runAndroid() async {
    final adb = tc.adbPath;
    Future<Out> a(
      List<String> args, {
      Duration timeout = const Duration(minutes: 2),
    }) => sh([adb, '-s', device, ...args], timeout: timeout);
    final state = (await a(['get-state'])).text;
    if (state != 'device') {
      invalid('$device is "$state" over adb, not "device"');
    }
    final apk = stagedApk;
    await a(['uninstall', _androidPackage]);
    final inst = await a([
      'install',
      '-r',
      apk,
    ], timeout: const Duration(minutes: 5));
    if (!inst.ok || !inst.stdout.contains('Success')) {
      invalid('install failed: ${inst.text}');
    }
    say('installed $_androidPackage build $runId');
    final all = StringBuffer();
    try {
      for (var phase = 0; phase < 4; phase++) {
        say('launch ${phase + 1} of 4 (phase $phase)');
        await a(['logcat', '-c']);
        await a(['shell', 'am', 'force-stop', _androidPackage]);
        final l = await a([
          'shell',
          'am',
          'start',
          '-W',
          '-n',
          '$_androidPackage/.MainActivity',
        ]);
        if (!l.ok) invalid('am start failed: ${l.text}');
        // The pid of THIS launch, read while the process is alive (it crashes right after its marker): the crash
        // evidence below is about this pid and no other.
        final pid = await until<int>(
          () async {
            final r = await a(['shell', 'pidof', _androidPackage]);
            return r.ok
                ? int.tryParse(r.text.split(RegExp(r'\s+')).first)
                : null;
          },
          timeout: const Duration(seconds: 20),
          every: const Duration(seconds: 1),
        );
        if (pid == null) {
          invalid('phase $phase: no pid for $_androidPackage after am start');
        }
        final wantsExit = phase == 1 || phase == 2;
        final marker = wantsExit ? '"kind":"crashing"' : '"kind":"phase-done"';
        final end = DateTime.now().add(const Duration(minutes: 5));
        var seen = false;
        var log = '';
        while (DateTime.now().isBefore(end)) {
          log = (await a(['logcat', '-d', '-s', 'flutter'])).stdout;
          if (log.contains(marker)) {
            seen = true;
            break;
          }
          await delay(2);
        }
        all.writeln(redact(log, _secrets));
        if (!seen) {
          invalid(
            'phase $phase never reached ${wantsExit ? 'its crash' : 'its end'}',
          );
        }
        if (wantsExit) {
          // Gone means a successful `pidof` that no longer lists the pid; an adb failure is inconclusive
          // and polls on (it ends as "still alive" only if it never clears).
          final gone = await until<bool>(
            () async {
              final r = await a(['shell', 'pidof', _androidPackage]);
              return androidPidGone(
                        code: r.code,
                        stdout: r.stdout,
                        stderr: r.stderr,
                        pid: pid,
                      ) ==
                      true
                  ? true
                  : null;
            },
            timeout: const Duration(seconds: 90),
            every: const Duration(seconds: 2),
          );
          if (gone != true) {
            invalid(
              'phase $phase announced a crash and the process (pid $pid) is not confirmed gone after 90 s',
            );
          }
          // and it died OF the announced crash (its pid, its signal or exception), not of anything else
          final kind = phase == 1 ? 'ffi-segv' : 'java-main';
          final bad = androidCrashProblems(
            kind,
            (await a(['logcat', '-d'])).stdout,
            pid,
          );
          if (bad.isNotEmpty) invalid('phase $phase: ${bad.join('; ')}');
          say('phase $phase: process $pid ended of $kind');
        }
      }
    } finally {
      _saveConsole(all);
      await a(['shell', 'am', 'force-stop', _androidPackage]);
      await a(['uninstall', _androidPackage]);
    }
    _checkEvents('android');
  }

  /// Saving the console must never stop the device cleanup (uninstall) that follows it.
  void _saveConsole(StringBuffer all) {
    try {
      File(consoleFile).writeAsStringSync(all.toString());
    } on Object catch (e) {
      say('WARNING: could not save $consoleFile: ${failureText(e, _secrets)}');
    }
  }

  void _checkEvents(String os) {
    final events = e2eEvents(File(consoleFile).readAsStringSync(), runId);
    say('${events.length} events of run $runId in the console');
    final problems = phaseProblems(events, os: os, release: true);
    if (problems.isNotEmpty) invalid('the device run: ${problems.join('; ')}');
    say(
      'device run complete: 4 launches (errors, native signal, platform crash, upload), 2 crashes, all launched',
    );
  }

  // ---- the backend --------------------------------------------------------------------------------

  /// The page size asked of the issue list. The partner API's paging was not verified here, so a FULL page is
  /// reported (this build's issues could be on a later one) instead of being silently trusted.
  static const _pageLimit = 100;

  Future<int> readBack(String serverToken, String appId, Duration wait) async {
    if (serverToken.isEmpty || appId.isEmpty) {
      say(
        'UNVERIFIED: reading the backend needs the organisation SERVER token (BUGSEE_SERVER_TOKEN, the public '
        'API\'s x-auth-servertoken) and the application id (BUGSEE_${ios ? 'IOS' : 'ANDROID'}_APP_ID). An app token '
        'cannot read issues. Everything before this point ran: the build is $runId; find it in the dashboard '
        'by that version string.',
      );
      return 3;
    }
    final base =
        '${endpoint.isEmpty ? 'https://api.bugsee.com' : endpoint}/v2/partner/';
    final client = HttpClient();
    final end = DateTime.now().add(wait);
    try {
      // The poll ends when the EXPECTED CONTENT is there (no raw frame, every name in a frame), or at the
      // deadline. Issues appear before their symbolication and the crashes are the last uploaded, so a count
      // of issues says nothing; each pass reads the issues and their reports again.
      var problems = <String>['nothing was read yet'];
      final passes = <({bool ok, int reports})>[];
      var unstable = false;
      while (true) {
        final pass = await _readOnce(client, base, serverToken, appId, end);
        final reports = pass.reports;
        problems = readbackProblems(
          reports,
          unreadRecordings: pass.unread,
          expectedDartNames: _expectedDart,
          expectedNativeFrames: [
            'crash_lab.dart',
            ios ? 'AppDelegate.swift' : 'MainActivity.java',
          ],
        );
        passes.add((ok: problems.isEmpty, reports: reports.length));
        if (readbackSettled(passes)) break;
        final more = DateTime.now()
            .add(const Duration(seconds: 30))
            .isBefore(end);
        if (problems.isEmpty) {
          // Found everything, but a report that arrives later could still be raw: read again until two
          // consecutive passes agree. No confirming pass is scheduled past the deadline: the run then ends
          // NOT CONFIRMED (exit 1) and says it was one pass short.
          say(
            'backend: everything expected is there; reading again to catch a late report',
          );
          if (!more) {
            unstable = true;
            break;
          }
        } else {
          say('backend: not yet: ${problems.join('; ')}');
          if (!more) break;
        }
        await delay(30);
      }
      if (unstable) {
        say(
          'NOT CONFIRMED: the set of reports kept changing until the deadline',
        );
        return 1;
      }
      if (problems.isNotEmpty) {
        say(
          'NOT SYMBOLICATED (or not found) at the deadline: ${problems.join('; ')}',
        );
        return 1;
      }
      say(
        'VERIFIED: the backend shows ${_expectedDart.join(', ')} in symbolicated frames, a native frame of the ffi crash and one of the platform crash in reports of their own, and no raw frame',
      );
      return 0;
    } finally {
      client.close(force: true);
    }
  }

  /// One pass: the issues of this build, then the crash reports of THIS run's recordings. Errors are said; a
  /// recording (or an issue's recording list) that could not be read is COUNTED as unread, never skipped
  /// silently, and one failing recording does not stop the others.
  Future<({List<String> reports, int unread})> _readOnce(
    HttpClient client,
    String base,
    String serverToken,
    String appId,
    DateTime end,
  ) async {
    final reports = <String>[];
    var unread = 0;
    try {
      final r = await _get(
        client,
        '${base}applications/$appId/issues?limit=$_pageLimit',
        serverToken,
        end,
      ) as Map;
      final objs = (r['objects'] as List).cast<Map>();
      final mine = [
        for (final i in objs)
          if (((i['statistics'] as Map?)?['versions'] as Map?)?.keys.any(
                (k) => '$k' == runId,
              ) ??
              false)
            i.cast<String, Object?>(),
      ];
      say(
        'backend: ${objs.length} issues listed, ${mine.length} with version $runId',
      );
      if (objs.length >= _pageLimit) {
        say(
          'WARNING: the page is full ($_pageLimit): this build\'s issues may be on a later page, which this run does not read',
        );
      }
      for (final issue in mine) {
        final id = issue['_id'];
        say('issue $id type=${issue['type']} summary="${issue['summary']}"');
        List list;
        try {
          final recs = await _get(
            client,
            '${base}applications/$appId/issues/$id/recordings',
            serverToken,
            end,
          );
          list = (recs is Map ? recs['objects'] : recs) as List? ?? [];
        } on HarnessFailure {
          rethrow;
        } on Object catch (e) {
          say('  recording list of issue $id: ${redact('$e', _secrets)}');
          unread++;
          continue;
        }
        for (final rec in list) {
          final rid = (rec as Map)['_id'];
          // An issue spans runs (same error, older build, an earlier attempt): only THIS attempt's recordings
          // are evidence.
          switch (recordingScope(
            rec.cast<String, Object?>(),
            runId: runId,
            buildNumber: buildNumber,
            since: startedAt.subtract(const Duration(minutes: 2)),
          )) {
            case RecordingScope.mine:
              break;
            case RecordingScope.other:
              say('  recording $rid: another build or attempt, ignored');
              continue;
            case RecordingScope.unknown:
              invalid(
                'recording $rid of issue $id has neither an app version nor a creation time: it cannot be tied to this run, nothing can be verified',
              );
          }
          try {
            final text = await _getText(
              client,
              '${base}applications/$appId/issues/$id/recordings/$rid/crash_report',
              serverToken,
              end,
            );
            reports.add(text);
            File('$_workDir/backend-$id-$rid.txt')
                .writeAsStringSync(redact(text, _secrets));
            final raw = rawFrameLines(text);
            say(
              '  recording $rid: ${text.split('\n').length} lines, ${raw.length} raw frame line(s)',
            );
          } on HarnessFailure {
            rethrow;
          } on Object catch (e) {
            say('  recording $rid read: ${redact('$e', _secrets)}');
            unread++;
          }
        }
      }
    } on HarnessFailure {
      rethrow;
    } on Object catch (e) {
      say('backend read: ${redact('$e', _secrets)}');
    }
    return (reports: reports, unread: unread);
  }

  /// A GET answered within the run's remaining time: the connection, the headers and the body each bounded,
  /// the request aborted when one is not.
  Future<String> _getText(
    HttpClient c,
    String url,
    String serverToken,
    DateTime end,
  ) async {
    final left = end.difference(DateTime.now());
    // at least a few seconds even at the deadline: the last pass must be able to finish its reads
    final limit = left < const Duration(seconds: 20)
        ? const Duration(seconds: 20)
        : (left > const Duration(minutes: 2)
              ? const Duration(minutes: 2)
              : left);
    HttpClientRequest? req;
    try {
      req = await c.getUrl(Uri.parse(url)).timeout(limit);
      req.headers.set('x-auth-servertoken', serverToken);
      final res = await req.close().timeout(limit);
      final body = await res.transform(utf8.decoder).join().timeout(limit);
      if (res.statusCode != 200) {
        throw StateError(
          'GET ${Uri.parse(url).path} -> ${res.statusCode} ${redact(body, _secrets)}',
        );
      }
      return body;
    } on TimeoutException {
      req?.abort();
      throw StateError('GET ${Uri.parse(url).path} timed out after $limit');
    }
  }

  Future<Object?> _get(
    HttpClient c,
    String url,
    String serverToken,
    DateTime end,
  ) async {
    final v = jsonDecode(await _getText(c, url, serverToken, end));
    return v is Map && v.containsKey('result') ? v['result'] : v;
  }
}
