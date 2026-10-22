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

/// One snapshot of the managed view hierarchy (`vh`) of one Flutter view, as a JSON TEMPLATE
/// plus the numbers that fill it in (doc/view-hierarchy.md). Native keeps it in memory and
/// answers the SDK's `vh` request from it, synchronously, on whatever thread asks.
///
/// [segments] has `bounds.length / 4 + 2` entries: native writes `segments[0]`, the snapshot's
/// age in milliseconds, `segments[1]`, then for node `k` the box `[x,y,w,h]` converted from
/// `bounds[4k..4k+3]` and `segments[k + 2]`. Never parsed, never changed otherwise. An EMPTY
/// [segments] means "no hierarchy": it clears this isolate's snapshot. A list that does not
/// have the shape above is refused and clears it too (fail closed).
///
/// [bounds] is flat `[l, t, r, b, ...]` in the view's LOGICAL pixels measured at
/// [devicePixelRatio], origin at the view's top-left, converted by the same code that places the
/// secure rectangles (physical pixels on Android, points on iOS).
///
/// Ordering is the secure rectangles' (`epoch`: a random id of the Dart isolate; `sequence`
/// grows per message): a message that is not newer than one native applied is ignored.
class ViewHierarchyMessage {
  ViewHierarchyMessage({
    required this.epoch,
    required this.sequence,
    required this.viewId,
    required this.devicePixelRatio,
    required this.segments,
    required this.bounds,
  });

  int epoch;
  int sequence;

  /// `FlutterView.viewId`. Mobile engines have only the implicit view (0).
  int viewId;
  double devicePixelRatio;
  List<String> segments;
  List<double> bounds;
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

/// One attachment of a report, as the SDK lists it: the display name, the MIME type and the
/// source file's base name. Never the file's content or its place in the SDK's storage.
class ReportAttachmentMessage {
  ReportAttachmentMessage({this.name, this.mimeType, this.fileName});

  String? name;
  String? mimeType;
  String? fileName;
}

/// One screenshot a report holds. [annotated] is whether the user (or the app) drew on it.
class ReportScreenshotMessage {
  ReportScreenshotMessage({required this.displayId, required this.annotated});

  int displayId;
  bool annotated;
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
    required this.attachments,
    required this.screenshots,
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

  /// The attachments, in the order they were added; metadata only.
  List<ReportAttachmentMessage> attachments;

  /// The displays that hold a screenshot, ascending by display id.
  List<ReportScreenshotMessage> screenshots;
}

/// A read of a report made by `createReport` (workbook 7.3 plus the SDKs' own creation APIs). iOS
/// gives the app a `BugseeExtendedReport`, which has no id, type, e-mail, screenshot flag or
/// attachment metadata beyond the name: those are absent here ([reportId] and [type] are empty
/// strings, [attachmentNames] carries only what iOS can list, [screenshotDisplayIds] is `[0]` or
/// empty there).
class CreatedReportSnapshotMessage {
  CreatedReportSnapshotMessage({
    required this.reportId,
    required this.type,
    this.summary,
    this.reportDescription,
    this.severity,
    required this.labels,
    required this.attributes,
    required this.attachmentNames,
    required this.screenshotDisplayIds,
  });

  String reportId;
  String type;
  String? summary;
  String? reportDescription;
  int? severity;
  List<String> labels;
  Map<String, Object> attributes;
  List<String> attachmentNames;
  List<int> screenshotDisplayIds;
}

/// Edits to a created report, validated as a WHOLE before any is applied (one bad field changes
/// nothing). A `set*` flag says the field is part of the patch: that is how a `null` summary
/// (clear it) differs from an absent one (leave it).
class CreatedReportPatchMessage {
  CreatedReportPatchMessage({
    this.setSummary = false,
    this.summary,
    this.setDescription = false,
    this.reportDescription,
    this.severity,
    this.labels,
    this.clearAttributes = false,
    this.attributes,
    this.removeAttributes,
  });

  bool setSummary;
  String? summary;
  bool setDescription;
  String? reportDescription;

  /// The SDK's internal integer (1..5), or null to leave it.
  int? severity;

  /// Replaces the labels when not null.
  List<String>? labels;

  /// Applied first, then [attributes], then [removeAttributes].
  bool clearAttributes;
  Map<String, Object>? attributes;
  List<String>? removeAttributes;
}

/// What native did with a launch request. Strings, not an enum: Pigeon sends an enum as its
/// ordinal (workbook 7.4), and the vocabulary is compared across Dart, Java and Objective-C by
/// `test/launch_drift_test.dart`.
///
/// [outcome] is one of
///   `launched`         the SDK launched and reported it (Android: its callback; iOS: `started:`);
///   `already-running`  the SDK was already Launching or Launched (an auto-init, an earlier
///                      launch, a native launch): the request's options were NOT applied;
///   `deferred`         iOS only: the app is in the background, so the SDK starts when it becomes
///                      active (the SDK answers `started:` YES at once, with nothing launched yet);
///   `refused`          the SDK declined; [reason] says why.
/// [reason] (only for `refused`) is one of `invalid-token`, `stopping` (a stop is still in
/// progress: launch again once it has completed), or `failed` (the SDK gave no further reason; its
/// log has it: a token it rejects, no context, capture that did not start, a stop that overtook it).
class LaunchOutcomeMessage {
  LaunchOutcomeMessage({required this.outcome, this.reason});

  String outcome;
  String? reason;
}

/// A breadcrumb the app records. [level] is the NAME (`debug`, `info`, `warning`, `error`,
/// `fatal`), never a number: the SDKs number their levels differently (Android debug 1 .. fatal 5,
/// iOS error 1 .. debug 4 with no fatal), so each native side maps the name itself.
class BreadcrumbMessage {
  BreadcrumbMessage({
    required this.category,
    required this.level,
    required this.message,
    required this.type,
    this.data,
  });

  String category;
  String level;
  String message;
  String type;

  /// Null leaves the crumb without data. Values Dart has checked: null, bool, number, String,
  /// List, Map.
  Map<String, Object?>? data;
}

/// One line of Dart output the log capture (Phase 5d: `print`, `debugPrint`, `Bugsee.forwardLog`)
/// hands to the SDK. Strings and integers only (no Pigeon enum: Pigeon sends an ordinal).
///
/// Native submits it through the wrapper channel with the wrapper's own source (`Custom`, 98: a
/// constant of native code, not a field: the SDKs accept five wrapper sources and Dart only ever
/// has host-runtime output to report), so it is never recorded as the app's own `Bugsee.log`, and
/// the SDK runs the app's log filter on it always (the channel has no flag to say otherwise).
/// Neither SDK takes a timestamp on the channel: a line is stamped when it reaches the SDK.
class LogLineMessage {
  LogLineMessage({required this.message, required this.level, this.tag});

  /// The text, already filtered and cut to the line cap by Dart; never empty.
  String message;

  /// The SDK's internal `LogLevel` integer (1 error .. 5 verbose: the same on both SDKs).
  int level;

  /// Recorded on Android (`log.json` `tag`); iOS has no tag and drops it. Null or empty: none.
  String? tag;
}

/// One network event the Dart capture (`HttpOverrides`, Phase 5b) hands to the SDK. The wire
/// vocabulary is strings and integers only (no Pigeon enum: Pigeon sends an ordinal).
///
/// Native builds the SDK's own event from it (Android: `BugseeExchangeFactory.createNetworkEvent`,
/// iOS: `BugseeNetworkEvent`, because the iOS 7.0.0-beta7 factory answers nil) and submits it
/// through the wrapper channel with filtering REQUIRED, so the SDK's default sanitizer and the app's
/// native filter still apply (doc/network.md).
class NetworkEventMessage {
  NetworkEventMessage({
    required this.id,
    required this.stage,
    required this.mechanism,
    required this.method,
    required this.url,
    required this.ageMs,
    required this.size,
    required this.statusCode,
    this.headers,
    this.body,
    this.noBodyReason,
    this.statusText,
    this.errorShortMessage,
    this.errorDescription,
    this.redirectedFromUrl,
    this.timings,
  });

  /// Shared by every stage of one request; never empty.
  String id;

  /// `before`, `redirect`, `complete`, `error` or `abort` (the SDK's own stage names; iOS spells
  /// `abort` `cancel` and has no `redirect` stage, which native handles).
  String stage;

  /// The intercepted stack, free-form (`dart:io`).
  String mechanism;
  String method;
  String url;

  /// How long ago the event happened, in milliseconds, measured on Dart's monotonic clock when the
  /// batch was handed to the bridge. Native subtracts it from the SDK's own clock, so the event
  /// is stamped on the clock the SDK validates against (Android: `currentTimestamp()`, which is not
  /// `DateTime.now()` once the device clock has been corrected) and not on one the SDK may drop.
  int ageMs;

  /// Body size in bytes, 0 when unknown.
  int size;

  /// HTTP status, 0 for a stage with none.
  int statusCode;

  /// Header names are lower-case (Dart's), repeated values joined by `, `.
  Map<String, String>? headers;

  /// The body as text, only when Dart captured it (text content, within the SDK's size limit).
  String? body;

  /// Why [body] is absent: `no_data`, `size_too_large`, `unsupported_content_type`,
  /// `no_content_type` or `cant_read_data` (the SDKs' wire values).
  String? noBodyReason;

  /// Android stores it, iOS drops it (the iOS bundle writes null).
  String? statusText;
  String? errorShortMessage;
  String? errorDescription;

  /// iOS carries a redirect as the original URL on the final event; Android has `redirect` stages.
  String? redirectedFromUrl;

  /// Milliseconds, Android only (iOS has no field for them).
  Map<String, double>? timings;
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

  /// Publishes (or, with empty segments, clears) the managed view hierarchy native serves for
  /// the SDK's `vh` request (see [ViewHierarchyMessage]). Never throws on content. Returns
  /// whether the message was applied (`false`: older than one already applied, not an error).
  bool setViewHierarchy(ViewHierarchyMessage snapshot);

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

  // ---- Attachments and screenshots of a handler's report (Phase 6; workbook 7.3.3, report-contract
  // "path-first"). The file work is native: a path crosses, never a stream or a bitmap, and bytes
  // only up to a small cap (see `kMaxAttachmentBytes` in Dart). These run on a background thread (a
  // copy costs I/O proportional to the file; the SDKs say not to do it on the UI thread) and the reply
  // is a failure CODE: null when it was applied, `not-live` when the handle is no longer live (Dart
  // turns it into a ReportClosedError), or one of the codes in `AttachmentWire`. An argument the SDK
  // cannot take is a PlatformException `invalid-argument`. A handle that is live when the call is made
  // is kept live until the call has finished (the SDK's completion waits for it, never the other way).

  /// Copies ([move] false) or moves ([move] true) the file at [path] into the report's storage.
  @async
  String? reportAddAttachment(
    String handle,
    String path,
    String name,
    String? mimeType,
    bool move,
  );

  /// Writes [data] (at most `kMaxAttachmentBytes`) into the report's storage.
  @async
  String? reportAddAttachmentBytes(
    String handle,
    Uint8List data,
    String name,
    String? mimeType,
  );

  /// Removes every attachment, deleting their files.
  @async
  String? reportClearAttachments(String handle);

  /// Decodes the image file at [path] natively and stores it as the screenshot of [displayId].
  /// [annotated] says the picture carries the user's drawing (it reaches the bundle as the screenshot
  /// entry's `annotated` attribute).
  @async
  String? reportSetScreenshot(
    String handle,
    String path,
    int displayId,
    bool annotated,
  );

  /// Removes the screenshot of [displayId] (a no-op when there is none).
  @async
  String? reportRemoveScreenshot(String handle, int displayId);

  // ---- createReport (Phase 6). The SDKs' own way to make a report in code: Android
  // `Bugsee.createReport(listener)` hands the app a `Report`; iOS `+createReportWithCompletion:` hands
  // it a `BugseeExtendedReport`, a different and smaller object. One report at a time, held natively
  // under an opaque handle, released by upload, discard or the time limit; every operation answers
  // `not-live` once it is gone.

  /// Asks the SDK for a report to fill in. Completes with its handle, or null when the SDK made none
  /// (not launched). [ttlMs] is how long native keeps it: after that it is discarded, whatever Dart
  /// does. PlatformException `create-busy` when one is already outstanding, `create-rate-limited` after too many in a minute (the SDKs cannot cancel one), `create-timeout` when the
  /// SDK did not answer in time.
  @async
  String? createReport(int ttlMs);

  /// Null when the handle is not live.
  CreatedReportSnapshotMessage? createdReportRead(String handle);

  /// Applies [patch] as a whole. False when the handle is not live. An unusable field is a
  /// PlatformException `invalid-argument` and nothing is applied.
  bool createdReportApply(String handle, CreatedReportPatchMessage patch);

  /// Copies the file at [path] into the report (never moves it). iOS keeps the bytes in memory
  /// until upload and its SDK takes at most 3 files of 3 MiB (see doc/api-surface.md); a refusal
  /// is `limit` / `too-large`.
  @async
  String? createdReportAddAttachment(
    String handle,
    String path,
    String name,
    String? mimeType,
  );

  @async
  String? createdReportAddAttachmentBytes(
    String handle,
    Uint8List data,
    String name,
    String? mimeType,
  );

  @async
  String? createdReportClearAttachments(String handle);

  /// [annotated] is Android only: iOS answers `unsupported` for true.
  @async
  String? createdReportSetScreenshot(
    String handle,
    String path,
    bool annotated,
  );

  /// Hands the report to the SDK for processing and upload; the handle is dead from now on whatever the
  /// answer. Completes with whether the SDK scheduled it (Android: its callback; iOS: it has been
  /// handed off); false only means the SDK declined. PlatformException `not-live` when the handle is not
  /// live, `upload-timeout` when the SDK did not answer in 45 s (it may still send the report).
  @async
  bool createdReportUpload(String handle);

  /// Releases the report without uploading it (deletes the attachments the app added on Android; the
  /// SDK has no way to cancel a created report, so it is simply never sent). A no-op for an unknown
  /// handle.
  void createdReportDiscard(String handle);

  /// Launches the SDK with the flat `com.bugsee.option.*` map built by the Dart encoder (enums as
  /// the SDK's INTERNAL integers; Android converts them to its enum constants natively). Completes
  /// when the SDK answers: after capture started (`launched`), at once for the other outcomes. An
  /// exception the SDK throws crosses as a PlatformException `launch-failed`.
  @async
  LaunchOutcomeMessage launch(String token, Map<String, Object> options);

  /// Stops the SDK; completes when it has stopped (at once when it already is).
  @async
  void stop();

  /// The SDK's status, by name: `stopped`, `launching`, `launched` or `stopping` (names, never
  /// ordinals). Read from the SDK itself, not derived from the lifecycle channel.
  String status();

  /// The launch options in effect. With [hostOnly] false: the host-supplied options merged over the
  /// SDK defaults (the same on both SDKs); with true: the SDK's `getHostLaunchOptions`, whose
  /// platforms differ (Android: every recognised option the app passed; iOS: only those that differ
  /// from the iOS default). Keyed by `com.bugsee.option.*`, enums as internal integers, floats as
  /// doubles; hidden (`$$`) options are removed by Dart.
  Map<String, Object> launchOptions(bool hostOnly);

  // ---- Facade (Phase 4b). Every call below runs on the platform thread (a Pigeon handler
  // without a task queue), which is the thread both SDKs' public API is documented to be
  // called from. An argument the SDK cannot take is a PlatformException `invalid-argument`
  // (Dart has validated already), an SDK exception is `sdk-error`, and a call made while the
  // plugin has no engine is `not-attached`; none of them changes anything. What a call does
  // BEFORE the SDK is launched is the SDK's own behaviour (the wrapper queues nothing) and is
  // listed per method in doc/api-surface.md.

  /// Sets a custom attribute (persisted by the SDK across launches). [value] is a String, bool,
  /// int or double. After the SDK call native reads the value back: a value the SDK did not keep
  /// (size limits that differ per platform) is a PlatformException `attribute-rejected` and
  /// the previous value stays.
  void setAttribute(String name, Object value);

  /// The attribute's value as a String, bool, int, double or List<String> (Android can hold a
  /// set of strings that this API cannot create), or null when it is not set.
  Object? getAttribute(String name);

  /// Every attribute, same value types as [getAttribute]; empty when none.
  Map<String, Object> getAllAttributes();

  /// A no-op when the attribute is not set.
  void clearAttribute(String name);

  void clearAllAttributes();

  /// Null or empty clears (Android alone would store an empty string).
  void setUserIdentifier(String? identifier);

  /// Null when none is set (an empty identifier reads as none).
  String? getUserIdentifier();

  /// [value] is a String, bool, int or double.
  void trace(String name, Object value);

  void event(String name, Map<String, Object?>? params);

  /// Whether the SDK was handed the crumb: false when breadcrumb capture is off
  /// (`capture.breadcrumbs`, default off on both SDKs), the SDK is not launched or made no crumb.
  /// Handing it over is not proof it was recorded (the app's breadcrumb filter may drop it).
  bool addBreadcrumb(BreadcrumbMessage breadcrumb);

  /// [severity] is the SDK's internal integer (1..5) or null for unset. [fields] are the extra
  /// rows as a FLAT list `[key, value, key, value, ...]` (even length): a Pigeon map decodes to a
  /// hash map and loses the order, which Android's SDK preserves when given an ordered map (iOS's
  /// takes a dictionary, unordered). A call before launch is ignored by both SDKs.
  void relayNotification(
    String title,
    String? body,
    int? severity,
    List<String>? fields,
    bool urgent,
  );

  /// App-level log line. [level] is the SDK's internal `LogLevel` integer (1..5, the same on both).
  void log(String message, int level);

  void startBlackout();

  void endBlackout();

  /// Asks the SDK to capture the view hierarchy now (`Bugsee.captureViewHierarchy`), which asks the
  /// wrapper for the managed one: native answers from the snapshot Dart last published. A no-op
  /// before the SDK is launched, and when its `capture.view-hierarchy` option is off.
  void captureViewHierarchy();

  bool isBlackout();

  /// Opens the SDK's report dialog. A no-op before the SDK is launched.
  void showReportDialog(
    String? summary,
    String? description,
    int? severity,
    List<String>? labels,
  );

  /// Creates and uploads a report with no UI. A no-op before the SDK is launched.
  void upload(
    String summary,
    String description,
    int? severity,
    List<String>? labels,
  );

  // ---- Network capture (Phase 5b). Unlike the rest of the facade this one runs on a background thread.

  /// Hands a batch of captured network events to the SDK through the wrapper channel, in order.
  /// Returns how many the SDK was handed: native drops the rest without error (the SDK is not
  /// launched, `capture.network` is off, the plugin has no channel yet, a malformed event). Never
  /// throws for a single bad event.
  ///
  /// Runs on a serial BACKGROUND thread of the plugin, not the platform (main) thread: the SDK
  /// applies its sanitizer (and the app's native filter, if it set one) on the calling thread, up to
  /// one body-size-limit's worth of text per event, and that must not take UI time. The channel is
  /// documented to be callable from any thread; one queue keeps the order.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  int addNetworkEvents(List<NetworkEventMessage> events);

  // ---- Log capture (Phase 5d). Like network injection this runs on a background thread.

  /// Hands a batch of captured Dart output lines to the SDK through the wrapper channel, in order,
  /// attributed to the wrapper (`Custom`). Returns how many lines the SDK was handed: native drops
  /// the rest without error (the SDK is neither launching nor launched, `capture.logs` is off, the
  /// plugin has no channel yet, a malformed line). Never throws for a single bad line.
  ///
  /// Runs on a serial BACKGROUND thread of the plugin: the app's native log filter, if it set one,
  /// runs on the calling thread (documented for the channel), and an exception it throws must not
  /// reach the platform thread.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  int addLogLines(List<LogLineMessage> lines);

  // ---- Exceptions (Phase 5a). One call on the platform thread, like the facade; failures use the
  // facade's codes (`invalid-argument`, `sdk-error`, `not-attached`).

  /// Hands a Dart error to the SDK. [payload] is the JSON document the backend reads for a Flutter
  /// exception (built by Dart, `lib/src/exceptions`; native forwards it untouched, as the reason of
  /// an exception named `FlutterManagedException`: the name the backend routes on). [handled]
  /// true: an error report (Android `logException`, iOS `logException:reason:domain:`); false: a
  /// crash report (Android `logUnhandledException`, iOS `logUnhandledException:reason:`).
  /// [domain] is the SDK's grouping domain, null for none (iOS has no domain on the unhandled
  /// path: dropped there).
  ///
  /// Answers whether the SDK was HANDED the exception: `false` when it is not launching or
  /// launched (before launch, after stop), where the SDK would drop it itself (Android, iOS
  /// handled) or, on iOS unhandled, would still write a crash report, so the wrapper gates it. A
  /// payload over the contract's limit or an empty one is `invalid-argument`, nothing reaches the SDK.
  ///
  /// `@async`: Android hands the SDK call to its own single background thread (an unhandled error
  /// is written by the SDK on the calling thread, which snapshots the capture ring: up to a couple
  /// of seconds on the platform thread would be jank or an ANR) and replies when it ran; a full queue
  /// answers `false`. iOS answers at once on the platform thread.
  @async
  bool logException(String payload, bool handled, String? domain);
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
