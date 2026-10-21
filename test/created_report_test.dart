// `Bugsee.createReport` and the `CreatedReport` it yields, against a fake native side: what is
// validated in Dart, what crosses, how each native answer maps to a typed result, and the lifetime
// (upload, discard and the time to live all end it; a late call throws).
import 'dart:typed_data';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/bugsee.dart' show debugSetBugseeRuntime;
import 'package:bugsee_flutter/src/bugsee_runtime.dart';
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/facade_fake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FacadeFake native;
  late BugseeRuntime runtime;
  OptionPlatform? platform;

  setUp(() {
    native = FacadeFake();
    platform = OptionPlatform.android;
    runtime = BugseeRuntime(
      host: native,
      platform: () => platform,
      warn: (_) {},
    );
    debugSetBugseeRuntime(runtime);
  });

  List<String> callsOf(String prefix) =>
      native.calls.where((c) => c.startsWith(prefix)).toList();

  group('createReport', () {
    test('asks native with the time to live and wraps the handle', () async {
      final report = await Bugsee.createReport(
        timeToLive: const Duration(minutes: 3),
      );
      expect(report, isNotNull);
      expect(report!.reportId, 'created-1');
      expect(report.type, ReportType.bug);
      expect(report.isLive, isTrue);
      expect(callsOf('createReport'), ['createReport(180000)']);
    });

    test('the default time to live is ten minutes', () async {
      await Bugsee.createReport();
      expect(callsOf('createReport'), ['createReport(600000)']);
    });

    test('null when the SDK made none (not launched)', () async {
      native.createdHandle = null;
      expect(await Bugsee.createReport(), isNull);
      expect(callsOf('createdReportRead'), isEmpty);
    });

    test('an iOS report has no id', () async {
      native.createdSnapshot = CreatedReportSnapshotMessage(
        reportId: '',
        type: 'bug',
        labels: [],
        attributes: {},
        attachmentNames: [],
        screenshotDisplayIds: [],
      );
      final report = await Bugsee.createReport();
      expect(report!.reportId, isNull);
      expect((await report.read()).reportId, isNull);
    });

    test(
      'a time to live outside one second..one hour is refused in Dart',
      () async {
        for (final ttl in [
          Duration.zero,
          const Duration(milliseconds: 999),
          const Duration(hours: 1, milliseconds: 1),
          const Duration(days: 1),
        ]) {
          await expectLater(
            Bugsee.createReport(timeToLive: ttl),
            throwsA(
              isA<BugseeArgumentException>().having(
                (e) => e.argument,
                'argument',
                'timeToLive',
              ),
            ),
            reason: '$ttl',
          );
        }
        expect(native.calls, isEmpty);
      },
    );

    test('busy and timeout are typed', () async {
      native.failing['createReport'] = PlatformException(code: 'create-busy');
      await expectLater(
        Bugsee.createReport(),
        throwsA(
          isA<CreateReportException>().having(
            (e) => e.reason,
            'reason',
            CreateReportFailure.busy,
          ),
        ),
      );
      native.failing['createReport'] = PlatformException(
        code: 'create-timeout',
      );
      await expectLater(
        Bugsee.createReport(),
        throwsA(
          isA<CreateReportException>().having(
            (e) => e.reason,
            'reason',
            CreateReportFailure.timeout,
          ),
        ),
      );
      native.failing['createReport'] = PlatformException(
        code: 'create-rate-limited',
      );
      await expectLater(
        Bugsee.createReport(),
        throwsA(
          isA<CreateReportException>().having(
            (e) => e.reason,
            'reason',
            CreateReportFailure.rateLimited,
          ),
        ),
      );
      native.failing['createReport'] = PlatformException(code: 'sdk-error');
      await expectLater(Bugsee.createReport(), throwsA(isA<BugseeException>()));
    });

    test('on a platform with no SDK it is null, nothing is called', () async {
      platform = null;
      expect(await Bugsee.createReport(), isNull);
      expect(native.calls, isEmpty);
    });
  });

  group('editing', () {
    late CreatedReport report;
    setUp(() async {
      report = (await Bugsee.createReport())!;
      native.calls.clear();
    });

    test('each setter is one patch with only its own field', () async {
      await report.setSummary('s');
      await report.setSummary(null);
      await report.setDescription('d');
      await report.setSeverity(ReportSeverity.critical);
      await report.replaceLabels(['a', 'b']);
      await report.setAttribute('k', 1.5);
      await report.removeAttribute('k');
      await report.clearAttributes();
      expect(callsOf('createdReportApply'), [
        'createdReportApply(cr-1, summary=s, description=-, severity=null, labels=null, clear=false, attributes=null, remove=null)',
        'createdReportApply(cr-1, summary=null, description=-, severity=null, labels=null, clear=false, attributes=null, remove=null)',
        'createdReportApply(cr-1, summary=-, description=d, severity=null, labels=null, clear=false, attributes=null, remove=null)',
        // Critical is index 3 and value 4: the value crosses.
        'createdReportApply(cr-1, summary=-, description=-, severity=4, labels=null, clear=false, attributes=null, remove=null)',
        'createdReportApply(cr-1, summary=-, description=-, severity=null, labels=[a, b], clear=false, attributes=null, remove=null)',
        'createdReportApply(cr-1, summary=-, description=-, severity=null, labels=null, clear=false, attributes={k: 1.5}, remove=null)',
        'createdReportApply(cr-1, summary=-, description=-, severity=null, labels=null, clear=false, attributes=null, remove=[k])',
        'createdReportApply(cr-1, summary=-, description=-, severity=null, labels=null, clear=true, attributes=null, remove=null)',
      ]);
    });

    test(
      'an attribute both SDKs cannot carry is refused before it crosses',
      () async {
        for (final bad in <Object>[
          double.nan,
          double.infinity,
          ['x'],
          {'a': 1},
        ]) {
          await expectLater(
            report.setAttribute('k', bad),
            throwsA(isA<BugseeArgumentException>()),
          );
        }
        await expectLater(
          report.setAttribute('', 1),
          throwsA(isA<BugseeArgumentException>()),
        );
        expect(native.calls, isEmpty);
      },
    );

    test(
      'native refusing a patch is an argument error and the report stays live',
      () async {
        native.failing['createdReportApply'] = PlatformException(
          code: 'invalid-argument',
          message: 'bad',
        );
        await expectLater(
          report.setSeverity(ReportSeverity.high),
          throwsA(isA<BugseeArgumentException>()),
        );
        expect(report.isLive, isTrue);
      },
    );

    test('read maps the snapshot to values', () async {
      native.createdSnapshot = CreatedReportSnapshotMessage(
        reportId: 'r',
        type: 'bug',
        summary: 's',
        reportDescription: 'd',
        severity: 5,
        labels: ['l'],
        attributes: {'a': 1},
        attachmentNames: ['x.txt'],
        screenshotDisplayIds: [0],
      );
      final s = await report.read();
      expect(s.reportId, 'r');
      expect(s.severity, ReportSeverity.blocker);
      expect(s.labels, ['l']);
      expect(s.attachmentNames, ['x.txt']);
      expect(s.screenshotDisplayIds, [0]);
      expect(() => s.labels.add('x'), throwsUnsupportedError);
    });

    test(
      'files cross as a path (copy: there is no move) and bytes under the cap',
      () async {
        await report.addAttachment(
          '/d/a.txt',
          name: 'a',
          mimeType: 'text/plain',
        );
        await report.addAttachmentBytes(Uint8List(5), name: 'b');
        await report.setScreenshot('/d/s.png', annotated: true);
        await report.clearAttachments();
        expect(native.calls, [
          'createdReportAddAttachment(cr-1, /d/a.txt, a, text/plain)',
          'createdReportAddAttachmentBytes(cr-1, 5, b, null)',
          'createdReportSetScreenshot(cr-1, /d/s.png, true)',
          'createdReportClearAttachments(cr-1)',
        ]);
      },
    );

    test(
      'empty and oversize bytes, and malformed files, never cross',
      () async {
        await expectLater(
          report.addAttachmentBytes(Uint8List(0), name: 'n'),
          throwsA(isA<BugseeArgumentException>()),
        );
        await expectLater(
          report.addAttachmentBytes(
            Uint8List(maxAttachmentBytes + 1),
            name: 'n',
          ),
          throwsA(isA<BugseeArgumentException>()),
        );
        await expectLater(
          report.addAttachment('relative', name: 'n'),
          throwsA(isA<BugseeArgumentException>()),
        );
        await expectLater(
          report.addAttachment('/a', name: '../n'),
          throwsA(isA<BugseeArgumentException>()),
        );
        await expectLater(
          report.addAttachment('/a', name: 'n', mimeType: 'x'),
          throwsA(isA<BugseeArgumentException>()),
        );
        await expectLater(
          report.setScreenshot('file:///a.png'),
          throwsA(isA<BugseeArgumentException>()),
        );
        expect(native.calls, isEmpty);
      },
    );

    test('a refusal is typed and the report stays live', () async {
      native.fileReply = 'limit';
      await expectLater(
        report.addAttachment('/a', name: 'n'),
        throwsA(
          isA<ReportAttachmentException>().having(
            (e) => e.reason,
            'reason',
            ReportAttachmentFailure.limitReached,
          ),
        ),
      );
      native.fileReply = 'unsupported';
      await expectLater(
        report.setScreenshot('/a.png', annotated: true),
        throwsA(
          isA<ReportAttachmentException>().having(
            (e) => e.reason,
            'reason',
            ReportAttachmentFailure.unsupported,
          ),
        ),
      );
      expect(report.isLive, isTrue);
    });
  });

  group('lifetime', () {
    test('upload hands the report over once and ends it', () async {
      final report = (await Bugsee.createReport())!;
      expect(await report.upload(), isTrue);
      expect(report.isLive, isFalse);
      await expectLater(
        report.upload(),
        throwsA(isA<CreatedReportClosedError>()),
      );
      await expectLater(
        report.setSummary('x'),
        throwsA(isA<ReportClosedError>()),
      );
      await expectLater(report.read(), throwsStateError);
      await expectLater(
        report.addAttachment('/a', name: 'n'),
        throwsA(isA<ReportClosedError>()),
      );
      expect(callsOf('createdReportUpload'), ['createdReportUpload(cr-1)']);
      expect(callsOf('createdReportApply'), isEmpty);
    });

    test(
      'native saying not-live to an upload is a CreatedReportClosedError, not false',
      () async {
        final report = (await Bugsee.createReport())!;
        native.failing['createdReportUpload'] = PlatformException(
          code: 'not-live',
        );
        await expectLater(
          report.upload(),
          throwsA(isA<CreatedReportClosedError>()),
        );
        expect(report.isLive, isFalse);
      },
    );

    test('an SDK that never answers the upload is a typed timeout', () async {
      final report = (await Bugsee.createReport())!;
      native.failing['createdReportUpload'] = PlatformException(
        code: 'upload-timeout',
      );
      await expectLater(
        report.upload(),
        throwsA(
          isA<CreateReportException>()
              .having(
                (e) => e.reason,
                'reason',
                CreateReportFailure.uploadTimeout,
              )
              .having(
                (e) => e.message,
                'message',
                contains('do not upload it again'),
              ),
        ),
      );
      expect(report.isLive, isFalse);
    });

    test('an unknown upload failure stays a platform error', () async {
      final report = (await Bugsee.createReport())!;
      native.failing['createdReportUpload'] = PlatformException(
        code: 'sdk-error',
      );
      await expectLater(report.upload(), throwsA(isA<PlatformException>()));
    });

    test('two overlapping uploads cross once', () async {
      final report = (await Bugsee.createReport())!;
      final first = report.upload();
      await expectLater(
        report.upload(),
        throwsA(isA<CreatedReportClosedError>()),
      );
      expect(await first, isTrue);
      expect(callsOf('createdReportUpload'), hasLength(1));
    });

    test(
      'upload answers false when the SDK did not schedule it; the report is dead anyway',
      () async {
        native.createdUploadResult = false;
        final report = (await Bugsee.createReport())!;
        expect(await report.upload(), isFalse);
        expect(report.isLive, isFalse);
      },
    );

    test(
      'discard releases it once; later calls throw; discard again is harmless',
      () async {
        final report = (await Bugsee.createReport())!;
        await report.discard();
        await report.discard();
        expect(callsOf('createdReportDiscard'), ['createdReportDiscard(cr-1)']);
        await expectLater(
          report.setSummary('x'),
          throwsA(isA<CreatedReportClosedError>()),
        );
        await expectLater(
          report.upload(),
          throwsA(isA<CreatedReportClosedError>()),
        );
      },
    );

    test(
      'a report native no longer has throws on the next call and stays closed',
      () async {
        final report = (await Bugsee.createReport())!;
        native.createdApplied = false;
        await expectLater(
          report.setSummary('x'),
          throwsA(isA<CreatedReportClosedError>()),
        );
        expect(report.isLive, isFalse);
        native.fileReply = null;
        final before = native.calls.length;
        await expectLater(
          report.setSummary('y'),
          throwsA(isA<CreatedReportClosedError>()),
        );
        expect(native.calls.length, before, reason: 'closed: no round trip');
      },
    );

    test('native answering not-live to a file call closes it', () async {
      final report = (await Bugsee.createReport())!;
      native.fileReply = 'not-live';
      await expectLater(
        report.addAttachment('/a', name: 'n'),
        throwsA(isA<CreatedReportClosedError>()),
      );
      expect(report.isLive, isFalse);
    });

    test('read of a report native lost closes it', () async {
      final report = (await Bugsee.createReport())!;
      native.createdSnapshot = null;
      await expectLater(
        report.read(),
        throwsA(isA<CreatedReportClosedError>()),
      );
      expect(report.isLive, isFalse);
    });

    testWidgets('the time to live closes it in Dart without a round trip', (
      tester,
    ) async {
      final report = (await Bugsee.createReport(
        timeToLive: const Duration(seconds: 30),
      ))!;
      expect(report.isLive, isTrue);
      await tester.pump(const Duration(seconds: 29));
      expect(report.isLive, isTrue);
      final before = native.calls.length;
      await tester.pump(const Duration(seconds: 2));
      expect(report.isLive, isFalse);
      await expectLater(
        report.setSummary('late'),
        throwsA(isA<CreatedReportClosedError>()),
      );
      expect(native.calls.length, before);
    });

    // The harness fails a test that ends with a Timer still pending: that is the assertion.
    testWidgets('upload cancels the time to live timer', (tester) async {
      final report = (await Bugsee.createReport())!;
      await report.upload();
    });

    testWidgets('discard cancels the time to live timer', (tester) async {
      final report = (await Bugsee.createReport())!;
      await report.discard();
    });
  });
}
