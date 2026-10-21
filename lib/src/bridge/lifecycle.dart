// Lifecycle events and the status derived from them (workbook Part 4).
// Internal: not exported from package:bugsee_flutter.

import '../lifecycle_event.dart';
import '../status.dart';

export '../lifecycle_event.dart' show LifecycleEvent;

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
