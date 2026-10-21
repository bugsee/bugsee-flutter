// What `Bugsee.launch` returns and throws. Public.
//
// The bridge vocabulary (`launched`, `already-running`, ...) is repeated in Dart, Java and
// Objective-C; test/launch_drift_test.dart compares the three.

/// What a successful `Bugsee.launch` did.
enum LaunchResult {
  /// The SDK launched (and has reported that capture started).
  launched,

  /// The SDK was already launching or launched, so nothing was done and the options passed to
  /// this call were NOT applied.
  ///
  /// The usual cause on Android is the SDK's own auto-init: when the app's manifest declares
  /// `com.bugsee.app-token` meta-data the SDK launches from a content provider before any Dart
  /// code runs. Add `<meta-data android:name="com.bugsee.auto-init" android:value="false"/>` (or
  /// leave the token out of the manifest) to make this call the launch. Launching twice from
  /// Dart is the other cause.
  alreadyRunning,

  /// iOS only: the app was in the background when this was called, so the SDK starts when the
  /// app becomes active. The options are kept for that start; `Bugsee.statusChanges` reports it.
  deferred,
}

/// Why a launch was refused or failed.
enum LaunchFailure {
  /// The token is empty or blank (rejected before anything reaches the SDK).
  invalidToken,

  /// A stop is still in progress, and the SDK refuses a launch until it has completed: `await
  /// Bugsee.stop()` first.
  stopping,

  /// The SDK declined without saying why in a form this plugin can read: a token it rejects, no
  /// application context, capture that did not start, or a stop that overtook the launch. The
  /// SDK's own log (`Bugsee` tag on Android, the console on iOS) has the reason.
  rejected,

  /// The native side threw while launching.
  nativeError,

  /// The app is running on a platform this plugin has no SDK for (anything but Android and iOS).
  unsupportedPlatform,
}

/// Something went wrong calling the Bugsee SDK.
class BugseeException implements Exception {
  const BugseeException(this.message, {this.cause});

  /// A description for the developer.
  final String message;

  /// The underlying error, when there is one (a `PlatformException`, for example).
  final Object? cause;

  @override
  String toString() => 'BugseeException: $message';
}

/// `Bugsee.launch` did not launch the SDK. [reason] says why.
class BugseeLaunchException extends BugseeException {
  const BugseeLaunchException(this.reason, super.message, {super.cause});

  final LaunchFailure reason;

  @override
  String toString() => 'BugseeLaunchException(${reason.name}): $message';
}

/// The strings the bridge carries for a launch (`LaunchOutcomeMessage`), in one place on the Dart
/// side. Repeated in `LaunchOps.java` and `BGSFlutterLaunchOps.m`.
abstract final class LaunchWire {
  static const launched = 'launched';
  static const alreadyRunning = 'already-running';
  static const deferred = 'deferred';
  static const refused = 'refused';

  static const invalidToken = 'invalid-token';
  static const stopping = 'stopping';
  static const failed = 'failed';

  /// The PlatformException code native uses when the SDK threw.
  static const errorCode = 'launch-failed';
}
