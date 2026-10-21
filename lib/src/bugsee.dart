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
}
