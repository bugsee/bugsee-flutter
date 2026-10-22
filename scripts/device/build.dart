// Builds the verification app (example/lib/verify_main.dart) and records what the build contains: the
// artefact set (workbook 1.2, 1.4: the NDK artefact, the Gradle plugin >= 4.0.7), the libraries in the
// APK, the merged manifest's providers. The record travels with the build into every scenario's launch
// guard, so no scenario can run on an APK nobody looked inside.
import 'dart:io';
import 'dart:typed_data';

import 'core/expectations.dart';
import 'core/log_parsers.dart';
import 'core/zip.dart';
import 'shell.dart';
import 'toolchain.dart';

class AndroidBuild {
  AndroidBuild({
    required this.name,
    required this.mode,
    required this.apk,
    required this.buildNumber,
    required this.obfuscated,
    this.symbolsDir,
    this.mappingFile,
    required this.entries,
    required this.apkBytes,
    required this.manifestXml,
    required this.gradleDependencies,
    required this.gradlePluginVersions,
    required this.buildUuid,
  });

  final String name;
  final String mode;
  final String apk;
  final int buildNumber;
  final bool obfuscated;
  final String? symbolsDir;
  final String? mappingFile;
  final List<ZipEntry> entries;
  final Uint8List apkBytes;
  final String manifestXml;

  /// `./gradlew :app:dependencies`: artefact to resolved versions.
  final Map<String, Set<String>> gradleDependencies;

  /// The Bugsee Gradle plugin versions present in the (private) Gradle home the build resolved from.
  final Set<String> gradlePluginVersions;

  /// `assets/bugsee_build_id.properties`: the id the Gradle plugin stamped, which a report must echo.
  final String? buildUuid;

  /// What is wrong with the artefact set (empty = the build under test is the one the pins describe).
  List<String> artefactProblems(Pins pins, String abi) {
    final out = <String>[];
    for (final artefact in ['bugsee-android', 'bugsee-android-ndk']) {
      final v = gradleDependencies[artefact];
      if (v == null) {
        out.add(
          '$artefact is not in the dependency graph (workbook 1.2: no native crash would be reported)',
        );
      } else if (v.length != 1 || v.single != pins.androidSdk) {
        out.add('$artefact resolved to $v, pinned ${pins.androidSdk}');
      }
    }
    if (gradlePluginVersions.length != 1 ||
        gradlePluginVersions.single != pins.gradlePlugin) {
      out.add(
        'Gradle plugin versions in use $gradlePluginVersions, pinned ${pins.gradlePlugin}',
      );
    }
    final libs = apkBugseeLibs(entries, abi);
    const wanted = {
      'libbugsee-crashcp.so',
      'libbugsee-crashpad-handler.so',
      'libbugsee-crashpad-trampoline.so',
      'libbugsee-native.so',
    };
    if (!libs.containsAll(wanted)) {
      out.add('APK ($abi) carries $libs, expected $wanted');
    }
    final providers = parseProviders(manifestXml);
    final wrapper = providers.where(
      (p) => p.name == 'com.bugsee.flutter.FlutterWrapperInitProvider',
    );
    if (wrapper.isEmpty) {
      out.add(
        'the wrapper provider is not in the merged manifest (it was stripped)',
      );
    } else if (wrapper.first.initOrder != 200) {
      out.add(
        'the wrapper provider has initOrder ${wrapper.first.initOrder}, expected 200',
      );
    }
    final sdk = providers.where(
      (p) => p.name == 'com.bugsee.library.BugseeInitProvider',
    );
    if (sdk.isEmpty) {
      out.add('the SDK provider is not in the merged manifest');
    } else if ((sdk.first.initOrder ?? 0) >= 200) {
      out.add(
        'the SDK provider (initOrder ${sdk.first.initOrder}) does not start after the wrapper (200)',
      );
    }
    return out;
  }

  String describe(String abi) {
    final libs = apkBugseeLibs(entries, abi).toList()..sort();
    return 'build $name ($mode, versionCode $buildNumber${obfuscated ? ', obfuscated' : ''}): '
        'deps ${gradleDependencies.map((k, v) => MapEntry(k, v.join('/')))}, '
        'gradle plugin $gradlePluginVersions, libs $libs, build id $buildUuid';
  }
}

/// Builds one APK variant and inspects it.
Future<AndroidBuild> buildAndroid(
  Toolchain tc, {
  required String name,
  required String mode,
  required int port,
  int buildNumber = 1,
  bool obfuscate = false,
  List<String> extraDefines = const [],
  String abi = 'arm64-v8a',
  void Function(String)? say,
}) async {
  final example = '${tc.repoRoot}/example';
  final symbols = obfuscate ? '${tc.workDir}/symbols/$name' : null;
  if (symbols != null) Directory(symbols).createSync(recursive: true);
  final platform = abi == 'arm64-v8a' ? 'android-arm64' : 'android-x64';
  final args = [
    tc.flutter,
    'build',
    'apk',
    '--$mode',
    '--target-platform',
    platform,
    '-t',
    'lib/verify_main.dart',
    '--build-number',
    '$buildNumber',
    '--build-name',
    '1.0.$buildNumber',
    '--dart-define=VERIFY_SERVER=10.0.2.2:$port',
    '--dart-define=BUGSEE_ENDPOINT=http://10.0.2.2:$port',
    for (final d in extraDefines) '--dart-define=$d',
    if (obfuscate) ...['--obfuscate', '--split-debug-info=$symbols'],
  ];
  say?.call('building $name: ${args.skip(1).join(' ')}');
  final r = await sh(
    args,
    cwd: example,
    env: tc.buildEnv,
    timeout: const Duration(minutes: 40),
  );
  if (!r.ok) {
    throw StateError(
      'flutter build failed for $name:\n${r.stdout}\n${r.stderr}'
          .split("\n")
          .takeLast(60),
    );
  }
  final built = '$example/build/app/outputs/flutter-apk/app-$mode.apk';
  Directory('${tc.workDir}/apks').createSync(recursive: true);
  final apk = '${tc.workDir}/apks/$name.apk';
  File(built).copySync(apk);
  String? mapping;
  final mappingSrc = File(
    '$example/build/app/outputs/mapping/$mode/mapping.txt',
  );
  if (mappingSrc.existsSync()) {
    mapping = '${tc.workDir}/apks/$name.mapping.txt';
    mappingSrc.copySync(mapping);
  }
  return inspectAndroid(
    tc,
    name: name,
    mode: mode,
    apk: apk,
    buildNumber: buildNumber,
    obfuscated: obfuscate,
    symbolsDir: symbols,
    mapping: mapping,
  );
}

Future<AndroidBuild> inspectAndroid(
  Toolchain tc, {
  required String name,
  required String mode,
  required String apk,
  required int buildNumber,
  required bool obfuscated,
  String? symbolsDir,
  String? mapping,
}) async {
  final bytes = File(apk).readAsBytesSync();
  final entries = zipEntries(bytes);
  final manifest = await sh([
    tc.apkanalyzer,
    'manifest',
    'print',
    apk,
  ], env: tc.buildEnv);
  final deps = await sh(
    [
      './gradlew',
      '-q',
      '-Dorg.gradle.daemon=false',
      ':app:dependencies',
      '--configuration',
      '${mode}RuntimeClasspath',
    ],
    cwd: '${tc.repoRoot}/example/android',
    env: tc.buildEnv,
    timeout: const Duration(minutes: 10),
  );
  final plugin = <String>{};
  final cache = Directory(
    '${tc.gradleHome}/caches/modules-2/files-2.1/com.bugsee/bugsee-android-gradle-plugin',
  );
  if (cache.existsSync()) {
    for (final d in cache.listSync().whereType<Directory>()) {
      plugin.add(d.uri.pathSegments.where((s) => s.isNotEmpty).last);
    }
  }
  final idEntry = entries.where(
    (e) => e.name == 'assets/bugsee_build_id.properties',
  );
  String? uuid;
  if (idEntry.isNotEmpty) {
    uuid = RegExp(
      r'bugsee\.build_id=(\S+)',
    ).firstMatch(String.fromCharCodes(zipRead(bytes, idEntry.first)))?.group(1);
  }
  return AndroidBuild(
    name: name,
    mode: mode,
    apk: apk,
    buildNumber: buildNumber,
    obfuscated: obfuscated,
    symbolsDir: symbolsDir,
    mappingFile: mapping,
    entries: entries,
    apkBytes: bytes,
    manifestXml: manifest.stdout,
    gradleDependencies: parseGradleBugseeArtefacts(deps.stdout),
    gradlePluginVersions: plugin,
    buildUuid: uuid,
  );
}

extension _TakeLast on List<String> {
  String takeLast(int n) => sublist(length > n ? length - n : 0).join('\n');
}
