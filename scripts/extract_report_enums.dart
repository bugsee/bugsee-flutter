// Extracts the report enum values from the two native SDKs' SOURCE into
// test/fixtures/report_enums.json, the fixture test/report_enum_parity_test.dart
// compares the Dart enums, the Java mapping and the Objective-C mapping against
// (workbook 7.4.2: extract from SDK source, do not hand-write; 7.4.3: compare both
// platforms, because a fixture from one SDK cannot see a divergence in the other).
//
// Run (inputs are the files at the pinned versions, native-versions.json):
//
//   git -C <android sdk> show v7.4.2:library/src/main/java/com/bugsee/library/contracts/options/IssueSeverity.java > /tmp/IssueSeverity.java
//   git -C <android sdk> show v7.4.2:library/src/main/java/com/bugsee/library/contracts/options/IssueType.java > /tmp/IssueType.java
//   # iOS: the headers the pinned xcframework ships (Bugsee.framework/Headers)
//   dart scripts/extract_report_enums.dart --android-severity /tmp/IssueSeverity.java \
//     --android-type /tmp/IssueType.java --ios-constants .../BugseeConstants.h \
//     --ios-contracts .../BGSContracts.h \
//     --android-coordinator /tmp/BugseeIssueReportingCoordinator.java \
//     --android-chain /tmp/ReportHandlerChain.java --android-options /tmp/OptionsDescriptors.java \
//     --ios-coordinator /tmp/BGSIssueReportingCoordinator.m --ios-source-ref origin/nextgen@0581aa02c [--check]
//
// The same fixture also carries the SDKs' report-handler TIMINGS (workbook 7.3.5), read from
// source, so the wrapper's deadlines are compared with the SDK's real numbers and not with
// copies of themselves. The iOS timings are constants of a .m that the shipped binary does not
// expose: they come from the nextgen commit named by --ios-source-ref (no 7.0.0-beta7 tag exists
// in the iOS SDK repository; the shipped headers equal nextgen's).
//
// `--check` compares with the committed fixture instead of writing it. The fixture
// records the pins it was extracted at; test/report_enum_parity_test.dart fails when
// they stop matching native-versions.json, so bumping a native pin without
// re-extracting is caught.
import 'dart:convert';
import 'dart:io';

/// Source with comments removed, so a commented-out member is not read as real.
String stripComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// `Name(1)` (or `Name((byte)1)`) members of a Java enum, by the enum's declared name.
Map<String, int> javaIntEnum(String source, String enumName) {
  final body = _javaEnumBody(stripComments(source), enumName);
  return {
    for (final m in RegExp(
      r'(\w+)\(\s*(?:\(byte\)\s*)?(-?\d+)\s*\)\s*[,;]',
    ).allMatches(body))
      m.group(1)!: int.parse(m.group(2)!),
  };
}

/// `Name("text")` members of a Java enum.
Map<String, String> javaStringEnum(String source, String enumName) {
  final body = _javaEnumBody(stripComments(source), enumName);
  return {
    for (final m in RegExp(r'(\w+)\(\s*"([^"]*)"\s*\)\s*[,;]').allMatches(body))
      m.group(1)!: m.group(2)!,
  };
}

String _javaEnumBody(String clean, String enumName) {
  final start = RegExp('enum\\s+$enumName\\b[^{]*\\{').firstMatch(clean);
  if (start == null) throw FormatException('no enum $enumName');
  // The constants end at the first `;` that follows the last member.
  final rest = clean.substring(start.end);
  final end = rest.indexOf(';');
  return end < 0 ? rest : rest.substring(0, end + 1);
}

/// `NAME = 3000L;` / `NAME = 60_000L;` in Java.
int javaLong(String source, String name) {
  final m = RegExp(
    '$name\\s*=\\s*([\\d_]+)L',
  ).firstMatch(stripComments(source));
  if (m == null) throw FormatException('no constant $name');
  return int.parse(m.group(1)!.replaceAll('_', ''));
}

/// The default of `OptionDescriptor.createAndRegister(Options.NAME, Integer.class, 30)`.
int javaOptionDefault(String source, String option) {
  final m = RegExp(
    'Options\\.$option\\s*,\\s*Integer\\.class\\s*,\\s*(\\d+)',
  ).firstMatch(stripComments(source));
  if (m == null) throw FormatException('no option $option');
  return int.parse(m.group(1)!);
}

/// `static const NSTimeInterval NAME = 30.0;` in Objective-C.
num objcSeconds(String source, String name) {
  final m = RegExp(
    '$name\\s*=\\s*([\\d.]+)\\s*;',
  ).firstMatch(stripComments(source));
  if (m == null) throw FormatException('no constant $name');
  return num.parse(m.group(1)!);
}

/// `typedef enum : T { A = 1, B = 2 } Name;` and `typedef NS_ENUM(T, Name) { ... };`.
Map<String, int> objcEnum(String source, String enumName) {
  final clean = stripComments(source);
  final trailing = RegExp(
    r'typedef\s+enum\s*(?::\s*[\w ]+)?\s*\{([^}]*)\}\s*(\w+)\s*;',
  );
  final nsEnum = RegExp(
    r'typedef\s+NS_(?:ENUM|OPTIONS)\s*\(\s*[\w ]+\s*,\s*(\w+)\s*\)\s*\{([^}]*)\}',
  );
  String? body;
  for (final m in trailing.allMatches(clean)) {
    if (m.group(2) == enumName) body = m.group(1);
  }
  for (final m in nsEnum.allMatches(clean)) {
    if (m.group(1) == enumName) body = m.group(2);
  }
  if (body == null) throw FormatException('no enum $enumName');
  final out = <String, int>{};
  var next = 0;
  for (final entry in body.split(',')) {
    final m = RegExp(r'^\s*(\w+)\s*(?:=\s*(-?\d+)\s*)?$').firstMatch(entry);
    if (m == null) continue;
    final value = m.group(2) == null ? next : int.parse(m.group(2)!);
    out[m.group(1)!] = value;
    next = value + 1;
  }
  return out;
}

/// The strings iOS's `BGSReportContract.type` documents (`@"bug"`, ...), read from the
/// doc comment on the property, which is where the SDK states them.
List<String> iosTypeStrings(String contractsHeader) {
  final line = RegExp(
    r'///\s*The issue type:[^\n]*',
  ).firstMatch(contractsHeader);
  if (line == null) throw const FormatException('no "The issue type" comment');
  return [
    for (final m in RegExp(r'`@"(\w+)"`').allMatches(line.group(0)!))
      m.group(1)!,
  ];
}

Map<String, Object?> extract({
  required String androidSeverity,
  required String androidType,
  required String iosConstants,
  required String iosContracts,
  required String androidCoordinator,
  required String androidChain,
  required String androidOptions,
  required String iosCoordinator,
  required String iosSourceRef,
  required Map<String, Object?> pins,
}) => {
  '_comment':
      'Extracted from the native SDK sources by scripts/extract_report_enums.dart; '
      'do not edit by hand. Compared by test/report_enum_parity_test.dart.',
  'pins': pins,
  'android': {
    'IssueSeverity': javaIntEnum(androidSeverity, 'IssueSeverity'),
    'IssueType': javaStringEnum(androidType, 'IssueType'),
    'reportHandlerTimings': {
      'terminatingCapMs': javaLong(
        androidCoordinator,
        'TERMINATING_HANDLER_CAP_MILLIS',
      ),
      'chainCapMs': javaLong(androidChain, 'HANDLER_CHAIN_CAP_MILLIS'),
      'handlerTimeoutDefaultSeconds': javaOptionDefault(
        androidOptions,
        'ReportHandlerCallbackTimeout',
      ),
    },
  },
  'ios': {
    'BugseeSeverityLevel': objcEnum(iosConstants, 'BugseeSeverityLevel'),
    'issueTypeStrings': iosTypeStrings(iosContracts),
    'reportHandlerTimings': {
      'source': iosSourceRef,
      'handlerTimeoutSeconds': objcSeconds(
        iosCoordinator,
        'kBGSReportHandlerCallbackTimeoutSeconds',
      ),
      'chainTimeoutSeconds': objcSeconds(
        iosCoordinator,
        'kBGSReportHandlerChainTimeoutSeconds',
      ),
      'boundedCapSeconds': objcSeconds(
        iosCoordinator,
        'kBGSBoundedReportHandlerCapSeconds',
      ),
    },
  },
};

String arg(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) {
    stderr.writeln('missing $name');
    exit(2);
  }
  return args[i + 1];
}

void main(List<String> args) {
  final root = File.fromUri(Platform.script).parent.parent.path;
  final versions =
      jsonDecode(File('$root/native-versions.json').readAsStringSync()) as Map;
  final fixture = extract(
    androidSeverity: File(arg(args, '--android-severity')).readAsStringSync(),
    androidType: File(arg(args, '--android-type')).readAsStringSync(),
    iosConstants: File(arg(args, '--ios-constants')).readAsStringSync(),
    iosContracts: File(arg(args, '--ios-contracts')).readAsStringSync(),
    androidCoordinator: File(
      arg(args, '--android-coordinator'),
    ).readAsStringSync(),
    androidChain: File(arg(args, '--android-chain')).readAsStringSync(),
    androidOptions: File(arg(args, '--android-options')).readAsStringSync(),
    iosCoordinator: File(arg(args, '--ios-coordinator')).readAsStringSync(),
    iosSourceRef: arg(args, '--ios-source-ref'),
    pins: {
      'android': (versions['android'] as Map)['sdk'],
      'ios': (versions['ios'] as Map)['sdk'],
    },
  );
  final text = '${const JsonEncoder.withIndent('  ').convert(fixture)}\n';
  final path = '$root/test/fixtures/report_enums.json';
  if (args.contains('--check')) {
    if (File(path).readAsStringSync() != text) {
      stderr.writeln('$path is stale; re-run without --check');
      exit(1);
    }
    stdout.writeln('report enum fixture is current');
    return;
  }
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  stdout.writeln('wrote $path');
}
