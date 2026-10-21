// The vendored options manifests (test/fixtures/option_manifests): what they must be, and what
// the two platforms must agree on (bugsee/specs sdk/options, "Consumer rules").
//
// The manifests are the SDKs' own published artifacts, generated from their live option
// registry. Everything else in the options work (the generated registry and BugseeOptions, the
// native enum tables, the encoder) is checked against them, offline.
//
//   strict on keys, types and enum VALUES between platforms;
//   tolerant, but explicit, on defaults: each difference is listed below with its two values, so
//   a NEW difference fails until somebody has looked at it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/sync_option_manifests.dart' as sync;

const dir = 'test/fixtures/option_manifests';

Map<String, dynamic> readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

Map<String, Map<String, dynamic>> byKey(Map<String, dynamic> manifest) => {
  for (final o in (manifest['options'] as List).cast<Map<String, dynamic>>())
    o['key'] as String: o,
};

/// Enum members a platform deliberately does not have, by SDK enum name. A one-sided member is
/// fine (the Dart enum says which platform has it); an UNLISTED one-sided member means an SDK
/// added or removed a value and somebody has to decide what that means for the wrapper.
const knownOneSidedEnumMembers = {
  // Android-only: iOS's BugseeFrameRate stops at High (ios/sdk BugseeConstants.h).
  'FrameRate': {'Raw': 4},
};

/// Same internal value, different NAME on the two platforms (workbook 7.4.2): the enum compares
/// by value, and the name difference is information, not a failure.
const knownNameDivergences = {
  'IssueSeverity': {'VeryLow': 'Low'},
};

/// Defaults that differ between platforms ON PURPOSE (BGSOptionsDescriptors.m: "iOS defaults;
/// some differ from Android intentionally"). Reviewed; a new difference fails until added.
const knownDefaultDifferences = {
  'com.bugsee.option.capture.video.adaptive': (false, true),
  'com.bugsee.option.config.max-data-size': (150, 50),
};

void main() {
  final pins = readJson('native-versions.json');
  final android = readJson('$dir/android.json');
  final ios = readJson('$dir/ios.json');
  final a = byKey(android);
  final i = byKey(ios);

  group('the manifests are the ones for the pinned SDKs', () {
    test('each is the published manifest of the pinned version', () {
      expect(
        sync.manifestProblems(
          File('$dir/android.json').readAsStringSync(),
          sdk: 'android',
          version: (pins['android'] as Map)['sdk'] as String,
        ),
        isEmpty,
      );
      expect(
        sync.manifestProblems(
          File('$dir/ios.json').readAsStringSync(),
          sdk: 'ios',
          version: (pins['ios'] as Map)['sdk'] as String,
        ),
        isEmpty,
      );
    });

    test('a manifest for another version, platform or format is refused', () {
      final text = File('$dir/android.json').readAsStringSync();
      expect(
        sync.manifestProblems(text, sdk: 'android', version: '7.4.3'),
        contains(contains('sdkVersion is 7.4.2, the pin is 7.4.3')),
      );
      expect(
        sync.manifestProblems(text, sdk: 'ios', version: '7.4.2'),
        contains(contains('sdk is android, expected ios')),
      );
      expect(
        sync.manifestProblems(
          text.replaceFirst('"manifestVersion": 1', '"manifestVersion": 2'),
          sdk: 'android',
          version: '7.4.2',
        ),
        contains(contains('manifestVersion is 2')),
      );
      expect(
        sync.manifestProblems('{', sdk: 'android', version: '7.4.2'),
        contains(startsWith('not JSON')),
      );
    });

    test('the URL is built from the template in native-versions.json', () {
      final template =
          (pins['optionsManifest'] as Map)['urlTemplate'] as String;
      expect(
        sync.manifestUrl(template, 'ios', '7.0.0-beta7'),
        'https://download.bugsee.com/sdk/options/ios/7.0.0-beta7.json',
      );
      expect(
        (pins['optionsManifest'] as Map)['fixtureDir'],
        dir,
        reason: 'the sync script writes where the tests read',
      );
    });

    test('keys are unique within each manifest', () {
      for (final m in [android, ios]) {
        final keys = [
          for (final o in (m['options'] as List).cast<Map<String, dynamic>>())
            o['key'],
        ];
        expect(keys.toSet().length, keys.length);
      }
    });
  });

  group('inventory', () {
    final shared = a.keys.toSet().intersection(i.keys.toSet());

    test('counts, so a changed option surface is noticed', () {
      // Android 7.4.2: 87 (84 public + 3 hidden). iOS 7.0.0-beta7: 70 (69 public + 1 hidden).
      expect(a.length, 87);
      expect(i.length, 70);
      expect(shared.length, 49);
      expect(a.keys.toSet().difference(i.keys.toSet()).length, 38);
      expect(i.keys.toSet().difference(a.keys.toSet()).length, 21);
    });

    test('the hidden options are exactly the known internals', () {
      Set<String> hidden(Map<String, Map<String, dynamic>> m) => {
        for (final e in m.entries)
          if (e.value['hidden'] == true) e.key,
      };
      expect(hidden(a), {
        'com.bugsee.option.\$\$DEBUG',
        'com.bugsee.option.\$\$ENDPOINT',
        'com.bugsee.option.\$\$WRAPPER',
      });
      expect(hidden(i), {'com.bugsee.option.\$\$ENDPOINT'});
    });

    test('every key is in the shared namespace', () {
      for (final k in [...a.keys, ...i.keys]) {
        expect(k, startsWith('com.bugsee.option.'));
      }
    });

    test(
      'Android modules are the core, the NDK extension and the leak extension',
      () {
        expect(
          {for (final o in a.values) o['module']},
          {'bugsee-android', 'bugsee-android-ndk', 'bugsee-android-leak'},
        );
        expect({for (final o in i.values) o['module']}, {'Bugsee'});
      },
    );
  });

  group('platform parity (strict on keys present on both, types, enum values)', () {
    final shared = a.keys.toSet().intersection(i.keys.toSet()).toList()..sort();

    test('a key on both platforms has the same type and hidden flag', () {
      for (final k in shared) {
        expect(a[k]!['type'], i[k]!['type'], reason: k);
        expect(a[k]!['hidden'], i[k]!['hidden'], reason: k);
      }
    });

    test('an enum key is an enum on both, and its values agree by VALUE', () {
      for (final k in shared) {
        final ea = a[k]!['enum'] as Map<String, dynamic>?;
        final ei = i[k]!['enum'] as Map<String, dynamic>?;
        expect(ea == null, ei == null, reason: k);
        if (ea == null) continue;
        final va = (ea['values'] as Map).cast<String, Object>();
        final vi = (ei!['values'] as Map).cast<String, Object>();
        // Values of the same JSON type on both (a string enum never agrees with a number enum).
        for (final v in [...va.values, ...vi.values]) {
          expect(
            v,
            isA<int>(),
            reason: '$k: this wrapper maps number-valued enums',
          );
        }
        final oneSided = knownOneSidedEnumMembers[ea['name']] ?? const {};
        final androidOnly = {
          for (final e in va.entries)
            if (!vi.containsValue(e.value)) e.key: e.value,
        };
        final iosOnly = {
          for (final e in vi.entries)
            if (!va.containsValue(e.value)) e.key: e.value,
        };
        expect(androidOnly, oneSided, reason: '$k: Android-only members');
        expect(iosOnly, isEmpty, reason: '$k: iOS-only members');
        // Where the value is on both, the name agrees or is a known divergence.
        final divergences = knownNameDivergences[ea['name']] ?? const {};
        for (final e in va.entries) {
          final iosName = vi.entries
              .where((x) => x.value == e.value)
              .map((x) => x.key)
              .firstOrNull;
          if (iosName == null) continue;
          expect(
            iosName,
            divergences[e.key] ?? e.key,
            reason:
                '$k: value ${e.value} is ${e.key} on Android, $iosName on iOS',
          );
        }
      }
    });

    test('no enum member NAME maps to different numbers on the two platforms', () {
      // The Dart enum merges the two name tables by member name and lets Android win on a
      // clash, so a name that meant two numbers would silently launch the wrong one on iOS.
      for (final k in shared) {
        final ea = a[k]!['enum'] as Map<String, dynamic>?;
        final ei = i[k]!['enum'] as Map<String, dynamic>?;
        if (ea == null || ei == null) continue;
        final va = (ea['values'] as Map).cast<String, Object>();
        final vi = (ei['values'] as Map).cast<String, Object>();
        for (final name in va.keys.toSet().intersection(vi.keys.toSet())) {
          expect(
            vi[name],
            va[name],
            reason: '$k: $name is ${va[name]} on Android, ${vi[name]} on iOS',
          );
        }
      }
    });

    test('default differences are exactly the reviewed ones', () {
      final differing = <String, (Object?, Object?)>{
        for (final k in shared)
          if (a[k]!['default'] != i[k]!['default'])
            k: (a[k]!['default'], i[k]!['default']),
      };
      expect(differing, knownDefaultDifferences);
    });

    test('enum internal values are never the ordinals (7.4.1)', () {
      // The reason the manifest publishes values at all: four of the five Android option enums
      // differ from their ordinals.
      final video =
          (a['com.bugsee.option.capture.video.mode']!['enum'] as Map)['values']
              as Map;
      expect(video['Fullscreen'], 20);
      expect(video['DirectBuffers'], 21);
      final logs =
          (a['com.bugsee.option.capture.logs.level']!['enum'] as Map)['values']
              as Map;
      expect(logs['Error'], 1);
    });
  });

  group('the option docs fixture', () {
    final docs = readJson('$dir/docs.json');

    test('records where it was read from, and covers every public option', () {
      expect((docs['sources'] as Map).keys, ['android', 'ios']);
      final described = (docs['docs'] as Map).keys.toSet();
      final public = {
        for (final m in [a, i])
          for (final e in m.entries)
            if (e.value['hidden'] != true) e.key,
      };
      expect(
        public.difference(described),
        isEmpty,
        reason: 'options with no description at all',
      );
    });
  });
}
