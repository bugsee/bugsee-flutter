// What the feedback API throws. Public.
import 'package:bugsee_flutter/bugsee_flutter.dart' show BugseeException;

/// Why a feedback call failed.
enum BugseeFeedbackFailure {
  /// The SDK has no feedback module registered, so there is nothing to call. The module registers
  /// itself when the native feedback dependency is linked: on Android from the SDK's own init
  /// provider (or, with the Bugsee Gradle plugin's extension consolidation, from a call the plugin
  /// injects into the SDK's provider), on iOS from the `BugseeFeedback` add-on's `register()`. A
  /// build that lost either (a manifest merge that removed the provider, an app that was not
  /// rebuilt after adding the package) ends here.
  notRegistered,

  /// The `bugsee_flutter` package this build uses is not the version this package was released
  /// with (a path, git or overridden dependency, or a stale build). The two are released together;
  /// the native pins would differ otherwise.
  incompatibleCore,

  /// The native side could not do it: the plugin is not part of the build (a missing rebuild), or
  /// the SDK threw.
  nativeError,
}

/// A feedback call failed. [reason] says why.
///
/// A [BugseeException], so `on BugseeException` catches every error the Bugsee packages raise.
class BugseeFeedbackException extends BugseeException {
  const BugseeFeedbackException(this.reason, super.message, {super.cause});

  final BugseeFeedbackFailure reason;

  @override
  String toString() => 'BugseeFeedbackException(${reason.name}): $message';
}

/// The strings the bridge carries for a failure (a PlatformException's `code`), in one place on the
/// Dart side. Repeated in `FeedbackOps.java` and `BGSFlutterFeedbackOps.m`;
/// `test/feedback_package_drift_test.dart` compares the three.
abstract final class FeedbackWire {
  /// The SDK has no feedback module registered.
  static const notRegistered = 'not-registered';

  /// The SDK threw.
  static const sdkError = 'sdk-error';
}
