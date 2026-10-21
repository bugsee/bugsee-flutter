// Runs on a device or simulator (it needs the native SDKs and, to read the bundle, a local stand-in
// for the API that refuses the upload so the bundle stays on disk):
//
//   python3 mock_api.py 8196 &         # any HTTP server answering 503 to POST /v2/issues and 200 otherwise
//   cd example && flutter test integration_test/attachments_test.dart -d <device> \
//       --dart-define=BUGSEE_ENDPOINT=http://10.0.2.2:8196      # Android emulator; iOS: http://localhost:8196
//
// Attachments, annotated screenshots and createReport through the real SDKs. The readback is the report
// BUNDLE the SDK wrote (a zip in the app's own data directory, which the app can read): its manifest has
// an entry per attachment (name, fileName, mimeType) and per screenshot (`annotated`), and each file's
// content hash is compared with the source's. Files are attached from inside the report handler (the
// public way), and from a report made with `Bugsee.createReport`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_example/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/painting.dart' show Offset, Paint, Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/bundle_reader.dart';

void say(String line) => debugPrint('integration: $line');

Future<File> writePng(File file, int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.indigo,
  );
  canvas.drawCircle(
    Offset(width / 2, height / 2),
    height / 4,
    Paint()..color = Colors.amber,
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  return file..writeAsBytesSync(data.buffer.asUint8List());
}

/// One file of a bundle: its size and content hash.
class Entry {
  const Entry(this.size, this.sha256);
  final int size;
  final String sha256;
}

/// A report bundle the SDK produced, as the test reads it: from the SDK's own file in the app's data
/// directory when it is there (Android keeps it), else from what the stand-in API received (iOS hands the
/// upload to the system and keeps no file). The same questions are asked of both.
class Bundle {
  Bundle(this.source, this.manifest, this.request, this.entries);

  final String source;
  final Map manifest;
  final Map<String, Object?> request;
  final Map<String, Entry> entries;

  factory Bundle.fromZip(String source, Uint8List bytes) {
    final zip = readZip(bytes);
    return Bundle(
      source,
      jsonDecode(utf8.decode(zip['manifest.json']!)) as Map,
      jsonDecode(utf8.decode(zip['request.json']!)) as Map<String, Object?>,
      {
        for (final e in zip.entries)
          e.key: Entry(e.value.length, sha256Hex(e.value)),
      },
    );
  }

  factory Bundle.fromServer(Map json) => Bundle(
    'stand-in API: ${json['file']}',
    json['manifest'] as Map,
    (json['request'] as Map).cast<String, Object?>(),
    {
      for (final e in (json['entries'] as Map).entries)
        e.key as String: Entry(
          (e.value as Map)['size'] as int,
          (e.value as Map)['sha256'] as String,
        ),
    },
  );

  List<Map> get files => [for (final f in manifest['files'] as List) f as Map];
  List<Map> ofType(String type) => [
    for (final f in files)
      if (f['type'] == type) f,
  ];
  Entry file(Map manifestEntry) => entries[manifestEntry['filename']]!;
}

/// The bundle whose request has this [summary]: polled, because the SDK builds it after the handler.
Future<Bundle?> bundleWithSummary(String summary, {int seconds = 60}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    for (final f in bundles(Directory.systemTemp.parent)) {
      try {
        final bundle = Bundle.fromZip(f.path, f.readAsBytesSync());
        if (bundle.request['summary'] == summary) return bundle;
      } on FormatException {
        // Still being written.
      } on StateError {
        // Not a report bundle.
      } on TypeError {
        // Still being written.
      }
    }
    if (endpoint.isNotEmpty) {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse('$endpoint/__bundles'));
        final response = await request.close();
        final body = await utf8.decodeStream(response);
        for (final json in jsonDecode(body) as List) {
          final bundle = Bundle.fromServer(json as Map);
          if (bundle.request['summary'] == summary) return bundle;
        }
      } on Object catch (e) {
        say('the stand-in API did not answer: $e');
      } finally {
        client.close(force: true);
      }
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('files attached from a report handler reach the bundle', (
    tester,
  ) async {
    final android = defaultTargetPlatform == TargetPlatform.android;
    if (endpoint.isEmpty) {
      say(
        'no BUGSEE_ENDPOINT: the SDK cannot be pointed at the stand-in API, '
        'so the bundle cannot be read',
      );
    }
    final dir = await Directory.systemTemp.createTemp('attachments');
    final text = File('${dir.path}/notes.txt')
      ..writeAsStringSync('hello bugsee attachment\n' * 50);
    final copied = File('${dir.path}/copied.log')
      ..writeAsStringSync('copy: the source must survive\n');
    final moved = File('${dir.path}/moved.log')
      ..writeAsStringSync('move: the source is consumed\n');
    final image = await tester.runAsync(
      () => writePng(File('${dir.path}/photo.png'), 64, 48),
    );
    final shot = await tester.runAsync(
      () => writePng(File('${dir.path}/edited.png'), 120, 80),
    );
    final bytes = Uint8List.fromList(List.generate(300, (i) => i % 251));
    final sources = {
      'notes': (text.readAsBytesSync(), 'text/plain', 'notes.txt'),
      'photo': (image!.readAsBytesSync(), 'image/png', 'photo.png'),
      'copied': (copied.readAsBytesSync(), null, 'copied.log'),
      'moved': (moved.readAsBytesSync(), null, 'moved.log'),
      'raw': (bytes, 'application/octet-stream', 'raw'),
    };
    final shotHash = sha256Hex(shot!.readAsBytesSync());

    // ---- before launch: nothing to attach to ------------------------------------------------------
    final seen = <String>[];
    ReportProxy? kept;
    ReportSnapshot? duringHandler;
    final failures = <String, Object>{};
    final afterDone = Completer<void>();
    String? reportId;
    // The handler attaches only for the report it is told about: the created reports below pass
    // through the same handler.
    var attachFromHandler = true;

    await Bugsee.setReportHandler(
      BugseeReportHandler(
        onBeforeReportCreated: (report) async {
          seen.add('before:${report.typeName}');
          if (!attachFromHandler) return;
          kept = report;
          reportId = report.id;
          await report.addAttachment(
            text.path,
            name: 'notes',
            mimeType: 'text/plain',
          );
          await report.addAttachment(
            image.path,
            name: 'photo',
            mimeType: 'image/png',
          );
          await report.addAttachment(copied.path, name: 'copied');
          await report.addAttachment(moved.path, name: 'moved', move: true);
          await report.addAttachmentBytes(
            bytes,
            name: 'raw',
            mimeType: 'application/octet-stream',
          );
          await report.setScreenshot(shot.path, annotated: true);
          // Refusals: typed, and the report is unchanged.
          Future<void> expectFailure(
            String what,
            Future<void> Function() call,
          ) async {
            try {
              await call();
              failures[what] = 'accepted';
            } catch (e) {
              failures[what] = e;
            }
          }

          await expectFailure(
            'missing',
            () => report.addAttachment('${dir.path}/nope.txt', name: 'x'),
          );
          await expectFailure(
            'directory',
            () => report.addAttachment(dir.path, name: 'x'),
          );
          await expectFailure(
            'url',
            () => report.addAttachment('file://${text.path}', name: 'x'),
          );
          await expectFailure(
            'mime',
            () => report.addAttachment(text.path, name: 'x', mimeType: 'bad'),
          );
          await expectFailure(
            'not an image',
            () => report.setScreenshot(text.path, displayId: 3),
          );
          await expectFailure(
            'missing move',
            () => report.addAttachment(
              '${dir.path}/nope2.txt',
              name: 'x',
              move: true,
            ),
          );
          duringHandler = await report.read();
        },
        onAfterReportCreated: (report) async {
          seen.add('after:${report.typeName}');
          if (attachFromHandler && !afterDone.isCompleted) {
            afterDone.complete();
          }
        },
      ),
    );

    final launch = await Bugsee.launch(defaultToken, options: exampleOptions());
    say('launch -> $launch');
    expect(await Bugsee.waitUntilLaunched(), isTrue);

    await Bugsee.upload('attachments test', 'files from a report handler');
    await afterDone.future.timeout(const Duration(seconds: 45));
    say('handler phases: $seen, report id $reportId');

    // ---- what the handler saw -----------------------------------------------------------------------
    expect(
      failures['missing'],
      isA<ReportAttachmentException>().having(
        (e) => e.reason,
        'reason',
        ReportAttachmentFailure.fileNotFound,
      ),
    );
    expect(
      failures['directory'],
      isA<ReportAttachmentException>().having(
        (e) => e.reason,
        'reason',
        ReportAttachmentFailure.notAFile,
      ),
    );
    expect(failures['url'], isA<BugseeArgumentException>());
    expect(failures['mime'], isA<BugseeArgumentException>());
    expect(
      failures['not an image'],
      isA<ReportAttachmentException>().having(
        (e) => e.reason,
        'reason',
        ReportAttachmentFailure.imageUndecodable,
      ),
    );
    expect(failures['missing move'], isA<ReportAttachmentException>());
    say('refusals: ${failures.map((k, v) => MapEntry(k, v.runtimeType))}');

    final snap = duringHandler!;
    say('snapshot attachments: ${snap.attachments}');
    say('snapshot screenshots: ${snap.screenshots}');
    expect(
      snap.attachments.map((a) => a.name),
      containsAll(['notes', 'photo', 'copied', 'moved', 'raw']),
    );
    final byName = {for (final a in snap.attachments) a.name: a};
    expect(byName['notes']!.mimeType, 'text/plain');
    expect(byName['notes']!.fileName, 'notes.txt');
    expect(byName['raw']!.fileName, 'raw');
    expect(byName['moved']!.mimeType, isNull);
    expect(
      snap.screenshots.any((s) => s.displayId == 0 && s.annotated),
      isTrue,
      reason: 'the annotated screenshot is read back from the SDK',
    );
    expect(
      snap.screenshots.any((s) => s.displayId == 3),
      isFalse,
      reason: 'a refused image changed nothing',
    );

    // ---- copy and move -------------------------------------------------------------------------------
    expect(text.existsSync(), isTrue, reason: 'a copy leaves the source');
    expect(copied.existsSync(), isTrue);
    expect(image.existsSync(), isTrue);
    expect(
      moved.existsSync(),
      isFalse,
      reason: 'a move consumed its source (the SDK now owns the file)',
    );
    say('copy: sources kept (notes, copied, photo); move: moved.log consumed');

    // ---- late attach ----------------------------------------------------------------------------------
    expect(kept!.isLive, isFalse);
    final survivor = File('${dir.path}/late.txt')..writeAsStringSync('late');
    await expectLater(
      kept!.addAttachment(survivor.path, name: 'late', move: true),
      throwsA(isA<ReportClosedError>()),
    );
    await expectLater(
      kept!.addAttachmentBytes(bytes, name: 'late'),
      throwsA(isA<ReportClosedError>()),
    );
    await expectLater(
      kept!.setScreenshot(shot.path),
      throwsA(isA<ReportClosedError>()),
    );
    await expectLater(
      kept!.clearAttachments(),
      throwsA(isA<ReportClosedError>()),
    );
    expect(
      survivor.existsSync(),
      isTrue,
      reason: 'a late move must not consume the file',
    );
    say('late attach after completion: ReportClosedError, source untouched');

    // ---- the bundle ---------------------------------------------------------------------------------------
    final bundle = await bundleWithSummary('attachments test');
    if (bundle == null) {
      say(
        'no bundle was found within the wait (is BUGSEE_ENDPOINT set and the stand-in API running?): '
        'the readback above is the SDK\'s own',
      );
      expect(
        endpoint.isEmpty,
        isTrue,
        reason: 'with the stand-in API a bundle must arrive',
      );
    } else {
      say('bundle from ${bundle.source}');
      final attachments = bundle.ofType('attachment');
      say('manifest attachment entries: ${attachments.length}');
      for (final entry in attachments) {
        final content = bundle.file(entry);
        say(
          'attachment name=${entry['name']} attrs=${entry['attrs']} size=${content.size} '
          'sha256=${content.sha256}',
        );
      }
      expect(attachments.map((e) => e['name']).toSet(), {
        'notes',
        'photo',
        'copied',
        'moved',
        'raw',
      });
      for (final entry in attachments) {
        final name = entry['name'] as String;
        final expected = sources[name]!;
        final content = bundle.file(entry);
        expect(
          content.sha256,
          sha256Hex(expected.$1),
          reason: '$name: the bundle holds the source\'s content',
        );
        expect(content.size, expected.$1.length, reason: '$name size');
        final attrs = entry['attrs'] as Map;
        expect(attrs['fileName'], expected.$3, reason: '$name fileName');
        expect(attrs['mimeType'], expected.$2, reason: '$name mimeType');
        expect(attrs['name'], name);
      }
      final screenshots = bundle.ofType('screenshot');
      expect(screenshots, isNotEmpty);
      final entry = screenshots.firstWhere(
        (s) => (s['attrs'] as Map)['displayId'] == 0,
      );
      say('screenshot entry: ${entry['attrs']}');
      expect(
        (entry['attrs'] as Map)['annotated'],
        isTrue,
        reason: 'the manifest says the screenshot is annotated',
      );
      final stored = bundle.file(entry);
      say(
        'screenshot size=${stored.size} sha256=${stored.sha256} '
        '(source png sha256=$shotHash; the SDK re-encodes the picture)',
      );
    }

    // ====================================================================================================
    // createReport
    // ====================================================================================================
    attachFromHandler = false;
    seen.clear();
    final note = File('${dir.path}/created.txt')
      ..writeAsStringSync('from a created report\n' * 20);

    // A report the app forgets: it is held for its time to live and then released, with no help from Dart.
    final forgotten = await Bugsee.createReport(
      timeToLive: const Duration(seconds: 2),
    );
    expect(forgotten, isNotNull, reason: 'the SDK is launched');
    say('created ${forgotten!.reportId} (${forgotten.type?.name})');
    await forgotten.addAttachment(note.path, name: 'forgotten');
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
    say('a second createReport while one is outstanding: busy');
    await Future<void>.delayed(const Duration(milliseconds: 2600));
    expect(forgotten.isLive, isFalse);
    await expectLater(
      forgotten.addAttachment(note.path, name: 'too late'),
      throwsA(isA<CreatedReportClosedError>()),
    );
    await expectLater(forgotten.upload(), throwsA(isA<ReportClosedError>()));
    say(
      'a report nobody completed: released at its time to live; late calls throw',
    );

    // A report the app fills in and sends.
    final created = (await Bugsee.createReport(
      timeToLive: const Duration(minutes: 2),
    ))!;
    say('created ${created.reportId} (${created.type?.name})');
    await created.setSummary('created through the API');
    await created.setDescription('summary, labels and files from createReport');
    await created.setSeverity(ReportSeverity.high);
    await created.replaceLabels(['created', 'attachments']);
    await created.setAttribute('example.created', true);
    await created.addAttachment(
      note.path,
      name: 'created note',
      mimeType: 'text/plain',
    );
    await created.addAttachmentBytes(bytes, name: 'created raw');
    if (android) {
      await created.setScreenshot(shot.path, annotated: true);
    } else {
      // iOS's created report has no annotated flag: refused, loudly, with nothing changed.
      await expectLater(
        created.setScreenshot(shot.path, annotated: true),
        throwsA(
          isA<ReportAttachmentException>().having(
            (e) => e.reason,
            'reason',
            ReportAttachmentFailure.unsupported,
          ),
        ),
      );
      await created.setScreenshot(shot.path);
    }
    final createdSnapshot = await created.read();
    say(
      'created snapshot: summary=${createdSnapshot.summary} severity=${createdSnapshot.severity} '
      'labels=${createdSnapshot.labels} attachments=${createdSnapshot.attachmentNames} '
      'screenshots=${createdSnapshot.screenshotDisplayIds}',
    );
    expect(createdSnapshot.summary, 'created through the API');
    expect(createdSnapshot.severity, ReportSeverity.high);
    expect(createdSnapshot.labels, ['created', 'attachments']);
    expect(createdSnapshot.attachmentNames, ['created note', 'created raw']);
    expect(createdSnapshot.screenshotDisplayIds, contains(0));
    expect(note.existsSync(), isTrue, reason: 'a created report copies');

    expect(await created.upload(), isTrue);
    expect(created.isLive, isFalse);
    await expectLater(
      created.addAttachment(note.path, name: 'after upload'),
      throwsA(isA<CreatedReportClosedError>()),
    );
    say('uploaded; handler phases for the created report: $seen');

    final createdBundle = await bundleWithSummary('created through the API');
    if (createdBundle == null) {
      say('no bundle for the created report within the wait');
      expect(
        endpoint.isEmpty,
        isTrue,
        reason: 'with the stand-in API a bundle must arrive',
      );
    } else {
      say('created bundle from ${createdBundle.source}');
      final request = createdBundle.request;
      say(
        'request: summary=${request['summary']} severity=${request['severity']} '
        'labels=${request['labels']} type=${request['type']}',
      );
      expect(request['summary'], 'created through the API');
      expect(request['severity'], ReportSeverity.high.value);
      expect(request['labels'], ['created', 'attachments']);
      final screenshot = createdBundle.ofType('screenshot');
      say('created screenshot entries: ${screenshot.map((s) => s['attrs'])}');
      if (android) {
        final attachments = createdBundle.ofType('attachment');
        for (final entry in attachments) {
          final content = createdBundle.file(entry);
          say(
            'created attachment name=${entry['name']} attrs=${entry['attrs']} '
            'size=${content.size} sha256=${content.sha256}',
          );
        }
        expect(
          attachments.map((e) => e['name']).toSet(),
          {'created note', 'created raw'},
          reason: 'the forgotten report\'s file is not in this one',
        );
        final byName = {for (final e in attachments) e['name'] as String: e};
        expect(
          createdBundle.file(byName['created note']!).sha256,
          sha256Hex(note.readAsBytesSync()),
        );
        expect(
          createdBundle.file(byName['created raw']!).sha256,
          sha256Hex(bytes),
        );
        expect(
          screenshot.any((s) => (s['attrs'] as Map)['annotated'] == true),
          isTrue,
        );
      } else {
        // iOS's created report is applied to the real one at upload as legacy attachments: they are
        // files named after the attachment's file name, with no manifest entry of type `attachment`.
        for (final name in ['created.txt', 'created raw']) {
          final content = createdBundle.entries[name];
          say(
            'created attachment file $name size=${content?.size} sha256=${content?.sha256}',
          );
          expect(content, isNotNull, reason: name);
        }
        expect(
          createdBundle.entries['created.txt']!.sha256,
          sha256Hex(note.readAsBytesSync()),
        );
        expect(createdBundle.entries['created raw']!.sha256, sha256Hex(bytes));
        expect(
          createdBundle.entries.keys.any((k) => k.contains('forgotten')),
          isFalse,
        );
      }
    }

    await Bugsee.setReportHandler(null);
    await Bugsee.stop();
    await dir.delete(recursive: true);
  });
}
