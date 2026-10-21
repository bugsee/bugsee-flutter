// Drift guard for every pinned native version (workbook 1.1, 1.2.2, 1.4.1).
//
// native-versions.json is the single source. Each other place that has to repeat
// a value is read here and compared to it. Change one copy and this file must
// fail; see the mutation notes in PLAN.md Phase 1.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

/// Uncommented lines only.
String liveOf(String yaml) =>
    yaml.split('\n').where((l) => !l.trimLeft().startsWith('#')).join('\n');

/// Job id -> body, for a workflow's `jobs:` section (two-space job keys).
Map<String, String> jobsOf(String live) {
  final jobs = live.substring(live.indexOf('\njobs:'));
  final headers = RegExp(
    r'^  ([a-z0-9-]+):\s*$',
    multiLine: true,
  ).allMatches(jobs).toList();
  return {
    for (var i = 0; i < headers.length; i++)
      headers[i].group(1)!: jobs.substring(
        headers[i].end,
        i + 1 < headers.length ? headers[i + 1].start : jobs.length,
      ),
  };
}

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
      },
    );

    test('no SNAPSHOT pins', () {
      expect(jsonEncode(pins), isNot(contains('SNAPSHOT')));
    });
  });

  group('pubspec.yaml', () {
    final pubspec = read('pubspec.yaml');

    test('Dart floor matches (plugin and example)', () {
      final dart = flutterPin['dart'] as String;
      final caret = '^${dart.split('.').take(2).join('.')}.0';
      expect(pubspec, contains('sdk: $caret'));
      expect(read('example/pubspec.yaml'), contains('sdk: $caret'));
    });

    test('version is semver and the CHANGELOG has an entry for it', () {
      final v = RegExp(
        r'^version: (\S+)\s*$',
        multiLine: true,
      ).firstMatch(pubspec)!.group(1)!;
      expect(
        v,
        matches(
          RegExp(r'^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'),
        ),
      );
      expect(
        read('CHANGELOG.md'),
        startsWith('## $v\n'),
        reason: 'newest CHANGELOG entry must be the pubspec version',
      );
    });

    test('repository and issue tracker point at the real repo', () {
      expect(
        pubspec,
        contains('repository: https://github.com/bugsee/bugsee-flutter\n'),
      );
      expect(
        pubspec,
        contains(
          'issue_tracker: https://github.com/bugsee/bugsee-flutter/issues\n',
        ),
      );
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
      expect(
        RegExp(r'com\.bugsee:bugsee-android[a-z-]*:\d').hasMatch(gradle),
        isFalse,
        reason:
            'a literal version here would not be covered by native-versions.json',
      );
    });

    test('declares the NDK artefact next to the core (workbook 1.2.1)', () {
      expect(
        gradle,
        contains(
          r'api "com.bugsee:bugsee-android:${nativeVersions.android.sdk}"',
        ),
      );
      expect(
        gradle,
        contains(
          r'api "com.bugsee:bugsee-android-ndk:${nativeVersions.android.sdk}"',
        ),
      );
    });

    test('example applies the Gradle plugin at the pinned version', () {
      final settings = read('example/android/settings.gradle.kts');
      expect(
        settings,
        contains(
          'id("com.bugsee.android.gradle") version "${android['gradlePlugin']}"',
        ),
      );
      expect(
        read('example/android/app/build.gradle.kts'),
        contains('id("com.bugsee.android.gradle")'),
      );
    });
  });

  group('iOS', () {
    final manifest = read('ios/bugsee_flutter/Package.swift');

    test('pins the SPM package exactly', () {
      expect(
        manifest,
        contains('.package(url: "${ios['spmUrl']}", exact: "${ios['sdk']}")'),
      );
    });

    test('deployment target matches', () {
      expect(manifest, contains('.iOS("${ios['deploymentTarget']}")'));
      final pbx = read('example/ios/Runner.xcodeproj/project.pbxproj');
      final targets = RegExp(
        r'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);',
      ).allMatches(pbx).map((m) => m.group(1)).toSet();
      expect(targets, {ios['deploymentTarget']});
    });

    test('committed Package.resolved files pin the same SPM version', () {
      final files = Process.runSync('git', ['ls-files', '*Package.resolved'])
          .stdout
          .toString()
          .trim()
          .split('\n')
          .where((f) => f.isNotEmpty)
          .toList();
      expect(
        files,
        isNotEmpty,
        reason: 'expected committed Package.resolved files',
      );
      for (final f in files) {
        final pins = (jsonDecode(read(f))['pins'] as List)
            .cast<Map<String, dynamic>>();
        final spm = pins.where(
          (p) =>
              (p['location'] as String).toLowerCase() ==
              (ios['spmUrl'] as String).toLowerCase(),
        );
        expect(spm, hasLength(1), reason: '$f must pin ${ios['spmUrl']}');
        expect(
          spm.single['state']['version'],
          ios['sdk'],
          reason: '$f drifted from native-versions.json',
        );
      }
    });

    test('the test-only wrapper package pins the SPM package the same way', () {
      final tests = read('ios/wrapper_tests/Package.swift');
      expect(
        tests,
        contains('.package(url: "${ios['spmUrl']}", exact: "${ios['sdk']}")'),
      );
      expect(tests, contains('.iOS("${ios['deploymentTarget']}")'));
    });

    test('has no podspec: Bugsee publishes no pod, so one could not build', () {
      expect(
        Directory('ios').listSync().whereType<File>().where(
          (f) => f.path.endsWith('.podspec'),
        ),
        isEmpty,
      );
    });
  });

  group('pigeon', () {
    final pin = (pins['pigeon'] as Map<String, dynamic>)['version'] as String;

    test('the generator package pins the same version, exactly', () {
      expect(
        read('pigeons/pubspec.yaml'),
        matches(RegExp('^  pigeon: ${RegExp.escape(pin)}\$', multiLine: true)),
      );
    });

    test('the lockfile resolves the same version', () {
      expect(
        read('pigeons/pubspec.lock'),
        matches(
          RegExp('pigeon:\\n(?:.*\\n)*?    version: "${RegExp.escape(pin)}"'),
        ),
      );
    });

    test('every committed generated file was produced by that version', () {
      for (final f in [
        'lib/src/bridge/messages.g.dart',
        'android/src/main/java/com/bugsee/flutter/Messages.java',
        'ios/bugsee_flutter/Sources/bugsee_flutter/Messages.g.swift',
      ]) {
        expect(
          read(f),
          contains('Autogenerated from Pigeon (v$pin)'),
          reason: '$f was generated by another pigeon',
        );
      }
    });

    test('pigeon is not a dependency of the plugin (needs a newer meta)', () {
      expect(read('pubspec.yaml'), isNot(contains('pigeon:')));
    });

    test('the generated bridge is internal: not exported', () {
      expect(read('lib/bugsee_flutter.dart'), isNot(contains('bridge')));
      expect(read('lib/bugsee_flutter.dart'), isNot(contains('messages')));
    });
  });

  group('CI', () {
    final ci = read('.github/workflows/ci.yml');
    // Live (uncommented) lines only.
    final live = ci
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('#'))
        .join('\n');

    test('uses a supported JDK on a live line', () {
      final jdks = ((android['jdk'] as Map)['supported'] as List).cast<int>();
      final all = RegExp(
        r"""^\s*java-version: ['"](\d+)['"]""",
        multiLine: true,
      ).allMatches(live).toList();
      final setups = RegExp(
        r'uses: actions/setup-java@',
      ).allMatches(live).length;
      expect(all, isNotEmpty, reason: 'no live java-version line in ci.yml');
      expect(
        all.length,
        setups,
        reason: 'every setup-java step needs a live java-version',
      );
      for (final m in all) {
        expect(jdks, contains(int.parse(m.group(1)!)));
      }
    });

    test(
      'enables SwiftPM before pub get in the same job (the plugin has no podspec)',
      () {
        final enable = RegExp(
          r'^\s*- run: flutter config --enable-swift-package-manager\s*$\n(?:.*\n)*?\s*- run: flutter pub get\s*$',
          multiLine: true,
        );
        // Every job that runs pub get must enable SwiftPM first.
        for (final job
            in live
                .split(RegExp(r'^  (?=[a-z-]+:\s*$)', multiLine: true))
                .where((j) => j.contains('flutter pub get'))) {
          expect(
            enable.hasMatch(job),
            isTrue,
            reason:
                'job lacks a live SwiftPM enable step before pub get:\n$job',
          );
        }
        expect(enable.hasMatch(live), isTrue);
      },
    );

    test('tests the Flutter floor via the matrix', () {
      final floor = RegExp(
        "^\\s*flutter-version: '${RegExp.escape(flutterPin['min'] as String)}'\\s*\$",
        multiLine: true,
      );
      // Both the macOS test job and the Linux apk job must run the floor.
      expect(
        RegExp(
          r'^\s*flutter-version: \$\{\{ matrix\.flutter-version \}\}\s*$',
          multiLine: true,
        ).allMatches(live).length,
        2,
        reason: 'each job must read the version from its matrix',
      );
      // Two matrices plus the format job pinned to the floor.
      expect(
        floor.allMatches(live).length,
        6,
        reason:
            'floor must be in both matrices, the format job, bridge-codegen, '
            'options-codegen and publish-check',
      );
      for (final job in [
        'format',
        'bridge-codegen',
        'options-codegen',
        'publish-check',
      ]) {
        expect(
          jobsOf(live)[job],
          matches(floor),
          reason: '$job must run on the floor',
        );
      }
    });

    test('runs on macOS and builds iOS and Android', () {
      expect(live, contains('runs-on: macos-latest'));
      expect(live, contains('flutter build ios --debug --no-codesign'));
      expect(live, contains('flutter build apk --debug'));
    });

    test('checks the generated option registry, offline, on the floor', () {
      final job = jobsOf(live)['options-codegen']!;
      expect(job, contains('dart scripts/generate_options.dart --check'));
      for (final network in ['sync_option_manifests', 'check_native_pins']) {
        expect(live, isNot(contains(network)), reason: 'no network in PR CI');
      }
      // The SDK checkouts the source cross-check reads are private: never a CI step.
      expect(live, isNot(contains('verify_option_manifests')));
      expect(live, isNot(contains('extract_option_docs')));
    });

    test('checks the bridge codegen and runs the iOS wrapper tests', () {
      expect(live, contains('dart scripts/generate_pigeon.dart --check'));
      expect(live, contains('cd ios/wrapper_tests'));
      expect(
        live,
        contains('xcodebuild test -scheme bugsee_flutter_wrapper_tests'),
      );
      // The scheme the workflow names is the package's name.
      expect(
        read('ios/wrapper_tests/Package.swift'),
        contains('name: "bugsee_flutter_wrapper_tests"'),
      );
    });

    test(
      '.pubignore repeats every .gitignore rule and drops the dev trees',
      () {
        final pub = read('.pubignore');
        for (final rule
            in read('.gitignore')
                .split('\n')
                .where(
                  (l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#'),
                )) {
          expect(pub, contains(rule), reason: '.pubignore lacks `$rule`');
        }
        expect(pub, contains('/ios/wrapper_tests/'));
        expect(pub, contains('/pigeons/'));
      },
    );

    test('claude-review.yml calls the shared workflow', () {
      final review = read('.github/workflows/claude-review.yml');
      expect(
        review,
        contains(
          'uses: bugsee/.github/.github/workflows/claude-review.yml@main',
        ),
      );
    });
  });

  group('workflows', () {
    final files = Directory('.github/workflows')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yml'))
        .toList();
    // claude-review.yml is owned by the org's shared workflow.
    final ours = files.where((f) => !f.path.endsWith('claude-review.yml'));

    test('every workflow is least-privilege', () {
      for (final f in ours) {
        final live = liveOf(read(f.path));
        expect(
          live,
          matches(
            RegExp(r'^permissions:\n  contents: read\n', multiLine: true),
          ),
          reason: '${f.path}: top-level permissions must be contents: read',
        );
        expect(
          live,
          isNot(contains('write')),
          reason: '${f.path}: no write permission',
        );
        expect(
          live,
          isNot(contains(RegExp(r'secrets\s*[.\[]'))),
          reason: '${f.path}: no secrets',
        );
        final checkouts = RegExp(
          r'uses: actions/checkout@v\d+\n\s+with:\n\s+persist-credentials: false',
        ).allMatches(live).length;
        expect(
          checkouts,
          RegExp(r'uses: actions/checkout@').allMatches(live).length,
          reason: '${f.path}: every checkout needs persist-credentials: false',
        );
      }
    });

    test('every job has a timeout', () {
      for (final f in ours) {
        for (final e in jobsOf(liveOf(read(f.path))).entries) {
          // Job level only (4-space indent); a step-level timeout does not count.
          expect(
            e.value,
            matches(RegExp(r'^    timeout-minutes: \d+\s*$', multiLine: true)),
            reason: '${f.path} job ${e.key}',
          );
        }
      }
    });

    test('nothing publishes: pub publish is always a dry run', () {
      for (final f in files) {
        for (final l in liveOf(read(f.path)).split('\n')) {
          if (RegExp(r'(flutter|dart) pub publish').hasMatch(l)) {
            expect(l, contains('--dry-run'), reason: '${f.path}: $l');
          }
        }
      }
    });

    test('ci-ok needs every other ci.yml job', () {
      final jobs = jobsOf(liveOf(read('.github/workflows/ci.yml')));
      final needs = RegExp(r'needs: \[([^\]]*)\]').firstMatch(jobs['ci-ok']!)!;
      final listed = needs.group(1)!.split(',').map((e) => e.trim()).toSet();
      expect(listed, jobs.keys.toSet()..remove('ci-ok'));
      final okJob = jobs['ci-ok']!;
      // Must run (and fail) on a cancelled run too: a skipped required check passes.
      expect(okJob, contains('if: always()'));
      expect(okJob, isNot(contains('cancelled()')));
      // The step that actually fails the job.
      expect(
        okJob,
        contains('jq -e \'all(.[]; .result == "success")\''),
        reason: 'ci-ok must fail unless every needed job succeeded',
      );
      expect(okJob, contains(r'NEEDS: ${{ toJSON(needs) }}'));
    });

    test(
      'concurrency: PRs cancel superseded runs, pushes never share a group',
      () {
        final ci = liveOf(read('.github/workflows/ci.yml'));
        expect(
          ci,
          contains(
            r"group: ci-${{ github.event_name == 'pull_request' && github.ref || github.sha }}",
          ),
        );
        expect(
          ci,
          contains(
            r"cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
          ),
        );
      },
    );

    test(
      'dependabot cannot bump Bugsee pins (Gradle entries ignore com.bugsee*)',
      () {
        final dep = liveOf(read('.github/dependabot.yml'));
        final gradle = RegExp(
          r'package-ecosystem: gradle\n(?:(?!  - package-ecosystem)[\s\S])*',
        ).allMatches(dep).toList();
        expect(gradle, hasLength(2));
        for (final g in gradle) {
          expect(g.group(0), contains('dependency-name: "com.bugsee*"'));
        }
      },
    );

    test('every dependabot entry targets nextgen', () {
      final dep = liveOf(read('.github/dependabot.yml'));
      expect(
        'package-ecosystem:'.allMatches(dep).length,
        'target-branch: nextgen'.allMatches(dep).length,
      );
    });

    test(
      'format gate is enforced on lib, test, example, scripts and pigeons',
      () {
        expect(
          liveOf(read('.github/workflows/ci.yml')),
          contains(
            'dart format --output=none --set-exit-if-changed lib test example/lib example/integration_test scripts pigeons',
          ),
        );
      },
    );

    test('native-pins runs on a schedule, in its own workflow only', () {
      final pins = liveOf(read('.github/workflows/native-pins.yml'));
      expect(pins, contains('schedule:'));
      expect(pins, contains('workflow_dispatch:'));
      expect(pins, contains('dart scripts/check_native_pins.dart'));
      expect(
        pins,
        contains('dart scripts/sync_option_manifests.dart --check'),
        reason: 'the vendored option manifests are refetched here, weekly',
      );
      expect(
        pins,
        matches(
          RegExp(
            r'uses: actions/checkout@v\d+\n\s+with:\n(?:\s+[a-z-]+: .*\n)*?\s+ref: nextgen\n',
          ),
        ),
        reason: 'scheduled runs use the default branch tree, which has no pins',
      );
      expect(
        pins,
        contains("sdk: '${flutterPin['dart']}'"),
        reason: 'Dart SDK must match flutter.dart in native-versions.json',
      );
      expect(
        liveOf(read('.github/workflows/ci.yml')),
        isNot(contains('check_native_pins')),
        reason: 'network checks must not run in PR CI',
      );
    });
  });
}
