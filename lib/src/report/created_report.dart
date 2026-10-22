// The report `Bugsee.createReport` hands out: the SDKs' own way to make a report in code, fill it in
// and send it (Android `Bugsee.createReport(listener)` + `Bugsee.upload(report)`, iOS
// `+createReportWithCompletion:` + `+uploadReport:`). Public; only the constructor is internal.
import 'dart:async';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/services.dart' show PlatformException;

import '../bridge/messages.g.dart';
import '../errors.dart';
import '../launch.dart';
import 'attachments.dart';
import 'report_enums.dart';
import 'report_proxy.dart';

/// An operation on a [CreatedReport] that is no longer live: it was uploaded, discarded, or its time
/// to live passed. A [ReportClosedError], so `on ReportClosedError` covers a handler's report too.
class CreatedReportClosedError extends ReportClosedError {
  CreatedReportClosedError(String reportId)
    : super.because(
        'The created report ${reportId.isEmpty ? '' : '$reportId '}is no longer live: it was '
        'uploaded, discarded, or its time to live passed, so this change would be lost.',
      );
}

/// Why `Bugsee.createReport` failed.
enum CreateReportFailure {
  /// A created report is already outstanding: [CreatedReport.upload] or [CreatedReport.discard] it
  /// (or wait for its time to live) first. One at a time keeps a forgotten report from holding the
  /// SDK's storage and capture buffers for good.
  busy,

  /// The SDK did not answer in time. Whatever it makes later is discarded.
  timeout,

  /// Too many created reports were started in a minute. The SDKs have no way to cancel a created report:
  /// each one the app discards or forgets leaves the SDK's opened snapshot on disk until its next
  /// launch's recovery drops it, so the plugin allows a handful a minute.
  rateLimited,

  /// Thrown by [CreatedReport.upload]: the SDK did not say in time whether it took the report. The
  /// report is gone from the plugin's side and the SDK MAY STILL SEND IT: do not upload it again.
  uploadTimeout,
}

/// `Bugsee.createReport` failed. [reason] says why.
class CreateReportException extends BugseeException {
  const CreateReportException(this.reason, super.message, {super.cause});

  final CreateReportFailure reason;

  @override
  String toString() => 'CreateReportException(${reason.name}): $message';
}

/// A read of a [CreatedReport] at one moment. A value, not live.
final class CreatedReportSnapshot {
  const CreatedReportSnapshot({
    required this.reportId,
    required this.typeName,
    required this.summary,
    required this.description,
    required this.severity,
    required this.labels,
    required this.attributes,
    required this.attachmentNames,
    required this.screenshotDisplayIds,
  });

  /// The SDK's id for the report; `null` on iOS, whose created report has none.
  final String? reportId;

  /// `bug`; iOS does not say, so it is `bug` there too.
  final String typeName;
  ReportType? get type => ReportType.fromWire(typeName);

  final String? summary;
  final String? description;

  /// `null` when the SDK states none or a value this version does not know.
  final ReportSeverity? severity;
  final List<String> labels;

  /// Strings, bools and numbers only.
  final Map<String, Object> attributes;

  /// The display names of the attachments added so far.
  final List<String> attachmentNames;

  /// The displays that hold a screenshot (iOS: `[0]` or empty).
  final List<int> screenshotDisplayIds;
}

/// A report made by `Bugsee.createReport`, held natively until it is uploaded, discarded or its time to
/// live passes. Fill it in, then [upload] it.
///
/// **What differs by platform** (the SDKs hand the app different objects; nothing here pretends
/// otherwise):
///
/// * Android gives a real report: the files go into the report's own storage at once (copied, so the
///   source stays), the id and type are real, and the handler's `onBeforeReportCreated` already ran
///   inside `createReport`.
/// * iOS gives a `BugseeExtendedReport`: attachments are held in memory until [upload] (at most 3, each at
///   most 3 MiB, the legacy rules; `mimeType` is not kept), there is no id, and one screenshot (display
///   0) that cannot be marked annotated. The handler's before and after both run at [upload], after
///   this object's fields were applied.
///
/// Every operation throws a [CreatedReportClosedError] once the report is gone, and a
/// [ReportAttachmentException] when a file is refused (the report is then unchanged).
final class CreatedReport {
  CreatedReport._({
    required this.reportId,
    required String typeName,
    required String handle,
    required BugseeBridgeHostApi host,
    required Duration timeToLive,
  }) : _typeName = typeName,
       _handle = handle,
       _host = host {
    _expiry = Timer(timeToLive, _expire);
  }

  /// The SDK's id for the report; `null` on iOS, whose created report has none.
  final String? reportId;
  final String _typeName;
  ReportType? get type => ReportType.fromWire(_typeName);

  final String _handle;
  final BugseeBridgeHostApi _host;
  late Timer _expiry;
  bool _live = true;

  /// Whether the report can still be changed and uploaded.
  bool get isLive => _live;

  void _expire() {
    // Native discards at the same moment (it is told the same duration); this only spares a round
    // trip for the next call.
    _live = false;
  }

  void _end() {
    _live = false;
    _expiry.cancel();
  }

  void _ensureLive() {
    if (!_live) throw CreatedReportClosedError(reportId ?? '');
  }

  Future<CreatedReportSnapshot> read() async {
    _ensureLive();
    final m = await _host.createdReportRead(_handle);
    if (m == null) {
      _end();
      throw CreatedReportClosedError(reportId ?? '');
    }
    return CreatedReportSnapshot(
      reportId: m.reportId.isEmpty ? null : m.reportId,
      typeName: m.type,
      summary: m.summary,
      description: m.reportDescription,
      severity: ReportSeverity.fromValue(m.severity),
      labels: List.unmodifiable(m.labels),
      attributes: Map.unmodifiable(m.attributes),
      attachmentNames: List.unmodifiable(m.attachmentNames),
      screenshotDisplayIds: List.unmodifiable(m.screenshotDisplayIds),
    );
  }

  Future<void> _patch(String what, Object patch) async {
    _ensureLive();
    final bool applied;
    try {
      applied = await _sendPatch(_host, _handle, patch);
    } on PlatformException catch (e) {
      if (e.code == FacadeWire.invalidArgument) {
        throw BugseeArgumentException(
          'argument',
          '$what: ${e.message ?? e.code}',
          cause: e,
        );
      }
      rethrow;
    }
    if (!applied) {
      _end();
      throw CreatedReportClosedError(reportId ?? '');
    }
  }

  /// Sets (or, with `null`, clears) the summary.
  Future<void> setSummary(String? summary) =>
      _patch('setSummary', _Patches.summary(summary));

  Future<void> setDescription(String? description) =>
      _patch('setDescription', _Patches.description(description));

  /// Crosses as the SDK's integer ([ReportSeverity.value]).
  Future<void> setSeverity(ReportSeverity severity) =>
      _patch('setSeverity', _Patches.severity(severity.value));

  /// Replaces every label with [labels].
  Future<void> replaceLabels(List<String> labels) =>
      _patch('replaceLabels', _Patches.labels(List.of(labels)));

  /// Sets an attribute on this report (not globally). The value must be a [String], [bool], [int] or a
  /// finite [double]; anything else is a [BugseeArgumentException] and nothing is sent.
  Future<void> setAttribute(String name, Object value) async {
    if (name.isEmpty) {
      throw const BugseeArgumentException('name', 'must not be empty');
    }
    if (!ReportProxy.isAllowedAttributeValue(value)) {
      throw BugseeArgumentException(
        'value',
        'an attribute value must be a String, bool, int or a finite double',
      );
    }
    await _patch('setAttribute', _Patches.attribute(name, value));
  }

  Future<void> removeAttribute(String name) =>
      _patch('removeAttribute', _Patches.remove(name));

  Future<void> clearAttributes() =>
      _patch('clearAttributes', _Patches.clearAttributes());

  /// Copies the file at [path] into the report (the source is left alone: a created report has no
  /// move). Rules as [ReportProxy.addAttachment]; on iOS also at most 3 attachments of at most 3 MiB,
  /// and [mimeType] is not kept.
  Future<void> addAttachment(
    String path, {
    required String name,
    String? mimeType,
  }) async {
    final p = checkAttachmentPath(path);
    final n = checkAttachmentName(name);
    final m = checkMimeType(mimeType);
    await _file(
      'addAttachment',
      () => _host.createdReportAddAttachment(_handle, p, n, m),
    );
  }

  /// Adds [bytes] (1 to [maxAttachmentBytes]; empty data is refused because iOS would drop it).
  Future<void> addAttachmentBytes(
    Uint8List bytes, {
    required String name,
    String? mimeType,
  }) async {
    final n = checkAttachmentName(name);
    final m = checkMimeType(mimeType);
    if (bytes.isEmpty) {
      throw const BugseeArgumentException(
        'bytes',
        'a created-report attachment must not be empty',
      );
    }
    if (bytes.length > maxAttachmentBytes) {
      throw BugseeArgumentException(
        'bytes',
        'at most $maxAttachmentBytes bytes can be attached as bytes; '
            'write a file and attach its path',
      );
    }
    await _file(
      'addAttachmentBytes',
      () => _host.createdReportAddAttachmentBytes(_handle, bytes, n, m),
    );
  }

  Future<void> clearAttachments() => _file(
    'clearAttachments',
    () => _host.createdReportClearAttachments(_handle),
  );

  /// Sets the screenshot (display 0) from the image file at [path]. [annotated] is Android only: on iOS
  /// `true` is a [ReportAttachmentException] (`unsupported`) and nothing changes.
  Future<void> setScreenshot(String path, {bool annotated = false}) async {
    final p = checkAttachmentPath(path);
    await _file(
      'setScreenshot',
      () => _host.createdReportSetScreenshot(_handle, p, annotated),
    );
  }

  Future<void> _file(String what, Future<String?> Function() send) async {
    _ensureLive();
    final String? code;
    try {
      code = await send();
    } on PlatformException catch (e) {
      if (e.code == FacadeWire.invalidArgument) {
        throw BugseeArgumentException(
          'argument',
          '$what: ${e.message ?? e.code}',
          cause: e,
        );
      }
      rethrow;
    }
    if (code == null) return;
    if (code == ReportWire.notLive) {
      _end();
      throw CreatedReportClosedError(reportId ?? '');
    }
    throw attachmentFailure(what, code);
  }

  /// Hands the report to the SDK to process and upload (the report handler's after phase runs first).
  /// The report is dead from now on, whatever the answer: it completes with whether the SDK scheduled
  /// it (`false`: the SDK declined). Calling it twice, or after it expired, throws a
  /// [CreatedReportClosedError]; an SDK that does not answer in 45 s is a [CreateReportException]
  /// (`uploadTimeout`) and the report may still be sent.
  Future<bool> upload() async {
    _ensureLive();
    // Before the call, not after it: two overlapping uploads must cross once.
    _end();
    try {
      return await _host.createdReportUpload(_handle);
    } on PlatformException catch (e) {
      if (e.code == ReportWire.notLive) {
        // Native already released it (its time to live started before Dart's timer did).
        throw CreatedReportClosedError(reportId ?? '');
      }
      final failure = createReportFailure(e);
      if (failure != null) throw failure;
      rethrow;
    }
  }

  /// Releases the report without uploading it, and deletes the attachments added to it (Android). The
  /// SDKs have no way to cancel a created report, so it is simply never sent (what the SDK still holds
  /// for it is dropped with the process, and an unsubmitted one is discarded at the next launch).
  /// Harmless on a report that is already gone.
  Future<void> discard() async {
    final wasLive = _live;
    _end();
    if (wasLive) await _host.createdReportDiscard(_handle);
  }
}

Future<bool> _sendPatch(
  BugseeBridgeHostApi host,
  String handle,
  Object patch,
) => host.createdReportApply(handle, patch as CreatedReportPatchMessage);

/// The patches the setters send; here so the public class names no bridge type.
abstract final class _Patches {
  static Object summary(String? v) =>
      CreatedReportPatchMessage(setSummary: true, summary: v);
  static Object description(String? v) =>
      CreatedReportPatchMessage(setDescription: true, reportDescription: v);
  static Object severity(int v) => CreatedReportPatchMessage(severity: v);
  static Object labels(List<String> v) => CreatedReportPatchMessage(labels: v);
  static Object attribute(String name, Object value) =>
      CreatedReportPatchMessage(attributes: {name: value});
  static Object remove(String name) =>
      CreatedReportPatchMessage(removeAttributes: [name]);
  static Object clearAttributes() =>
      CreatedReportPatchMessage(clearAttributes: true);
}

/// Wraps a handle native minted. Internal (the runtime's): not exported.
CreatedReport createCreatedReport({
  required String? reportId,
  required String typeName,
  required String handle,
  required BugseeBridgeHostApi host,
  required Duration timeToLive,
}) => CreatedReport._(
  reportId: reportId,
  typeName: typeName,
  handle: handle,
  host: host,
  timeToLive: timeToLive,
);

/// The exception for a `createReport` PlatformException; `null` for any other code.
CreateReportException? createReportFailure(PlatformException e) {
  return switch (e.code) {
    ReportWire.createBusy => CreateReportException(
      CreateReportFailure.busy,
      'a created report is already outstanding: upload or discard it first',
      cause: e,
    ),
    ReportWire.createTimeout => CreateReportException(
      CreateReportFailure.timeout,
      'the SDK did not answer in time',
      cause: e,
    ),
    ReportWire.createRateLimited => CreateReportException(
      CreateReportFailure.rateLimited,
      'too many created reports were started in a minute (the SDKs cannot cancel one)',
      cause: e,
    ),
    ReportWire.uploadTimeout => CreateReportException(
      CreateReportFailure.uploadTimeout,
      'the SDK did not say in time whether it took the report; it may still send it, '
      'so do not upload it again',
      cause: e,
    ),
    _ => null,
  };
}
