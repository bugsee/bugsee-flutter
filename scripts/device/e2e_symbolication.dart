// End-to-end symbolication against the REAL Bugsee backend, on a physical device (doc/verification.md,
// "End-to-end symbolication"). No mock: the default endpoint, the real app token.
//
//   BUGSEE_IOS_TOKEN=... dart scripts/device/e2e_symbolication.dart ios --udid <UDID>
//   BUGSEE_ANDROID_TOKEN=... dart scripts/device/e2e_symbolication.dart android --serial <adb serial>
//
// Reading the result back needs a credential an app token is not: the organisation's SERVER token of the
// public API (`x-auth-servertoken`) and the application's id:
//   BUGSEE_SERVER_TOKEN=... BUGSEE_IOS_APP_ID=... (or BUGSEE_ANDROID_APP_ID=...)
// Without them the run still builds, uploads, runs and crashes, and ends UNVERIFIED (exit 3): it never
// passes without having read the backend's symbolicated frames.
//
// What one run does:
//   1. a unique build string (`9.MMDD.HHMM`, the run id), a release build with `--obfuscate --split-debug-info`
//      of example/lib/e2e_main.dart; guards: the symbols are the platform's format, the app's own function
//      names are NOT in the shipped binary (obfuscation took place)
//   2. uploads: the Dart symbols with the pinned symbols.py (HTTP statuses recorded), the native symbols
//      (iOS: the dSYM with bugsee-cli; Android: the Bugsee Gradle plugin during the release build)
//   3. installs, launches 4 times (doc: example/lib/e2e_main.dart): Dart errors; a native-signal crash;
//      a platform-language crash; the upload of the last recovered report
//   4. reads the backend: the issues whose versions contain the run id, their crash reports; expects the
//      app's readable function names and no raw addresses
//
// Exit: 0 verified, 3 UNVERIFIED (everything ran, nothing could be read back), 1 INVALID or FAILED, 64 usage.
// No token is ever printed or saved: every line goes through `redact`.
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
const _devlock = '/Volumes/External2TB/tmp-claude/device-locks/devlock.sh';

const _expectedDart = [
  'e2eHandledSite',
  'e2eUnhandledSite',
  'e2eUncaughtThrower',
];

late List<String> _secrets;
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
  Process.runSync(_devlock, ['release', d, 'claude-e2e-symbolication']);
}

Never invalid(String why) {
  say('INVALID: $why');
  _save();
  _unlock();
  exit(1);
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
  if (args.isEmpty || !{'ios', 'android'}.contains(args.first)) {
    stderr.writeln(
      'usage: e2e_symbolication.dart ios --udid <UDID> | android --serial <serial> '
      '[--run-id <id>] [--reuse-build] [--no-lock] [--readback-wait-minutes N]',
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
  final repo = Directory.current.path.endsWith('/scripts/device')
      ? Directory.current.parent.parent.path
      : Directory.current.path;
  final runId = opt('--run-id') ?? runIdFor(DateTime.now());
  _workDir =
      '${env['E2E_WORK_DIR'] ?? '${Directory.systemTemp.path}/bugsee-e2e'}/$platform-$runId';
  Directory(_workDir).createSync(recursive: true);
  final tc = Toolchain.detect(repo, _workDir);
  say('run $runId on $platform $device, work dir $_workDir');
  say('flutter ${(await tc.describe())['flutter']}, java ${tc.javaHome}');
  final job = _Job(
    tc,
    platform,
    device,
    token,
    runId,
    opt('--reuse-build') != null,
  );

  var locked = false;
  if (!args.contains('--no-lock')) {
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
  final verdict = await job.readBack(
    serverToken,
    appId,
    Duration(minutes: int.tryParse(opt('--readback-wait-minutes') ?? '') ?? 15),
  );
  _save();
  exit(verdict);
}

class _Job {
  _Job(this.tc, this.platform, this.device, this.token, this.runId, this.reuse);
  final Toolchain tc;
  final String platform;
  final String device;
  final String token;
  final String runId;
  final bool reuse;
  bool get ios => platform == 'ios';

  /// `BUGSEE_ENDPOINT` (a version-less base such as https://apidev.bugsee.com): empty means the default,
  /// production, endpoint everywhere (SDK, symbols.py, bugsee-cli, Gradle plugin). The same value goes to all.
  String get endpoint => (Platform.environment['BUGSEE_ENDPOINT'] ?? '')
      .replaceAll(RegExp(r'/+$'), '');
  String get symbolsDir => '$_workDir/symbols';
  String get buildNumber => runId.split('.').last; // HHMM

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

  Future<void> build() async {
    Directory(symbolsDir).createSync(recursive: true);
    final bugseeProps = File('$example/android/bugsee.properties');
    if (!ios && !reuse) {
      // The Gradle plugin reads the app token here (gitignored) and uploads the native libraries' symbols
      // when the release variant is assembled. Removed in the `finally` below.
      bugseeProps.writeAsStringSync(
        'app_token=$token\n${endpoint.isEmpty ? '' : 'plugin.endpoint=$endpoint\n'}',
      );
      await sh(['chmod', '600', bugseeProps.path]);
    }
    try {
      if (!reuse) {
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
        if (!b.ok)
          invalid(
            'flutter build failed (see $_workDir/build.log): ${redact(b.stderr, _secrets)}',
          );
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
      }
    } finally {
      if (!ios && bugseeProps.existsSync()) bugseeProps.deleteSync();
    }
    // guard: the symbols are the platform's format
    final files = Directory(symbolsDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.symbols'))
        .toList();
    if (files.isEmpty)
      invalid(
        'no .symbols file in $symbolsDir: --split-debug-info did not write any',
      );
    for (final f in files) {
      final fmt = symbolsFormat(f.openSync().readSync(8));
      final want = ios ? 'macho' : 'elf';
      if (fmt != want) invalid('${f.path} is $fmt, expected $want');
      say('symbols: ${f.path.split('/').last} ($fmt, ${f.lengthSync()} bytes)');
    }
    // guard: obfuscation took place: the app's own function name is not in the shipped binary
    final binary = ios
        ? '$example/build/ios/iphoneos/Runner.app/Frameworks/App.framework/App'
        : null;
    if (binary != null) {
      final s = await sh([
        'strings',
        '-a',
        binary,
      ], timeout: const Duration(minutes: 3));
      if (s.stdout.contains('e2eHandledSite')) {
        invalid(
          'the shipped App binary still contains "e2eHandledSite": not obfuscated, a readable backend name would prove nothing',
        );
      }
      say(
        'obfuscation guard: "e2eHandledSite" is not in the shipped App binary',
      );
    }
  }

  bool nativeUploadSeen = true;

  Future<void> uploadDartSymbols() async {
    final py = '$_workDir/symbols.py';
    final dl = await sh(['curl', '-fsSL', _symbolsPy, '-o', py]);
    if (!dl.ok) invalid('could not fetch symbols.py: ${dl.text}');
    final sha = (await sh(['shasum', '-a', '256', py])).text.split(' ').first;
    if (sha != _symbolsPySha)
      invalid('symbols.py sha256 is $sha, pinned $_symbolsPySha');
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
    if (problems.isNotEmpty)
      invalid('the Dart symbols upload: ${problems.join('; ')}');
    say('Dart symbols uploaded (POST and PUT both 2xx)');

    if (ios) {
      // The native side: the dSYM of this build, with bugsee-cli (docs: /cli/xcode, /cli/debug-files).
      final cli = Platform.environment['BUGSEE_CLI'] ?? 'bugsee-cli';
      final dsyms = Directory('$example/build/ios')
          .listSync(recursive: true)
          .whereType<Directory>()
          .where((d) => d.path.endsWith('.dSYM'))
          .map((d) => d.path)
          .toList();
      say('dSYMs of the build: $dsyms');
      if (dsyms.isEmpty)
        invalid(
          'no .dSYM was produced by the release build: the native iOS frames cannot be symbolicated',
        );
      final dir = '$_workDir/dsyms';
      Directory(dir).createSync(recursive: true);
      for (final d in dsyms) {
        await sh(['cp', '-R', d, dir]);
      }
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
    final app = '$example/build/ios/iphoneos/Runner.app';
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
        final wantsExit = phase == 1 || phase == 2;
        final marker = wantsExit ? '"kind":"crashing"' : '"kind":"phase-done"';
        final ok = await c.waitFor(marker, timeout: const Duration(minutes: 5));
        if (!ok) {
          all.write(redact(c.output.toString(), _secrets));
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
            await c.stop();
            all.write(redact(c.output.toString(), _secrets));
            invalid(
              'phase $phase announced a crash and the process did not end within 90 s',
            );
          }
          say('phase $phase: the process ended (devicectl exit $code)');
        } else {
          await c.stop();
          // Stopping the console child makes devicectl terminate the app it launched, and not at once: the next
          // launch of the run was found killed by that SIGTERM 0.2 s after it started (run 7). Let it finish.
          await delay(10);
        }
        all.writeln(redact(c.output.toString(), _secrets));
      }
    } finally {
      File(consoleFile).writeAsStringSync(all.toString());
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
    if (state != 'device')
      invalid('$device is "$state" over adb, not "device"');
    final apk = '$example/build/app/outputs/flutter-apk/app-release.apk';
    await a(['uninstall', _androidPackage]);
    final inst = await a([
      'install',
      '-r',
      apk,
    ], timeout: const Duration(minutes: 5));
    if (!inst.ok || !inst.stdout.contains('Success'))
      invalid('install failed: ${inst.text}');
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
        if (!seen)
          invalid(
            'phase $phase never reached ${wantsExit ? 'its crash' : 'its end'}',
          );
        if (wantsExit) {
          final gone = await until<bool>(
            () async =>
                (await a(['shell', 'pidof', _androidPackage])).text.isEmpty
                ? true
                : null,
            timeout: const Duration(seconds: 90),
            every: const Duration(seconds: 2),
          );
          if (gone != true)
            invalid(
              'phase $phase announced a crash and the process is still alive after 90 s',
            );
          say('phase $phase: the process ended');
        }
      }
    } finally {
      File(consoleFile).writeAsStringSync(all.toString());
      await a(['shell', 'am', 'force-stop', _androidPackage]);
      await a(['uninstall', _androidPackage]);
    }
    _checkEvents('android');
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
    Future<Object?> get(String path) async {
      final req = await client.getUrl(Uri.parse('$base$path'));
      req.headers.set('x-auth-servertoken', serverToken);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw StateError(
          'GET $path -> ${res.statusCode} ${redact(body, _secrets)}',
        );
      }
      final v = jsonDecode(body);
      return v is Map && v.containsKey('result') ? v['result'] : v;
    }

    final end = DateTime.now().add(wait);
    List<Map<String, Object?>> mine = [];
    while (DateTime.now().isBefore(end)) {
      try {
        final r = await get('applications/$appId/issues?limit=100') as Map;
        final objs = (r['objects'] as List).cast<Map>();
        mine = [
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
        if (mine.length >= 3) break; // handled+uncaught are error issues, the crashes are issues too
      } on Object catch (e) {
        say('backend read: $e');
      }
      await delay(30);
    }
    final reports = <String>[];
    for (final issue in mine) {
      final id = issue['_id'];
      say('issue $id type=${issue['type']} summary="${issue['summary']}"');
      try {
        final recs = await get('applications/$appId/issues/$id/recordings');
        final list = (recs is Map ? recs['objects'] : recs) as List? ?? [];
        for (final rec in list.take(3)) {
          final rid = (rec as Map)['_id'];
          final text = await _text(
            client,
            '${base}applications/$appId/issues/$id/recordings/$rid/crash_report',
            serverToken,
          );
          reports.add(text);
          File('$_workDir/backend-$id-$rid.txt')
              .writeAsStringSync(redact(text, _secrets));
          final raw = rawFrameLines(text);
          say(
            '  recording $rid: ${text.split('\n').length} lines, ${raw.length} raw frame line(s)',
          );
          for (final l
              in text
                  .split('\n')
                  .where((l) => _expectedDart.any(l.contains))
                  .take(6)) {
            say('    $l');
          }
        }
      } on Object catch (e) {
        say('  recording read: $e');
      }
    }
    final problems = readbackProblems(
      reports,
      expectedDartNames: _expectedDart,
      expectedNativeNames: [ios ? 'AppDelegate' : 'MainActivity'],
    );
    if (problems.isNotEmpty) {
      say('NOT SYMBOLICATED (or not found): ${problems.join('; ')}');
      return 1;
    }
    say(
      'VERIFIED: the backend shows the readable names ${_expectedDart.join(', ')} and the native side',
    );
    return 0;
  }

  Future<String> _text(HttpClient c, String url, String serverToken) async {
    final req = await c.getUrl(Uri.parse(url));
    req.headers.set('x-auth-servertoken', serverToken);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200)
      throw StateError('GET crash_report -> ${res.statusCode}');
    return body;
  }
}
