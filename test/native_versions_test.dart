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
    test('Android Gradle plugin is >= 4.0.7 (4.0.6 silently unregisters every extension)', () {
      final parts = (android['gradlePlugin'] as String).split('.').map(int.parse).toList();
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
      expect(RegExp(r'com\.bugsee:bugsee-android[a-z-]*:\d').hasMatch(gradle), isFalse,
          reason: 'a literal version here would not be covered by native-versions.json');
    });

    test('declares the NDK artefact next to the core (workbook 1.2.1)', () {
      expect(gradle, contains(r'api "com.bugsee:bugsee-android:${nativeVersions.android.sdk}"'));
      expect(gradle, contains(r'api "com.bugsee:bugsee-android-ndk:${nativeVersions.android.sdk}"'));
    });

    test('example applies the Gradle plugin at the pinned version', () {
      final settings = read('example/android/settings.gradle.kts');
      expect(settings,
          contains('id("com.bugsee.android.gradle") version "${android['gradlePlugin']}"'));
      expect(read('example/android/app/build.gradle.kts'), contains('id("com.bugsee.android.gradle")'));
    });
  });

  group('iOS', () {
    final manifest = read('ios/bugsee_flutter/Package.swift');

    test('pins the SPM package exactly', () {
      expect(manifest, contains('.package(url: "${ios['spmUrl']}", exact: "${ios['sdk']}")'));
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
      expect(Directory('ios').listSync().whereType<File>().where((f) => f.path.endsWith('.podspec')), isEmpty);
    });
  });

  group('CI', () {
    test('uses a supported JDK', () {
      final jdks = ((android['jdk'] as Map)['supported'] as List).cast<int>();
      final m = RegExp(r"java-version: '(\d+)'").firstMatch(read('.github/workflows/ci.yml'));
      expect(jdks, contains(int.parse(m!.group(1)!)));
    });

    test('tests the Flutter floor', () {
      expect(read('.github/workflows/ci.yml'), contains("flutter-version: '${flutterPin['min']}'"));
    });
  });
}
