// Definition of the internal Dart <-> native bridge. Generated outputs are
// committed; regenerate with `dart scripts/generate_pigeon.dart` (and
// `--check` verifies the committed files are current). Nothing here is public
// API: the generated Dart is not exported from package:bugsee_flutter.
//
// Run from this directory's package (pigeons/pubspec.yaml pins pigeon, which
// cannot be a dependency of the plugin itself: it needs a newer `meta` than
// Flutter 3.41.0 ships).
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: '../lib/src/bridge/messages.g.dart',
    dartOptions: DartOptions(),
    javaOut: '../android/src/main/java/com/bugsee/flutter/Messages.java',
    javaOptions: JavaOptions(
      package: 'com.bugsee.flutter',
      className: 'Messages',
    ),
    swiftOut: '../ios/bugsee_flutter/Sources/bugsee_flutter/Messages.g.swift',
    dartPackageName: 'bugsee_flutter',
  ),
)
/// One SDK lifecycle event, as the native side hands it to Dart.
///
/// The `com.bugsee.lifecycle.` prefix is already stripped (once, natively). A
/// name this version does not know is carried unchanged.
class LifecycleEventMessage {
  LifecycleEventMessage({required this.name, this.reportId, this.data});

  String name;

  /// Set only for the events that carry a report id; carried, not interpreted.
  String? reportId;

  /// String-to-string payload entries that crossed cleanly; null when none.
  Map<String, String>? data;
}

/// The wrapper identity the Dart runtime sends once it is up (workbook 2.4.2).
class WrapperIdentityMessage {
  WrapperIdentityMessage({
    required this.type,
    required this.version,
    this.build,
    required this.context,
  });

  String type;
  String version;
  String? build;
  Map<String, String> context;
}

/// The rectangles of one Flutter view, flat `[l, t, r, b, l, t, r, b, ...]`, in
/// the view's own LOGICAL pixels (Flutter logical pixels: iOS points, Android
/// dp), origin at the view's top-left, right/bottom exclusive. Native converts
/// them to the SDK's unit and places the view on the screen.
class SecureViewRectanglesMessage {
  SecureViewRectanglesMessage({
    required this.viewId,
    required this.devicePixelRatio,
    required this.rectangles,
  });

  /// `FlutterView.viewId`. Mobile engines have only the implicit view (0).
  int viewId;

  /// `FlutterView.devicePixelRatio` the rectangles were measured with. Native
  /// scales by THIS, not by what the display reports now: a density change is
  /// applied natively before Dart has laid out again, so rectangles measured at
  /// the old ratio must not be scaled by the new one. When the two differ,
  /// native covers the whole display until Dart republishes.
  double devicePixelRatio;
  List<double> rectangles;
}

/// The COMPLETE set of secure rectangles of this Dart isolate: a view that is
/// absent from [views] has none. Whole-state, not a delta, so a lost or late
/// message can never leave a rectangle behind.
///
/// Ordering: within one `epoch` native ignores a message whose `sequence` is
/// not newer than the newest it accepted. `epoch` is a random id of the Dart
/// isolate (never a clock: a clock can go backwards). A message with an epoch
/// native has not seen starts a new isolate (a hot restart; its counter restarts
/// at 1) and replaces the old one's state; a message of an epoch native has
/// already retired is a late straggler of a dead isolate and is ignored.
class SecureRectanglesMessage {
  SecureRectanglesMessage({
    required this.epoch,
    required this.sequence,
    required this.views,
  });

  int epoch;
  int sequence;
  List<SecureViewRectanglesMessage> views;
}

/// One report-handler delivery native hands to Dart: the report is reachable
/// only through [handle] (a proxy, never a copy; workbook 7.3.1), and only until
/// the handler's completion runs (7.3.4).
///
/// There is deliberately NO Pigeon enum anywhere in this bridge: Pigeon sends an
/// enum as its ordinal, and workbook 7.4 forbids ordinals. Severity crosses as the
/// SDK's internal integer, the phase as a bool, the issue type as the SDKs' string.
class ReportHandlerRequestMessage {
  ReportHandlerRequestMessage({
    required this.handle,
    required this.deliveryId,
    required this.after,
    required this.reportId,
    required this.type,
    required this.deadlineMs,
  });

  /// Unique per delivery and opaque; names the live report in every report
  /// operation and in [BugseeBridgeHostApi.completeReportHandler].
  String handle;

  /// STABLE for the same report and phase (`before:<reportId>` /
  /// `after:<reportId>`), so Dart can recognise a re-delivery: `onBefore` is
  /// at-most-once and may be skipped, `onAfter` is at-least-once (7.2). Unique per
  /// delivery (never shared) when the report's id could not be read.
  String deliveryId;

  /// `false`: onBeforeReportCreated. `true`: onAfterReportCreated.
  bool after;

  String reportId;

  /// The SDK's issue type string (`bug`, `crash`, `error`), as it reads it. Not
  /// evidence that the report is a recovered crash (7.2.3).
  String type;

  /// How much longer native keeps the report live, measured when this message is
  /// SENT (so time spent queueing for the platform thread is already deducted): it
  /// runs the SDK's completion itself when this has passed, after which every
  /// operation on the handle is refused (7.3.5). The window is the SDK's budget less a
  /// margin; the time the SDK spent queueing the handler before native saw it cannot be
  /// observed, so the margin, not this number, is what absorbs it.
  int deadlineMs;
}

/// A read of a live report. [severity] is the SDK's internal integer (1..5), or
/// null when the SDK reports none (iOS reads 0 for "never set"; 7.4).
class ReportSnapshotMessage {
  ReportSnapshotMessage({
    required this.id,
    required this.type,
    this.summary,
    this.reportDescription,
    this.email,
    this.severity,
    required this.labels,
    required this.attributes,
  });

  String id;
  String type;
  String? summary;

  /// Named `reportDescription`: `description` collides with NSObject's in Swift.
  String? reportDescription;
  String? email;
  int? severity;
  List<String> labels;

  /// Only values both SDKs accept: String, bool, int, double. Anything else the
  /// report holds is left out rather than stringified.
  Map<String, Object> attributes;
}

/// Dart calls native.
@HostApi()
abstract class BugseeBridgeHostApi {
  /// The Dart side is listening: flush what was buffered while it was not (in
  /// order) and deliver from now on.
  void attachLifecycle();

  /// Replaces the natively registered placeholder wrapper with the full
  /// identity. Never throws on malformed content: facts become "unknown".
  void setWrapperIdentity(WrapperIdentityMessage identity);

  /// Publishes the secure rectangles (see [SecureRectanglesMessage]). Never
  /// throws on content: an unusable value fails closed natively. Returns
  /// whether the message was applied (`false`: it was older than one already
  /// applied, which is not an error).
  bool setSecureRectangles(SecureRectanglesMessage state);

  /// A new Dart isolate is up (`BugseeBridge.start` calls it once, first): native completes
  /// every delivery still outstanding to the previous isolate (a hot restart would otherwise
  /// leave each report waiting for its deadline) and forgets which phases had a handler.
  void resetReportHandlers();

  /// Tells native whether a Dart handler exists for each phase. With none, native
  /// completes the SDK's callback at once and never calls Dart (no waiting). Sent
  /// again (false, false) by every new Dart isolate, so a hot restart that has not
  /// registered one yet is not waited on.
  void setReportHandlerPhases(bool before, bool after);

  /// The Dart handler is done (or failed): run the SDK's completion. Idempotent;
  /// a handle native already completed (its deadline) is a no-op.
  void completeReportHandler(String handle);

  /// Report operations. Each returns whether it was APPLIED: `false` means the
  /// handle is no longer live (the completion already ran), which Dart turns into
  /// an error; native ignores the call (7.3.4). An argument the SDK cannot take
  /// (a severity outside 1..5, an attribute value that is not a string, number or
  /// bool) is a PlatformException `invalid-argument` and changes nothing.
  ///
  /// null: the handle is not live.
  ReportSnapshotMessage? reportRead(String handle);

  bool reportSetSummary(String handle, String? value);

  bool reportSetDescription(String handle, String? value);

  bool reportSetEmail(String handle, String? value);

  /// [severity] is the SDK's internal integer, never an ordinal.
  bool reportSetSeverity(String handle, int severity);

  /// Atomic: a reader never sees the report without labels in between.
  bool reportReplaceLabels(String handle, List<String> labels);

  bool reportAddLabels(String handle, List<String> labels);

  bool reportClearLabels(String handle);

  bool reportSetAttribute(String handle, String name, Object value);

  bool reportRemoveAttribute(String handle, String name);

  bool reportClearAttributes(String handle);
}

/// Native calls Dart. Always from the platform (main) thread.
@FlutterApi()
abstract class BugseeBridgeFlutterApi {
  void onLifecycleEvent(LifecycleEventMessage event);

  /// A report handler delivery. Native does NOT wait for this call's reply: the
  /// SDK's completion runs when Dart calls `completeReportHandler`, when the
  /// deadline passes, or when this call fails (Dart not listening). Never
  /// delivered while the SDK says the process is terminating.
  void onReportHandlerRequest(ReportHandlerRequestMessage request);
}
