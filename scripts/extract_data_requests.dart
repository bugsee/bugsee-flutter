// Extracts what the native SDKs' SOURCE says about the `vh` data request (the managed view
// hierarchy) into test/fixtures/data_requests.json, the fixture
// test/view_hierarchy_drift_test.dart compares the wrapper's Java and Objective-C copies against
// (workbook 6: the type string and the budget are the SDK's, not ours; a number copied from a
// spec, or from the wrapper itself, cannot see the SDK change).
//
// Run (the iOS constants are in a .m the shipped binary does not expose, so they come from the
// nextgen commit named by --ios-source-ref; no 7.0.0-beta7 tag exists in the iOS repository):
//
//   git -C <android sdk> show v7.4.2:library/src/main/java/com/bugsee/library/contracts/internal/DataRequestTypes.java > /tmp/DataRequestTypes.java
//   git -C <android sdk> show v7.4.2:library/src/main/java/com/bugsee/library/capture/providers/vh/BugseeCaptureDataProviderViewHierarchy.java > /tmp/AndroidVH.java
//   git -C <ios sdk> show origin/nextgen:BugseeDev/BugseeLib/BugseeLib/Capture/Providers/ViewHierarchy/BGSCaptureDataProviderViewHierarchy.m > /tmp/IosVH.m
//   dart scripts/extract_data_requests.dart --android-types /tmp/DataRequestTypes.java \
//     --android-provider /tmp/AndroidVH.java --ios-provider /tmp/IosVH.m \
//     --ios-source-ref origin/nextgen@0581aa02c [--check]
//
// `--check` compares with the committed fixture instead of writing it. The fixture records the
// pins it was extracted at; the drift test fails when they stop matching native-versions.json.
import 'dart:convert';
import 'dart:io';

String stripComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

String _one(String source, RegExp pattern, String what) {
  final m = pattern.firstMatch(source);
  if (m == null) throw FormatException('not found in the SDK source: $what');
  return m.group(1)!;
}

Map<String, Object?> extract({
  required String androidTypes,
  required String androidProvider,
  required String iosProvider,
  required String iosSourceRef,
  required Map<String, Object?> pins,
}) {
  final at = stripComments(androidTypes);
  final ap = stripComments(androidProvider);
  final ip = stripComments(iosProvider);
  return {
    '_comment':
        'Extracted from the native SDK sources by scripts/extract_data_requests.dart; do not edit by hand. Compared by test/view_hierarchy_drift_test.dart.',
    'pins': pins,
    'android': {
      'vhType': _one(
        at,
        RegExp(r'VIEW_HIERARCHY\s*=\s*"([^"]*)"'),
        'VIEW_HIERARCHY',
      ),
      'vhBudgetMs': int.parse(
        _one(
          at,
          RegExp(r'VIEW_HIERARCHY_TIMEOUT_MS\s*=\s*(\d+)'),
          'VIEW_HIERARCHY_TIMEOUT_MS',
        ),
      ),
      'snapshotCaptureTimeoutMs': int.parse(
        _one(
          ap,
          RegExp(r'SNAPSHOT_CAPTURE_TIMEOUT_MS\s*=\s*(\d+)'),
          'SNAPSHOT_CAPTURE_TIMEOUT_MS',
        ),
      ),
      // The SDK waits for a late reply only when the snapshot is made OFF the main thread.
      'waitsForReplyOffMainThreadOnly':
          ap.contains('!BugseeHandlerWrapper.isMainThread()') &&
          ap.contains('barrier.awaitAll'),
    },
    'ios': {
      'source': iosSourceRef,
      'vhType': _one(
        ip,
        RegExp(r'BGSManagedHierarchyDataType\s*=\s*@"([^"]*)"'),
        'BGSManagedHierarchyDataType',
      ),
      'vhBudgetMs': int.parse(
        _one(
          ip,
          RegExp(r'BGSManagedHierarchyTimeoutMs\s*=\s*(\d+)'),
          'BGSManagedHierarchyTimeoutMs',
        ),
      ),
      'silentBudgetMs': int.parse(
        _one(
          ip,
          RegExp(r'BGSManagedHierarchySilentTimeoutMs\s*=\s*(\d+)'),
          'BGSManagedHierarchySilentTimeoutMs',
        ),
      ),
      'silentAfterTimeouts': int.parse(
        _one(
          ip,
          RegExp(r'kBGSManagedHierarchySilentAfterTimeouts\s*=\s*(\d+)'),
          'kBGSManagedHierarchySilentAfterTimeouts',
        ),
      ),
    },
  };
}

void main(List<String> args) {
  String? arg(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final androidTypes = arg('--android-types');
  final androidProvider = arg('--android-provider');
  final iosProvider = arg('--ios-provider');
  final ref = arg('--ios-source-ref');
  if (androidTypes == null ||
      androidProvider == null ||
      iosProvider == null ||
      ref == null) {
    stderr.writeln(
      'usage: see the header of scripts/extract_data_requests.dart',
    );
    exit(64);
  }
  final versions =
      jsonDecode(File('native-versions.json').readAsStringSync())
          as Map<String, Object?>;
  final pins = {
    'android': (versions['android']! as Map<String, Object?>)['sdk'],
    'ios': (versions['ios']! as Map<String, Object?>)['sdk'],
  };
  final result = extract(
    androidTypes: File(androidTypes).readAsStringSync(),
    androidProvider: File(androidProvider).readAsStringSync(),
    iosProvider: File(iosProvider).readAsStringSync(),
    iosSourceRef: ref,
    pins: pins,
  );
  final text = '${const JsonEncoder.withIndent('  ').convert(result)}\n';
  const path = 'test/fixtures/data_requests.json';
  if (args.contains('--check')) {
    if (File(path).readAsStringSync() != text) {
      stderr.writeln(
        '$path is not what the SDK source says; re-run without --check',
      );
      exit(1);
    }
    return;
  }
  File(path).writeAsStringSync(text);
}
