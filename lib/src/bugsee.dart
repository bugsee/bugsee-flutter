// The public entry point. Everything behind it is `BugseeRuntime`, which a test can replace.
import 'package:meta/meta.dart' show visibleForTesting;

import 'bugsee_runtime.dart';
import 'errors.dart';
import 'facade/breadcrumb.dart';
import 'launch.dart';
import 'lifecycle_event.dart';
import 'network/network_event.dart';
import 'network/network_pipeline.dart' show NetworkCaptureStats;
import 'options/bugsee_options.g.dart';
import 'report/report_enums.dart';
import 'report/report_handler.dart';
import 'status.dart';

/// Replaces the native side (and everything else the facade uses). For tests only: not exported
/// from package:bugsee_flutter, so `BugseeRuntime` is not part of the public signature.
@visibleForTesting
void debugSetBugseeRuntime(BugseeRuntime runtime) => Bugsee._runtime = runtime;

/// The Bugsee SDK.
///
/// ```dart
/// final result = await Bugsee.launch(
///   'YOUR_APP_TOKEN',
///   options: const BugseeOptions(captureVideo: true, detectHang: true),
/// );
/// ```
///
/// Android and iOS are two SDKs behind one set of options (`BugseeOptions`). Launching is
/// asynchronous in both: [launch] completes once the SDK reports that capture started; follow
/// the transitions with [statusChanges].
abstract final class Bugsee {
  static BugseeRuntime _runtime = BugseeRuntime();

  /// Launches the SDK with the application [token] from the Bugsee dashboard.
  ///
  /// [options] configure the SDK for this launch. They are ignored when the SDK is already
  /// running (see [LaunchResult.alreadyRunning]); stop it first to change them.
  ///
  /// Completes with what happened. This is when the SDK answered, which is not always "capture
  /// started":
  ///  * [LaunchResult.launched]: the SDK launched and capture started;
  ///  * [LaunchResult.alreadyRunning]: the SDK was already `launching` or `launched`; nothing was
  ///    changed and these options were not applied (if it is still `launching`, capture has not
  ///    started: see [waitUntilLaunched]);
  ///  * [LaunchResult.deferred]: iOS, the app is not active yet; the SDK starts when it is. Not a
  ///    failure: do not write `if (result != LaunchResult.launched)`; see [waitUntilLaunched].
  ///
  /// Throws a [BugseeLaunchException] when the SDK did not launch (a blank token, a stop still in
  /// progress, a refusal, an exception native side, an unsupported platform), and an
  /// [ArgumentError] for an option that cannot be honoured on any platform (an unknown key in
  /// `BugseeOptions.custom`, a bad endpoint). An option that exists on the other platform only is
  /// not an error: it is skipped, with a warning in debug builds.
  ///
  /// Registers the Flutter wrapper's identity with the SDK first (it is in place from process
  /// start; the Flutter, Dart and engine versions are added before the launch).
  static Future<LaunchResult> launch(
    String token, {
    BugseeOptions options = const BugseeOptions(),
  }) => _runtime.launch(token, options);

  /// Completes with whether the SDK is launched, waiting for a launch that is still starting:
  /// the answer to [LaunchResult.deferred] (iOS, the usual result of launching before `runApp`)
  /// and to [LaunchResult.alreadyRunning] while the SDK is still `launching`.
  ///
  /// `true` as soon as the status is `launched`. `false` when the launch failed (the status went
  /// back to `stopped` after `launching`) or nothing happened within [timeout]. A deferred launch
  /// that never starts (the app is never active) times out. Never throws for a failed launch.
  static Future<bool> waitUntilLaunched({
    Duration timeout = const Duration(seconds: 30),
  }) => _runtime.waitUntilLaunched(timeout);

  /// Stops the SDK; completes when it has stopped (at once if it was not running). A launch
  /// before that is refused ([LaunchFailure.stopping]).
  ///
  /// The next [launch] applies the options it is given: this is how the options change.
  static Future<void> stop() => _runtime.stop();

  /// The status the SDK last announced to this app (`launching`, `launched`, `stopping`,
  /// `stopped`), or [BugseeStatus.stopped] before it announced one.
  ///
  /// Kept from the SDK's lifecycle events, so it is not available the instant the app starts:
  /// the first call attaches to the SDK, and a launch made natively before that (the Android
  /// manifest auto-init) is reported once attached. Use [getStatus] for the SDK's own answer.
  static BugseeStatus get status {
    _runtime.ensureStartedInBackground();
    return _runtime.status;
  }

  /// Every status transition, from when a listener subscribes: only `launching`, `launched`,
  /// `stopping` and `stopped`; no other SDK event changes the status.
  ///
  /// A broadcast stream. A transition that happened before the first call into this plugin is
  /// delivered when it attaches (the latest status is replayed).
  static Stream<BugseeStatus> get statusChanges {
    _runtime.ensureStartedInBackground();
    return _runtime.statusChanges;
  }

  /// The SDK's current status, read from the SDK.
  static Future<BugseeStatus> getStatus() => _runtime.getStatus();

  /// Whether the SDK is launched and capturing (`status == launched`, read from the SDK). False
  /// during the launch window, while capture is still starting.
  static Future<bool> isLaunched() async =>
      await _runtime.getStatus() == BugseeStatus.launched;

  /// The launch options in effect: what the app supplied, merged over the SDK's defaults.
  ///
  /// Keyed by `com.bugsee.option.*`; enums as the SDK's internal integer, floats as `double` (with
  /// the precision of a 32-bit float). Before the first launch these are the SDK's defaults, which
  /// differ between Android and iOS for a few options. Internal (`$$`) options are never included.
  /// Both SDKs, at the versions this plugin pins, return the merged set here (the 6.x iOS SDK
  /// returned only what differed from its defaults).
  static Future<Map<String, Object>> getLaunchOptions() =>
      _runtime.launchOptions(hostOnly: false);

  /// The options the app supplied to the last launch (empty before the first), without the
  /// defaults [getLaunchOptions] merges them over. Replaced, not merged, by the next launch.
  ///
  /// The two platforms do NOT agree on what counts as supplied: Android reports every recognised
  /// option the app passed, iOS reports only those whose value differs from the iOS default (an
  /// option set to its default is absent there). So on iOS "absent" does not mean "the app did not
  /// set it"; use [getLaunchOptions] for what is in effect.
  static Future<Map<String, Object>> getHostLaunchOptions() =>
      _runtime.launchOptions(hostOnly: true);

  // ---- Attributes -------------------------------------------------------------------------------

  /// Sets a custom attribute that is attached to every report from now on, and persists across
  /// launches (the SDKs store it on the device).
  ///
  /// [value] is a [String] (at most 1024 UTF-16 units), a [bool], an [int] or a finite [double]
  /// below the largest 32-bit float in magnitude: the intersection of what Android and iOS store.
  /// Set it again to replace it.
  ///
  /// Throws a [BugseeAttributeException]: `invalidName` (empty), `invalidValue` (another type, too
  /// long, not finite: nothing reaches the SDK) or `rejected`. The SDKs drop a value over their size
  /// limits without saying so (one value, or all attributes together, which differ between Android
  /// and iOS: about 800 ASCII characters on iOS, 25 KB in all on Android); this reads the value
  /// back and reports it as `rejected`, and the previous value stays. Android stores a non-integer
  /// as a 32-bit float, so `0.1` is read back as `0.1`, and a double with more digits is narrowed the same way by `getAttribute` and
  /// `getAllAttributes` (`3.141592653589793` reads `3.1415927`); iOS keeps the double.
  ///
  /// Works before [launch] on both platforms: the SDKs keep attributes outside the session.
  static Future<void> setAttribute(String name, Object value) =>
      _runtime.setAttribute(name, value);

  /// The attribute's value, or `null` when it is not set: a [String], [bool], [int], [double], or
  /// (Android only, for a set of strings the app set natively) a `List<String>`.
  static Future<Object?> getAttribute(String name) =>
      _runtime.getAttribute(name);

  /// Every attribute (same value types as [getAttribute]); empty when none. Not modifiable.
  static Future<Map<String, Object>> getAllAttributes() =>
      _runtime.getAllAttributes();

  /// Removes one attribute; does nothing when it is not set.
  static Future<void> clearAttribute(String name) =>
      _runtime.clearAttribute(name);

  /// Removes every attribute.
  static Future<void> clearAllAttributes() => _runtime.clearAllAttributes();

  // ---- User identity ----------------------------------------------------------------------------

  /// Sets the identifier of the current user, attached to every report from now on and persisted
  /// across launches. If it is an email address the server may link reports to that user's account.
  /// An empty string clears it (the same as [clearUserIdentifier] on both platforms; Android alone
  /// would store an empty identifier).
  ///
  /// The SDKs have this one field: there is no separate name or email. Works before [launch] on
  /// both platforms (Android: preferences, iOS: the Keychain, with `NSUserDefaults` as a fallback).
  static Future<void> setUserIdentifier(String identifier) =>
      _runtime.setUserIdentifier(identifier);

  /// The identifier set with [setUserIdentifier], or `null` when there is none.
  static Future<String?> getUserIdentifier() => _runtime.getUserIdentifier();

  /// Clears the identifier: reports are no longer associated with a user.
  static Future<void> clearUserIdentifier() => _runtime.setUserIdentifier(null);

  // ---- Events, traces, logs ---------------------------------------------------------------------

  /// Records a named event in the report's timeline, with optional [params].
  ///
  /// [params] holds strings, numbers, bools, `null`, and lists and maps (string keys) of those,
  /// at most 16 levels deep; a finite number below 2^63. Anything else is a
  /// [BugseeArgumentException], thrown before the SDK is touched, naming the path of the bad value.
  /// The map is copied, so changing it afterwards changes nothing.
  ///
  /// **Dropped before [launch]** (and after stop) on both platforms; nothing is queued. During
  /// `launching` iOS keeps the call; Android keeps it once its capture provider exists.
  static Future<void> event(String name, [Map<String, Object?>? params]) =>
      _runtime.event(name, params);

  /// Records a named trace value: how a value changed over time before a problem. [value] is a
  /// [String], [bool], [int] or finite [double] (below 2^63).
  ///
  /// Dropped before [launch], like [event].
  static Future<void> trace(String name, Object value) =>
      _runtime.trace(name, value);

  /// Adds a line to the SDK's log, at [level] (default [LogLevel.info]). This is the app-level
  /// `Bugsee.log`: it does not print to the console, and it bypasses the app's log filter. The
  /// wrapper's own capture of Dart's `print` and `debugPrint` is separate (and later).
  ///
  /// Dropped before [launch] on both platforms.
  static Future<void> log(String message, {LogLevel level = LogLevel.info}) =>
      _runtime.log(message, level);

  /// Adds a [BugseeBreadcrumb] to the report's trail. Completes with whether the SDK was handed
  /// it; `false` means it was not: breadcrumb capture is off (**the default on both SDKs**: enable
  /// it with `BugseeOptions(captureBreadcrumbs: true)`), or the SDK is not launching or launched
  /// (before launch, and after [stop]). Handing it over
  /// is not proof it is recorded (the app's breadcrumb filter, set natively, may drop it).
  static Future<bool> addBreadcrumb(BugseeBreadcrumb breadcrumb) =>
      _runtime.addBreadcrumb(breadcrumb);

  // ---- Notifications, blackout, reports ---------------------------------------------------------

  /// Sends a notification to the app's configured messaging integrations (Slack, Teams, ...)
  /// without creating a bug report: no video, logs or events are attached. The SDK keeps it on the
  /// device and uploads in batches, so nothing is lost offline; [urgent] posts it at once, ahead of
  /// older queued ones, when a session and network exist.
  ///
  /// [title] must not be blank. [severity] is optional. [fields] are extra rows; their order is kept
  /// on Android (the iOS SDK takes an unordered dictionary).
  ///
  /// **Ignored before [launch]** on both platforms (the SDK logs it); nothing is queued.
  static Future<void> notify(
    String title, {
    String? body,
    ReportSeverity? severity,
    Map<String, String>? fields,
    bool urgent = false,
  }) => _runtime.notify(
    title,
    body: body,
    severity: severity,
    fields: fields,
    urgent: urgent,
  );

  /// Stops recording everything that describes the screen: the video (black frames), the report
  /// screenshot, touch recording and the view hierarchy. Logs, network events, traces and the
  /// rest keep being captured. End it with [endBlackout]; there is no pause and no resume.
  ///
  /// **May be called before [launch]** on both platforms: capture then starts blacked out
  /// ([isBlackout] reflects it at once). On Android a blackout lasts from launch to [stop] (stopping
  /// ends it, with a `BlackoutEnded` lifecycle event) and a later launch starts without one, except
  /// one requested WHILE the SDK is stopping, which the stop hands to the next launch; iOS keeps the
  /// flag until [endBlackout].
  static Future<void> startBlackout() => _runtime.startBlackout();

  /// Resumes what [startBlackout] suppressed. Before [launch] it cancels an earlier
  /// [startBlackout]. Android ignores it while the SDK is stopping (the stop ends the blackout).
  static Future<void> endBlackout() => _runtime.endBlackout();

  /// Whether a blackout is in effect, as [startBlackout] and [endBlackout] left it.
  static Future<bool> isBlackout() => _runtime.isBlackout();

  /// Opens the SDK's bug report dialog, optionally pre-filled. The dialog runs the report
  /// handler's `onBeforeReportCreated` before it opens.
  ///
  /// A no-op before [launch] (and, on iOS, while `launching`: it needs `launched`), and while a
  /// dialog is already showing. Without a [severity] the SDK applies its default bug priority.
  static Future<void> showReportDialog({
    String? summary,
    String? description,
    ReportSeverity? severity,
    List<String>? labels,
  }) => _runtime.showReportDialog(
    summary: summary,
    description: description,
    severity: severity,
    labels: labels,
  );

  /// Creates and uploads a bug report at once, without UI, from what the SDK has captured.
  ///
  /// A no-op before [launch]. Without a [severity] the SDK applies its default bug priority. To
  /// edit a report as it is created, use [setReportHandler]; adding files to it comes with the
  /// report API (not here yet).
  static Future<void> upload(
    String summary,
    String description, {
    ReportSeverity? severity,
    List<String>? labels,
  }) =>
      _runtime.upload(summary, description, severity: severity, labels: labels);

  // ---- Network capture --------------------------------------------------------------------------

  /// Starts recording the app's HTTP traffic from Dart into the report: everything built on
  /// `dart:io`'s `HttpClient` (`package:http`, `dio`'s default adapter, `Image.network`, the
  /// WebSocket handshake, ...). The SDKs' own interception cannot see it (Dart does not use the
  /// platform's networking stack), so this plugin captures it in Dart and hands each event to the
  /// SDK, which applies its network options and privacy rules exactly as it does to the traffic it
  /// intercepts itself. Call it **once, early in `main`**, before the app makes a request:
  ///
  /// ```dart
  /// void main() {
  ///   Bugsee.installNetworkCapture();
  ///   runApp(const MyApp());
  /// }
  /// ```
  ///
  /// Installs `HttpOverrides` **in front of** whatever `HttpOverrides` the app has installed: it
  /// chains to them (clients, certificate callbacks, proxy settings and `findProxy` are theirs and
  /// untouched). Idempotent: calling it again while it is in effect does nothing. Returns whether
  /// the capture is in effect, `false` on a platform with no SDK (desktop, web).
  ///
  /// Nothing is recorded until the SDK is `launched`, and only while `capture.network` is on
  /// (`BugseeOptions.captureNetwork`, on by default); a request that began before the launch is
  /// never recorded. Bodies follow `captureNetworkBodySizeLimit` (20 KiB by default; a longer body
  /// is dropped, not cut) and `captureNetworkBodyWithoutType`; only text is kept. Requests to
  /// Bugsee itself are never recorded. See `doc/network.md` for the full list of what is and is
  /// not captured.
  ///
  /// **Limits**: other isolates (their own `HttpOverrides`, and no channel to the SDK), a client
  /// made before this call by code that keeps it (a static `HttpClient`, the first `WebSocket`),
  /// an app that replaces `HttpOverrides` without chaining to the current ones, and a zone that
  /// scopes its own overrides are not captured. Native networking plugins (`cronet_http`,
  /// `cupertino_http`, a WebView) are captured by the SDK's own interception instead.
  ///
  /// Throws a [BugseeException] when called from a background isolate.
  static bool installNetworkCapture() => _runtime.installNetworkCapture();

  /// Stops recording. Restores the `HttpOverrides` that were in place before when this capture is
  /// still the one set; if the app chained its own over it, it stays in the chain and forwards
  /// without recording. Clients already created stop recording too. Events already queued are
  /// still handed to the SDK. [installNetworkCapture] starts it again.
  static void uninstallNetworkCapture() => _runtime.uninstallNetworkCapture();

  /// Whether [installNetworkCapture] was called and not undone.
  static bool get networkCaptureInstalled => _runtime.networkCaptureInstalled;

  /// Sets the filter every captured event goes through **before** it is handed to the SDK; `null`
  /// removes it. Return the event (changed in place or a copy) to record it, `null` to drop it:
  ///
  /// ```dart
  /// Bugsee.setNetworkFilter((event) {
  ///   if (Uri.parse(event.url).host == 'internal.example.com') return null; // not recorded
  ///   event.headers.remove('x-session');
  ///   return event;
  /// });
  /// ```
  ///
  /// The filter runs in Dart, so it cannot be bypassed: nothing reaches the SDK without passing
  /// it. It sees the event raw (the SDK's default sanitizer runs after it, on what it returns,
  /// and so does a filter the app set on the native SDK). It runs on the isolate that made the
  /// request (normally the UI isolate), one event at a time, in order, **never inside the HTTP
  /// call**: the request is not held up. A slow synchronous filter still takes UI time: keep it
  /// fast. It may return a `Future`.
  ///
  /// **Fails closed.** A filter that throws, returns something other than a `BugseeNetworkEvent`
  /// or `null`, or returns a future that does not complete within [timeout] drops that event (and
  /// a debug warning is printed once; [networkCaptureStats] counts them). A filter that never
  /// answers therefore drops every event it is given, at one per [timeout] while the queue
  /// fills and the rest are dropped. [timeout] defaults to 10 seconds, the SDK's own network
  /// filter timeout, and must be positive and at most 5 minutes (a [BugseeArgumentException]
  /// otherwise).
  static void setNetworkFilter(
    BugseeNetworkFilter? filter, {
    // The SDK's own network filter timeout; `test/network_drift_test.dart` compares the copies.
    Duration timeout = const Duration(seconds: 10),
  }) => _runtime.setNetworkFilter(filter, timeout);

  /// The filter set with [setNetworkFilter], or `null`.
  static BugseeNetworkFilter? get networkFilter => _runtime.networkFilter;

  /// What happened to the captured events so far (for diagnosis): captured, handed to the SDK,
  /// dropped by a full queue, by the filter, or by a failure to deliver.
  static NetworkCaptureStats get networkCaptureStats =>
      _runtime.networkCaptureStats;

  // ---- Report handler and lifecycle events ------------------------------------------------------

  /// The handler set with [setReportHandler], or `null`.
  static BugseeReportHandler? get reportHandler => _runtime.reportHandler;

  /// Sets the handler the SDK hands each report to, before and after it is built; `null` (or a
  /// handler with neither phase) clears it. A later call replaces it. Completes when the native
  /// side knows which phases have a handler; with none, the SDK is never kept waiting for Dart.
  ///
  /// Register it **before [launch]** to see reports the SDK recovers while launching. Read
  /// [BugseeReportHandler] for the delivery rules (`onBeforeReportCreated` at most once,
  /// `onAfterReportCreated` at least once and idempotent), and [ReportProxy] for what a handler can
  /// change. Attachments are not part of the report API yet.
  static Future<void> setReportHandler(BugseeReportHandler? handler) =>
      _runtime.setReportHandler(handler);

  /// Every SDK lifecycle event ([LifecycleEvent]), from when a listener subscribes, including
  /// names this version does not know. A broadcast stream; the status transitions are also on
  /// [statusChanges]. Events the SDK raised before the plugin attached are delivered when it does
  /// (the first call into this class attaches it); what a late listener misses is described on
  /// [LifecycleEvent].
  static Stream<LifecycleEvent> get lifecycleEvents {
    _runtime.ensureStartedInBackground();
    return _runtime.lifecycleEvents;
  }
}
