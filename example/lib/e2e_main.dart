// The app `scripts/device/e2e_symbolication.dart` builds and drives against the REAL Bugsee backend
// (doc/verification.md, "End-to-end symbolication"). Not part of the plugin, not the example UI.
//
// It has no server and no commands. It keeps a phase counter in a file of the app's temp directory;
// every launch does the next phase and prints `E2E|<json>` lines (the harness reads them from the console):
//
//   phase 0  handled error, an uncaught Dart error, `logUnhandledException` (a crash report), then waits
//   phase 1  waits for the previous reports to upload, then dies of a native signal (FFI write to address 0)
//   phase 2  waits, then dies of the platform's own language (`java-main` / `objc-main`)
//   phase 3  waits for the recovered crash report to upload, nothing else
//
// The token comes from `--dart-define=BUGSEE_E2E_TOKEN` (an environment variable given to `devicectl process
// launch` did not reach the app, measured; Android has no per-launch environment). The build is local, installed
// for the run and uninstalled after it, and never leaves the harness' work directory. The token is never printed. The run id
// (`--dart-define=E2E_RUN`) is the build's unique string: it is in every message and an attribute.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'crash_lab.dart' as crash_lab;

const _run = String.fromEnvironment('E2E_RUN');
const _defineToken = String.fromEnvironment('BUGSEE_E2E_TOKEN');
const _endpoint = String.fromEnvironment('BUGSEE_ENDPOINT');
const _wait = int.fromEnvironment('E2E_WAIT_SECONDS', defaultValue: 40);

void _emit(String kind, [Map<String, Object?> data = const {}]) {
  final line = 'E2E|${jsonEncode({'kind': kind, 'run': _run, ...data})}';
  // Android: logcat shows `print`. iOS release: `print` is not on the devicectl console, stdout is.
  // ignore: avoid_print
  print(line);
  if (Platform.isIOS) stdout.writeln(line);
}

// The Dart sites whose NAMES must come back from the backend. Never inlined, so each is a frame of
// its own; obfuscation renames all of them, so a readable name in the backend is the symbolication.
@pragma('vm:never-inline')
Future<void> e2eHandledSite() async {
  try {
    throw FormatException('e2e-$_run handled');
  } catch (e, s) {
    await Bugsee.logException(e, s);
  }
}

@pragma('vm:never-inline')
Future<void> e2eUnhandledSite() async {
  await Bugsee.logUnhandledException(StateError('e2e-$_run unhandled'));
}

@pragma('vm:never-inline')
void e2eUncaughtSite() {
  unawaited(
    Future<void>.delayed(const Duration(milliseconds: 20))
        .then((_) => e2eUncaughtThrower()),
  );
}

@pragma('vm:never-inline')
void e2eUncaughtThrower() => throw StateError('e2e-$_run uncaught');

@pragma('vm:never-inline')
Future<void> e2eNativeCrashSite(String kind) => crash_lab.crash(kind);

int _readPhase(File f) {
  try {
    return int.parse(f.readAsStringSync().trim());
  } on Object {
    return 0;
  }
}

Future<void> _phases() async {
  final token = _defineToken;
  if (token.isEmpty || _run.isEmpty) {
    _emit('invalid', {'why': 'no token or no E2E_RUN'});
    return;
  }
  final state = File('${Directory.systemTemp.path}/e2e_phase');
  final phase = _readPhase(state);
  _emit('start', {
    'phase': phase,
    'mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
    'os': Platform.operatingSystem,
  });
  WidgetsFlutterBinding.ensureInitialized();
  Bugsee.installErrorHandlers(); // reportAsCrash false: the default
  // Empty = the SDK's default (production) endpoint.
  final launch = await Bugsee.launch(
    token,
    options: BugseeOptions(endpoint: _endpoint.isEmpty ? null : _endpoint),
  );
  // iOS answers `deferred` while the app is not active yet; the SDK then starts by itself. Capture has
  // started only once the status says so, so the phase runs after that and the event carries the outcome.
  var result = launch.name;
  if (launch == LaunchResult.deferred) {
    result = await Bugsee.waitUntilLaunched()
        ? 'launched'
        : 'deferred-never-launched';
  }
  _emit('launch', {'result': result, 'answer': launch.name});
  if (result != 'launched') {
    _emit('invalid', {
      'why': 'launch answered ${launch.name}, outcome $result',
    });
    return;
  }
  await Bugsee.setAttribute('e2e_run', _run);
  Future<void> pause(String why) async {
    _emit('waiting', {'why': why, 'seconds': _wait});
    await Future<void>.delayed(const Duration(seconds: _wait));
  }

  switch (phase) {
    case 0:
      await e2eHandledSite();
      e2eUncaughtSite();
      await Future<void>.delayed(const Duration(seconds: 1));
      await e2eUnhandledSite();
      _emit('reported', {'kinds': 'handled,uncaught,unhandled'});
      state.writeAsStringSync('1');
      await pause('upload of the error reports');
      _emit('phase-done', {'phase': 0});
    case 1:
      await pause('upload of the phase 0 reports');
      state.writeAsStringSync('2');
      _emit('crashing', {'crash': 'ffi-segv'});
      await e2eNativeCrashSite('ffi-segv');
    case 2:
      await pause('upload of the recovered ffi-segv report');
      state.writeAsStringSync('3');
      final kind = Platform.isIOS ? 'objc-main' : 'java-main';
      _emit('crashing', {'crash': kind});
      await e2eNativeCrashSite(kind);
    default:
      await pause('upload of the recovered platform crash report');
      _emit('phase-done', {'phase': phase});
  }
}

void main() {
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('e2e'))),
    ),
  );
  unawaited(_phases());
}
