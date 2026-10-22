// The toolchain a run used, found and recorded: Flutter, Dart, JDK, Android SDK, Xcode. The report
// prints it (doc/verification.md quotes it) because a result is only reproducible with it.
import 'dart:convert';
import 'dart:io';

import 'core/expectations.dart';
import 'shell.dart';

class Toolchain {
  Toolchain({
    required this.repoRoot,
    required this.workDir,
    required this.flutter,
    required this.javaHome,
    required this.gradleHome,
    required this.androidHome,
  });

  final String repoRoot;
  final String workDir;
  final String flutter;
  final String? javaHome;
  final String gradleHome;
  final String androidHome;

  static Toolchain detect(String repoRoot, String workDir) {
    final env = Platform.environment;
    final home = env['HOME'] ?? '';
    final fvm = '$home/fvm/versions/3.41.0/bin/flutter';
    final flutter =
        env['VERIFY_FLUTTER'] ?? (File(fvm).existsSync() ? fvm : 'flutter');
    final androidHome =
        env['ANDROID_HOME'] ??
        env['ANDROID_SDK_ROOT'] ??
        '$home/Library/Android/sdk';
    // Gradle 8.14 (the Flutter template's) cannot read JDK 25: 17 or 21 only (native-versions.json).
    var java = env['VERIFY_JAVA_HOME'] ?? env['JAVA_HOME'];
    if (java == null || !_javaOk(java)) {
      final r = Process.runSync('/usr/libexec/java_home', ['-v', '21']);
      if (r.exitCode == 0) java = (r.stdout as String).trim();
    }
    return Toolchain(
      repoRoot: repoRoot,
      workDir: workDir,
      flutter: flutter,
      javaHome: java,
      gradleHome: env['VERIFY_GRADLE_HOME'] ?? '$workDir/gradle-home',
      androidHome: androidHome,
    );
  }

  static bool _javaOk(String home) {
    final release = File('$home/release');
    if (!release.existsSync()) return false;
    final m = RegExp(
      r'JAVA_VERSION="(\d+)',
    ).firstMatch(release.readAsStringSync());
    final major = int.tryParse(m?.group(1) ?? '');
    return major == 17 || major == 21;
  }

  /// The environment Gradle-backed builds run in: JDK 17/21, a private Gradle home, no daemon.
  Map<String, String> get buildEnv => {
    ...Platform.environment,
    if (javaHome != null) 'JAVA_HOME': javaHome!,
    if (javaHome != null)
      'GRADLE_OPTS':
          '-Dorg.gradle.java.home=$javaHome -Dorg.gradle.daemon=false',
    'GRADLE_USER_HOME': gradleHome,
    'ANDROID_HOME': androidHome,
    'PATH':
        '${File(flutter).parent.path}:$androidHome/platform-tools:$androidHome/cmdline-tools/latest/bin:'
        '${Platform.environment['PATH']}',
  };

  /// The `dart` next to the Flutter executable (its own `bin/`), or plain `dart` when [flutter] is a bare
  /// command name. Never derived by editing the path text (a checkout may live in a directory named flutter).
  String get dartExecutable =>
      flutter.contains('/') ? '${File(flutter).parent.path}/dart' : 'dart';

  String get adbPath => '$androidHome/platform-tools/adb';

  String get apkanalyzer {
    final tools = Directory('$androidHome/cmdline-tools');
    if (tools.existsSync()) {
      final dirs = tools.listSync().whereType<Directory>().toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final d in dirs) {
        final f = File('${d.path}/bin/apkanalyzer');
        if (f.existsSync()) return f.path;
      }
    }
    return 'apkanalyzer';
  }

  /// `flutter --version --machine`, plus what the report needs.
  Future<Map<String, String>> describe() async {
    final fv = await sh([flutter, '--version', '--machine'], env: buildEnv);
    final m = (jsonDecode(fv.stdout.substring(fv.stdout.indexOf('{'))) as Map)
        .cast<String, Object?>();
    final java = javaHome == null
        ? 'none'
        : (await sh([
            '$javaHome/bin/java',
            '-version',
          ])).stderr.split('\n').first;
    final xcode = Platform.isMacOS
        ? (await sh(['xcodebuild', '-version'])).text.replaceAll('\n', ' ')
        : 'n/a';
    return {
      'flutter': '${m['frameworkVersion']}',
      'flutterChannel': '${m['channel']}',
      'dart': '${m['dartSdkVersion']}'.split(' ').first,
      'engine': '${m['engineRevision']}',
      'java': java,
      'javaHome': '$javaHome',
      'xcode': xcode,
      'host': (await sh(['uname', '-a'])).text,
    };
  }

  /// The expectation for a build in [mode].
  Future<BuildExpectation> expectation(String mode) async {
    final d = await describe();
    final pubspec = File('$repoRoot/pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1)!;
    return BuildExpectation(
      pins: Pins.read(repoRoot),
      wrapperVersion: version,
      flutterVersion: d['flutter']!,
      dartVersion: d['dart']!,
      engineRevision: d['engine']!.substring(0, 10),
      mode: mode,
    );
  }
}
