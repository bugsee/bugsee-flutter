// Drift guards for the report enums (workbook 7.4): values cross by VALUE, never by
// ordinal or name, and both platforms are compared (a fixture extracted from one SDK
// cannot see a divergence in the other).
//
// The fixture test/fixtures/report_enums.json is extracted from the two SDKs' source by
// scripts/extract_report_enums.dart. The JUnit test (ReportOpsTest, ReportEnumParityTest)
// and the XCTest (BGSFlutterReportOpsTests) compare the Java and Objective-C mappings with
// the SDKs' REAL enums at the pinned versions; this file compares everything that is
// repeated as text.
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/src/report/report_enums.dart';
import 'package:flutter_test/flutter_test.dart';

import '../scripts/extract_report_enums.dart' as extract;

Map<String, Object?> json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

String code(String path) =>
    extract.stripComments(File(path).readAsStringSync());

const java = 'android/src/main/java/com/bugsee/flutter';
const objc = 'ios/bugsee_flutter/Sources/bugsee_flutter_wrapper';

String lowerFirst(String s) => s[0].toLowerCase() + s.substring(1);

void main() {
  final fixture = json('test/fixtures/report_enums.json');
  final android = fixture['android']! as Map<String, Object?>;
  final ios = fixture['ios']! as Map<String, Object?>;
  final androidSeverity = (android['IssueSeverity']! as Map)
      .cast<String, int>();
  final iosSeverity = (ios['BugseeSeverityLevel']! as Map).cast<String, int>();

  group('the fixture is current', () {
    test('it was extracted at the pinned native versions', () {
      final pins = json('native-versions.json');
      final at = fixture['pins']! as Map<String, Object?>;
      expect(at['android'], (pins['android']! as Map)['sdk']);
      expect(at['ios'], (pins['ios']! as Map)['sdk']);
    });
  });

  group('IssueSeverity agrees across platforms and with Dart, by value', () {
    test('both SDKs and Dart assign the same set of values', () {
      final dart = ReportSeverity.values.map((s) => s.value).toSet();
      expect(androidSeverity.values.toSet(), dart);
      expect(iosSeverity.values.toSet(), dart);
      expect(dart, {1, 2, 3, 4, 5});
    });

    test('every Dart severity maps to the SDKs member of the same value', () {
      for (final s in ReportSeverity.values) {
        expect(
          androidSeverity[androidSeverity.keys.firstWhere(
            (k) => androidSeverity[k] == s.value,
          )],
          s.value,
        );
        expect(ReportSeverity.fromValue(s.value), same(s));
      }
    });

    test('names agree except for the ONE known divergence at value 1', () {
      // Android VeryLow, iOS Low. A list that silently absorbed new entries would look
      // like coverage, so the exception is exactly this one.
      const knownIosAlias = {'Low': 'VeryLow'};
      final iosNames = {
        for (final e in iosSeverity.entries)
          e.value: () {
            final bare = e.key.replaceFirst('BugseeSeverity', '');
            return knownIosAlias[bare] ?? bare;
          }(),
      };
      final androidNames = {
        for (final e in androidSeverity.entries) e.value: e.key,
      };
      expect(iosNames, androidNames);
      expect(
        {for (final s in ReportSeverity.values) s.value: s.name},
        {for (final e in androidNames.entries) e.key: lowerFirst(e.value)},
      );
      // The iOS spelling is available under its own name, for the same value.
      expect(ReportSeverity.low, same(ReportSeverity.veryLow));
      expect(ReportSeverity.low.value, iosSeverity['BugseeSeverityLow']);
    });

    test('Blocker stays the highest on every platform', () {
      expect(androidSeverity['Blocker'], 5);
      expect(iosSeverity['BugseeSeverityBlocker'], 5);
      expect(ReportSeverity.blocker.value, 5);
    });

    test('a value outside the range is no severity, "never set" included', () {
      for (final v in [0, -1, 6, 100, null]) {
        expect(ReportSeverity.fromValue(v), isNull, reason: '$v');
      }
    });

    test(
      'the accepted range is repeated alike in Dart, Java and Objective-C',
      () {
        final values = androidSeverity.values;
        final lo = values.reduce((a, b) => a < b ? a : b);
        final hi = values.reduce((a, b) => a > b ? a : b);
        expect([ReportSeverity.minValue, ReportSeverity.maxValue], [lo, hi]);
        final j = code('$java/ReportOps.java');
        expect(
          RegExp(r'MIN_SEVERITY\s*=\s*(\d+)').firstMatch(j)!.group(1),
          '$lo',
        );
        expect(
          RegExp(r'MAX_SEVERITY\s*=\s*(\d+)').firstMatch(j)!.group(1),
          '$hi',
        );
        final m = code('$objc/BGSFlutterReportOps.m');
        expect(
          RegExp(r'minSeverity\s*\{\s*return\s+(\d+);').firstMatch(m)!.group(1),
          '$lo',
        );
        expect(
          RegExp(r'maxSeverity\s*\{\s*return\s+(\d+);').firstMatch(m)!.group(1),
          '$hi',
        );
      },
    );
  });

  group('IssueType agrees across platforms and with Dart', () {
    test('Android toString(), iOS strings and Dart wire names are the same', () {
      final androidWire = (android['IssueType']! as Map).cast<String, String>();
      final iosWire = (ios['issueTypeStrings']! as List).cast<String>();
      final dart = ReportType.values.map((t) => t.wire).toList();
      expect(androidWire.values.toList(), dart);
      expect(iosWire, dart);
      // The enum NAME is not the wire value ("Crash" vs "crash"): the wire one crosses.
      expect(androidWire.keys.map(lowerFirst).toList(), dart);
      expect(
        androidWire.keys.toList(),
        ReportType.values.map(
          (t) => t.name[0].toUpperCase() + t.name.substring(1),
        ),
      );
    });

    test('an unknown type is not guessed', () {
      expect(ReportType.fromWire('anr'), isNull);
      expect(ReportType.fromWire(''), isNull);
      expect(ReportType.fromWire(null), isNull);
      expect(ReportType.fromWire('crash'), ReportType.crash);
    });
  });

  group('nothing crosses by ordinal', () {
    test(
      'the bridge definition declares no enum (Pigeon sends enums as ordinals)',
      () {
        expect(
          RegExp(
            r'^\s*enum\s',
            multiLine: true,
          ).hasMatch(code('pigeons/bridge.dart')),
          isFalse,
        );
        expect(
          RegExp(
            r'^\s*enum\s',
            multiLine: true,
          ).hasMatch(code('lib/src/bridge/messages.g.dart')),
          isFalse,
          reason: 'a generated enum would be sent as its index',
        );
      },
    );

    test('no code under lib/src/report or the report glue uses an ordinal', () {
      final files = [
        for (final f in Directory('lib/src/report').listSync())
          if (f is File && f.path.endsWith('.dart')) f.path,
        'lib/src/bridge/bridge.dart',
        '$java/ReportOps.java',
        '$java/ReportHandlerPipeline.java',
        '$java/BugseeFlutterPlugin.java',
        '$objc/BGSFlutterReportOps.m',
        '$objc/BGSFlutterReportHandlerPipeline.m',
        'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
      ];
      for (final path in files) {
        final text = code(path);
        expect(text, isNot(contains('.ordinal()')), reason: path);
        expect(RegExp(r'\.index\b').hasMatch(text), isFalse, reason: path);
        expect(text, isNot(contains('.byName')), reason: path);
      }
    });
  });

  group('the extraction script reads what the SDKs write', () {
    test('Java int and string enums, comments ignored', () {
      const src = '''
public enum IssueSeverity implements Foo {
    /** doc mentioning Medium(2) */
    VeryLow(1),
    // Hidden(9),
    Medium(2),
    Blocker(5);
    private final int v;
}''';
      expect(extract.javaIntEnum(src, 'IssueSeverity'), {
        'VeryLow': 1,
        'Medium': 2,
        'Blocker': 5,
      });
      expect(
        extract.javaStringEnum(
          'enum IssueType { Bug("bug"), Crash("crash"); }',
          'IssueType',
        ),
        {'Bug': 'bug', 'Crash': 'crash'},
      );
      expect(() => extract.javaIntEnum(src, 'Nope'), throwsFormatException);
    });

    test('Objective-C enums: trailing typedef, NS_ENUM, implicit values', () {
      const trailing = '''
typedef enum : NSUInteger {
    /** Low = 99 */
    BugseeSeverityLow = 1,
    BugseeSeverityMedium = 2
} BugseeSeverityLevel;''';
      expect(extract.objcEnum(trailing, 'BugseeSeverityLevel'), {
        'BugseeSeverityLow': 1,
        'BugseeSeverityMedium': 2,
      });
      const ns = 'typedef NS_ENUM(NSInteger, BGSIssueType) { A = 0, B, C };';
      expect(extract.objcEnum(ns, 'BGSIssueType'), {'A': 0, 'B': 1, 'C': 2});
      expect(() => extract.objcEnum(ns, 'Other'), throwsFormatException);
    });

    test('timings: Java constants, the option default and Objective-C seconds', () {
      expect(
        extract.javaLong('static final long A_MS = 3000L; // 1L', 'A_MS'),
        3000,
      );
      expect(extract.javaLong('X_CAP = 60_000L;', 'X_CAP'), 60000);
      expect(() => extract.javaLong('nothing', 'X_CAP'), throwsFormatException);
      const options =
          'createAndRegister(Options.ReportHandlerCallbackTimeout, Integer.class, 30);'
          ' // Options.Other, Integer.class, 99';
      expect(
        extract.javaOptionDefault(options, 'ReportHandlerCallbackTimeout'),
        30,
      );
      expect(
        () => extract.javaOptionDefault(options, 'Nope'),
        throwsFormatException,
      );
      const m =
          'static const NSTimeInterval kA = 30.0;\n// kB = 9.0;\nstatic const NSTimeInterval kB = 3.0;';
      expect(extract.objcSeconds(m, 'kA'), 30.0);
      expect(extract.objcSeconds(m, 'kB'), 3.0);
      expect(() => extract.objcSeconds(m, 'kC'), throwsFormatException);
    });

    test('the iOS type strings come from the property documentation', () {
      const header =
          '/// The issue type: `@"bug"`, `@"crash"` or `@"error"`. Readonly.\n'
          '@property NSString *type;';
      expect(extract.iosTypeStrings(header), ['bug', 'crash', 'error']);
      expect(() => extract.iosTypeStrings('nothing'), throwsFormatException);
    });
  });
}
