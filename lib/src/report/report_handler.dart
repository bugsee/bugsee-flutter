// The public report-handler registration types. Exported from package:bugsee_flutter.
import 'dart:async';

import 'report_proxy.dart';

/// A report handler: runs for one report, in one of the two phases of [BugseeReportHandler].
///
/// The [report] is live only until the returned future completes (or the SDK's deadline passes,
/// whichever is first): await every edit. An error it throws is reported through
/// `FlutterError.reportError` and the report still proceeds.
typedef ReportHandler = FutureOr<void> Function(ReportProxy report);

/// What to do with a report before and after the SDK assembles it (set with
/// `Bugsee.setReportHandler`). Either phase may be `null`: nothing runs for it, and the SDK is not
/// kept waiting.
///
/// * [onBeforeReportCreated] runs before the report is built (for a dialog, before it opens).
///   **At most once** per report, and it may be skipped.
/// * [onAfterReportCreated] runs once the report is assembled. **At least once**: it can run
///   again, in a later process, for a report that already carries the first run's changes (a
///   recovered crash is one), so make it idempotent (`replaceLabels`, not `addLabels`; set an
///   attribute rather than append). Within one run of the app a repeat is not delivered again.
///
/// Neither runs while the process is terminating (the SDK says so, and Dart cannot run then), and
/// neither can run for a report the SDK recovers before the Flutter engine exists. The window for a
/// handler is the SDK's budget less a margin (see `docs/api-surface.md`); work that must be slow
/// belongs before the edit calls, and the edits must be awaited before the handler returns.
final class BugseeReportHandler {
  const BugseeReportHandler({
    this.onBeforeReportCreated,
    this.onAfterReportCreated,
  });

  final ReportHandler? onBeforeReportCreated;
  final ReportHandler? onAfterReportCreated;

  /// Whether this handler does anything.
  bool get isEmpty =>
      onBeforeReportCreated == null && onAfterReportCreated == null;
}
