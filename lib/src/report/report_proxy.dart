// A proxy of the SDK's report, for the report handlers (workbook Part 7). Public: exported from
// package:bugsee_flutter (the types a handler receives); only its constructor is internal.
import '../bridge/messages.g.dart';
import 'report_enums.dart';

/// An edit was attempted on a report the SDK has already taken back.
///
/// A report is live only until the handler's completion runs (workbook 7.3.4), by
/// the handler returning or by the SDK's own deadline passing (7.3.5). The SDK
/// ignores an edit after that, which is indistinguishable from failure, so the
/// proxy raises this instead: loudly, on the Dart side, and nothing is sent.
class ReportClosedError extends StateError {
  ReportClosedError(String reportId)
    : super(
        'The report $reportId was already handed back to the SDK: its handler '
        'finished or the SDK deadline passed, so this change would be lost. '
        'Await every edit before the handler returns, and do slow work first.',
      );
}

/// A read of the report at one moment. A value, not live: later edits do not change it.
final class ReportSnapshot {
  const ReportSnapshot({
    required this.id,
    required this.typeName,
    required this.summary,
    required this.description,
    required this.email,
    required this.severity,
    required this.labels,
    required this.attributes,
  });

  final String id;

  /// The type as the SDK states it; [type] is `null` for one this version does not know.
  final String typeName;
  ReportType? get type => ReportType.fromWire(typeName);

  final String? summary;
  final String? description;
  final String? email;

  /// `null` when the SDK states none (iOS reads 0 for a report nobody set) or a
  /// value this version does not know.
  final ReportSeverity? severity;
  final List<String> labels;

  /// Strings, bools and numbers only: what both SDKs carry.
  final Map<String, Object> attributes;
}

/// The live report behind one report-handler delivery: an opaque handle plus the
/// operations the contract has, not a copy (workbook 7.3.1).
///
/// Every operation is asynchronous (it crosses to native) and **must be awaited
/// before the handler returns**: the report goes back to the SDK when the handler
/// does, and a later edit throws [ReportClosedError].
///
/// The handler may run again for the same report (`onAfterReportCreated` is
/// at-least-once, workbook 7.2.2), in a later process, against a report that already
/// carries part of the first run's contribution: set attributes and labels rather
/// than append, and do no one-shot work.
///
/// Attachments and screenshots are not here yet (the report handler's public API documents that).
/// // TODO(phase-6): path-first
/// attachments (`addAttachment(path, name, mimeType, move)`): native does the file
/// work and no bytes or streams cross the bridge (workbook 7.3.3).
final class ReportProxy {
  ReportProxy._({
    required this.id,
    required this.typeName,
    required this.deliveryId,
    required String handle,
    required BugseeBridgeHostApi host,
  }) : _handle = handle,
       _host = host;

  /// The SDK's id of this report. Stable across a re-delivery.
  final String id;

  /// The SDK's issue type string. See [ReportType].
  final String typeName;
  ReportType? get type => ReportType.fromWire(typeName);

  /// Stable for this report and phase, unlike the delivery's own handle: two
  /// deliveries with the same id are the same report being handled again.
  final String deliveryId;

  final String _handle;
  final BugseeBridgeHostApi _host;
  bool _live = true;

  /// Whether edits can still reach the SDK. Native has the last word: this turns
  /// `false` when the handler completes, when the deadline passes here, and when
  /// native refuses an edit.
  bool get isLive => _live;

  void _ensureLive() {
    if (!_live) throw ReportClosedError(id);
  }

  /// Sends one operation. Returns normally only when native applied it.
  Future<void> _apply(Future<bool> Function() send) async {
    _ensureLive();
    final applied = await send();
    if (!applied) {
      // Native completed first (its deadline, an engine detach) and ignored the edit.
      _live = false;
      throw ReportClosedError(id);
    }
  }

  /// The report's current state. Throws [ReportClosedError] once it is not live.
  Future<ReportSnapshot> read() async {
    _ensureLive();
    final m = await _host.reportRead(_handle);
    if (m == null) {
      _live = false;
      throw ReportClosedError(id);
    }
    return ReportSnapshot(
      id: m.id,
      typeName: m.type,
      summary: m.summary,
      description: m.reportDescription,
      email: m.email,
      severity: ReportSeverity.fromValue(m.severity),
      labels: List.unmodifiable(m.labels),
      attributes: Map.unmodifiable(m.attributes),
    );
  }

  Future<void> setSummary(String? summary) =>
      _apply(() => _host.reportSetSummary(_handle, summary));

  Future<void> setDescription(String? description) =>
      _apply(() => _host.reportSetDescription(_handle, description));

  Future<void> setEmail(String? email) =>
      _apply(() => _host.reportSetEmail(_handle, email));

  /// Crosses as the SDK's integer ([ReportSeverity.value]), never the ordinal.
  Future<void> setSeverity(ReportSeverity severity) =>
      _apply(() => _host.reportSetSeverity(_handle, severity.value));

  /// Replaces every label with [labels] in one atomic step: a reader never sees
  /// the report without labels in between. The idempotent way to set labels.
  Future<void> replaceLabels(List<String> labels) =>
      _apply(() => _host.reportReplaceLabels(_handle, List.of(labels)));

  /// Adds labels. Not idempotent across a re-delivery: prefer [replaceLabels].
  Future<void> addLabels(List<String> labels) =>
      _apply(() => _host.reportAddLabels(_handle, List.of(labels)));

  Future<void> clearLabels() => _apply(() => _host.reportClearLabels(_handle));

  /// Sets an attribute. The value must be a [String], [bool], [int] or a finite
  /// [double] (the types both SDKs carry): anything else is an [ArgumentError]
  /// and nothing is sent. Setting the same name again replaces it.
  Future<void> setAttribute(String name, Object value) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
    if (!isAllowedAttributeValue(value)) {
      throw ArgumentError.value(
        value.runtimeType,
        'value',
        'an attribute value must be a String, bool, int or a finite double',
      );
    }
    return _apply(() => _host.reportSetAttribute(_handle, name, value));
  }

  Future<void> removeAttribute(String name) =>
      _apply(() => _host.reportRemoveAttribute(_handle, name));

  Future<void> clearAttributes() =>
      _apply(() => _host.reportClearAttributes(_handle));

  /// The value types an attribute may have (what both SDKs carry).
  static bool isAllowedAttributeValue(Object? value) {
    if (value is String || value is bool || value is int) return true;
    return value is double && value.isFinite;
  }
}

/// Creates the proxy for one delivery. Internal (the bridge's): not exported from
/// package:bugsee_flutter, so the proxy's public type carries no bridge types.
ReportProxy createReportProxy({
  required String id,
  required String typeName,
  required String deliveryId,
  required String handle,
  required BugseeBridgeHostApi host,
}) => ReportProxy._(
  id: id,
  typeName: typeName,
  deliveryId: deliveryId,
  handle: handle,
  host: host,
);

/// The completion is about to run (or has): further edits fail. Idempotent. Internal.
void closeReportProxy(ReportProxy proxy) => proxy._live = false;
