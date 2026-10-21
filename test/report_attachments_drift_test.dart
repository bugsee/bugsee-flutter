// Drift guards for what the attachment and created-report paths repeat across Dart, Java and
// Objective-C: the failure codes, the limits, the name/MIME/path rules, and which SDK call each path
// makes. The natives answer before Dart can look at them, so each copy is compared with its source,
// and the SDK's own numbers come from the extracted fixture (scripts/extract_report_enums.dart), not
// from another copy of the wrapper's.
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/src/report/attachments.dart';
import 'package:flutter_test/flutter_test.dart';

const java = 'android/src/main/java/com/bugsee/flutter';
const objc = 'ios/bugsee_flutter/Sources/bugsee_flutter_wrapper';

String read(String path) => File(path).readAsStringSync();

String stripComments(String s) => s
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

void main() {
  final javaOps = stripComments(read('$java/ReportOps.java'));
  final javaFlow = stripComments(read('$java/ReportFileFlow.java'));
  final javaPlugin = stripComments(read('$java/BugseeFlutterPlugin.java'));
  final objcFiles = stripComments(read('$objc/BGSFlutterReportFiles.m'));
  final objcFlow = stripComments(read('$objc/BGSFlutterReportFileFlow.m'));
  final objcCreated = stripComments(read('$objc/BGSFlutterCreatedReportOps.m'));
  final objcPipeline = stripComments(
    read('$objc/BGSFlutterReportHandlerPipeline.m'),
  );
  final fixture =
      jsonDecode(read('test/fixtures/report_enums.json'))
          as Map<String, Object?>;
  final androidLimits =
      (fixture['android'] as Map)['attachments'] as Map<String, Object?>;
  final iosLimits =
      (fixture['ios'] as Map)['attachments'] as Map<String, Object?>;

  /// The Dart code for each Java constant / Objective-C symbol.
  final codes = <String, (String, String)>{
    ReportWire.notLive: ('NOT_LIVE', 'NotLive'),
    ReportWire.fileNotFound: ('FILE_NOT_FOUND', 'NotFound'),
    ReportWire.notAFile: ('NOT_A_FILE', 'NotAFile'),
    ReportWire.unreadable: ('UNREADABLE', 'Unreadable'),
    ReportWire.tooLarge: ('TOO_LARGE', 'TooLarge'),
    ReportWire.limit: ('LIMIT', 'Limit'),
    ReportWire.rejected: ('REJECTED', 'Rejected'),
    ReportWire.busy: ('BUSY', 'Busy'),
    ReportWire.unsupported: ('UNSUPPORTED', 'Unsupported'),
    ReportWire.imageUndecodable: ('IMAGE_UNDECODABLE', 'ImageUndecodable'),
    ReportWire.imageTooLarge: ('IMAGE_TOO_LARGE', 'ImageTooLarge'),
  };

  group('the failure codes are the same in Dart, Java and Objective-C', () {
    test('Java names every code with the same value', () {
      final found = {
        for (final m in RegExp(
          r'static final String (\w+) = "([^"]*)";',
        ).allMatches(javaOps))
          m.group(1)!: m.group(2)!,
      };
      for (final e in codes.entries) {
        expect(found[e.value.$1], e.key, reason: e.value.$1);
      }
    });

    test('Objective-C names every code with the same value', () {
      final found = {
        for (final m in RegExp(
          r'NSString \*const BGSFlutterFile(\w+) = @"([^"]*)";',
        ).allMatches(objcFiles))
          m.group(1)!: m.group(2)!,
      };
      for (final e in codes.entries) {
        expect(found[e.value.$2], e.key, reason: e.value.$2);
      }
      expect(found.length, codes.length, reason: 'no other code');
    });

    test('Dart maps every code but not-live to a reason, and no other', () {
      expect(
        ReportWire.failures.keys.toSet(),
        codes.keys.toSet()..remove(ReportWire.notLive),
      );
      expect(
        ReportWire.failures.values.toSet().length,
        ReportWire.failures.length,
      );
      for (final reason in ReportAttachmentFailure.values) {
        expect(ReportWire.failures.values, contains(reason), reason: '$reason');
      }
    });

    test(
      'the created-report codes added by the review: rate limit, upload timeout, not-live',
      () {
        expect(ReportWire.createRateLimited, 'create-rate-limited');
        expect(ReportWire.uploadTimeout, 'upload-timeout');
        expect(
          javaFlow,
          contains('CREATE_RATE_LIMITED = "${ReportWire.createRateLimited}"'),
        );
        expect(
          javaFlow,
          contains('UPLOAD_TIMEOUT = "${ReportWire.uploadTimeout}"'),
        );
        expect(javaFlow, contains('NOT_LIVE = "${ReportWire.notLive}"'));
        expect(
          objcFlow,
          contains(
            'BGSFlutterCreateRateLimited = @"${ReportWire.createRateLimited}"',
          ),
        );
        expect(
          objcFlow,
          contains('BGSFlutterUploadTimeout = @"${ReportWire.uploadTimeout}"'),
        );
      },
    );

    test('createReport codes: Dart, Java and Objective-C', () {
      expect(ReportWire.createBusy, 'create-busy');
      expect(ReportWire.createTimeout, 'create-timeout');
      expect(javaFlow, contains('CREATE_BUSY = "${ReportWire.createBusy}"'));
      expect(
        javaFlow,
        contains('CREATE_TIMEOUT = "${ReportWire.createTimeout}"'),
      );
      expect(
        objcFlow,
        contains('BGSFlutterCreateBusy = @"${ReportWire.createBusy}"'),
      );
      expect(
        objcFlow,
        contains('BGSFlutterCreateTimeout = @"${ReportWire.createTimeout}"'),
      );
    });
  });

  group('the limits and rules are the same in Dart, Java and Objective-C', () {
    test('bytes, name, MIME, path and pixel limits', () {
      expect(maxAttachmentBytes, 1024 * 1024);
      expect(javaOps, contains('MAX_ATTACHMENT_BYTES = 1024 * 1024;'));
      expect(
        objcFiles,
        contains('BGSFlutterMaxAttachmentBytes = 1024 * 1024;'),
      );

      expect(maxAttachmentFileBytes, 20 * 1024 * 1024);
      expect(
        javaOps,
        contains('MAX_ATTACHMENT_FILE_BYTES = 20L * 1024L * 1024L;'),
      );
      expect(
        objcFiles,
        contains(
          'BGSFlutterMaxAttachmentFileBytes = 20ULL * 1024ULL * 1024ULL;',
        ),
      );

      expect(maxAttachmentNameLength, 255);
      expect(
        javaOps,
        contains('MAX_ATTACHMENT_NAME_LENGTH = $maxAttachmentNameLength;'),
      );
      expect(
        objcFiles,
        contains(
          'BGSFlutterMaxAttachmentNameLength = $maxAttachmentNameLength;',
        ),
      );

      expect(maxMimeTypeLength, 255);
      expect(javaOps, contains('MAX_MIME_TYPE_LENGTH = $maxMimeTypeLength;'));
      expect(
        objcFiles,
        contains('BGSFlutterMaxMimeTypeLength = $maxMimeTypeLength;'),
      );

      expect(maxAttachmentPathLength, 4096);
      expect(javaOps, contains('MAX_PATH_LENGTH = $maxAttachmentPathLength;'));
      expect(
        objcFiles,
        contains('BGSFlutterMaxPathLength = $maxAttachmentPathLength;'),
      );

      expect(maxScreenshotPixels, 4096 * 4096);
      expect(javaOps, contains('MAX_SCREENSHOT_PIXELS = 4096L * 4096L;'));
      expect(
        objcFiles,
        contains('BGSFlutterMaxScreenshotPixels = 4096ULL * 4096ULL;'),
      );

      expect(maxDisplayId, 0x7fffffff);
      expect(javaOps, contains('displayId > Integer.MAX_VALUE'));
      expect(objcFiles, contains('displayId > INT32_MAX'));
    });

    test('"blank" is one explicit set of code points in all three', () {
      List<int> hexes(String text) => [
        for (final m in RegExp(r'0x([0-9A-Fa-f]+)').allMatches(text))
          int.parse(m.group(1)!, radix: 16),
      ];
      final dart = hexes(
        RegExp(
          r'_blankRanges = <List<int>>\[(.*?)\];',
          dotAll: true,
        ).firstMatch(read('lib/src/report/attachments.dart'))!.group(1)!,
      );
      final javaSet = hexes(
        RegExp(
          r'BLANK_RANGES = \{(.*?)\};',
          dotAll: true,
        ).firstMatch(javaOps)!.group(1)!,
      );
      final objcSet = hexes(
        RegExp(
          r'kBlankRanges\[\]\[2\] = \{(.*?)\};',
          dotAll: true,
        ).firstMatch(objcFiles)!.group(1)!,
      );
      expect(dart, isNotEmpty);
      expect(javaSet, dart);
      expect(objcSet, dart);
      for (final source in [javaOps, objcFiles]) {
        expect(source, isNot(contains('.trim()')));
        expect(source, isNot(contains('whitespaceAndNewlineCharacterSet')));
      }
    });

    test('the MIME grammar is one regular expression in all three', () {
      String normal(String s) => s.replaceAll(r'\\', r'\');
      final dart = RegExp(
        r'_mimeToken = RegExp\(\s*r"(.*?)",',
        dotAll: true,
      ).firstMatch(read('lib/src/report/attachments.dart'))!.group(1)!;
      final javaPattern = RegExp(
        r'MIME = Pattern\.compile\(\s*"(.*?)"\);',
        dotAll: true,
      ).firstMatch(javaOps)!.group(1)!;
      final objcPattern = RegExp(
        r'regularExpressionWithPattern:@"(\^\[A-Za-z0-9\]\[A-Za-z0-9.*?\$)"',
      ).firstMatch(objcFiles)!.group(1)!;
      expect(normal(javaPattern), normal(dart));
      expect(normal(objcPattern), normal(dart));
    });

    test('the URL-scheme rule is the same expression in all three', () {
      String normal(String s) => s.replaceAll(r'\\', r'\');
      final dart = RegExp(
        r"RegExp\(r'(\^\[A-Za-z\]\[A-Za-z0-9\+\.\\-\]\*:)'\)",
      ).firstMatch(read('lib/src/report/attachments.dart'))!.group(1)!;
      expect(normal(javaOps), contains(normal(dart.replaceAll(r'\-', r'\-'))));
      expect(normal(objcFiles), contains(normal(dart)));
    });

    test(
      'the SDKs\' own attachment caps are the fixture\'s (extracted from source)',
      () {
        expect(androidLimits['maxPerReport'], 1000);
        expect(
          javaOps,
          contains(
            'MAX_REPORT_ATTACHMENTS = ${androidLimits['maxPerReport']};',
          ),
        );
        expect(iosLimits['maxPerReport'], androidLimits['maxPerReport']);
        expect(
          read('$objc/BGSFlutterReportFiles.m'),
          contains(
            'BGSFlutterMaxReportAttachments = ${iosLimits['maxPerReport']};',
          ),
        );
        expect(
          objcCreated,
          contains(
            'BGSFlutterCreatedReportMaxAttachments = ${iosLimits['legacyCreatedReportMaxCount']};',
          ),
        );
        expect(
          objcCreated,
          contains(
            'BGSFlutterCreatedReportMaxAttachmentBytes = 3u * 1024u * 1024u;',
          ),
        );
        expect(iosLimits['legacyCreatedReportMaxBytes'], 3 * 1024 * 1024);
      },
    );

    test(
      'the plugin cap of a bytes attachment stays under both SDKs\' legacy limit',
      () {
        // A bytes attachment is capped below what the legacy iOS created report takes, so one cap is
        // never the reason a created report refuses what a handler report took.
        expect(
          maxAttachmentBytes,
          lessThan(iosLimits['legacyCreatedReportMaxBytes']! as int),
        );
      },
    );
  });

  group('each path makes the SDK call the spec names', () {
    test(
      'Android: the path-first and bytes overloads of Report, never the stream',
      () {
        expect(
          javaOps,
          contains('report.addAttachment(data, checkedName, checkedMime)'),
        );
        expect(
          javaOps,
          contains('report.setScreenshot(id, bitmap, annotated)'),
        );
        expect(
          javaOps,
          contains(
            'report.setScreenshot(checkedDisplayId(displayId), null, false)',
          ),
        );
        for (final source in [javaOps, javaFlow, javaPlugin]) {
          expect(source, isNot(contains('openStream')));
          expect(source, isNot(contains('createAndAddAttachment')));
        }
      },
    );

    test(
      'iOS: the path-first and bytes methods of BGSReportContract, never the object forms',
      () {
        expect(
          objcFiles,
          contains(
            'addAttachmentWithFilePath:path name:name mimeType:mimeType move:move',
          ),
        );
        expect(
          objcFiles,
          contains('addAttachmentWithData:data name:name mimeType:mimeType'),
        );
        expect(
          objcFiles,
          contains(
            'setScreenshot:image displayId:(NSInteger)displayId annotated:annotated',
          ),
        );
        expect(
          objcFiles,
          contains(
            'setScreenshot:nil displayId:(NSInteger)displayId annotated:NO',
          ),
        );
        for (final source in [objcFiles, objcFlow]) {
          expect(source, isNot(contains('createAndAddAttachmentWithName')));
          expect(source, isNot(contains('addAttachment:')));
        }
      },
    );

    test(
      'createReport: Android Bugsee.createReport/upload, iOS createReportWithCompletion/uploadReport',
      () {
        expect(javaFlow, contains('Bugsee.createReport(listener)'));
        expect(javaFlow, contains('Bugsee.upload(report, done)'));
        expect(objcFlow, contains('[Bugsee createReportWithCompletion:'));
        expect(
          objcFlow,
          contains(
            '[Bugsee uploadReport:(BugseeExtendedReport *)report completion:completion]',
          ),
        );
      },
    );

    test(
      'a created report is only ever copied: neither platform exposes a move for it',
      () {
        expect(
          javaFlow,
          contains(
            'ReportOps.addFile(report, path, name, mimeType, false, window)',
          ),
        );
        expect(RegExp(r'\bmove\b').hasMatch(objcCreated), isFalse);
      },
    );
  });

  group('nothing blocks, and file work is off the platform thread', () {
    test('no blocking primitive in the new native flows', () {
      for (final entry in {
        'ReportFileFlow.java': javaFlow,
        'ReportFileWorker.java': stripComments(
          read('$java/ReportFileWorker.java'),
        ),
        'CreatedReports.java': stripComments(read('$java/CreatedReports.java')),
        'BGSFlutterReportFileFlow.m': objcFlow,
        'BGSFlutterCreatedReports.m': stripComments(
          read('$objc/BGSFlutterCreatedReports.m'),
        ),
      }.entries) {
        for (final banned in [
          RegExp(r'\.get\(\s*\)'),
          RegExp(r'\.await\('),
          RegExp(r'Thread\.sleep'),
          RegExp(r'dispatch_semaphore_wait'),
          RegExp(r'dispatch_group_wait'),
          RegExp(r'dispatch_sync\('),
          RegExp(r'\bsleep\('),
          RegExp(r'CountDownLatch'),
        ]) {
          expect(
            banned.hasMatch(entry.value),
            isFalse,
            reason: '${entry.key}: $banned',
          );
        }
      }
    });

    test(
      'a handler report\'s file operations are queued on the worker, behind a lease',
      () {
        expect(javaFlow, contains('pipeline.acquire(handle)'));
        expect(javaFlow, contains('worker.execute('));
        expect(objcFlow, contains('[_pipeline acquireHandle:handle]'));
        expect(objcFlow, contains('_worker('));
        // The SDK's completion waits for the claim, in both pipelines.
        expect(
          stripComments(read('$java/ReportHandlerPipeline.java')),
          contains('completionDeferred'),
        );
        expect(objcPipeline, contains('deferredCompletion'));
      },
    );

    test(
      'the Pigeon file operations are asynchronous, the cheap ones synchronous',
      () {
        final bridge = read('pigeons/bridge.dart');
        for (final method in [
          'reportAddAttachment',
          'reportAddAttachmentBytes',
          'reportClearAttachments',
          'reportSetScreenshot',
          'reportRemoveScreenshot',
          'createReport',
          'createdReportAddAttachment',
          'createdReportAddAttachmentBytes',
          'createdReportClearAttachments',
          'createdReportSetScreenshot',
          'createdReportUpload',
        ]) {
          expect(
            bridge,
            matches(RegExp('@async\\s+[\\w?<>]+ $method\\(')),
            reason: '$method must not run on the platform thread',
          );
        }
      },
    );
  });

  group('every native bridge method is wired in both natives', () {
    final methods = RegExp(
      r'(?:Future<[^>]+>|[\w?<>]+) (reportAddAttachment|reportAddAttachmentBytes|reportClearAttachments|reportSetScreenshot|reportRemoveScreenshot|createReport|createdReport\w+)\(',
    ).allMatches(read('pigeons/bridge.dart')).map((m) => m.group(1)!).toSet();

    test('the list is complete', () {
      expect(methods, hasLength(14));
    });

    for (final method in methods) {
      test('$method: Java overrides it, Swift implements it', () {
        expect(
          javaPlugin,
          contains('public void $method(')
              .or(contains('public Boolean $method('))
              .or(contains('Messages.CreatedReportSnapshotMessage $method(')),
          reason: method,
        );
        expect(
          read(
            'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
          ),
          contains('func $method('),
          reason: method,
        );
      });
    }
  });
}

extension on Matcher {
  Matcher or(Matcher other) => anyOf(this, other);
}
