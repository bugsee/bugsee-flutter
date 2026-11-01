// The generated option registry and the typed `BugseeOptions`, against the vendored manifests.
//
// `dart scripts/generate_options.dart --check` (CI) says the committed Dart is what the generator
// writes; this says what the generator wrote is what the manifests say, field by field, and that
// the pieces repeated by hand (the bundled modules) agree with their source.
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/src/options/bugsee_options.g.dart';
import 'package:bugsee_flutter/src/options/launch_options.dart'
    show bundledModules;
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:bugsee_flutter/src/options/option_registry.g.dart';
import 'package:bugsee_flutter/src/report/report_enums.dart';
import 'package:flutter_test/flutter_test.dart';

import '../scripts/generate_options.dart' as gen;
import 'helpers/option_samples.dart';

const dir = 'test/fixtures/option_manifests';

Map<String, Map<String, dynamic>> manifest(String sdk) {
  final json =
      jsonDecode(File('$dir/$sdk.json').readAsStringSync())
          as Map<String, dynamic>;
  return {
    for (final o in (json['options'] as List).cast<Map<String, dynamic>>())
      o['key'] as String: o,
  };
}

void main() {
  final android = manifest('android');
  final ios = manifest('ios');
  final registry = {for (final s in optionSpecs) s.key: s};

  group('the generated registry is what the manifests say', () {
    test('it has every option of both manifests, and nothing else', () {
      expect(registry.keys.toSet(), {...android.keys, ...ios.keys});
      expect(registry.length, optionSpecs.length, reason: 'no duplicate key');
    });

    test(
      'per platform: presence, type, module, default, enum values, hidden',
      () {
        for (final entry in registry.entries) {
          for (final platform in OptionPlatform.values) {
            final source = (platform == OptionPlatform.android
                ? android
                : ios)[entry.key];
            final here = entry.value.on(platform);
            expect(
              here == null,
              source == null,
              reason: '${entry.key} on $platform',
            );
            if (source == null) continue;
            expect(here!.module, source['module'], reason: entry.key);
            expect(here.defaultValue, source['default'], reason: entry.key);
            expect(entry.value.hidden, source['hidden'], reason: entry.key);
            final e = source['enum'] as Map<String, dynamic>?;
            expect(here.enumName, e?['name'], reason: entry.key);
            expect(
              here.enumValues,
              e == null ? isNull : e['values'],
              reason: entry.key,
            );
            final deprecated = source['deprecated'] as Map<String, dynamic>?;
            expect(
              here.deprecatedSince,
              deprecated?['since'],
              reason: entry.key,
            );
            final type = source['type'] as String;
            expect(
              entry.value.type.name,
              type == 'enum' ? 'enumeration' : type,
              reason: entry.key,
            );
          }
        }
      },
    );

    test(
      'hidden options have no typed field, nor do those of a module not bundled',
      () {
        for (final spec in optionSpecs) {
          final bundledAndroid =
              spec.android != null &&
              bundledModules[OptionPlatform.android]!.contains(
                spec.android!.module,
              );
          final bundledIos =
              spec.ios != null &&
              bundledModules[OptionPlatform.ios]!.contains(spec.ios!.module);
          final deprecated =
              (spec.android?.deprecatedSince ?? spec.ios?.deprecatedSince) !=
              null;
          expect(
            spec.typed,
            !spec.hidden && !deprecated && (bundledAndroid || bundledIos),
            reason: spec.key,
          );
        }
        // The four leak-module options (bugsee-android-leak is not a dependency of this plugin).
        expect(
          optionSpecs
              .where((s) => s.android?.module == 'bugsee-android-leak')
              .map((s) => s.typed),
          everyElement(isFalse),
        );
      },
    );

    test(
      'the bundled modules are the artefacts android/build.gradle declares',
      () {
        final gradle = File('android/build.gradle').readAsStringSync();
        final declared = {
          for (final m in RegExp(
            r'api "com\.bugsee:(bugsee-android[a-z-]*):',
          ).allMatches(gradle))
            m.group(1)!,
        };
        expect(bundledModules[OptionPlatform.android], declared);
        expect(gen.bundledModules['android'], declared);
        expect(bundledModules[OptionPlatform.ios], {'Bugsee'});
        expect(gen.bundledModules['ios'], {'Bugsee'});
      },
    );
  });

  group('BugseeOptions has a field for every typed option', () {
    final typed = optionSpecs.where((s) => s.typed).toList();

    test(
      'there are 100 of them (84 + 71 public, 51 shared, less 4 leak-module and 1 deprecated)',
      () {
        expect(typed.length, 100);
      },
    );

    test(
      'each registry key is a constructor field of the generated name, emitted under its key',
      () {
        for (final spec in typed) {
          final name = gen.fieldName(spec.key);
          final s = sample(spec);
          final options =
              Function.apply(BugseeOptions.new, [], {Symbol(name): s.value})
                  as BugseeOptions;
          expect(options.typedEntries(), {
            spec.key: s.entry,
          }, reason: '$name -> ${spec.key}');
        }
      },
    );

    test('an unset option is not emitted: null means "the SDK default"', () {
      expect(const BugseeOptions().typedEntries(), isEmpty);
    });

    test('enums cross by internal value, never by ordinal', () {
      final options = BugseeOptions(
        captureVideoMode: VideoMode.fullscreen,
        captureLogsLevel: LogLevel.error,
        captureVideoFrameRate: FrameRate.raw,
        reportingDefaultsCrashPriority: ReportSeverity.veryLow,
        reportingUiStyle: BugseeStyle.system,
      );
      expect(options.typedEntries(), {
        'com.bugsee.option.capture.video.mode': 20, // ordinal 3
        'com.bugsee.option.capture.logs.level': 1, // ordinal 0
        'com.bugsee.option.capture.video.frame-rate': 4,
        'com.bugsee.option.reporting.defaults.crash-priority': 1,
        'com.bugsee.option.reporting.ui.style': 3,
      });
    });

    test(
      'generated enum constants match the manifests by value, with platform flags',
      () {
        void expectEnum(
          String sdkEnum,
          String platform,
          Map<String, int> dart,
        ) {
          final source = (platform == 'android' ? android : ios).values
              .map((o) => o['enum'] as Map<String, dynamic>?)
              .firstWhere((e) => e?['name'] == sdkEnum)!;
          final values = (source['values'] as Map).cast<String, int>();
          expect(
            dart.values.toSet(),
            values.values.toSet(),
            reason: '$sdkEnum on $platform',
          );
        }

        Map<String, int> of<T extends Enum>(
          List<T> all,
          int Function(T) value,
          bool Function(T) on,
        ) => {
          for (final c in all)
            if (on(c)) c.name: value(c),
        };
        expectEnum(
          'LogLevel',
          'android',
          of(LogLevel.values, (c) => c.value, (c) => c.onAndroid),
        );
        expectEnum(
          'BugseeLogLevel',
          'ios',
          of(LogLevel.values, (c) => c.value, (c) => c.onIos),
        );
        expectEnum(
          'FrameRate',
          'android',
          of(FrameRate.values, (c) => c.value, (c) => c.onAndroid),
        );
        expectEnum(
          'BugseeFrameRate',
          'ios',
          of(FrameRate.values, (c) => c.value, (c) => c.onIos),
        );
        expectEnum(
          'VideoMode',
          'android',
          of(VideoMode.values, (c) => c.value, (c) => c.onAndroid),
        );
        expectEnum(
          'VideoQuality',
          'android',
          of(VideoQuality.values, (c) => c.value, (c) => c.onAndroid),
        );
        expectEnum(
          'BugseeVideoQuality',
          'ios',
          of(VideoQuality.values, (c) => c.value, (c) => c.onIos),
        );
        expectEnum(
          'BugseeCrashHandlerType',
          'ios',
          of(CrashHandlerType.values, (c) => c.value, (c) => c.onIos),
        );
        expectEnum(
          'BugseeDataEncryptionMode',
          'ios',
          of(DataEncryptionMode.values, (c) => c.value, (c) => c.onIos),
        );
        expectEnum(
          'BugseeStyle',
          'ios',
          of(BugseeStyle.values, (c) => c.value, (c) => c.onIos),
        );
        // The hand-written severity enum is compared by value with both platforms (ReportSeverity).
        expectEnum('IssueSeverity', 'android', {
          for (final s in ReportSeverity.values) s.name: s.value,
        });
        expectEnum('BugseeSeverityLevel', 'ios', {
          for (final s in ReportSeverity.values) s.name: s.value,
        });
        // The one value a platform lacks.
        expect(FrameRate.raw.onIos, isFalse);
        expect(FrameRate.raw.onAndroid, isTrue);
        expect(FrameRate.fromValue(3), FrameRate.high);
        expect(FrameRate.fromValue(99), isNull);
      },
    );
  });

  group('the generator', () {
    test('field names mirror the key', () {
      expect(
        gen.fieldName('com.bugsee.option.capture.video.frame-rate'),
        'captureVideoFrameRate',
      );
      expect(
        gen.fieldName('com.bugsee.option.detect.exit.bg_low_memory_as_error'),
        'detectExitBgLowMemoryAsError',
      );
      expect(
        gen.fieldName('com.bugsee.option.crash-ndk.tombstone-logs'),
        'crashNdkTombstoneLogs',
      );
    });

    test(
      'the deprecated no-op option has no typed field but is in the registry',
      () {
        final spec =
            registry['com.bugsee.option.capture.webview.domain-allowlist']!;
        expect(spec.android!.deprecatedSince, '7.1.2');
        expect(spec.typed, isFalse);
      },
    );

    test(
      'name overrides: compound words are capitalised, and every override names a real option',
      () {
        expect(
          gen.fieldName('com.bugsee.option.capture.avplayer'),
          'captureAvPlayer',
        );
        expect(
          gen.fieldName('com.bugsee.option.capture.logs.allsources'),
          'captureLogsAllSources',
        );
        expect(
          gen.fieldName('com.bugsee.option.capture.logs.oslog'),
          'captureLogsOsLog',
        );
        expect(
          gen.fieldName('com.bugsee.option.capture.websocket'),
          'captureWebSocket',
        );
        expect(gen.constantName('Default', 'VideoQuality'), 'defaultQuality');
        for (final k in gen.fieldNameOverrides.keys) {
          expect(
            registry.containsKey('com.bugsee.option.$k'),
            isTrue,
            reason: 'stale override $k',
          );
        }
      },
    );

    test('a reserved word as a constant gets the enum name appended', () {
      expect(gen.constantName('Default', 'VideoQuality'), 'defaultQuality');
      expect(gen.constantName('Fullscreen', 'VideoMode'), 'fullscreen');
      expect(gen.constantName('MachAndBSD', 'CrashHandlerType'), 'machAndBsd');
    });

    Map<String, gen.PlatformOption> one(
      String key,
      Map<String, dynamic> json,
    ) => {
      key: gen.PlatformOption({
        'module': 'm',
        'default': null,
        'hidden': false,
        ...json,
      }),
    };

    test('a type that differs between platforms stops generation', () {
      expect(
        () => gen.mergeManifests(
          one('com.bugsee.option.x', {'type': 'int'}),
          one('com.bugsee.option.x', {'type': 'boolean'}),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'message',
            contains('type int on Android, boolean on iOS'),
          ),
        ),
      );
    });

    test('a new SDK enum with no Dart name stops generation', () {
      final options = gen.mergeManifests(
        one('com.bugsee.option.x', {
          'type': 'enum',
          'enum': {
            'name': 'BrandNewMode',
            'values': {'A': 1},
          },
        }),
        {},
      );
      expect(
        () => gen.collectEnums(options),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'message',
            contains('BrandNewMode has no Dart name'),
          ),
        ),
      );
    });

    test('one value with two names on two platforms stops generation', () {
      final options = gen.mergeManifests(
        one('com.bugsee.option.x', {
          'type': 'enum',
          'enum': {
            'name': 'LogLevel',
            'values': {'Error': 1},
          },
        }),
        one('com.bugsee.option.x', {
          'type': 'enum',
          'enum': {
            'name': 'BugseeLogLevel',
            'values': {'Fatal': 1},
          },
        }),
      );
      final enums = gen.collectEnums(options);
      expect(
        () => gen.membersOf(enums['LogLevel']!),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'message',
            contains('value 1 is Error on Android and Fatal on iOS'),
          ),
        ),
      );
    });

    test('a member only one platform has is flagged for that platform', () {
      final options = gen.mergeManifests(
        one('com.bugsee.option.x', {
          'type': 'enum',
          'enum': {
            'name': 'FrameRate',
            'values': {'Low': 1, 'Raw': 4},
          },
        }),
        one('com.bugsee.option.x', {
          'type': 'enum',
          'enum': {
            'name': 'BugseeFrameRate',
            'values': {'Low': 1},
          },
        }),
      );
      final members = gen.membersOf(gen.collectEnums(options)['FrameRate']!);
      expect(
        [for (final m in members) (m.sdkName, m.onAndroid, m.onIos)],
        [('Low', true, true), ('Raw', true, false)],
      );
    });
  });
}
