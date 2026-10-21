// The public entry point. Everything behind it is `BugseeRuntime`, which a test can replace.
import 'package:meta/meta.dart';

import 'status.dart';
import 'bugsee_runtime.dart';
import 'launch.dart';
import 'options/bugsee_options.g.dart';

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

  /// Replaces the native side (and everything else the facade uses). For tests only.
  @visibleForTesting
  static void debugSetRuntime(BugseeRuntime runtime) => _runtime = runtime;

  /// Launches the SDK with the application [token] from the Bugsee dashboard.
  ///
  /// [options] configure the SDK for this launch. They are ignored when the SDK is already
  /// running (see [LaunchResult.alreadyRunning]); stop it first to change them.
  ///
  /// Completes with what happened:
  ///  * [LaunchResult.launched]: capture started;
  ///  * [LaunchResult.alreadyRunning]: the SDK was running already; nothing was changed;
  ///  * [LaunchResult.deferred]: iOS, the app is in the background; the SDK starts when it is
  ///    active.
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
  /// Keyed by `com.bugsee.option.*`; enums as the SDK's internal integer, floats as `double`.
  /// Before the first launch these are the SDK's defaults, which differ between Android and iOS
  /// for a few options. Internal (`$$`) options are never included. Both SDKs, at the versions
  /// this plugin pins, return the same thing here (the 6.x iOS SDK returned only what differed
  /// from its defaults).
  static Future<Map<String, Object>> getLaunchOptions() =>
      _runtime.launchOptions(hostOnly: false);

  /// Only the options the app supplied to the last launch (empty before the first), without the
  /// defaults [getLaunchOptions] merges them over. Use it to tell "the app asked for this" from
  /// "this is the default".
  static Future<Map<String, Object>> getHostLaunchOptions() =>
      _runtime.launchOptions(hostOnly: true);
}
