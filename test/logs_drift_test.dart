// What log capture repeats across Dart, Java and Objective-C, compared with one fixture
// (`test/fixtures/log_wire.json`), the option keys it reads (against the SDKs' vendored manifests),
// and the rules the source attribution depends on. The native sides answer before Dart can look at
// them, so each copy is checked against its source, and the fixture against the real SDK enums by the
// JUnit/XCTest suites.
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter/src/logs/log_capture.dart';
import 'package:bugsee_flutter/src/logs/log_pipeline.dart';
import 'package:bugsee_flutter/src/logs/log_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const java = 'android/src/main/java/com/bugsee/flutter';
const objc = 'ios/bugsee_flutter/Sources/bugsee_flutter_wrapper';

String read(String path) => File(path).readAsStringSync();

void main() {
  final fixture =
      jsonDecode(read('test/fixtures/log_wire.json')) as Map<String, dynamic>;
  final javaOps = read('$java/LogOps.java');
  final javaSdk = read('$java/BugseeLogSdk.java');
  final objcOps = read('$objc/BGSFlutterLogOps.m');
  final objcHeader = read('$objc/include/BGSFlutterLogOps.h');

  group('the numbers', () {
    test('Dart\'s level values are the fixture\'s, which are the SDKs\'', () {
      expect({
        for (final l in LogLevel.values) l.name: l.value,
      }, fixture['levels']);
      expect(LogWire.minLevel, fixture['minLevel']);
      expect(LogWire.maxLevel, fixture['maxLevel']);
      expect(
        LogLevel.values.map((l) => l.value).reduce((a, b) => a < b ? a : b),
        LogWire.minLevel,
      );
      expect(
        LogLevel.values.map((l) => l.value).reduce((a, b) => a > b ? a : b),
        LogWire.maxLevel,
      );
    });

    test('the source is Custom, 98, in Dart, Java and Objective-C', () {
      expect(LogWire.source, fixture['source']);
      expect(
        javaOps,
        contains('WRAPPER_SOURCE = LogSource.${fixture['androidSourceEnum']};'),
      );
      expect(objcOps, contains('return ${fixture['iosSourceConstant']};'));
      expect(objcOps, contains('source:${fixture['iosSourceConstant']}]'));
      expect(javaSdk, contains('LogOps.WRAPPER_SOURCE'));
    });

    test(
      'the level range native accepts is the same in Java and Objective-C',
      () {
        expect(
          RegExp(r'MIN_LEVEL = (\d+);').firstMatch(javaOps)!.group(1),
          '${fixture['minLevel']}',
        );
        expect(
          RegExp(r'MAX_LEVEL = (\d+);').firstMatch(javaOps)!.group(1),
          '${fixture['maxLevel']}',
        );
        expect(
          RegExp(r'kMinLevel = (\d+);').firstMatch(objcOps)!.group(1),
          '${fixture['minLevel']}',
        );
        expect(
          RegExp(r'kMaxLevel = (\d+);').firstMatch(objcOps)!.group(1),
          '${fixture['maxLevel']}',
        );
        expect(objcHeader, contains('minLevel'));
        expect(objcHeader, contains('wrapperSource'));
      },
    );

    test('the line cap is the fixture\'s', () {
      expect(LogWire.maxLineLength, fixture['maxLineLength']);
    });

    test(
      'the filter timeout is the SDK\'s 10 seconds in the constant and in the public signature',
      () {
        expect(
          LogWire.defaultFilterTimeout,
          Duration(seconds: fixture['filterTimeoutSeconds'] as int),
        );
        expect(
          read('lib/src/bugsee.dart'),
          contains(
            'Duration timeout = const Duration(seconds: ${fixture['filterTimeoutSeconds']}),',
          ),
        );
        expect(LogWire.maxFilterTimeout, const Duration(minutes: 5));
      },
    );
  });

  group('the source attribution', () {
    test('no native file of the log path can claim the app\'s own source', () {
      // `Bugsee` (4) is the app's deliberate Bugsee.log: claiming it would misattribute host output
      // AND skip the app's log filter on Android's default rule. The SDKs record any reserved value
      // as Custom anyway, but the wrapper never relies on that coercion.
      for (final source in [javaOps, javaSdk]) {
        expect(source, isNot(contains('LogSource.Bugsee')));
        expect(source, isNot(contains('LogSource.Internal')));
        expect(source, isNot(contains('LogSource.LogCat')));
      }
      expect(objcOps, isNot(contains('BGSLogEventSourceBugsee')));
      expect(objcOps, isNot(contains('BGSLogEventSourceInternal')));
      expect(objcOps, isNot(contains('BGSLogEventSourceOSLog')));
    });

    test('the log path never reaches the app-level log API', () {
      // `Bugsee.log` / `+[Bugsee log:...]` / `BugseeInternal.log` record as `Bugsee` and can skip the
      // filter; the channel is the only route.
      expect(javaSdk, isNot(contains('Bugsee.log(')));
      expect(javaSdk, contains('channel.log('));
      expect(objcOps, isNot(contains('[Bugsee log:')));
      expect(objcOps, contains('logWithTag:tag message:message level:'));
    });

    test(
      'the source is not a field of the wire message (a constant of native)',
      () {
        final bridge = read('pigeons/bridge.dart');
        final cls = RegExp(
          r'class LogLineMessage \{(.*?)\n\}',
          dotAll: true,
        ).firstMatch(bridge)!.group(1)!;
        expect(
          RegExp(
            r'^\s*(?:String\??|int) (\w+);',
            multiLine: true,
          ).allMatches(cls).map((m) => m.group(1)).toList(),
          ['message', 'level', 'tag'],
        );
      },
    );

    test('Dart tags are the two routes and nothing the SDK reserves', () {
      expect(LogTags.print, 'print');
      expect(LogTags.debugPrint, 'debugPrint');
    });
  });

  group(
    'the option keys the policy reads exist in both SDKs, with these types and defaults',
    () {
      Map<String, Map<String, dynamic>> manifest(String sdk) {
        final data =
            jsonDecode(read('test/fixtures/option_manifests/$sdk.json'))
                as Map<String, dynamic>;
        return {
          for (final o
              in (data['options'] as List).cast<Map<String, dynamic>>())
            o['key'] as String: o,
        };
      }

      test('the keys are the fixture\'s', () {
        expect(LogOptionKeys.capture, (fixture['options'] as Map)['capture']);
        expect(LogOptionKeys.level, (fixture['options'] as Map)['level']);
      });

      for (final sdk in ['android', 'ios']) {
        test(sdk, () {
          final options = manifest(sdk);
          expect(
            options[LogOptionKeys.capture],
            allOf(
              containsPair('type', 'boolean'),
              containsPair('default', true),
            ),
          );
          final level = options[LogOptionKeys.level]!;
          expect(level, containsPair('type', 'enum'));
          expect(level, containsPair('default', 'Verbose'));
          final values = (level['enum'] as Map)['values'] as Map;
          // The same numbers on both SDKs (the breadcrumb levels are not).
          expect({
            for (final e in values.entries)
              (e.key as String).toLowerCase(): e.value,
          }, fixture['levels']);
        });
      }

      test(
        'the default level is the most verbose, so nothing is cut by default',
        () {
          expect(const LogPolicy().maxLevel, LogLevel.verbose);
        },
      );
    },
  );

  group('no blocking on the platform thread beyond what the SDK does', () {
    test('the injection files do not wait, sleep or take a lock', () {
      for (final source in [javaOps, javaSdk]) {
        for (final banned in [
          'synchronized',
          '.wait(',
          'Thread.sleep',
          '.await(',
          'CountDownLatch',
          'Semaphore',
          'join(',
        ]) {
          expect(source, isNot(contains(banned)), reason: banned);
        }
      }
      for (final banned in [
        '@synchronized',
        'dispatch_sync',
        'dispatch_semaphore',
        'sleep(',
        'usleep',
      ]) {
        expect(objcOps, isNot(contains(banned)), reason: banned);
      }
    });

    test(
      'the bridge call runs on a background thread, never the platform thread',
      () {
        expect(
          read('pigeons/bridge.dart'),
          contains(
            '@TaskQueue(type: TaskQueueType.serialBackgroundThread)\n  int addLogLines(',
          ),
        );
      },
    );

    test('the plugin entry points delegate to the shared channel holder', () {
      expect(
        read('$java/BugseeFlutterPlugin.java'),
        contains('new BugseeLogSdk(NetworkChannelHolder.shared())'),
      );
      expect(
        read(
          'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
        ),
        contains('BGSFlutterLogOps.addLines(sdk: logSdk'),
      );
    });
  });
}
