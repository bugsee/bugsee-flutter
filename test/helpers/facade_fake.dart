// A native end for the facade tests: records every call with its arguments and answers as
// scripted. Everything the lifecycle/launch side needs is a no-op.
import 'dart:async';
import 'dart:typed_data' show Uint8List;

import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:flutter/services.dart' show PlatformException;

class FacadeFake extends BugseeBridgeHostApi {
  /// `name(arg, arg)` per call, in order.
  final List<String> calls = [];

  /// The structured arguments of the last call to each method.
  final Map<String, List<Object?>> last = {};

  /// When set, the next facade call throws it (once).
  PlatformException? failNext;

  /// Always thrown by calls to this method name.
  final Map<String, PlatformException> failing = {};

  Object? attributeValue;
  Map<String, Object> allAttributes = {};
  String? userIdentifier;
  bool breadcrumbAccepted = true;
  bool blackout = false;
  bool exceptionAccepted = true;

  Phases? phases;

  // ---- Report files (Phase 6) and created reports: scripted answers, calls recorded --------
  /// What the file operations answer (null = applied; `not-live` or a failure code otherwise).
  String? fileReply;

  /// What `createReport` answers (a handle, or null when the SDK made none).
  String? createdHandle = 'cr-1';

  /// What `createdReportRead` answers; null = not live.
  CreatedReportSnapshotMessage? createdSnapshot = CreatedReportSnapshotMessage(
    reportId: 'created-1',
    type: 'bug',
    labels: [],
    attributes: {},
    attachmentNames: [],
    screenshotDisplayIds: [],
  );
  bool createdApplied = true;
  bool createdUploadResult = true;
  Completer<void>? createGate;
  Completer<void>? fileGate;

  /// Once true, `failing['setReportHandlerPhases']` applies (the attach-time call is exempt).
  bool phasesArmed = false;
  int armedPhaseCalls = 0;

  /// The (1-based, once armed) phase calls that fail; the first waits on [firstPhasesGate] if set.
  final Set<int> failPhaseCalls = {};
  Completer<void>? firstPhasesGate;

  /// How many times the plugin was attached (the lifecycle channel).
  int attachCount = 0;

  T _record<T>(String name, List<Object?> args, T result) {
    calls.add('$name(${args.join(', ')})');
    last[name] = args;
    final failure = failing[name] ?? failNext;
    if (failure != null) {
      if (identical(failure, failNext)) failNext = null;
      throw failure;
    }
    return result;
  }

  @override
  Future<void> attachLifecycle() async {
    attachCount++;
  }

  @override
  Future<void> resetReportHandlers() async {}

  @override
  Future<LaunchOutcomeMessage> launch(
    String token,
    Map<String, Object> options,
  ) async => LaunchOutcomeMessage(outcome: 'launched');

  @override
  Future<void> setWrapperIdentity(WrapperIdentityMessage identity) async {}

  @override
  Future<void> setReportHandlerPhases(bool before, bool after) async {
    if (phasesArmed) {
      final n = ++armedPhaseCalls;
      if (n == 1) await firstPhasesGate?.future;
      if (failPhaseCalls.contains(n)) throw refusal('sdk-error');
    }
    final failure = failing['setReportHandlerPhases'];
    if (failure != null && phasesArmed) throw failure;
    phases = Phases(before, after);
  }

  @override
  Future<void> setAttribute(String name, Object value) async =>
      _record('setAttribute', [name, value], null);

  @override
  Future<Object?> getAttribute(String name) async =>
      _record('getAttribute', [name], attributeValue);

  @override
  Future<Map<String, Object>> getAllAttributes() async =>
      _record('getAllAttributes', [], allAttributes);

  @override
  Future<void> clearAttribute(String name) async =>
      _record('clearAttribute', [name], null);

  @override
  Future<void> clearAllAttributes() async =>
      _record('clearAllAttributes', [], null);

  @override
  Future<void> setUserIdentifier(String? identifier) async =>
      _record('setUserIdentifier', [identifier], null);

  @override
  Future<String?> getUserIdentifier() async =>
      _record('getUserIdentifier', [], userIdentifier);

  @override
  Future<void> trace(String name, Object value) async =>
      _record('trace', [name, value], null);

  @override
  Future<void> event(String name, Map<String, Object?>? params) async =>
      _record('event', [name, params], null);

  @override
  Future<bool> addBreadcrumb(BreadcrumbMessage breadcrumb) async =>
      _record('addBreadcrumb', [
        breadcrumb.category,
        breadcrumb.level,
        breadcrumb.message,
        breadcrumb.type,
        breadcrumb.data,
      ], breadcrumbAccepted);

  @override
  Future<void> relayNotification(
    String title,
    String? body,
    int? severity,
    List<String>? fields,
    bool urgent,
  ) async => _record('relayNotification', [
    title,
    body,
    severity,
    fields,
    urgent,
  ], null);

  @override
  Future<void> log(String message, int level) async =>
      _record('log', [message, level], null);

  @override
  Future<void> startBlackout() async {
    _record('startBlackout', [], null);
    blackout = true;
  }

  @override
  Future<void> endBlackout() async {
    _record('endBlackout', [], null);
    blackout = false;
  }

  @override
  Future<bool> isBlackout() async => _record('isBlackout', [], blackout);

  @override
  Future<void> captureViewHierarchy() async =>
      _record('captureViewHierarchy', [], null);

  @override
  Future<bool> logException(
    String payload,
    bool handled,
    String? domain,
  ) async =>
      _record('logException', [payload, handled, domain], exceptionAccepted);

  @override
  Future<void> showReportDialog(
    String? summary,
    String? description,
    int? severity,
    List<String>? labels,
  ) async => _record('showReportDialog', [
    summary,
    description,
    severity,
    labels,
  ], null);

  @override
  Future<String?> reportAddAttachment(
    String handle,
    String path,
    String name,
    String? mimeType,
    bool move,
  ) async {
    await fileGate?.future;
    return _record('reportAddAttachment', [
      handle,
      path,
      name,
      mimeType,
      move,
    ], fileReply);
  }

  @override
  Future<String?> reportAddAttachmentBytes(
    String handle,
    Uint8List data,
    String name,
    String? mimeType,
  ) async => _record('reportAddAttachmentBytes', [
    handle,
    data.length,
    name,
    mimeType,
  ], fileReply);

  @override
  Future<String?> reportClearAttachments(String handle) async =>
      _record('reportClearAttachments', [handle], fileReply);

  @override
  Future<String?> reportSetScreenshot(
    String handle,
    String path,
    int displayId,
    bool annotated,
  ) async => _record('reportSetScreenshot', [
    handle,
    path,
    displayId,
    annotated,
  ], fileReply);

  @override
  Future<String?> reportRemoveScreenshot(String handle, int displayId) async =>
      _record('reportRemoveScreenshot', [handle, displayId], fileReply);

  @override
  Future<String?> createReport(int ttlMs) async {
    await createGate?.future;
    return _record('createReport', [ttlMs], createdHandle);
  }

  @override
  Future<CreatedReportSnapshotMessage?> createdReportRead(
    String handle,
  ) async => _record('createdReportRead', [handle], createdSnapshot);

  @override
  Future<bool> createdReportApply(
    String handle,
    CreatedReportPatchMessage patch,
  ) async => _record('createdReportApply', [
    handle,
    'summary=${patch.setSummary ? patch.summary : '-'}',
    'description=${patch.setDescription ? patch.reportDescription : '-'}',
    'severity=${patch.severity}',
    'labels=${patch.labels}',
    'clear=${patch.clearAttributes}',
    'attributes=${patch.attributes}',
    'remove=${patch.removeAttributes}',
  ], createdApplied);

  @override
  Future<String?> createdReportAddAttachment(
    String handle,
    String path,
    String name,
    String? mimeType,
  ) async => _record('createdReportAddAttachment', [
    handle,
    path,
    name,
    mimeType,
  ], fileReply);

  @override
  Future<String?> createdReportAddAttachmentBytes(
    String handle,
    Uint8List data,
    String name,
    String? mimeType,
  ) async => _record('createdReportAddAttachmentBytes', [
    handle,
    data.length,
    name,
    mimeType,
  ], fileReply);

  @override
  Future<String?> createdReportClearAttachments(String handle) async =>
      _record('createdReportClearAttachments', [handle], fileReply);

  @override
  Future<String?> createdReportSetScreenshot(
    String handle,
    String path,
    bool annotated,
  ) async => _record('createdReportSetScreenshot', [
    handle,
    path,
    annotated,
  ], fileReply);

  @override
  Future<bool> createdReportUpload(String handle) async =>
      _record('createdReportUpload', [handle], createdUploadResult);

  @override
  Future<void> createdReportDiscard(String handle) async =>
      _record('createdReportDiscard', [handle], null);

  @override
  Future<void> upload(
    String summary,
    String description,
    int? severity,
    List<String>? labels,
  ) async => _record('upload', [summary, description, severity, labels], null);
}

class Phases {
  const Phases(this.before, this.after);
  final bool before;
  final bool after;
  @override
  String toString() => 'Phases($before, $after)';
}

PlatformException refusal(String code, [String message = 'refused']) =>
    PlatformException(code: code, message: message);
