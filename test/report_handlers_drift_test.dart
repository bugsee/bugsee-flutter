// Drift guards for the report-handler pipeline (workbook Part 7) that are about TEXT repeated
// across Dart, Android and iOS, or about a property that is cheap to see in source. The behaviour
// itself is tested by test/report_handlers_test.dart, the JUnit tests
// (ReportHandlerPipelineTest) and the XCTests (BGSFlutterReportHandlerPipelineTests).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source with comments removed, so a call that is only commented out does not satisfy a guard.
String code(String path) => File(path)
    .readAsStringSync()
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

const java = 'android/src/main/java/com/bugsee/flutter';
const objc = 'ios/bugsee_flutter/Sources/bugsee_flutter_wrapper';

int constant(String source, RegExp pattern) =>
    int.parse(pattern.firstMatch(source)!.group(1)!.replaceAll('_', ''));

void main() {
  final pipelineJava = code('$java/ReportHandlerPipeline.java');
  final deadlinesJava = code('$java/ReportHandlerDeadlines.java');
  final pipelineObjc = code('$objc/BGSFlutterReportHandlerPipeline.m');
  final wrapperJava = code('$java/FlutterWrapper.java');
  final wrapperObjc = code('$objc/BGSFlutterWrapper.m');

  group('the deadlines are inside the SDKs, and alike on both platforms', () {
    test('live: 25 s, inside the 30 s per-handler timeout of both SDKs', () {
      final android = constant(
        deadlinesJava,
        RegExp(r'LIVE_DEADLINE_MS\s*=\s*([\d_]+)L'),
      );
      final sdkAndroid = constant(
        deadlinesJava,
        RegExp(r'SDK_DEFAULT_HANDLER_TIMEOUT_MS\s*=\s*([\d_]+)L'),
      );
      final ios = constant(
        pipelineObjc,
        RegExp(r'BGSFlutterReportLiveDeadlineMs\s*=\s*(\d+)'),
      );
      final sdkIos = constant(
        pipelineObjc,
        RegExp(r'BGSFlutterReportSdkLiveHandlerTimeoutMs\s*=\s*(\d+)'),
      );
      expect(android, 25000);
      expect(ios, android);
      expect(sdkAndroid, 30000, reason: 'ReportHandlerCallbackTimeout default');
      expect(sdkIos, sdkAndroid);
      expect(android, lessThan(sdkAndroid));
      expect(ios, lessThan(sdkIos));
    });

    test('recovery on iOS: inside the 3 s bounded cap', () {
      final recovery = constant(
        pipelineObjc,
        RegExp(r'BGSFlutterReportRecoveryDeadlineMs\s*=\s*(\d+)'),
      );
      final cap = constant(
        pipelineObjc,
        RegExp(r'BGSFlutterReportSdkBoundedCapMs\s*=\s*(\d+)'),
      );
      expect(cap, 3000);
      expect(recovery, lessThan(cap));
      expect(recovery, greaterThanOrEqualTo(1000));
    });

    test('Android tells its waited-for path by the SDK thread name', () {
      expect(
        deadlinesJava,
        contains('LIVE_HANDLER_THREAD = "BugseeReportHandlerThread"'),
      );
    });
  });

  group('terminating is decided before anything else', () {
    test(
      'Android: the isTerminating branch precedes every use of Dart, time or the report',
      () {
        final terminating = pipelineJava.indexOf('if (isTerminating)');
        expect(terminating, isPositive);
        for (final later in [
          'registrationFor(',
          'scheduler.schedule(',
          'platform.post(',
          'handles.put(',
          'safeId(report)',
          'ReportOps.typeOf(',
        ]) {
          final at = pipelineJava.indexOf(later);
          expect(at, greaterThan(terminating), reason: later);
        }
      },
    );

    test(
      'iOS: the isTerminating branch precedes every use of Dart, time or the report',
      () {
        final terminating = pipelineObjc.indexOf('if (isTerminating)');
        expect(terminating, isPositive);
        for (final later in [
          '_registrations',
          '_schedule(',
          '_platformPost(',
          '_handles[handleId]',
          'SafeReportId(report)',
          'typeOfReport:',
        ]) {
          final at = pipelineObjc.indexOf(later, terminating);
          expect(at, greaterThan(terminating), reason: later);
        }
        // ...and the report is not read before it: only the nil check comes first.
        final before = pipelineObjc.substring(
          pipelineObjc.indexOf('- (void)dispatchOnce:'),
          terminating,
        );
        expect(before, isNot(contains('SafeReportId')));
        expect(before, isNot(contains('typeOfReport')));
      },
    );

    test(
      'the Dart message has no isTerminating field: Dart is never asked',
      () {
        final bridge = code('pigeons/bridge.dart');
        expect(bridge, isNot(contains('isTerminating')));
      },
    );
  });

  group('nothing in the pipeline waits (the deadlock)', () {
    test('Android pipeline has no blocking primitive', () {
      for (final blocking in [
        'CountDownLatch',
        '.await(',
        'Thread.sleep',
        '.join(',
        '.wait(',
        'LockSupport',
        'Semaphore',
      ]) {
        expect(pipelineJava, isNot(contains(blocking)), reason: blocking);
      }
    });

    test('iOS pipeline has no blocking primitive', () {
      for (final blocking in [
        'dispatch_semaphore_wait',
        'dispatch_group_wait',
        'dispatch_sync',
        'sleep(',
        'usleep',
        'NSCondition',
        'NSConditionLock',
        'waitUntilDate',
      ]) {
        expect(pipelineObjc, isNot(contains(blocking)), reason: blocking);
      }
    });

    test('the request is posted to the platform thread, never run inline', () {
      expect(pipelineJava, contains('platform.post('));
      expect(pipelineObjc, contains('_platformPost('));
      // Production hop on iOS: always asynchronous, even when the caller IS main.
      expect(
        pipelineObjc,
        contains('dispatch_async(dispatch_get_main_queue(), task)'),
      );
    });
  });

  group('the wrapper routes both phases through the pipeline', () {
    test('Android', () {
      expect(
        wrapperJava,
        contains('reports.dispatch(ReportHandlerPipeline.Phase.BEFORE'),
      );
      expect(
        wrapperJava,
        contains('reports.dispatch(ReportHandlerPipeline.Phase.AFTER'),
      );
      // No direct completion: that would skip Dart entirely.
      expect(wrapperJava, isNot(contains('completionCallback.run()')));
    });

    test('iOS', () {
      expect(
        wrapperObjc,
        contains('dispatchPhase:BGSFlutterReportPhaseBefore'),
      );
      expect(wrapperObjc, contains('dispatchPhase:BGSFlutterReportPhaseAfter'));
      expect(wrapperObjc, isNot(contains('completion();')));
      expect(wrapperObjc, contains('onMainThread:[NSThread isMainThread]'));
    });
  });

  group('requestData always answers null (workbook 6.1)', () {
    test('Android answers null, and catches whatever the callback throws', () {
      final start = wrapperJava.indexOf('public void requestData');
      final body = wrapperJava.substring(
        wrapperJava.indexOf('{', start),
        wrapperJava.indexOf('@Override', start),
      );
      expect(body, contains('callback.onResult(null)'));
      expect(body, contains('catch (Throwable'));
      expect(
        body,
        isNot(contains('dataType')),
        reason: 'no type is special yet',
      );
    });

    test('iOS answers nil, and catches whatever the callback throws', () {
      final start = wrapperObjc.indexOf('requestDataWithType');
      final body = wrapperObjc.substring(
        wrapperObjc.indexOf('{', start),
        wrapperObjc.indexOf('- (void)onLifecycleEvent', start),
      );
      expect(body, contains('onResult:nil'));
      expect(body, contains('@catch'));
      expect(body, isNot(contains('dataType')));
    });
  });
}
