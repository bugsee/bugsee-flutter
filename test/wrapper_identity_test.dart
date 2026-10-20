// Identity drift guard (workbook 2.4.3, 3.x): the wrapper type and version are
// repeated in Dart, Android and iOS because the native side registers before
// Dart exists. Every copy must agree, or two different wrappers register
// depending on how far start-up got.
import 'dart:io';

import 'package:bugsee_flutter/src/wrapper_identity.dart' as dart;
import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

String pubspecVersion() => RegExp(
  r'^version:\s*(\S+)\s*$',
  multiLine: true,
).firstMatch(read('pubspec.yaml'))!.group(1)!;

void main() {
  group('wrapper type', () {
    test('Dart constant is the backend identifier', () {
      // worker/typedefs/common.py BugseeFrameworkType.FLUTTER = "flutter";
      // the 9.x plugin sent the same string.
      expect(dart.wrapperType, 'flutter');
    });

    test('Android copy matches Dart', () {
      final java = read(
        'android/src/main/java/com/bugsee/flutter/FlutterWrapper.java',
      );
      final m = RegExp(
        r'static final String WRAPPER_TYPE = "([^"]*)";',
      ).firstMatch(java);
      expect(m, isNotNull, reason: 'WRAPPER_TYPE constant not found');
      expect(m!.group(1), dart.wrapperType);
    });

    test('iOS copy matches Dart', () {
      final swift = read(
        'ios/bugsee_flutter/Sources/bugsee_flutter/WrapperIdentity.swift',
      );
      final m = RegExp(r'static let type = "([^"]*)"').firstMatch(swift);
      expect(m, isNotNull, reason: 'WrapperIdentity.type not found');
      expect(m!.group(1), dart.wrapperType);
    });

    test('native code has no other spelling of the type', () {
      // The type literal lives only in the constants above.
      for (final f in [
        'android/src/main/java/com/bugsee/flutter/FlutterWrapperInitProvider.java',
        'ios/bugsee_flutter/Sources/bugsee_flutter/FlutterWrapper.swift',
        'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
      ]) {
        expect(
          read(f),
          isNot(contains('"flutter"')),
          reason: '$f repeats the type literal',
        );
      }
    });
  });

  group('wrapper version', () {
    test('Dart constant equals pubspec.yaml', () {
      expect(dart.wrapperVersion, pubspecVersion());
    });

    test('iOS constant equals pubspec.yaml', () {
      final swift = read(
        'ios/bugsee_flutter/Sources/bugsee_flutter/WrapperIdentity.swift',
      );
      final m = RegExp(r'static let version = "([^"]*)"').firstMatch(swift);
      expect(m, isNotNull, reason: 'WrapperIdentity.version not found');
      expect(m!.group(1), pubspecVersion());
    });

    test('Gradle reads pubspec.yaml and the regex it uses agrees', () {
      final gradle = read('android/build.gradle');
      expect(gradle, contains('"pubspec.yaml"'));
      expect(
        gradle,
        contains(
          r'buildConfigField "String", "WRAPPER_VERSION", "\"${wrapperVersion}\""',
        ),
      );
      expect(gradle, contains('buildConfig = true'));
      // Run the very regex literal Gradle uses (Groovy `/.../`, same syntax as
      // Dart's for this pattern) against pubspec.yaml.
      final lit = RegExp(
        r'wrapperVersionMatch = \(pubspecFile\.getText\("UTF-8"\) =~ /(.+)/\)',
      ).firstMatch(gradle);
      expect(lit, isNotNull, reason: 'Gradle version regex not found');
      final pattern = lit!.group(1)!.replaceFirst('(?m)', '');
      final m = RegExp(
        pattern,
        multiLine: true,
      ).firstMatch(read('pubspec.yaml'));
      expect(m, isNotNull);
      expect(m!.group(1), dart.wrapperVersion);
    });
    // The compiled BuildConfig value is asserted by the JUnit test
    // FlutterWrapperTest.buildConfigVersionMatchesPubspec.
  });
}
