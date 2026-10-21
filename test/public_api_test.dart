// The public API surface, pinned. `lib/bugsee_flutter.dart` is the only file an app imports; what it
// exports and what `Bugsee` offers are listed here, so an accidental export (an internal that gained a
// `show` entry, a new `Bugsee` method nobody reviewed, a re-export through another file) fails
// instead of becoming API. Adding to the API means editing this list in the same change.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const entry = 'lib/bugsee_flutter.dart';

String read(String path) => File(path).readAsStringSync();

/// `{path: [names]}` for every `export 'path' show A, B;` in [source].
Map<String, List<String>> exportsOf(String source) => {
  for (final m in RegExp(
    r"export '([^']+)'\s+show\s+([^;]+);",
    multiLine: true,
  ).allMatches(source))
    m.group(1)!: [for (final n in m.group(2)!.split(',')) n.trim()]..sort(),
};

void main() {
  final source = read(entry);
  final exports = exportsOf(source);

  /// What `package:bugsee_flutter/bugsee_flutter.dart` exports.
  const expected = <String, List<String>>{
    'src/bugsee.dart': ['Bugsee'],
    'src/errors.dart': [
      'AttributeFailure',
      'BugseeArgumentException',
      'BugseeAttributeException',
    ],
    'src/facade/breadcrumb.dart': ['BreadcrumbLevel', 'BugseeBreadcrumb'],
    'src/launch.dart': [
      'BugseeException',
      'BugseeLaunchException',
      'LaunchFailure',
      'LaunchResult',
    ],
    'src/lifecycle_event.dart': ['LifecycleEvent'],
    'src/options/bugsee_options.g.dart': [
      'BugseeOptions',
      'BugseeStyle',
      'CrashHandlerType',
      'DataEncryptionMode',
      'FrameRate',
      'LogLevel',
      'VideoMode',
      'VideoQuality',
    ],
    'src/report/report_enums.dart': ['ReportSeverity', 'ReportType'],
    'src/report/report_handler.dart': ['BugseeReportHandler', 'ReportHandler'],
    'src/report/report_proxy.dart': [
      'ReportClosedError',
      'ReportProxy',
      'ReportSnapshot',
    ],
    'src/secure/bugsee_secure_view.dart': ['BugseeSecureView'],
    'src/status.dart': ['BugseeStatus'],
  };

  test('the entry point exports exactly these symbols', () {
    expect(exports, expected);
  });

  test('every export has a `show` clause (no wholesale export)', () {
    final all = RegExp(r"^export\s", multiLine: true).allMatches(source).length;
    expect(all, exports.length);
  });

  test(
    'nothing is exported from the bridge, the options registry or the secure internals',
    () {
      for (final path in exports.keys) {
        expect(path, isNot(contains('bridge')));
        expect(path, isNot(contains('messages')));
        expect(path, isNot(contains('option_registry')));
        expect(path, isNot(endsWith('secure_region.dart')));
        expect(path, isNot(contains('runtime')));
      }
    },
  );

  test('an exported file does not re-export anything itself', () {
    for (final path in exports.keys) {
      expect(
        read('lib/$path'),
        isNot(matches(RegExp(r'^export\s', multiLine: true))),
        reason: '$path would widen the public surface behind the entry point',
      );
    }
  });

  test('internals stay hidden', () {
    const internal = [
      'BugseeRuntime',
      'BugseeBridge',
      'BugseeBridgeHostApi',
      'BugseeBridgeFlutterApi',
      'BugseeSecureRegion',
      'RenderSecureRegion',
      'SecureRegionRegistry',
      'MeasuredRegion',
      'FacadeWire',
      'LaunchWire',
      'LaunchOutcomeMessage',
      'LifecycleEventMessage',
      'SecureRectanglesMessage',
      'ReportHandlerRequestMessage',
      'BreadcrumbMessage',
      'ReportSnapshotMessage',
      'WrapperIdentity',
      'RuntimeFacts',
      'OptionPlatform',
      'OptionSpec',
      'statusForEvent',
      'reportIdEvents',
      'statusTransitionEvents',
      'optionSpecForKey',
      'encodeLaunchOptions',
      'checkAttributeValue',
      'checkTraceValue',
      'copyEventParams',
      'checkLabels',
      'mapFacadeError',
      'optionRegistry',
    ];
    final exported = exports.values.expand((n) => n).toSet();
    for (final name in internal) {
      expect(exported, isNot(contains(name)), reason: name);
    }
  });

  group('Bugsee', () {
    final api = read('lib/src/bugsee.dart');
    final members = {
      for (final m in RegExp(
        r'^  static (?:[\w<>?, ]+? )?(?:get |set )?(\w+)\s*(?:\(|=>|\{|=|;)',
        multiLine: true,
      ).allMatches(api))
        m.group(1)!,
    };

    test('offers exactly these static members', () {
      expect(members, {
        '_runtime',
        'debugSetRuntime',
        'launch',
        'waitUntilLaunched',
        'stop',
        'status',
        'statusChanges',
        'getStatus',
        'isLaunched',
        'getLaunchOptions',
        'getHostLaunchOptions',
        'setAttribute',
        'getAttribute',
        'getAllAttributes',
        'clearAttribute',
        'clearAllAttributes',
        'setUserIdentifier',
        'getUserIdentifier',
        'clearUserIdentifier',
        'event',
        'trace',
        'log',
        'addBreadcrumb',
        'notify',
        'startBlackout',
        'endBlackout',
        'isBlackout',
        'showReportDialog',
        'upload',
        'reportHandler',
        'setReportHandler',
        'lifecycleEvents',
      });
    });

    test('has no pause, resume, relaunch or test-crash shim', () {
      for (final banned in ['pause', 'resume', 'relaunch', 'testCrash']) {
        expect(members, isNot(contains(banned)), reason: banned);
      }
    });

    test('the one test hook is marked @visibleForTesting', () {
      expect(
        api,
        contains('@visibleForTesting\n  static void debugSetRuntime'),
      );
    });

    test('is not instantiable', () {
      expect(api, contains('abstract final class Bugsee'));
    });
  });

  test('the proxy constructor and its bridge-only hook are @internal', () {
    final proxy = read('lib/src/report/report_proxy.dart');
    expect(proxy, contains('@internal\n  ReportProxy.internal('));
    expect(proxy, contains('@internal\n  void markCompleted()'));
  });
}
