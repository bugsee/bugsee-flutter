// Drift guard for every pinned native version (workbook 1.1, 1.2.2, 1.4.1).
//
// native-versions.json is the single source. Each other place that has to repeat
// a value is read here and compared to it. Change one copy and this file must
// fail; see the mutation notes in PLAN.md Phase 1.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

void main() {
  final pins = jsonDecode(read('native-versions.json')) as Map<String, dynamic>;
  final flutterPin = pins['flutter'] as Map<String, dynamic>;
  final android = pins['android'] as Map<String, dynamic>;
  final ios = pins['ios'] as Map<String, dynamic>;

  group('native-versions.json', () {
    test(
        'Android Gradle plugin is >= 4.0.7 (4.0.6 silently unregisters every extension)',
        () {
      final parts = (android['gradlePlugin'] as String)
          .split('.')
          .map(int.parse)
          .toList();
      final v = parts[0] * 1000000 + parts[1] * 1000 + parts[2];
      expect(v, greaterThanOrEqualTo(4 * 1000000 + 0 * 1000 + 7));
    });

    test('no SNAPSHOT pins', () {
      expect(jsonEncode(pins), isNot(contains('SNAPSHOT')));
    });
  });

  group('pubspec.yaml', () {
    final pubspec = read('pubspec.yaml');

    test('Dart floor matches', () {
      final dart = flutterPin['dart'] as String;
      final caret = '^${dart.split('.').take(2).join('.')}.0';
      expect(pubspec, contains('sdk: $caret'));
    });

    test('Flutter floor matches', () {
      expect(pubspec, contains('flutter: ">=${flutterPin['min']}"'));
    });
  });

  group('Android', () {
    final gradle = read('android/build.gradle');

    test('reads the pins instead of repeating them', () {
      expect(gradle, contains('native-versions.json'));
      expect(gradle, contains(r'bugsee-android:${nativeVersions.android.sdk}'));
      expect(gradle, contains('nativeVersions.android.minSdk'));
      expect(RegExp(r'com\.bugsee:bugsee-android[a-z-]*:\d').hasMatch(gradle),
          isFalse,
          reason:
              'a literal version here would not be covered by native-versions.json');
    });

    test('declares the NDK artefact next to the core (workbook 1.2.1)', () {
      expect(
          gradle,
          contains(
              r'api "com.bugsee:bugsee-android:${nativeVersions.android.sdk}"'));
      expect(
          gradle,
          contains(
              r'api "com.bugsee:bugsee-android-ndk:${nativeVersions.android.sdk}"'));
    });

    test('example applies the Gradle plugin at the pinned version', () {
      final settings = read('example/android/settings.gradle.kts');
      expect(
          settings,
          contains(
              'id("com.bugsee.android.gradle") version "${android['gradlePlugin']}"'));
      expect(read('example/android/app/build.gradle.kts'),
          contains('id("com.bugsee.android.gradle")'));
    });
  });

  group('iOS', () {
    final manifest = read('ios/bugsee_flutter/Package.swift');

    test('pins the SPM package exactly', () {
      expect(
          manifest,
          contains(
              '.package(url: "${ios['spmUrl']}", exact: "${ios['sdk']}")'));
    });

    test('deployment target matches', () {
      expect(manifest, contains('.iOS("${ios['deploymentTarget']}")'));
      final pbx = read('example/ios/Runner.xcodeproj/project.pbxproj');
      final targets = RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);')
          .allMatches(pbx)
          .map((m) => m.group(1))
          .toSet();
      expect(targets, {ios['deploymentTarget']});
    });

    test('has no podspec: Bugsee publishes no pod, so one could not build', () {
      expect(
          Directory('ios')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.podspec')),
          isEmpty);
    });
  });

  group('CI', () {
    final ci = read('.github/workflows/ci.yml');
    // Live (uncommented) lines only.
    final live =
        ci.split('\n').where((l) => !l.trimLeft().startsWith('#')).join('\n');

    test('uses a supported JDK on a live line', () {
      final jdks = ((android['jdk'] as Map)['supported'] as List).cast<int>();
      final all =
          RegExp(r"""^\s*java-version: ['"](\d+)['"]""", multiLine: true)
              .allMatches(live)
              .toList();
      final setups =
          RegExp(r'uses: actions/setup-java@').allMatches(live).length;
      expect(all, isNotEmpty, reason: 'no live java-version line in ci.yml');
      expect(all.length, setups,
          reason: 'every setup-java step needs a live java-version');
      for (final m in all) {
        expect(jdks, contains(int.parse(m.group(1)!)));
      }
    });

    test(
        'enables SwiftPM before pub get in the same job (the plugin has no podspec)',
        () {
      final enable = RegExp(
          r'^\s*- run: flutter config --enable-swift-package-manager\s*$\n(?:.*\n)*?\s*- run: flutter pub get\s*$',
          multiLine: true);
      // Every job that runs pub get must enable SwiftPM first.
      for (final job in live
          .split(RegExp(r'^  (?=[a-z-]+:\s*$)', multiLine: true))
          .where((j) => j.contains('flutter pub get'))) {
        expect(enable.hasMatch(job), isTrue,
            reason:
                'job lacks a live SwiftPM enable step before pub get:\n$job');
      }
      expect(enable.hasMatch(live), isTrue);
    });

    test('tests the Flutter floor via the matrix', () {
      expect(
          RegExp("^\\s*flutter-version: '${RegExp.escape(flutterPin['min'] as String)}'\\s*\$",
                  multiLine: true)
              .hasMatch(live),
          isTrue,
          reason: 'no live floor flutter-version in ci.yml');
      expect(live, contains(r'flutter-version: ${{ matrix.flutter-version }}'));
    });

    test('runs on macOS and builds iOS and Android', () {
      expect(live, contains('runs-on: macos-latest'));
      expect(live, contains('flutter build ios --debug --no-codesign'));
      expect(live, contains('flutter build apk --debug'));
    });

    test('claude-review.yml calls the shared workflow', () {
      final review = read('.github/workflows/claude-review.yml');
      expect(
          review,
          contains(
              'uses: bugsee/.github/.github/workflows/claude-review.yml@main'));
    });
  });
}
