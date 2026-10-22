// Drift guards for the separate feedback package (packages/bugsee_flutter_feedback, PLAN.md D4):
// how it is laid out and published next to the core, which native pins it repeats and where, how
// its native module registers with the SDK, and that the core stays free of it.
//
// The package's own behaviour is tested in the package (its Dart tests, Gradle JUnit, XCTest);
// everything that must agree ACROSS the two packages is here, because the core's tests run from
// the repository root and see both.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const pkg = 'packages/bugsee_flutter_feedback';

String read(String path) => File(path).readAsStringSync();

/// Source with `//` and `/* */` comments removed, so a call that is only commented out does not
/// satisfy a guard.
String code(String path) => read(path)
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'(?<![:/])//[^\n]*'), '');

String liveOf(String yaml) =>
    yaml.split('\n').where((l) => !l.trimLeft().startsWith('#')).join('\n');

/// Every file under [dir] with one of [extensions], recursively.
List<File> filesUnder(String dir, List<String> extensions) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => extensions.any(f.path.endsWith))
    .toList();

/// Job id -> body, for a workflow's `jobs:` section (two-space job keys).
Map<String, String> jobsOf(String live) {
  final section = live.substring(live.indexOf('\njobs:'));
  final headers = RegExp(
    r'^  ([a-z0-9-]+):\s*$',
    multiLine: true,
  ).allMatches(section).toList();
  return {
    for (var i = 0; i < headers.length; i++)
      headers[i].group(1)!: section.substring(
        headers[i].end,
        i + 1 < headers.length ? headers[i + 1].start : section.length,
      ),
  };
}

String topLevel(String yaml, String key) =>
    RegExp('^$key: *(.+?) *\$', multiLine: true).firstMatch(yaml)!.group(1)!;

/// The pattern the Bugsee Gradle plugin strips from the merged manifest (the core's guard uses the
/// same one).
final strippedByGradlePlugin = RegExp(r'^.*\.Bugsee[A-Za-z0-9_]+InitProvider$');

void main() {
  final pins = jsonDecode(read('native-versions.json')) as Map<String, dynamic>;
  final android = pins['android'] as Map<String, dynamic>;
  final ios = pins['ios'] as Map<String, dynamic>;
  final flutterPin = pins['flutter'] as Map<String, dynamic>;
  final feedbackPin = pins['feedback'] as Map<String, dynamic>;

  final rootPubspec = read('pubspec.yaml');
  final feedbackPubspec = read('$pkg/pubspec.yaml');
  final coreVersion = topLevel(rootPubspec, 'version');

  group('layout and publishing', () {
    test('native-versions.json names the package and where it lives', () {
      expect(feedbackPin['dir'], pkg);
      expect(topLevel(feedbackPubspec, 'name'), feedbackPin['package']);
      expect(File('$pkg/pubspec.yaml').existsSync(), isTrue);
    });

    test(
      'the root pubspec is the pub workspace of the repo: both packages and the example',
      () {
        final workspace = RegExp(
          r'^workspace:\n((?:  - .+\n)+)',
          multiLine: true,
        ).firstMatch(rootPubspec)!.group(1)!;
        expect(
          workspace
              .split('\n')
              .where((l) => l.isNotEmpty)
              .map((l) => l.substring(4)),
          unorderedEquals([pkg, 'example']),
        );
        for (final member in [feedbackPubspec, read('example/pubspec.yaml')]) {
          expect(member, contains('\nresolution: workspace\n'));
        }
      },
    );

    test('the root package does not ship the sibling (or anything of it)', () {
      final pub = read('.pubignore');
      expect(pub, contains('\n/packages/\n'));
      // The example is not a package to publish either (it is `publish_to: none`).
      expect(read('example/pubspec.yaml'), contains("publish_to: 'none'"));
    });

    test(
      'the feedback package repeats .gitignore in .pubignore and drops its dev trees',
      () {
        final pub = read('$pkg/.pubignore');
        for (final rule
            in read('$pkg/.gitignore')
                .split('\n')
                .where(
                  (l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#'),
                )) {
          expect(pub, contains(rule), reason: '.pubignore lacks `$rule`');
        }
        expect(pub, contains('\n/ios/feedback_wrapper_tests/\n'));
        expect(pub, contains('\n/pigeons/\n'));
      },
    );

    test(
      'has its own LICENSE (pub publish needs one in the package root), the same text',
      () {
        expect(read('$pkg/LICENSE'), read('LICENSE'));
      },
    );

    test('has a README, a CHANGELOG and an example for pub.dev', () {
      for (final f in ['README.md', 'CHANGELOG.md', 'example/example.md']) {
        expect(File('$pkg/$f').existsSync(), isTrue, reason: f);
      }
    });

    test('same repository and issue tracker as the core', () {
      for (final key in ['repository', 'issue_tracker', 'homepage']) {
        expect(topLevel(feedbackPubspec, key), topLevel(rootPubspec, key));
      }
    });

    test('has no podspec: the iOS side is SwiftPM only, like the core', () {
      expect(
        Directory('$pkg/ios')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.podspec')),
        isEmpty,
      );
    });
  });

  group('the core works without it', () {
    test(
      'the core pubspec, Gradle file and manifest never mention the feedback package',
      () {
        expect(
          liveOf(rootPubspec).replaceAll(
            RegExp(r'^workspace:\n(  - .+\n)+', multiLine: true),
            '',
          ),
          isNot(contains('feedback')),
        );
        expect(code('android/build.gradle'), isNot(contains('feedback')));
        expect(
          read(
            'android/src/main/AndroidManifest.xml',
          ).replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ''),
          isNot(contains('eedback')),
        );
        expect(
          code('ios/bugsee_flutter/Package.swift'),
          isNot(contains('eedback')),
        );
        expect(
          code('ios/wrapper_tests/Package.swift'),
          isNot(contains('eedback')),
        );
      },
    );

    test(
      'no core source (Dart, Java, Swift, Objective-C) refers to the feedback module or SwiftUI',
      () {
        final sources = [
          ...filesUnder('lib', ['.dart']),
          ...filesUnder('android/src/main', ['.java', '.kt', '.xml']),
          ...filesUnder('ios/bugsee_flutter/Sources', ['.m', '.h', '.swift']),
          File('pigeons/bridge.dart'),
        ];
        for (final f in sources) {
          final text = code(f.path);
          expect(text, isNot(contains('BugseeFeedback')), reason: f.path);
          expect(
            text,
            isNot(contains('contracts.extensions.Feedback')),
            reason: f.path,
          );
          expect(
            text,
            isNot(contains('bugsee_flutter_feedback')),
            reason: f.path,
          );
          expect(text, isNot(contains('SwiftUI')), reason: f.path);
        }
      },
    );

    test(
      'the core bridge does not carry feedback calls (the feedback package has its own)',
      () {
        expect(
          read('pigeons/bridge.dart').toLowerCase(),
          isNot(contains('feedback')),
        );
      },
    );
  });

  group('version policy: released together, constrained to the same minor', () {
    test('the same version number as the core', () {
      expect(topLevel(feedbackPubspec, 'version'), coreVersion);
    });

    test('the Dart constant is the pubspec version', () {
      expect(
        read('$pkg/lib/src/feedback_version.dart'),
        contains("const String feedbackVersion = '$coreVersion';"),
      );
    });

    test(
      'depends on the core from that version up to, not including, the next minor',
      () {
        final m = RegExp(r'^\d+\.(\d+)\.\d+').firstMatch(coreVersion)!;
        final major = coreVersion.split('.').first;
        final next = '$major.${int.parse(m.group(1)!) + 1}.0';
        expect(
          feedbackPubspec,
          contains('\n  bugsee_flutter: ">=$coreVersion <$next"\n'),
          reason:
              'bump both packages and this constraint together (see feedback_version.dart)',
        );
        // Never a path or git dependency (not publishable); the workspace resolves it locally.
        expect(
          RegExp(
            r'bugsee_flutter:\s*\n\s+(path|git):',
          ).hasMatch(feedbackPubspec),
          isFalse,
        );
        expect(
          liveOf(feedbackPubspec),
          isNot(contains('dependency_overrides')),
        );
      },
    );

    test('the CHANGELOG starts with this version', () {
      expect(read('$pkg/CHANGELOG.md'), startsWith('## $coreVersion\n'));
    });

    test(
      'the same Dart and Flutter floors as the core, from native-versions.json',
      () {
        final dart = flutterPin['dart'] as String;
        final caret = '^${dart.split('.').take(2).join('.')}.0';
        expect(feedbackPubspec, contains('sdk: $caret'));
        expect(feedbackPubspec, contains('flutter: ">=${flutterPin['min']}"'));
        expect(topLevel(rootPubspec, 'version'), isNotEmpty);
      },
    );

    test(
      'depends on nothing the core does not: only flutter, bugsee_flutter and meta',
      () {
        final deps = RegExp(
          r'^dependencies:\n((?:  .+\n)+)',
          multiLine: true,
        ).firstMatch(feedbackPubspec)!.group(1)!;
        final names = RegExp(
          r'^  ([a-z_]+):',
          multiLine: true,
        ).allMatches(deps).map((m) => m.group(1)).toSet();
        expect(names, {'flutter', 'bugsee_flutter', 'meta'});
      },
    );
  });

  group('native pins', () {
    final gradle = read('$pkg/android/build.gradle');
    final manifest = read('$pkg/ios/bugsee_flutter_feedback/Package.swift');
    final testManifest = read('$pkg/ios/feedback_wrapper_tests/Package.swift');

    test('the Android artifact is the feedback module at android.sdk', () {
      expect(
        feedbackPin['androidArtifact'],
        'com.bugsee:bugsee-android-feedback',
      );
      expect(gradle, contains('def feedbackSdkVersion = "${android['sdk']}"'));
      expect(
        gradle,
        contains(
          'api "${feedbackPin['androidArtifact']}:\${feedbackSdkVersion}"',
        ),
      );
      expect(
        RegExp(r'com\.bugsee:bugsee-android[a-z-]*:\d').hasMatch(gradle),
        isFalse,
        reason:
            'a literal artifact version outside feedbackSdkVersion is not covered by the pins',
      );
    });

    test('minSdk is the SDK floor', () {
      expect(gradle, contains('def feedbackMinSdk = ${android['minSdk']}'));
      expect(gradle, contains('minSdk = feedbackMinSdk'));
    });

    test('Android is the same Gradle/AGP setup as the core', () {
      final core = read('android/build.gradle');
      for (final line in [
        'classpath("com.android.tools.build:gradle:8.11.1")',
        'compileSdk = 35',
        'sourceCompatibility = JavaVersion.VERSION_1_8',
      ]) {
        expect(core, contains(line));
        expect(gradle, contains(line));
      }
    });

    test(
      'iOS pins the core SPM package and the feedback add-on exactly, at ios.sdk',
      () {
        for (final m in [manifest, testManifest]) {
          expect(
            m,
            contains(
              '.package(url: "${ios['spmUrl']}", exact: "${ios['sdk']}")',
            ),
          );
          expect(
            m,
            contains(
              '.package(url: "${ios['feedbackSpmUrl']}", exact: "${ios['sdk']}")',
            ),
          );
          expect(m, contains('.iOS("${ios['deploymentTarget']}")'));
          expect(
            m,
            contains(
              '.product(name: "${feedbackPin['iosProduct']}", package: "feedback-spm")',
            ),
          );
        }
      },
    );

    test('and the core plugin pins the very same core package version', () {
      expect(
        read('ios/bugsee_flutter/Package.swift'),
        contains('.package(url: "${ios['spmUrl']}", exact: "${ios['sdk']}")'),
      );
    });

    test('committed Package.resolved files pin the feedback add-on too', () {
      final files = Process.runSync('git', [
        'ls-files',
        '*Package.resolved',
      ]).stdout.toString().trim().split('\n').where((f) => f.isNotEmpty);
      expect(files, isNotEmpty);
      for (final f in files) {
        final resolved = (jsonDecode(read(f))['pins'] as List)
            .cast<Map<String, dynamic>>();
        final feedback = resolved.where(
          (p) =>
              (p['location'] as String).toLowerCase() ==
              (ios['feedbackSpmUrl'] as String).toLowerCase(),
        );
        expect(
          feedback,
          hasLength(1),
          reason:
              '$f must pin ${ios['feedbackSpmUrl']} (the example uses the package)',
        );
        expect(
          feedback.single['state']['version'],
          ios['sdk'],
          reason: '$f drifted from native-versions.json',
        );
      }
    });
  });

  group('plugin identity', () {
    test(
      'the Dart, Android and iOS plugin classes are the ones the pubspec names',
      () {
        expect(
          feedbackPubspec,
          contains(
            'package: com.bugsee.flutter.feedback\n        pluginClass: BugseeFlutterFeedbackPlugin\n',
          ),
        );
        expect(
          feedbackPubspec,
          contains('ios:\n        pluginClass: BugseeFlutterFeedbackPlugin\n'),
        );
        expect(
          File(
            '$pkg/android/src/main/java/com/bugsee/flutter/feedback/BugseeFlutterFeedbackPlugin.java',
          ).existsSync(),
          isTrue,
        );
        expect(
          code(
            '$pkg/ios/bugsee_flutter_feedback/Sources/bugsee_flutter_feedback/BugseeFlutterFeedbackPlugin.swift',
          ),
          contains(
            'public class BugseeFlutterFeedbackPlugin: NSObject, FlutterPlugin',
          ),
        );
      },
    );

    test(
      'the Android namespace is the plugin package, and distinct from the core\'s',
      () {
        expect(
          read('$pkg/android/build.gradle'),
          contains('namespace = "com.bugsee.flutter.feedback"'),
        );
        expect(
          read('android/build.gradle'),
          contains('namespace = "com.bugsee.flutter"'),
        );
        expect(
          read('$pkg/android/settings.gradle'),
          contains("rootProject.name = 'bugsee_flutter_feedback'"),
        );
      },
    );

    test(
      'the SwiftPM library is the hyphenated plugin name Flutter looks for',
      () {
        final manifest = read('$pkg/ios/bugsee_flutter_feedback/Package.swift');
        expect(manifest, contains('name: "bugsee_flutter_feedback"'));
        expect(
          manifest,
          contains(
            '.library(name: "bugsee-flutter-feedback", targets: ["bugsee_flutter_feedback"])',
          ),
        );
      },
    );

    test('the Pigeon channels cannot collide with the core\'s', () {
      final dart = read('$pkg/lib/src/bridge/messages.g.dart');
      final channels = RegExp(
        r"'(dev\.flutter\.pigeon\.[^']+)\$",
      ).allMatches(dart);
      expect(channels, isNotEmpty);
      for (final c in channels) {
        expect(
          c.group(1),
          startsWith('dev.flutter.pigeon.bugsee_flutter_feedback.'),
        );
      }
    });

    test('nothing of the bridge is exported', () {
      final lib = read('$pkg/lib/bugsee_flutter_feedback.dart');
      expect(lib, isNot(contains('bridge')));
      expect(lib, isNot(contains('messages')));
      expect(lib, isNot(contains('runtime')));
    });
  });

  group('native registration', () {
    final androidSources = filesUnder('$pkg/android/src/main', [
      '.java',
      '.kt',
    ]);

    test(
      'the feedback module registers itself: this package adds no provider',
      () {
        final manifest = read(
          '$pkg/android/src/main/AndroidManifest.xml',
        ).replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
        expect(RegExp(r'<provider\b').hasMatch(manifest), isFalse);
        expect(manifest, isNot(contains('InitProvider')));
      },
    );

    test('no class of this package matches the name the Gradle plugin strips', () {
      for (final f in androidSources) {
        final text = code(f.path);
        final pkgName = RegExp(
          r'^package ([\w.]+);',
          multiLine: true,
        ).firstMatch(text)!.group(1)!;
        for (final m in RegExp(
          r'\b(?:class|interface|enum)\s+(\w+)',
        ).allMatches(text)) {
          expect(
            strippedByGradlePlugin.hasMatch('$pkgName.${m.group(1)}'),
            isFalse,
            reason:
                '${f.path}: ${m.group(1)} would be stripped from the manifest',
          );
        }
      }
      // The regex does catch the trap (guards the guard) and is the SDK's own provider's shape.
      expect(
        strippedByGradlePlugin.hasMatch(
          'com.bugsee.flutter.feedback.BugseeFeedbackInitProvider',
        ),
        isTrue,
      );
      expect(
        strippedByGradlePlugin.hasMatch(
          'com.bugsee.library.BugseeFeedbackInitProvider',
        ),
        isTrue,
      );
    });

    test(
      'Android: the SDK registrar is only called from the SDK seam, and it is the SDK\'s own method',
      () {
        final calls = androidSources
            .where((f) => code(f.path).contains('registerFeedbackExtension()'))
            .map((f) => f.path.split('/').last);
        expect(calls, ['BugseeFeedbackSdk.java']);
        expect(
          code(
            '$pkg/android/src/main/java/com/bugsee/flutter/feedback/BugseeFeedbackSdk.java',
          ),
          contains('import com.bugsee.library.BugseeFeedback;'),
        );
        // Called when the engine attaches, i.e. before Dart can launch the SDK.
        expect(
          code(
            '$pkg/android/src/main/java/com/bugsee/flutter/feedback/BugseeFlutterFeedbackPlugin.java',
          ),
          contains('if (sdk.registerIfMissing()) {'),
        );
      },
    );

    test(
      'Android: Bugsee.ext is asked for the Feedback contract interface, never the facade class',
      () {
        expect(
          code(
            '$pkg/android/src/main/java/com/bugsee/flutter/feedback/BugseeFeedbackSdk.java',
          ),
          contains('Bugsee.ext(Feedback.class)'),
        );
      },
    );

    test(
      'iOS: the add-on is registered at image load, once, and the plugin references that',
      () {
        final registrar = code(
          '$pkg/ios/bugsee_flutter_feedback/Sources/bugsee_flutter_feedback_wrapper/BGSFlutterFeedbackOps.m',
        );
        expect(
          registrar,
          matches(
            RegExp(r'\+ \(void\)load \{\s*\[self ensureRegistered\];\s*\}'),
          ),
        );
        expect(registrar, contains('dispatch_once(&gOnce'));
        expect(registrar, contains('[BugseeFeedback register];'));
        final plugin = code(
          '$pkg/ios/bugsee_flutter_feedback/Sources/bugsee_flutter_feedback/BugseeFlutterFeedbackPlugin.swift',
        );
        // The reference that keeps the translation unit (and its +load) in a static link.
        expect(
          plugin,
          contains('BGSFlutterFeedbackRegistrar.ensureRegistered()'),
        );
        expect(plugin, contains('registerIfMissing()'));
      },
    );

    test(
      'iOS: the wrapper target links the add-on product and imports its module',
      () {
        expect(
          read('$pkg/ios/bugsee_flutter_feedback/Package.swift'),
          contains('.product(name: "BugseeFeedback", package: "feedback-spm")'),
        );
        expect(
          code(
            '$pkg/ios/bugsee_flutter_feedback/Sources/bugsee_flutter_feedback_wrapper/BGSFlutterFeedbackOps.m',
          ),
          contains('@import BugseeFeedback;'),
        );
      },
    );

    test(
      'iOS: no header of the wrapper imports the add-on module (the Swift side must not need it)',
      () {
        for (final f in filesUnder(
          '$pkg/ios/bugsee_flutter_feedback/Sources/bugsee_flutter_feedback_wrapper/include',
          ['.h'],
        )) {
          expect(
            code(f.path),
            isNot(contains('BugseeFeedback;')),
            reason: f.path,
          );
        }
      },
    );
  });

  group('wire codes', () {
    final dart = read('$pkg/lib/src/errors.dart');
    final java = read(
      '$pkg/android/src/main/java/com/bugsee/flutter/feedback/FeedbackOps.java',
    );
    final objc = read(
      '$pkg/ios/bugsee_flutter_feedback/Sources/bugsee_flutter_feedback_wrapper/BGSFlutterFeedbackOps.m',
    );

    test('Dart, Java and Objective-C spell the failure codes alike', () {
      for (final (dartName, javaName, objcName, value) in [
        ('notRegistered', 'NOT_REGISTERED', 'kNotRegistered', 'not-registered'),
        ('sdkError', 'SDK_ERROR', 'kSdkError', 'sdk-error'),
      ]) {
        expect(dart, contains("static const $dartName = '$value';"));
        expect(java, contains('static final String $javaName = "$value";'));
        expect(objc, contains('static NSString *const $objcName = @"$value";'));
      }
    });

    test('the Dart mapping reads the not-registered code', () {
      expect(
        code('$pkg/lib/src/feedback_runtime.dart'),
        contains('FeedbackWire.notRegistered'),
      );
    });
  });

  group('pigeon', () {
    final pin = (pins['pigeon'] as Map<String, dynamic>)['version'] as String;

    test(
      'the generator package pins the same version, exactly, and its lock agrees',
      () {
        expect(
          read('$pkg/pigeons/pubspec.yaml'),
          matches(
            RegExp('^  pigeon: ${RegExp.escape(pin)}\$', multiLine: true),
          ),
        );
        expect(
          read('$pkg/pigeons/pubspec.lock'),
          matches(
            RegExp('pigeon:\\n(?:.*\\n)*?    version: "${RegExp.escape(pin)}"'),
          ),
        );
      },
    );

    test('every committed generated file was produced by that version', () {
      for (final f in [
        '$pkg/lib/src/bridge/messages.g.dart',
        '$pkg/android/src/main/java/com/bugsee/flutter/feedback/Messages.java',
        '$pkg/ios/bugsee_flutter_feedback/Sources/bugsee_flutter_feedback/Messages.g.swift',
      ]) {
        expect(
          read(f),
          contains('Autogenerated from Pigeon (v$pin)'),
          reason: f,
        );
      }
    });

    test('the definition writes exactly the three files the guards read', () {
      final outs =
          RegExp(
                r"^\s*(?:dart|java|swift)Out:\s*\n?\s*'([^']+)'",
                multiLine: true,
              )
              .allMatches(read('$pkg/pigeons/bridge.dart'))
              .map((m) => m.group(1))
              .toList();
      expect(outs, [
        '../lib/src/bridge/messages.g.dart',
        '../android/src/main/java/com/bugsee/flutter/feedback/Messages.java',
        '../ios/bugsee_flutter_feedback/Sources/bugsee_flutter_feedback/Messages.g.swift',
      ]);
    });

    test('pigeon is not a dependency of the package (needs a newer meta)', () {
      expect(feedbackPubspec, isNot(contains('pigeon:')));
    });
  });

  group('CI covers both packages', () {
    final ci = liveOf(read('.github/workflows/ci.yml'));
    final jobs = jobsOf(ci);
    String job(String id) => jobs[id]!;

    test(
      'the feedback bridge is checked and its generator package analyzed',
      () {
        final bridge = job('bridge-codegen');
        expect(
          bridge,
          contains('dart scripts/generate_pigeon.dart --package $pkg --check'),
        );
        expect(
          bridge,
          contains('cd $pkg/pigeons && dart analyze --fatal-infos'),
        );
      },
    );

    test(
      'the package is analyzed and tested next to the core, and the example builds with it',
      () {
        final test = job('test');
        expect(test, contains('cd $pkg && flutter analyze'));
        expect(test, contains('cd $pkg && flutter test'));
        expect(
          test,
          contains('cd example && flutter build ios --debug --no-codesign'),
        );
        expect(
          job('build-android'),
          contains('cd example && flutter build apk --debug'),
        );
      },
    );

    test(
      'the iOS glue tests run under the scheme the test package declares',
      () {
        expect(
          job('test'),
          contains('cd ../../$pkg/ios/feedback_wrapper_tests'),
        );
        expect(
          job('test'),
          contains(
            'xcodebuild test -scheme bugsee_flutter_feedback_wrapper_tests',
          ),
        );
        expect(
          read('$pkg/ios/feedback_wrapper_tests/Package.swift'),
          contains('name: "bugsee_flutter_feedback_wrapper_tests"'),
        );
      },
    );

    test('the JUnit tests of the glue run, under the Gradle project name', () {
      expect(
        job('build-android'),
        contains(':bugsee_flutter_feedback:testDebugUnitTest'),
      );
      expect(
        job('build-android'),
        contains(':bugsee_flutter:testDebugUnitTest'),
      );
    });

    test(
      'both packages are dry-run published, the core first, and the core is checked for the sibling',
      () {
        final publish = job('publish-check');
        final core = publish.indexOf('flutter pub publish --dry-run');
        final feedback = publish.indexOf('scripts/publish_feedback.sh');
        expect(core, isNonNegative);
        expect(feedback, greaterThan(core));
        expect(publish, contains('flutter pub publish --to-archive='));
        expect(
          publish,
          contains('scripts/check_pub_archive.sh "\$RUNNER_TEMP/core.tar.gz"'),
        );
      },
    );

    test(
      'the publish script dry-runs by default, publishes only on request, from a copy without git',
      () {
        final script = read('scripts/publish_feedback.sh');
        expect(script, contains('mode=(--dry-run)'));
        expect(script, contains('--publish) mode=() ;;'));
        expect(
          script,
          contains(
            'git -C "\$root" ls-files -z | rsync -a --from0 --files-from=-',
          ),
        );
        expect(script, contains('git -C "\$root" status --porcelain'));
        expect(script, contains('check_pub_archive.sh'));
        expect(script, contains('cd packages/bugsee_flutter_feedback'));
        expect(script, contains('flutter pub publish'));
        expect(
          File('scripts/publish_feedback.sh').statSync().mode & 0x40,
          isNonZero,
          reason: 'executable',
        );
      },
    );

    test(
      'no job was added for it (ci-ok and branch protection stay as they are)',
      () {
        final needs = RegExp(
          r'needs: \[([^\]]*)\]',
        ).firstMatch(job('ci-ok'))!.group(1)!;
        expect(needs.split(',').map((e) => e.trim()), [
          'format',
          'bridge-codegen',
          'options-codegen',
          'test',
          'build-android',
          'publish-check',
        ]);
      },
    );

    test(
      'Dependabot watches the package (pub and Gradle, never bumping Bugsee artifacts)',
      () {
        final dep = liveOf(read('.github/dependabot.yml'));
        expect(dep, contains('directory: /$pkg\n'));
        final gradle = RegExp(
          'package-ecosystem: gradle\\n\\s+directory: /$pkg/android\\n'
          r'(?:(?!  - package-ecosystem)[\s\S])*',
        ).firstMatch(dep)!;
        expect(gradle.group(0), contains('dependency-name: "com.bugsee*"'));
        expect(gradle.group(0), contains('target-branch: nextgen'));
      },
    );
  });

  group('publishing the sibling: what ends up in the archive', () {
    final junk = [
      '$pkg/android/local.properties',
      '$pkg/android/x.iml',
      '$pkg/lib/debug.log',
      'scratch-untracked.txt',
    ];

    void removeJunk() {
      for (final f in junk) {
        final file = File(f);
        if (file.existsSync()) file.deleteSync();
      }
    }

    setUp(removeJunk);
    tearDown(removeJunk);

    test(
      'the copy is made from tracked files only: untracked junk never reaches it',
      () {
        for (final f in junk) {
          File(
            f,
          ).writeAsStringSync('sdk.dir=/Users/someone/Library/Android/sdk\n');
        }
        final stage = Directory.systemTemp.createTempSync('stage');
        addTearDown(() => stage.deleteSync(recursive: true));
        final r = Process.runSync('bash', [
          'scripts/publish_feedback.sh',
          '--stage',
          stage.path,
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        for (final f in junk) {
          expect(
            File('${stage.path}/$f').existsSync(),
            isFalse,
            reason: '$f was copied',
          );
        }
        // What is tracked is there, symlinks included (the iOS test package's Sources).
        expect(File('${stage.path}/$pkg/pubspec.yaml').existsSync(), isTrue);
        expect(File('${stage.path}/pubspec.yaml').existsSync(), isTrue);
        expect(
          Link(
            '${stage.path}/$pkg/ios/feedback_wrapper_tests/Sources/BugseeFlutterFeedbackWrapper',
          ).existsSync(),
          isTrue,
        );
      },
    );

    /// A `flutter` that only records how it was called (and writes the archive it is asked for), so
    /// nothing here can reach pub.dev whatever the script does.
    Map<String, String> fakeFlutter(String log) {
      final bin = Directory.systemTemp.createTempSync('fakebin');
      addTearDown(() => bin.deleteSync(recursive: true));
      File('${bin.path}/flutter')
        ..writeAsStringSync('''#!/bin/sh
echo "\$PWD: \$*" >> "$log"
all="\$*"
case "\$all" in
  *--to-archive=*)
    f="\${all##*--to-archive=}"
    t="\$(mktemp -d)"
    echo x > "\$t/pubspec.yaml"
    if [ -n "\$FAKE_LEAK" ]; then mkdir -p "\$t/android"; echo sdk.dir=/x > "\$t/android/local.properties"; fi
    tar czf "\$f" -C "\$t" .
    ;;
esac
exit 0
''')
        ..createSync();
      Process.runSync('chmod', ['+x', '${bin.path}/flutter']);
      return {'PATH': '${bin.path}:${Platform.environment['PATH']}'};
    }

    String newLog() =>
        '${Directory.systemTemp.createTempSync('log').path}/calls';

    test('a real publish refuses a dirty tree before touching pub', () {
      // Not *.log: the root .gitignore ignores those, and an ignored file is not a dirty tree.
      File('scratch-untracked.txt').writeAsStringSync('x');
      addTearDown(() {
        final f = File('scratch-untracked.txt');
        if (f.existsSync()) f.deleteSync();
      });
      final log = newLog();
      final r = Process.runSync('bash', [
        'scripts/publish_feedback.sh',
        '--publish',
      ], environment: fakeFlutter(log));
      expect(r.exitCode, 1);
      expect('${r.stderr}', contains('dirty working tree'));
      expect(File(log).existsSync(), isFalse, reason: 'flutter was called');
    });

    test(
      'the default run only dry-runs, from the package in the copy, then checks its archive',
      () {
        final log = newLog();
        final r = Process.runSync('bash', [
          'scripts/publish_feedback.sh',
        ], environment: fakeFlutter(log));
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final calls = File(log).readAsLinesSync();
        expect(calls, hasLength(3));
        expect(calls[0], endsWith(': pub get'));
        // The archive is built (and checked) BEFORE anything is published.
        expect(calls[1], contains('pub publish --to-archive='));
        expect(
          calls[2],
          matches(
            RegExp(
              r'/packages/bugsee_flutter_feedback: pub publish --dry-run$',
            ),
          ),
        );
        expect(
          calls.where((c) => RegExp(r'pub publish$').hasMatch(c)),
          isEmpty,
        );
      },
    );

    test(
      'a leak in the sibling archive fails the script before anything is published',
      () {
        final log = newLog();
        final r = Process.runSync(
          'bash',
          ['scripts/publish_feedback.sh'],
          environment: {...fakeFlutter(log), 'FAKE_LEAK': '1'},
        );
        expect(r.exitCode, isNot(0));
        expect('${r.stderr}', contains('android/local.properties'));
        // Nothing is published (not even a dry run) after the check failed.
        final calls = File(log).readAsStringSync();
        expect(calls, isNot(contains('--dry-run')));
        expect(calls, isNot(matches(RegExp(r'pub publish$', multiLine: true))));
      },
    );

    test(
      'the archive check rejects every kind of leak and accepts a clean archive',
      () {
        Future<int> check(List<String> files) async {
          final dir = Directory.systemTemp.createTempSync('archive');
          addTearDown(() => dir.deleteSync(recursive: true));
          for (final f in files) {
            File('${dir.path}/src/$f')
              ..createSync(recursive: true)
              ..writeAsStringSync('x');
          }
          final tar = '${dir.path}/a.tar.gz';
          final made = Process.runSync('tar', [
            'czf',
            tar,
            '-C',
            '${dir.path}/src',
            '.',
          ]);
          expect(made.exitCode, 0);
          // tar lists "./name": the script must cope with it.
          return Process.runSync('bash', [
            'scripts/check_pub_archive.sh',
            tar,
          ]).exitCode;
        }

        expect(
          check([
            'pubspec.yaml',
            'lib/a.dart',
            'android/build.gradle',
            'ios/x/Package.swift',
            'CHANGELOG.md',
          ]),
          completion(0),
        );
        for (final leak in [
          'packages/bugsee_flutter_feedback/pubspec.yaml',
          'pigeons/bridge.dart',
          'ios/wrapper_tests/Package.swift',
          'ios/feedback_wrapper_tests/Package.swift',
          '.git/config',
          '.dart_tool/package_config.json',
          'build/x',
          'android/build/x',
          'android/.gradle/x',
          'ios/.build/x',
          'android/local.properties',
          'android/x.iml',
          'lib/debug.log',
          'Foo.class',
          '.idea/workspace.xml',
          'pubspec.lock',
          '.DS_Store',
        ]) {
          expect(check(['pubspec.yaml', leak]), completion(1), reason: leak);
        }
      },
    );

    test(
      'the package .gitignore and .pubignore carry the rules for local machine files',
      () {
        for (final f in ['$pkg/.gitignore', '$pkg/.pubignore']) {
          final text = read(f);
          for (final rule in [
            '*.iml',
            '*.log',
            '*.class',
            '.idea/',
            '/android/local.properties',
            '/android/.gradle/',
            '/android/build/',
          ]) {
            expect(text, contains('\n$rule\n'), reason: '$f lacks $rule');
          }
        }
      },
    );
  });

  group('the feedback package uses the core only through its public API', () {
    test(
      'no import of package:bugsee_flutter/src, and the version it checks is the public constant',
      () {
        for (final f in filesUnder('$pkg/lib', ['.dart'])) {
          expect(
            code(f.path),
            isNot(contains('package:bugsee_flutter/src/')),
            reason: f.path,
          );
        }
        expect(
          code('$pkg/lib/src/feedback_runtime.dart'),
          contains(
            "import 'package:bugsee_flutter/bugsee_flutter.dart' show bugseeFlutterVersion;",
          ),
        );
        expect(
          read('lib/src/wrapper_identity.dart'),
          contains('const String bugseeFlutterVersion = wrapperVersion;'),
        );
      },
    );
  });

  group('the workspace lock file is committed and used', () {
    test('tracked, not ignored, not published, built for the floor', () {
      final tracked = Process.runSync('git', [
        'ls-files',
        'pubspec.lock',
      ]).stdout.toString().trim();
      expect(tracked, 'pubspec.lock');
      expect(
        read('.gitignore').split('\n').map((l) => l.trim()),
        isNot(contains('/pubspec.lock')),
      );
      expect(read('.pubignore'), contains('\n/pubspec.lock\n'));
      final lock = read('pubspec.lock');
      expect(lock, contains('dart: ">=${flutterPin['dart']} <4.0.0"'));
      expect(lock, contains('flutter: ">=${flutterPin['min']}"'));
    });

    test(
      'every pub get in CI enforces it (the floor legs of the matrices; the stable legs may move)',
      () {
        final ci = liveOf(read('.github/workflows/ci.yml'));
        final lines = RegExp(
          r'^\s*- run: (flutter pub get.*)$',
          multiLine: true,
        ).allMatches(ci).map((m) => m.group(1)!).toList();
        expect(lines, hasLength(4));
        for (final l in lines) {
          expect(
            l == 'flutter pub get --enforce-lockfile' ||
                l ==
                    "flutter pub get \${{ matrix.channel == 'floor' && '--enforce-lockfile' || '' }}",
            isTrue,
            reason: l,
          );
        }
      },
    );
  });

  group('the example uses it', () {
    test('as a path dependency in the example app, and calls it', () {
      expect(
        read('example/pubspec.yaml'),
        contains(
          'bugsee_flutter_feedback:\n    path: ../packages/bugsee_flutter_feedback',
        ),
      );
      expect(
        read('example/lib/feedback_screen.dart'),
        contains(
          "import 'package:bugsee_flutter_feedback/bugsee_flutter_feedback.dart';",
        ),
      );
      expect(read('example/lib/main.dart'), contains('FeedbackScreen()'));
    });
  });
}
