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
    'src/exceptions/error_capture.dart': ['IsolateErrorListener'],
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
    'src/report/attachments.dart': [
      'ReportAttachment',
      'ReportAttachmentException',
      'ReportAttachmentFailure',
      'ReportScreenshot',
      'maxAttachmentBytes',
      'maxScreenshotPixels',
    ],
    'src/report/created_report.dart': [
      'CreateReportException',
      'CreateReportFailure',
      'CreatedReport',
      'CreatedReportClosedError',
      'CreatedReportSnapshot',
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
      'CreatedReportPatchMessage',
      'ReportWire',
      'createCreatedReport',
      'createReportFailure',
      'checkAttachmentPath',
      'attachmentFailure',
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
      'ErrorCapture',
      'ReportLimiter',
      'ExceptionWire',
      'ExceptionPayload',
      'StackDocument',
      'buildExceptionPayload',
      'classifyExceptionType',
      'classifyErrorText',
      'describeError',
      'describeStack',
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
        r'^  static (?:[\w<>?, ]+? )?(?:get |set )?(\w+)(?:<[^>]*>)?\s*(?:\(|=>|\{|=|;)',
        multiLine: true,
      ).allMatches(api))
        m.group(1)!,
    };

    test('offers exactly these static members', () {
      expect(members, {
        '_runtime',
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
        'createReport',
        'reportHandler',
        'setReportHandler',
        'lifecycleEvents',
        'logException',
        'logUnhandledException',
        'reportException',
        'installErrorHandlers',
        'uninstallErrorHandlers',
        'errorHandlersInstalled',
        'errorHandlersActive',
        'runGuarded',
        'listenToIsolateErrors',
      });
    });

    test('has no pause, resume, relaunch or test-crash shim', () {
      for (final banned in ['pause', 'resume', 'relaunch', 'testCrash']) {
        expect(members, isNot(contains(banned)), reason: banned);
      }
    });

    test('the test hook is not a member: it is a src-only function', () {
      expect(members, isNot(contains('debugSetRuntime')));
      expect(
        api,
        contains(
          '@visibleForTesting\nvoid debugSetBugseeRuntime(BugseeRuntime',
        ),
      );
      // ... and the entry point does not export it.
      expect(exports['src/bugsee.dart'], ['Bugsee']);
    });

    test('is not instantiable', () {
      expect(api, contains('abstract final class Bugsee'));
    });
  });

  test('a report proxy is only created through src-only functions', () {
    final proxy = read('lib/src/report/report_proxy.dart');
    expect(proxy, contains('  ReportProxy._({'));
    expect(proxy, contains('ReportProxy createReportProxy({'));
    expect(proxy, contains('void closeReportProxy(ReportProxy proxy)'));
    expect(proxy, isNot(contains('ReportProxy.internal')));
    expect(proxy, isNot(contains('markCompleted')));
  });

  group('the members of the exported classes', () {
    /// The body of `name` (brace matched), from the first `{` after its declaration.
    String body(String source, String name) {
      final decl = RegExp(
        '^(?:abstract |final |base |sealed )*(?:class|enum) $name\\b',
        multiLine: true,
      ).firstMatch(source)!;
      var i = source.indexOf('{', decl.end);
      var depth = 0;
      final start = i;
      for (; i < source.length; i++) {
        if (source[i] == '{') depth++;
        if (source[i] == '}' && --depth == 0) break;
      }
      return source.substring(start + 1, i);
    }

    /// The public member names declared at the class's own indentation.
    Set<String> membersOf(String source, String name) {
      final out = <String>{};
      for (final line in body(source, name).split('\n')) {
        if (!line.startsWith('  ') || line.startsWith('   ')) continue;
        final t = line.trim();
        if (t.isEmpty ||
            t.startsWith('//') ||
            t.startsWith('@') ||
            t.startsWith('}') ||
            t.startsWith(')')) {
          continue;
        }
        final constant = RegExp(r'^(\w+)[,;]$').firstMatch(t);
        final member = RegExp(
          r'^(?:static |final |const |factory |late )*(?:[\w<>?,\[\] .]+? )?(?:get |set )?(\w+)\s*(?:\(|;|=|\{|=>)',
        ).firstMatch(t);
        final n = constant?.group(1) ?? member?.group(1);
        if (n != null &&
            !n.startsWith('_') &&
            !{'toString', 'hashCode', 'operator'}.contains(n) &&
            !t.contains(' operator ')) {
          out.add(n);
        }
      }
      return out;
    }

    const expectedMembers = <String, (String, Set<String>)>{
      'ReportProxy': (
        'src/report/report_proxy.dart',
        {
          'id',
          'typeName',
          'type',
          'deliveryId',
          'isLive',
          'read',
          'setSummary',
          'setDescription',
          'setEmail',
          'setSeverity',
          'replaceLabels',
          'addLabels',
          'clearLabels',
          'setAttribute',
          'removeAttribute',
          'clearAttributes',
          'addAttachment',
          'addAttachmentBytes',
          'clearAttachments',
          'setScreenshot',
          'removeScreenshot',
          'isAllowedAttributeValue',
        },
      ),
      'ReportSnapshot': (
        'src/report/report_proxy.dart',
        {
          'ReportSnapshot',
          'id',
          'typeName',
          'type',
          'summary',
          'description',
          'email',
          'severity',
          'labels',
          'attributes',
          'attachments',
          'screenshots',
        },
      ),
      'ReportClosedError': (
        'src/report/report_proxy.dart',
        {'ReportClosedError'},
      ),
      'CreatedReport': (
        'src/report/created_report.dart',
        {
          'reportId',
          'type',
          'isLive',
          'read',
          'setSummary',
          'setDescription',
          'setSeverity',
          'replaceLabels',
          'setAttribute',
          'removeAttribute',
          'clearAttributes',
          'addAttachment',
          'addAttachmentBytes',
          'clearAttachments',
          'setScreenshot',
          'upload',
          'discard',
        },
      ),
      'CreatedReportSnapshot': (
        'src/report/created_report.dart',
        {
          'CreatedReportSnapshot',
          'reportId',
          'typeName',
          'type',
          'summary',
          'description',
          'severity',
          'labels',
          'attributes',
          'attachmentNames',
          'screenshotDisplayIds',
        },
      ),
      'CreatedReportClosedError': (
        'src/report/created_report.dart',
        {'CreatedReportClosedError'},
      ),
      'CreateReportException': (
        'src/report/created_report.dart',
        {'CreateReportException', 'reason'},
      ),
      'CreateReportFailure': (
        'src/report/created_report.dart',
        {'busy', 'timeout'},
      ),
      'ReportAttachment': (
        'src/report/attachments.dart',
        {'ReportAttachment', 'name', 'mimeType', 'fileName'},
      ),
      'ReportScreenshot': (
        'src/report/attachments.dart',
        {'ReportScreenshot', 'displayId', 'annotated'},
      ),
      'ReportAttachmentException': (
        'src/report/attachments.dart',
        {'ReportAttachmentException', 'reason'},
      ),
      'ReportAttachmentFailure': (
        'src/report/attachments.dart',
        {
          'fileNotFound',
          'notAFile',
          'unreadable',
          'tooLarge',
          'limitReached',
          'rejected',
          'busy',
          'unsupported',
          'imageUndecodable',
          'imageTooLarge',
        },
      ),
      'BugseeBreadcrumb': (
        'src/facade/breadcrumb.dart',
        {'BugseeBreadcrumb', 'category', 'message', 'level', 'type', 'data'},
      ),
      'BreadcrumbLevel': (
        'src/facade/breadcrumb.dart',
        {'debug', 'info', 'warning', 'error', 'fatal', 'fromName'},
      ),
      'LifecycleEvent': (
        'src/lifecycle_event.dart',
        {'LifecycleEvent', 'name', 'reportId', 'data'},
      ),
      'BugseeReportHandler': (
        'src/report/report_handler.dart',
        {
          'BugseeReportHandler',
          'onBeforeReportCreated',
          'onAfterReportCreated',
          'isEmpty',
        },
      ),
      'BugseeSecureView': (
        'src/secure/bugsee_secure_view.dart',
        {'BugseeSecureView', 'enabled', 'child', 'build'},
      ),
      'BugseeException': (
        'src/launch.dart',
        {'BugseeException', 'message', 'cause'},
      ),
      'BugseeLaunchException': (
        'src/launch.dart',
        {'BugseeLaunchException', 'reason'},
      ),
      'BugseeArgumentException': (
        'src/errors.dart',
        {'BugseeArgumentException', 'argument'},
      ),
      'BugseeAttributeException': (
        'src/errors.dart',
        {'BugseeAttributeException', 'reason', 'argument'},
      ),
      'AttributeFailure': (
        'src/errors.dart',
        {'invalidName', 'invalidValue', 'rejected'},
      ),
      'IsolateErrorListener': ('src/exceptions/error_capture.dart', {'cancel'}),
      'BugseeStatus': (
        'src/status.dart',
        {'stopped', 'launching', 'launched', 'stopping', 'fromName'},
      ),
    };

    for (final e in expectedMembers.entries) {
      test('${e.key} has exactly these public members', () {
        expect(membersOf(read('lib/${e.value.$1}'), e.key), e.value.$2);
      });
    }

    test('no exported class mentions a bridge or runtime type', () {
      for (final e in expectedMembers.entries) {
        // Private members (the proxy's private constructor and its `_host`) may name the bridge:
        // an app cannot see them.
        final text = body(read('lib/${e.value.$1}'), e.key)
            .replaceAll(
              RegExp(r'(?:ReportProxy|CreatedReport)\._\([\s\S]*?;\n'),
              '',
            )
            .split('\n')
            .where((l) => !RegExp(r'\b_\w+;').hasMatch(l))
            .join('\n');
        for (final internal in [
          'BugseeBridge',
          'BugseeRuntime',
          'HostApi',
          'FlutterApi',
          'Message',
        ]) {
          expect(
            text,
            isNot(contains(internal)),
            reason: '${e.key}: $internal',
          );
        }
      }
    });
  });
}
