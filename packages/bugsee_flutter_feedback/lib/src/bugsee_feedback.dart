// The public entry point. Everything behind it is `FeedbackRuntime`, which a test can replace.
import 'package:meta/meta.dart' show visibleForTesting;

import 'feedback_runtime.dart';

/// Replaces the native side (and everything else the facade uses). For tests only: not exported
/// from package:bugsee_flutter_feedback, so `FeedbackRuntime` is not part of the public signature.
@visibleForTesting
void debugSetFeedbackRuntime(FeedbackRuntime runtime) =>
    BugseeFeedback._runtime = runtime;

/// The in-app feedback chat: your users write to you from inside the app and you answer from the
/// Bugsee dashboard.
///
/// An optional add-on to `bugsee_flutter`: add this package next to it, nothing else to configure.
/// The chat has no Dart widget; it is the SDK's own native screen (Jetpack Compose on Android,
/// SwiftUI on iOS), shown by [show].
///
/// ```dart
/// await Bugsee.launch('YOUR_APP_TOKEN');
/// await BugseeFeedback.setGreeting('How can we help?');
/// await BugseeFeedback.show();
/// ```
///
/// Both SDKs expose exactly three things, and so does this class: show the chat, set the greeting
/// of an empty conversation, and listen for messages ([messagesReceived], [messageSent]). Neither
/// has an unread count, a notification setting, a feedback option key, or a separate user name or
/// e-mail: the chat asks the user for an e-mail itself, and skips that screen when the user
/// identifier you set with `Bugsee.setUserIdentifier` contains an `@`.
///
/// Call these after `Bugsee.launch`. Before it, Android's [show] does nothing and iOS presents a
/// chat that cannot reach the backend (see [show]).
abstract final class BugseeFeedback {
  static FeedbackRuntime _runtime = FeedbackRuntime();

  /// Whether the SDK has the feedback module registered, so [show] can work. `false` on a
  /// platform with no Bugsee SDK (everything but Android and iOS), and when the module did not
  /// register (see [BugseeFeedbackFailure.notRegistered]); the latter is the question to ask
  /// before offering a "contact support" button.
  ///
  /// Throws a [BugseeFeedbackException] when the build is unusable: the native plugin is not part
  /// of it ([BugseeFeedbackFailure.nativeError]) or the `bugsee_flutter` version does not match
  /// ([BugseeFeedbackFailure.incompatibleCore]).
  static Future<bool> isAvailable() => _runtime.isAvailable();

  /// Presents the feedback chat over the app. Completes once the SDK has been asked; the screen
  /// appears a moment later.
  ///
  /// The user is asked for an e-mail address first (skippable), unless the user identifier set
  /// with `Bugsee.setUserIdentifier` contains an `@`.
  ///
  /// Before the SDK is launched: on Android nothing happens, silently (the module refuses until the
  /// SDK's launch has started it: `BugseeFeedback.showFeedbackActivity` returns when it is not
  /// launched); on iOS the chat is presented anyway (`BugseeFeedback.showFeedbackUI` has no such
  /// check) but it cannot reach the backend. Launch first.
  ///
  /// On Android the chat is a separate activity; on iOS a full-screen sheet over the topmost view
  /// controller. If another chat is already showing, Android ignores the call.
  ///
  /// Throws a [BugseeFeedbackException] ([BugseeFeedbackFailure.notRegistered] when the module is
  /// not registered). Does nothing, with one debug warning, on a platform without a Bugsee SDK.
  static Future<void> show() => _runtime.show();

  /// The text an empty conversation opens with. `null` clears it. A blank string is passed on
  /// as it is.
  ///
  /// Works before the SDK is launched. The platforms differ: Android stores it (it survives an
  /// app restart) and a greeting the dashboard configures wins over it; iOS keeps it in memory
  /// for the process only, so set it on every start.
  ///
  /// Throws a [BugseeFeedbackException]; does nothing on a platform without a Bugsee SDK.
  static Future<void> setGreeting(String? greeting) =>
      _runtime.setGreeting(greeting);

  /// New messages from the dashboard, oldest first, delivered in the order the SDK received them
  /// (text only). Never an empty list.
  ///
  /// A broadcast stream: the native listener is installed when the first listener (of this or of
  /// [messageSent]) subscribes and removed when the last cancels. There is no replay: messages
  /// that arrived while nobody listened are not delivered, they are in the chat. If the listener
  /// cannot be installed (the module is not registered) the subscribers get a
  /// [BugseeFeedbackException] as an error event.
  ///
  /// Android calls the SDK's listener on a worker thread and iOS on the main thread; the stream
  /// always delivers on the platform thread (the one Dart runs on).
  static Stream<List<String>> get messagesReceived => _runtime.messagesReceived;

  /// The messages the user sent and the backend accepted (text only). Same rules as
  /// [messagesReceived].
  static Stream<String> get messageSent => _runtime.messagesSent;
}
