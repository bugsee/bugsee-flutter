// Drift guards for what launch, stop and the options repeat across Dart, Java and Objective-C.
//
// The strings of the bridge vocabulary, the status names and the error code exist three times (the
// native sides answer before Dart can look), and the Android enum table repeats the manifest. Each
// copy is compared with its source, so editing one without the others fails here.
import 'dart:io';

import 'package:bugsee_flutter/src/launch.dart';
import 'package:bugsee_flutter/src/options/launch_options.dart'
    show bundledModules;
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:bugsee_flutter/src/options/option_registry.g.dart';
import 'package:bugsee_flutter/src/status.dart';
import 'package:flutter_test/flutter_test.dart';

const java = 'android/src/main/java/com/bugsee/flutter';
const objc = 'ios/bugsee_flutter/Sources/bugsee_flutter_wrapper';

String read(String path) => File(path).readAsStringSync();

/// `static final String NAME = "value";` in Java.
Map<String, String> javaStrings(String source) => {
  for (final m in RegExp(
    r'static final String (\w+) = "([^"]*)";',
  ).allMatches(source))
    m.group(1)!: m.group(2)!,
};

/// `static NSString *const kName = @"value";` in Objective-C.
Map<String, String> objcStrings(String source) => {
  for (final m in RegExp(
    r'static NSString \*const (k\w+) = @"([^"]*)";',
  ).allMatches(source))
    m.group(1)!: m.group(2)!,
};

void main() {
  final javaOps = read('$java/LaunchOps.java');
  final objcOps = read('$objc/BGSFlutterLaunchOps.m');
  final wire = {
    LaunchWire.launched,
    LaunchWire.alreadyRunning,
    LaunchWire.deferred,
    LaunchWire.refused,
    LaunchWire.invalidToken,
    LaunchWire.stopping,
    LaunchWire.failed,
    LaunchWire.errorCode,
  };

  group('the launch vocabulary is the same in Dart, Java and Objective-C', () {
    test('Objective-C has every string, and no other', () {
      expect(objcStrings(objcOps).values.toSet(), wire);
    });

    test(
      'Java has every string it answers with (it never answers "deferred": iOS only)',
      () {
        expect(
          javaStrings(javaOps).values.toSet(),
          wire.difference({LaunchWire.deferred}).union({LaunchWire.deferred}),
        );
        final answered = {
          for (final name in [
            'LAUNCHED',
            'ALREADY_RUNNING',
            'REFUSED',
            'INVALID_TOKEN',
            'STOPPING',
            'FAILED',
            'ERROR_CODE',
          ])
            javaStrings(javaOps)[name],
        };
        expect(answered, wire.difference({LaunchWire.deferred}));
      },
    );

    test(
      'the pairing of names to values is the same (a swap would still be "all there")',
      () {
        final j = javaStrings(javaOps);
        final o = objcStrings(objcOps);
        expect(j['LAUNCHED'], LaunchWire.launched);
        expect(j['ALREADY_RUNNING'], LaunchWire.alreadyRunning);
        expect(j['REFUSED'], LaunchWire.refused);
        expect(j['INVALID_TOKEN'], LaunchWire.invalidToken);
        expect(j['STOPPING'], LaunchWire.stopping);
        expect(j['FAILED'], LaunchWire.failed);
        expect(j['ERROR_CODE'], LaunchWire.errorCode);
        expect(o['kLaunched'], LaunchWire.launched);
        expect(o['kAlreadyRunning'], LaunchWire.alreadyRunning);
        expect(o['kDeferred'], LaunchWire.deferred);
        expect(o['kRefused'], LaunchWire.refused);
        expect(o['kInvalidToken'], LaunchWire.invalidToken);
        expect(o['kStopping'], LaunchWire.stopping);
        expect(o['kFailed'], LaunchWire.failed);
        expect(o['kErrorCode'], LaunchWire.errorCode);
      },
    );

    test(
      'the Swift plugin takes the error code from Objective-C, not a literal',
      () {
        final swift = read(
          'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
        );
        expect(swift, contains('BGSFlutterLaunchOps.errorCode'));
        expect(swift, isNot(contains('"launch-failed"')));
        expect(
          read('$java/BugseeFlutterPlugin.java'),
          contains('LaunchOps.ERROR_CODE'),
        );
        expect(
          read('$java/BugseeFlutterPlugin.java'),
          isNot(contains('"launch-failed"')),
        );
      },
    );

    test(
      'the pigeon definition documents each outcome and reason it carries',
      () {
        final bridge = read('pigeons/bridge.dart');
        for (final s in wire.difference({LaunchWire.errorCode})) {
          expect(
            bridge,
            contains(s),
            reason: 'pigeons/bridge.dart does not mention "$s"',
          );
        }
      },
    );
  });

  group('status crosses by name', () {
    test(
      'iOS answers exactly the Dart names, and the Dart names are the lower-cased SDK ones',
      () {
        final names = {
          for (final m in RegExp(r'return @"(\w+)";').allMatches(
            objcOps
                .split('@implementation BGSFlutterRealBugsee')[1]
                .split('@end')
                .first,
          ))
            m.group(1)!,
        };
        expect(names, BugseeStatus.values.map((s) => s.name).toSet());
      },
    );

    test('Android lower-cases the SDK constant NAME, never the ordinal', () {
      expect(javaOps, contains('status.name().toLowerCase(Locale.ROOT)'));
      expect(javaOps, isNot(contains('ordinal()')));
    });
  });

  group('the Android enum table is the registry', () {
    test('its keys are the enum options of the bundled Android modules', () {
      final table = {
        for (final m in RegExp(
          r'table\.put\("([^"]+)", (\w+)\);',
        ).allMatches(read('$java/LaunchOptionValues.java')))
          m.group(1)!,
      };
      final expected = {
        for (final s in optionSpecs)
          if (s.type == OptionType.enumeration &&
              s.android != null &&
              bundledModules[OptionPlatform.android]!.contains(
                s.android!.module,
              ))
            s.key,
      };
      expect(table, expected);
      expect(table.length, 7);
    });
  });

  group('nothing is translated per platform', () {
    test('Objective-C names no option key (the namespace is shared)', () {
      expect(objcOps, isNot(contains('com.bugsee.option')));
      expect(
        read('$objc/include/BGSFlutterLaunchOps.h'),
        isNot(contains('com.bugsee.option')),
      );
    });

    test('Java names option keys only in the enum table', () {
      final source = read('$java/LaunchOptionValues.java');
      for (final line in source.split('\n')) {
        if (line.contains('com.bugsee.option')) {
          final isTable = line.trimLeft().startsWith(
            'table.put("com.bugsee.option.',
          );
          final isDoc =
              line.trimLeft().startsWith('*') ||
              line.trimLeft().startsWith('//');
          expect(isTable || isDoc, isTrue, reason: line);
        }
      }
      for (final f in Directory(
        java,
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.java'))) {
        if (f.path.endsWith('LaunchOptionValues.java') ||
            f.path.endsWith('Messages.java')) {
          continue;
        }
        expect(
          f.readAsStringSync(),
          isNot(contains('"com.bugsee.option')),
          reason: f.path,
        );
      }
    });

    test(
      'the hidden endpoint key is spelled once in Dart lib code (comments aside)',
      () {
        final hits = <String>{};
        for (final f
            in Directory('lib')
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.endsWith('.dart'))) {
          if (f.path.endsWith('.g.dart')) continue;
          for (final line in f.readAsLinesSync()) {
            if (!line.trimLeft().startsWith('//') &&
                RegExp(r'\\?\$\\?\$ENDPOINT').hasMatch(line)) {
              hits.add(f.path.split('/').last);
            }
          }
        }
        expect(hits, {'endpoint.dart'});
      },
    );
  });
}
