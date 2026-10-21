// Drift guards for the report-handler pipeline (workbook Part 7) that are about TEXT repeated
// across Dart, Android and iOS, or about a property that is cheap to see in source. The behaviour
// itself is tested by test/report_handlers_test.dart, the JUnit tests
// (ReportHandlerPipelineTest) and the XCTests (BGSFlutterReportHandlerPipelineTests).
import 'dart:convert';
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

  group(
    'the deadlines are inside the SDKs real budgets (read from SDK source)',
    () {
      // The SDKs' numbers come from test/fixtures/report_enums.json, extracted from their
      // source by scripts/extract_report_enums.dart, NOT from the wrapper: comparing the
      // wrapper's constants with each other proves nothing.
      final fixture =
          jsonDecode(File('test/fixtures/report_enums.json').readAsStringSync())
              as Map<String, Object?>;
      final a = (fixture['android']! as Map)['reportHandlerTimings']! as Map;
      final i = (fixture['ios']! as Map)['reportHandlerTimings']! as Map;
      final androidHandlerMs =
          (a['handlerTimeoutDefaultSeconds']! as int) * 1000;
      final iosHandlerMs = ((i['handlerTimeoutSeconds']! as num) * 1000)
          .round();
      final iosCapMs = ((i['boundedCapSeconds']! as num) * 1000).round();

      test('the SDKs agree with each other on the numbers we rely on', () {
        expect(androidHandlerMs, iosHandlerMs);
        expect(a['terminatingCapMs'], iosCapMs);
        expect(
          a['chainCapMs'],
          ((i['chainTimeoutSeconds']! as num) * 1000).round(),
        );
      });

      test('the wrapper repeats the SDKs numbers it documents', () {
        expect(
          constant(
            deadlinesJava,
            RegExp(r'SDK_DEFAULT_HANDLER_TIMEOUT_MS\s*=\s*([\d_]+)L'),
          ),
          androidHandlerMs,
        );
        expect(
          constant(
            pipelineObjc,
            RegExp(r'BGSFlutterReportSdkLiveHandlerTimeoutMs\s*=\s*(\d+)'),
          ),
          iosHandlerMs,
        );
        expect(
          constant(
            pipelineObjc,
            RegExp(r'BGSFlutterReportSdkBoundedCapMs\s*=\s*(\d+)'),
          ),
          iosCapMs,
        );
      });

      test(
        'live: a third of the SDK budget is kept as margin, on both platforms',
        () {
          final android = constant(
            deadlinesJava,
            RegExp(r'LIVE_DEADLINE_MS\s*=\s*([\d_]+)L'),
          );
          final ios = constant(
            pipelineObjc,
            RegExp(r'BGSFlutterReportLiveDeadlineMs\s*=\s*(\d+)'),
          );
          expect(android, lessThanOrEqualTo(androidHandlerMs * 2 ~/ 3));
          expect(ios, lessThanOrEqualTo(iosHandlerMs * 2 ~/ 3));
          expect(android, ios);
          // The margin rule is repeated in both languages.
          expect(
            constant(deadlinesJava, RegExp(r'MAX_MARGIN_MS\s*=\s*([\d_]+)L')),
            10000,
          );
          expect(
            deadlinesJava,
            contains('Math.min(MAX_MARGIN_MS, sdkMs / 3L)'),
          );
          expect(pipelineObjc, contains('MIN(10000, sdkMs / 3)'));
        },
      );

      test('recovery on iOS: a third of the bounded cap is kept as margin', () {
        final recovery = constant(
          pipelineObjc,
          RegExp(r'BGSFlutterReportRecoveryDeadlineMs\s*=\s*(\d+)'),
        );
        expect(recovery, lessThanOrEqualTo(iosCapMs * 2 ~/ 3));
        expect(recovery, greaterThanOrEqualTo(1000));
      });

      test('Android tells its waited-for path by the SDK thread name', () {
        expect(
          deadlinesJava,
          contains('LIVE_HANDLER_THREAD = "BugseeReportHandlerThread"'),
        );
      });
    },
  );

  group('terminating is decided before anything else', () {
    // Everything inside dispatchOnce that comes before the isTerminating branch is sliced out and
    // must contain none of the protected uses; each use must still exist after the branch (a
    // first-occurrence search could be satisfied by a later use while an earlier one slips in).
    void guardOrder(
      String source,
      String start,
      String branch,
      List<String> uses,
    ) {
      final from = source.indexOf(start);
      expect(from, isNonNegative, reason: start);
      final terminating = source.indexOf(branch, from);
      expect(terminating, greaterThan(from), reason: branch);
      final before = source.substring(from, terminating);
      for (final use in uses) {
        expect(before, isNot(contains(use)), reason: 'before the branch: $use');
        expect(
          source.indexOf(use, terminating),
          greaterThan(terminating),
          reason: 'after the branch: $use',
        );
      }
    }

    test(
      'Android: the isTerminating branch precedes every use of Dart, time or the report',
      () {
        guardOrder(
          pipelineJava,
          'private void dispatchOnce(',
          'if (isTerminating)',
          [
            'registrationFor(',
            'scheduler.schedule(',
            'platform.post(',
            'handles.put(',
            'safeId(',
            'ReportOps.typeOf(',
            'clock.nowMs(',
            'readOption(',
            'threadName.current(',
          ],
        );
      },
    );

    test(
      'iOS: the isTerminating branch precedes every use of Dart, time or the report',
      () {
        guardOrder(
          pipelineObjc,
          '- (void)dispatchOnce:',
          'if (isTerminating)',
          [
            '_registrations',
            '_schedule(',
            '_platformPost(',
            '_handles[',
            'SafeReportId',
            'typeOfReport',
            '_clock(',
          ],
        );
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

  group('nothing on the report path waits (the deadlock)', () {
    // The guard covers every file a report callback or a Dart reply passes through, not only
    // the pipelines. An exception is listed here, with its reason, or it is a failure.
    final javaFiles = [
      '$java/ReportHandlerPipeline.java',
      '$java/ReportHandlerDeadlines.java',
      '$java/ReportOps.java',
      '$java/FlutterWrapper.java',
      '$java/BugseeFlutterPlugin.java',
    ];
    final objcFiles = [
      '$objc/BGSFlutterReportHandlerPipeline.m',
      '$objc/BGSFlutterReportOps.m',
      '$objc/BGSFlutterWrapper.m',
      'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
    ];
    const javaBlocking = [
      'CountDownLatch',
      '.await(',
      '.take(',
      'Thread.sleep',
      '.join(',
      '.wait(',
      'Semaphore',
      'LockSupport',
      'Exchanger',
      'CyclicBarrier',
      'Phaser',
    ];
    const objcBlocking = [
      'dispatch_semaphore_wait',
      'dispatch_group_wait',
      'dispatch_sync',
      'sleep(',
      'usleep',
      'NSCondition',
      'waitUntilDate',
      'DispatchSemaphore',
      'DispatchGroup',
      '.wait(',
      'pthread_cond_wait',
      'pthread_join',
    ];

    test('no blocking primitive in any Java file of the report path', () {
      for (final path in javaFiles) {
        final text = code(path);
        for (final blocking in javaBlocking) {
          expect(text, isNot(contains(blocking)), reason: '$path: $blocking');
        }
        // A Future's get() blocks, whatever the variable is called: no get() without a key, and no
        // get(timeout, unit). (Map.get(key) and Atomic*.get() on the report path are not used.)
        expect(
          RegExp(r'\.get\(\s*\)|\.get\(\s*\d+\s*,').hasMatch(text),
          isFalse,
          reason: '$path: Future.get',
        );
      }
    });

    test(
      'no blocking primitive in any Objective-C or Swift file of the report path',
      () {
        for (final path in objcFiles) {
          final text = code(path);
          for (final blocking in objcBlocking) {
            expect(text, isNot(contains(blocking)), reason: '$path: $blocking');
          }
        }
      },
    );

    test('monitors are allowed only where listed, each with its reason', () {
      int count(String path, String word) => word.allMatches(code(path)).length;
      // Report pipeline (Java): the per-handle lock, held for "check live + apply" and for
      // flipping `done` (2 sites), around the report's own setters; never across the SDK's
      // completion, Dart or the scheduler.
      expect(count('$java/ReportHandlerPipeline.java', 'synchronized'), 2);
      // Pre-existing, not on the report path: one-time creation of the shared environment.
      expect(count('$java/BugseeFlutterPlugin.java', 'synchronized'), 1);
      for (final path in [
        '$java/ReportHandlerDeadlines.java',
        '$java/ReportOps.java',
        '$java/FlutterWrapper.java',
      ]) {
        expect(count(path, 'synchronized'), 0, reason: path);
      }
      // iOS: `@synchronized` guards only the once-flag of the SDK's completion (trivial, no
      // call out while held); the registrar's three are pre-existing registration code.
      expect(
        count('$objc/BGSFlutterReportHandlerPipeline.m', '@synchronized'),
        1,
      );
      expect(count('$objc/BGSFlutterReportOps.m', '@synchronized'), 0);
      expect(count('$objc/BGSFlutterWrapper.m', '@synchronized'), 3);
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

    test(
      'the SDK completion, Dart and the scheduler are called outside the handle lock',
      () {
        // Java: every `synchronized (handle)` block, braces balanced, calls none of them.
        var from = 0;
        var blocks = 0;
        while (true) {
          final at = pipelineJava.indexOf('synchronized (handle) {', from);
          if (at < 0) break;
          var depth = 0;
          var end = at;
          for (
            var i = pipelineJava.indexOf('{', at);
            i < pipelineJava.length;
            i++
          ) {
            if (pipelineJava[i] == '{') depth++;
            if (pipelineJava[i] == '}' && --depth == 0) {
              end = i;
              break;
            }
          }
          final block = pipelineJava.substring(at, end);
          for (final out in [
            'sdkCompletion',
            'runQuietly',
            'scheduler.',
            'sink.deliver',
            'platform.post',
            'outcomes.',
            'cancelQuietly',
          ]) {
            expect(block, isNot(contains(out)), reason: out);
          }
          blocks++;
          from = end;
        }
        expect(blocks, 2);
        // ObjC: the edit lock is unlocked before the completion runs in finish.
        final finish = pipelineObjc.substring(
          pipelineObjc.indexOf('- (BOOL)finish:'),
        );
        expect(
          finish.lastIndexOf('[handle.editLock unlock]'),
          lessThan(finish.indexOf('RunQuietly(completion)')),
        );
      },
    );
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
}
