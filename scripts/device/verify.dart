// The device verification harness (PLAN.md Phase 7, workbook Part 9). Not run in CI: it needs an
// emulator or simulator and builds the app. Its parsers and guards (core/) are unit-tested in
// test/device_harness_test.dart.
//
//   dart scripts/device/verify.dart build android [--only releaseA,debug]
//   dart scripts/device/verify.dart android --serial emulator-5584 [--scenarios 1,2,3|all]
//   dart scripts/device/verify.dart ios --udid <simulator> [--scenarios 1,2,3|all]
//
// Options: --work DIR (default build/device-verify), --port N (default 8731; the apps are built with it),
// --reuse (use the APKs/apps already in the work dir instead of building).
import 'dart:io';

import 'android_scenarios.dart';
import 'build.dart';
import 'builds.dart';
import 'ios_build.dart';
import 'ios_scenarios.dart';
import 'toolchain.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: verify.dart build|android|ios ...  (see the header of this file)',
    );
    exit(64);
  }
  String? opt(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final root = Directory.current.path;
  if (!File('$root/native-versions.json').existsSync()) {
    stderr.writeln(
      'run from the repository root (native-versions.json not found)',
    );
    exit(64);
  }
  final work = opt('--work') ?? '$root/build/device-verify';
  Directory(work).createSync(recursive: true);
  final isIos = (args.first == 'build' ? args[1] : args.first) == 'ios';
  // One port per platform, so both can run at once against their own mock API.
  final port = int.parse(opt('--port') ?? (isIos ? '8732' : '8731'));
  final tc = Toolchain.detect(root, work);
  final platform = args.first == 'build' ? args[1] : args.first;
  final scenarios = (opt('--scenarios') ?? 'all');
  final wanted = scenarios == 'all'
      ? null
      : scenarios.split(',').map(int.parse).toSet();

  if (args.first == 'build' && isIos) {
    final udid = opt('--udid') ?? '';
    if (udid.isEmpty) {
      stderr.writeln('--udid <simulator> is required');
      exit(64);
    }
    final only = opt('--only')?.split(',');
    for (final spec in iosBuildSpecs) {
      if (only != null && !only.contains(spec.name)) continue;
      final b = await buildIos(
        tc,
        name: spec.name,
        udid: udid,
        port: port,
        buildNumber: spec.buildNumber,
        extraDefines: spec.defines,
        say: stdout.writeln,
      );
      stdout.writeln(b.describe());
    }
    return;
  }
  if (args.first == 'build') {
    final only = opt('--only')?.split(',');
    for (final spec in androidBuildSpecs) {
      if (only != null && !only.contains(spec.name)) continue;
      final b = await buildAndroid(
        tc,
        name: spec.name,
        mode: spec.mode,
        port: port,
        buildNumber: spec.buildNumber,
        obfuscate: spec.obfuscate,
        extraDefines: spec.defines,
        say: stdout.writeln,
      );
      stdout.writeln(b.describe('arm64-v8a'));
    }
    return;
  }
  if (platform == 'android') {
    exit(
      await runAndroid(
        tc,
        serial: opt('--serial') ?? '',
        port: port,
        wanted: wanted,
        reuse: args.contains('--reuse'),
      ),
    );
  }
  if (platform == 'ios') {
    exit(
      await runIos(
        tc,
        udid: opt('--udid') ?? '',
        port: port,
        wanted: wanted,
        reuse: args.contains('--reuse'),
      ),
    );
  }
  stderr.writeln('unknown command $platform');
  exit(64);
}
