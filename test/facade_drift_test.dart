// Drift guards for what the facade repeats across Dart, Java and Objective-C: the failure codes,
// the attribute limits, the breadcrumb level names, and the log level range. The native sides
// answer before Dart can look at them, so each copy is compared with its source.
import 'dart:io';

import 'package:bugsee_flutter/src/errors.dart';
import 'package:bugsee_flutter/src/facade/breadcrumb.dart';
import 'package:bugsee_flutter/src/facade/validation.dart';
import 'package:bugsee_flutter/src/options/bugsee_options.g.dart' show LogLevel;
import 'package:flutter_test/flutter_test.dart';

const java = 'android/src/main/java/com/bugsee/flutter';
const objc = 'ios/bugsee_flutter/Sources/bugsee_flutter_wrapper';

String read(String path) => File(path).readAsStringSync();

void main() {
  final javaOps = read('$java/FacadeOps.java');
  final objcOps = read('$objc/BGSFlutterFacadeOps.m');
  final objcHeader = read('$objc/include/BGSFlutterFacadeOps.h');
  final codes = {
    FacadeWire.invalidArgument: 'INVALID_ARGUMENT',
    FacadeWire.attributeRejected: 'ATTRIBUTE_REJECTED',
    FacadeWire.sdkError: 'SDK_ERROR',
    FacadeWire.notAttached: 'NOT_ATTACHED',
  };

  group('the failure codes are the same in Dart, Java and Objective-C', () {
    test('Java names every code with the same value, and no other', () {
      final found = {
        for (final m in RegExp(
          r'static final String (\w+) = "([^"]*)";',
        ).allMatches(javaOps))
          m.group(1)!: m.group(2)!,
      };
      expect(found, {for (final e in codes.entries) e.value: e.key});
    });

    test('Objective-C names every code with the same value, and no other', () {
      final found = {
        for (final m in RegExp(
          r'static NSString \*const k(\w+) = @"([^"]*)";',
        ).allMatches(objcOps))
          m.group(1)!: m.group(2)!,
      };
      expect(found, {
        'InvalidArgument': FacadeWire.invalidArgument,
        'AttributeRejected': FacadeWire.attributeRejected,
        'SdkError': FacadeWire.sdkError,
        'NotAttached': FacadeWire.notAttached,
      });
    });

    test('the Objective-C class properties return those strings', () {
      for (final name in [
        'invalidArgument',
        'attributeRejected',
        'sdkError',
        'notAttached',
      ]) {
        expect(
          objcHeader,
          contains('@property(class, readonly) NSString *$name;'),
        );
      }
      expect(
        objcOps,
        contains('+ (NSString *)invalidArgument { return kInvalidArgument; }'),
      );
      expect(
        objcOps,
        contains(
          '+ (NSString *)attributeRejected { return kAttributeRejected; }',
        ),
      );
      expect(objcOps, contains('+ (NSString *)sdkError { return kSdkError; }'));
      expect(
        objcOps,
        contains('+ (NSString *)notAttached { return kNotAttached; }'),
      );
    });

    test(
      'Dart maps every code natively raised, and the plugins raise only those',
      () {
        final plugin = read('$java/BugseeFlutterPlugin.java');
        expect(plugin, contains('FacadeOps.NOT_ATTACHED'));
        expect(plugin, contains('failure.code'));
        final swift = read(
          'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
        );
        expect(swift, contains('result.errorCode'));
      },
    );
  });

  group('the attribute limits are the same in Dart, Java and Objective-C', () {
    test(
      'the longest string (Android SDK: CUSTOM_ATTRIBUTE_MAX_LENGTH_LIMIT)',
      () {
        expect(attributeStringMaxLength, 1024);
        expect(
          RegExp(
            r'ATTRIBUTE_STRING_MAX_LENGTH = (\d+);',
          ).firstMatch(javaOps)!.group(1),
          '$attributeStringMaxLength',
        );
        expect(
          RegExp(
            r'kAttributeStringMaxLength = (\d+);',
          ).firstMatch(objcOps)!.group(1),
          '$attributeStringMaxLength',
        );
      },
    );

    test('the largest number: Float.MAX_VALUE, in all three', () {
      expect(attributeNumberLimit, 3.4028234663852886e38);
      expect(
        javaOps,
        contains('ATTRIBUTE_NUMBER_LIMIT = (double) Float.MAX_VALUE;'),
      );
      expect(
        RegExp(
          r'kAttributeNumberLimit = ([0-9.e+]+);',
        ).firstMatch(objcOps)!.group(1),
        '3.4028234663852886e38',
      );
    });

    test('a bundle number is below 2^63', () {
      expect(bundleNumberLimit, 9223372036854775808.0);
      expect(bundleNumberLimit, 9.223372036854775808e18);
    });
  });

  group('breadcrumb levels', () {
    test('Java maps exactly the Dart names', () {
      final cases = {
        for (final m in RegExp(r'case "(\w+)":').allMatches(javaOps))
          m.group(1)!,
      };
      expect(cases, BreadcrumbLevel.values.map((l) => l.name).toSet());
    });

    test('Objective-C maps exactly the Dart names (fatal shares error)', () {
      final names = {
        for (final m in RegExp(r'isEqualToString:@"(\w+)"\]').allMatches(
          objcOps.substring(
            objcOps.indexOf('+ (NSInteger)breadcrumbLevelForName'),
            objcOps.indexOf('+ (BGSFlutterFacadeResult *)addBreadcrumbWithSdk'),
          ),
        ))
          m.group(1)!,
      };
      expect(names, BreadcrumbLevel.values.map((l) => l.name).toSet());
    });

    test('the bridge carries the name, never an index', () {
      final runtime = read('lib/src/bugsee_runtime.dart');
      expect(runtime, contains('level: crumb.level.name'));
      expect(runtime, isNot(contains('crumb.level.index')));
    });
  });

  group('log levels', () {
    test(
      'Objective-C accepts the manifest range, Java defers to the SDK enum',
      () {
        final values = LogLevel.values.map((l) => l.value).toList()..sort();
        expect(values, [1, 2, 3, 4, 5]);
        expect(
          objcOps,
          contains('if (level < ${values.first} || level > ${values.last})'),
        );
        expect(javaOps, contains('LaunchOptionValues.logLevel('));
      },
    );
  });

  group('the facade methods are on the bridge, by name, in both natives', () {
    final methods = [
      'setAttribute',
      'getAttribute',
      'getAllAttributes',
      'clearAttribute',
      'clearAllAttributes',
      'setUserIdentifier',
      'getUserIdentifier',
      'trace',
      'event',
      'addBreadcrumb',
      'relayNotification',
      'log',
      'startBlackout',
      'endBlackout',
      'isBlackout',
      'showReportDialog',
      'upload',
    ];
    test('declared once in the definition', () {
      final def = read('pigeons/bridge.dart');
      for (final m in methods) {
        expect(
          RegExp('^  [A-Za-z<>?, ]+ $m\\(', multiLine: true).allMatches(def),
          hasLength(1),
          reason: m,
        );
      }
    });

    test('each reaches FacadeOps in Java and Swift', () {
      final plugin = read('$java/BugseeFlutterPlugin.java');
      final swift = read(
        'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
      );
      for (final m in methods) {
        expect(
          plugin,
          contains(RegExp('FacadeOps(::$m\\)|\\.$m\\()')),
          reason: 'java $m',
        );
        expect(swift, contains('BGSFlutterFacadeOps.$m('), reason: 'swift $m');
      }
    });
  });
}
