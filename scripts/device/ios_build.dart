// Builds the verification app for the iOS simulator and records what the build contains: the Swift
// packages it resolved (the exact SDK revision, not a version string), the SDK framework inside the app.
//
// `flutter build ios --simulator` fails on Flutter 3.41 / Xcode 27.1 ("Flutter.framework/Flutter does not
// contain architectures arm64 x86_64": the generic simulator destination asks for both architectures, the
// check compares the strings in a different order than lipo prints them). The harness avoids the generic
// destination: `flutter build ios --config-only` writes the configuration (target, dart-defines, build
// name and number), then xcodebuild builds for ONE concrete simulator and ONE architecture, which is what
// `flutter run -d <simulator>` does.
//
// Release and profile are not buildable for a simulator by the Flutter tool ("Release mode is not
// supported for simulators"); [buildIosDeviceRelease] builds the device release for static inspection.
import 'dart:convert';
import 'dart:io';

import 'core/expectations.dart';
import 'shell.dart';
import 'toolchain.dart';

class IosBuild {
  IosBuild({
    required this.name,
    required this.mode,
    required this.app,
    required this.buildNumber,
    required this.resolved,
    required this.sdkFrameworkVersion,
  });
  final String name;
  final String mode;
  final String app;
  final int buildNumber;

  /// SwiftPM package identity -> `version@revision`, from the build's workspace-state.json.
  final Map<String, String> resolved;

  /// `CFBundleShortVersionString` of the SDK framework embedded in the app.
  final String? sdkFrameworkVersion;

  String get bundleId => 'com.bugsee.bugseeFlutterExample';

  List<String> artefactProblems(Pins pins) {
    final out = <String>[];
    final spm = resolved['spm'];
    if (spm == null) {
      out.add(
        'the SDK package (bugsee/spm) is not in the resolved packages: $resolved',
      );
    } else if (spm != '${pins.iosSdk}@${pins.iosSpmRevision}') {
      out.add(
        'bugsee/spm resolved to $spm, pinned ${pins.iosSdk}@${pins.iosSpmRevision}',
      );
    }
    final fb = resolved['feedback-spm'];
    if (fb != null && fb != '${pins.iosSdk}@${pins.iosFeedbackSpmRevision}') {
      out.add(
        'bugsee/feedback-spm resolved to $fb, pinned ${pins.iosSdk}@${pins.iosFeedbackSpmRevision}',
      );
    }
    if (sdkFrameworkVersion == null) out.add('no Bugsee.framework in the app');
    return out;
  }

  String describe() =>
      'build $name ($mode, build $buildNumber): packages $resolved, Bugsee.framework $sdkFrameworkVersion';
}

Future<IosBuild> buildIos(
  Toolchain tc, {
  required String name,
  required String udid,
  required int port,
  int buildNumber = 1,
  List<String> extraDefines = const [],
  void Function(String)? say,
}) async {
  final example = '${tc.repoRoot}/example';
  final dd = '${tc.workDir}/dd-ios';
  final config = await sh(
    [
      tc.flutter,
      'build',
      'ios',
      '--config-only',
      '--simulator',
      '--debug',
      '-t',
      'lib/verify_main.dart',
      '--build-number',
      '$buildNumber',
      '--build-name',
      '1.0.$buildNumber',
      '--dart-define=VERIFY_SERVER=localhost:$port',
      '--dart-define=BUGSEE_ENDPOINT=http://localhost:$port',
      for (final d in extraDefines) '--dart-define=$d',
    ],
    cwd: example,
    env: tc.buildEnv,
    timeout: const Duration(minutes: 10),
  );
  if (!config.ok) {
    throw StateError(
      'flutter build ios --config-only failed:\n${config.stdout}\n${config.stderr}',
    );
  }
  say?.call('xcodebuild $name for simulator $udid');
  final build = await sh(
    [
      'xcodebuild',
      '-workspace',
      'Runner.xcworkspace',
      '-scheme',
      'Runner',
      '-configuration',
      'Debug',
      '-destination',
      'platform=iOS Simulator,id=$udid',
      '-derivedDataPath',
      dd,
      'ARCHS=arm64',
      'ONLY_ACTIVE_ARCH=YES',
      'CODE_SIGNING_ALLOWED=NO',
      'CODE_SIGNING_REQUIRED=NO',
      'BUILD_DIR=$example/build/ios',
      'build',
    ],
    cwd: '$example/ios',
    env: tc.buildEnv,
    timeout: const Duration(minutes: 40),
  );
  if (!build.ok) {
    final lines = '${build.stdout}\n${build.stderr}'.split('\n');
    throw StateError(
      'xcodebuild failed:\n${lines.sublist(lines.length > 60 ? lines.length - 60 : 0).join('\n')}',
    );
  }
  Directory('${tc.workDir}/apps').createSync(recursive: true);
  final app = '${tc.workDir}/apps/$name.app';
  if (Directory(app).existsSync()) Directory(app).deleteSync(recursive: true);
  final cp = await sh([
    'cp',
    '-R',
    '$example/build/ios/Debug-iphonesimulator/Runner.app',
    app,
  ]);
  if (!cp.ok) throw StateError('copy failed: $cp');
  return inspectIos(
    tc,
    name: name,
    mode: 'debug',
    app: app,
    buildNumber: buildNumber,
    derivedData: dd,
  );
}

Future<IosBuild> inspectIos(
  Toolchain tc, {
  required String name,
  required String mode,
  required String app,
  required int buildNumber,
  required String derivedData,
}) async {
  final resolved = <String, String>{};
  final state = File('$derivedData/SourcePackages/workspace-state.json');
  if (state.existsSync()) {
    final json = jsonDecode(state.readAsStringSync()) as Map;
    for (final d in ((json['object'] as Map)['dependencies'] as List)) {
      final dep = d as Map;
      final id = (dep['packageRef'] as Map)['identity'] as String;
      final st = (dep['state'] as Map).cast<String, Object?>();
      final co = st['checkoutState'] as Map?;
      resolved[id] = co == null
          ? '${st['name']}:${st['path']}'
          : '${co['version'] ?? co['branch']}@${co['revision']}';
    }
  }
  final info = await sh([
    'plutil',
    '-extract',
    'CFBundleShortVersionString',
    'raw',
    '$app/Frameworks/Bugsee.framework/Info.plist',
  ]);
  return IosBuild(
    name: name,
    mode: mode,
    app: app,
    buildNumber: buildNumber,
    resolved: resolved,
    sdkFrameworkVersion: info.ok ? info.text : null,
  );
}
