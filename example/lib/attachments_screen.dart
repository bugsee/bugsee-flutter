import 'dart:io';
import 'dart:typed_data';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:flutter/material.dart';

/// Files, an annotated screenshot and `Bugsee.createReport`, one button each. Attachments are PATH-first:
/// the plugin copies or moves the file natively, nothing is read into Dart.
class AttachmentsScreen extends StatefulWidget {
  const AttachmentsScreen({super.key});

  @override
  State<AttachmentsScreen> createState() => _AttachmentsScreenState();
}

class _AttachmentsScreenState extends State<AttachmentsScreen> {
  final _log = <String>[];
  CreatedReport? _created;

  void _note(String line) {
    debugPrint('example: $line');
    if (mounted) setState(() => _log.insert(0, line));
  }

  Future<File> _file(String name, String text) async {
    final dir = await Directory.systemTemp.createTemp('bugsee-example');
    return File('${dir.path}/$name')..writeAsStringSync(text);
  }

  Future<void> _run(String name, Future<Object?> Function() action) async {
    try {
      final result = await action();
      _note(result == null ? name : '$name -> $result');
    } on ReportAttachmentException catch (e) {
      _note('$name refused: ${e.reason.name}');
    } on ReportClosedError catch (e) {
      _note('$name: ${e.message}');
    } on BugseeException catch (e) {
      _note('$name failed: ${e.message}');
    }
  }

  /// Uploads a report whose handler attaches a log file (copied) and a temporary file (moved).
  Future<void> _uploadWithFiles() async {
    final log = await _file('app.log', 'example log\n' * 20);
    final temp = await _file('temp.txt', 'temporary, consumed by the move');
    await Bugsee.setReportHandler(
      BugseeReportHandler(
        onBeforeReportCreated: (report) async {
          await report.addAttachment(
            log.path,
            name: 'app log',
            mimeType: 'text/plain',
          );
          await report.addAttachment(temp.path, name: 'temp', move: true);
          await report.addAttachmentBytes(
            Uint8List.fromList([1, 2, 3]),
            name: 'raw',
          );
        },
      ),
    );
    await Bugsee.upload('attachments example', 'files from the handler');
  }

  Future<void> _createAndSend() async {
    final report = await Bugsee.createReport();
    if (report == null) {
      _note('createReport: the SDK made none (launch first)');
      return;
    }
    _created = report;
    await report.setSummary('created from the example');
    final file = await _file('created.txt', 'attached to a created report');
    await report.addAttachment(
      file.path,
      name: 'created',
      mimeType: 'text/plain',
    );
    _note(
      'created report ${report.reportId ?? '(iOS: no id)'}; send or discard it',
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      children: [
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              key: const Key('upload-with-files'),
              onPressed: () => _run('upload with files', _uploadWithFiles),
              child: const Text('Upload with files'),
            ),
            OutlinedButton(
              key: const Key('create-report'),
              onPressed: () => _run('create report', _createAndSend),
              child: const Text('Create report'),
            ),
            OutlinedButton(
              key: const Key('send-created'),
              onPressed: () =>
                  _run('send created', () async => await _created?.upload()),
              child: const Text('Send created'),
            ),
            OutlinedButton(
              key: const Key('discard-created'),
              onPressed: () => _run(
                'discard created',
                () async => await _created?.discard(),
              ),
              child: const Text('Discard created'),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            children: [for (final l in _log) ListTile(title: Text(l))],
          ),
        ),
      ],
    ),
  );
}
