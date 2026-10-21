// One SDK lifecycle event, as a subscriber sees it. Public: exported from package:bugsee_flutter.
//
// The vocabulary (which events carry a report id, which are status transitions) and the
// status derived from them are internal, in `bridge/lifecycle.dart`.

/// A lifecycle event from the SDK, with the `com.bugsee.lifecycle.` prefix
/// already stripped natively.
///
/// [name] is deliberately an open string, not an enum: a newer SDK adding an
/// event must reach a subscriber through an older wrapper. A name this
/// version does not know is delivered unchanged, so compare against the names you handle and
/// ignore the rest. The SDKs' events include `Launching`, `Launched`, `Stopping`, `Stopped`,
/// `BlackoutStarted`, `BlackoutEnded`, `RelaunchedAfterCrash`, `BeforeReportShown`,
/// `AfterReportShown`, `BeforeReportAssembled`, `AfterReportAssembled`, `ReportAssemblyFailed`,
/// `BeforeReportUploaded`, `AfterReportUploaded`, `ReportUploadFailed` and
/// `ReportUploadFailedWithFutureRetry`; the two platforms do not emit exactly the same set.
///
/// An event is never proof that a report exists: `RelaunchedAfterCrash` fires whether or not a
/// crash report was produced. Events arrive on the app's main isolate, in the order the SDK
/// raised them, from when something listens; the status transitions are also on
/// `Bugsee.statusChanges`, and a listener that subscribes late misses what came before.
final class LifecycleEvent {
  const LifecycleEvent(this.name, {this.reportId, this.data = const {}});

  final String name;

  /// The id of the report this event is about, for the report events (assembled, uploaded,
  /// failed); `null` for the rest. Carried, not interpreted.
  final String? reportId;

  /// String-to-string payload entries that crossed cleanly; usually empty.
  final Map<String, String> data;

  @override
  String toString() =>
      'LifecycleEvent($name${reportId == null ? '' : ', reportId: $reportId'})';

  @override
  bool operator ==(Object other) =>
      other is LifecycleEvent &&
      other.name == name &&
      other.reportId == reportId &&
      _mapEquals(other.data, data);

  @override
  int get hashCode => Object.hash(name, reportId, data.length);
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length &&
    a.entries.every((e) => b.containsKey(e.key) && b[e.key] == e.value);
