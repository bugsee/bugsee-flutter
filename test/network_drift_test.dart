// What network capture repeats across Dart, Java and Objective-C, compared with one fixture
// (`test/fixtures/network_wire.json`), and the option keys it reads, compared with the SDKs' own
// published manifests. The native sides answer before Dart can look at them, so each copy is
// checked against its source, and the fixture against the real SDK enums by the JUnit/XCTest suites.
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/src/network/network_event.dart';
import 'package:bugsee_flutter/src/network/network_pipeline.dart';
import 'package:bugsee_flutter/src/network/network_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const java = 'android/src/main/java/com/bugsee/flutter';
const objc = 'ios/bugsee_flutter/Sources/bugsee_flutter_wrapper';

String read(String path) => File(path).readAsStringSync();

void main() {
  final fixture =
      jsonDecode(read('test/fixtures/network_wire.json'))
          as Map<String, dynamic>;
  final javaOps = read('$java/NetworkOps.java');
  final objcOps = read('$objc/BGSFlutterNetworkOps.m');
  final objcHeader = read('$objc/include/BGSFlutterNetworkOps.h');

  group('the stage names', () {
    final stages = (fixture['stages'] as List).cast<String>();

    test('Dart sends exactly the fixture\'s stages, by name', () {
      expect([for (final s in NetworkStage.values) s.name], stages);
    });

    test(
      'Java names each stage with the same value, in the same order, and no other',
      () {
        final found = [
          for (final m in RegExp(
            r'static final String STAGE_\w+ = "([^"]*)";',
          ).allMatches(javaOps))
            m.group(1)!,
        ];
        expect(found, stages);
      },
    );

    test(
      'Objective-C names each stage with the same value, in the same order, and no other',
      () {
        final found = [
          for (final m in RegExp(
            r'static NSString \*const kStage\w+ = @"([^"]*)";',
          ).allMatches(objcOps))
            m.group(1)!,
        ];
        expect(found, stages);
      },
    );

    test(
      'both natives map every stage Dart sends (iOS has no redirect stage, on purpose)',
      () {
        for (final s in stages) {
          expect(
            javaOps,
            contains('case STAGE_${s.toUpperCase()}:'),
            reason: s,
          );
        }
        final ios = fixture['iosStageConstants'] as Map<String, dynamic>;
        expect(ios.keys.toSet(), stages.toSet()..remove('redirect'));
        for (final constant in ios.values) {
          expect(objcOps, contains('return $constant;'), reason: '$constant');
        }
      },
    );
  });

  group('the body reasons', () {
    test('Dart\'s wire values are the fixture\'s', () {
      expect({
        for (final r in NoBodyReason.values) r.name: r.wire,
      }, fixture['noBodyReasons']);
    });
  });

  group('the numbers and names', () {
    test(
      'the oldest age native will stamp is the same in Dart, Java and Objective-C',
      () {
        final expected = fixture['maxAgeMs'] as int;
        expect(NetworkWire.maxAgeMs, expected);
        int product(String text) => text
            .split('*')
            .map((p) => int.parse(p.replaceAll(RegExp(r'[^0-9]'), '')))
            .reduce((a, b) => a * b);
        expect(
          product(
            RegExp(r'MAX_AGE_MS = ([^;]+);').firstMatch(javaOps)!.group(1)!,
          ),
          expected,
        );
        expect(
          product(
            RegExp(r'kMaxAgeMs = ([^;]+);').firstMatch(objcOps)!.group(1)!,
          ),
          expected,
        );
        expect(objcHeader, contains('maxAgeMs'));
      },
    );

    test('the mechanism Dart reports is the fixture\'s', () {
      expect(NetworkWire.mechanism, fixture['mechanism']);
    });

    test(
      'the filter timeout is the SDK\'s 10 seconds in the constant and in the public signature',
      () {
        expect(
          NetworkWire.defaultFilterTimeout,
          Duration(seconds: fixture['filterTimeoutSeconds'] as int),
        );
        expect(
          read('lib/src/bugsee.dart'),
          contains(
            'Duration timeout = const Duration(seconds: ${fixture['filterTimeoutSeconds']}),',
          ),
        );
      },
    );
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

      for (final sdk in ['android', 'ios']) {
        test(sdk, () {
          final options = manifest(sdk);
          expect(
            options[NetworkOptionKeys.capture],
            allOf(
              containsPair('type', 'boolean'),
              containsPair('default', true),
            ),
          );
          expect(
            options[NetworkOptionKeys.bodySizeLimit],
            allOf(
              containsPair('type', 'int'),
              containsPair('default', NetworkPolicy.defaultBodySizeLimit),
            ),
          );
          expect(
            options[NetworkOptionKeys.bodyWithoutType],
            allOf(
              containsPair('type', 'boolean'),
              containsPair('default', false),
            ),
          );
          expect(
            options['com.bugsee.option.\$\$ENDPOINT'],
            allOf(containsPair('hidden', true)),
          );
        });
      }
    },
  );

  group('no blocking on the platform thread beyond what the SDK does', () {
    test('the injection files do not wait, sleep or take a lock', () {
      for (final source in [
        javaOps,
        read('$java/NetworkChannelHolder.java'),
        read('$java/BugseeNetworkSdk.java'),
      ]) {
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
      expect(
        read('$java/NetworkChannelHolder.java'),
        contains('private volatile BugseeWrapperChannel channel;'),
      );
    });
  });
}
