// Lifecycle events and the status derived from them (workbook Part 4).
// Internal: not exported from package:bugsee_flutter.

import '../status.dart';

/// The events whose payload is the report's id (4.5). Native decides which
/// events get a `reportId`; this copy exists so the drift guard can compare all
/// three (Dart, Java, Objective-C) and so a reader can see the vocabulary.
const Set<String> reportIdEvents = {
  'BeforeReportAssembled',
  'AfterReportAssembled',
  'ReportAssemblyFailed',
  'BeforeReportUploaded',
  'AfterReportUploaded',
  'ReportUploadFailed',
  'ReportUploadFailedWithFutureRetry',
};

/// The only events that are status transitions (4.6). Repeated natively (the hub
/// replays the latest one to a new receiver); the drift guard compares the copies.
const Set<String> statusTransitionEvents = {
  'Launching',
  'Launched',
  'Stopping',
  'Stopped',
};

/// A lifecycle event from the SDK, with the `com.bugsee.lifecycle.` prefix
/// already stripped natively.
///
/// [name] is deliberately an open string, not an enum: a newer SDK adding an
/// event must reach a subscriber through an older wrapper (4.3). A name this
/// version does not know is delivered unchanged.
///
/// An event is never proof that a report exists (4.7): `RelaunchedAfterCrash`
/// fires whether or not a crash report was produced.
final class LifecycleEvent {
  const LifecycleEvent(this.name, {this.reportId, this.data = const {}});

  final String name;

  /// Present only on the events in [reportIdEvents]; carried, not interpreted.
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

/// The status [event] announces, or `null` when it announces none.
///
/// Status is derived from the lifecycle channel only: Android has no status
/// listener, and iOS's `bugseeDidChangeStatus:` belongs to the app's own
/// delegate (4.6). Only these four are transitions. `null` rather than a
/// default for everything else, including a name this version does not know:
/// reporting a status for a non-transition would say the SDK moved when it did
/// not.
BugseeStatus? statusForEvent(LifecycleEvent event) => switch (event.name) {
  'Launching' => BugseeStatus.launching,
  'Launched' => BugseeStatus.launched,
  'Stopping' => BugseeStatus.stopping,
  'Stopped' => BugseeStatus.stopped,
  _ => null,
};
