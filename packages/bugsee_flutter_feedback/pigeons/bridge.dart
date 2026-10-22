// Definition of the feedback package's own Dart <-> native bridge. Generated outputs are
// committed; regenerate with `dart scripts/generate_pigeon.dart --package packages/bugsee_flutter_feedback`
// from the repository root (add `--check` to verify the committed files are current).
// Nothing here is public API: the generated Dart is not exported from
// package:bugsee_flutter_feedback. The core's bridge (pigeons/bridge.dart at the repository root)
// is deliberately not widened for this: the core must keep working, and stay free of the
// feedback module, in apps that never show the chat.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: '../lib/src/bridge/messages.g.dart',
    dartOptions: DartOptions(),
    javaOut:
        '../android/src/main/java/com/bugsee/flutter/feedback/Messages.java',
    javaOptions: JavaOptions(
      package: 'com.bugsee.flutter.feedback',
      className: 'Messages',
    ),
    swiftOut:
        '../ios/bugsee_flutter_feedback/Sources/bugsee_flutter_feedback/Messages.g.swift',
    dartPackageName: 'bugsee_flutter_feedback',
  ),
)
/// Dart -> native. Every call lands on the platform thread. A failure is a `FlutterError` whose
/// code is one of `not-registered` (the SDK has no feedback module registered), `invalid-argument`
/// or `sdk-error` (the SDK threw).
@HostApi()
abstract class FeedbackHostApi {
  /// Called once per Dart isolate before anything else. Forgets a listener a previous isolate of
  /// this engine (a hot restart) left installed, and answers whether the SDK has the feedback
  /// module registered right now.
  bool attach();

  /// Presents the chat.
  void show();

  /// The greeting an empty conversation opens with; null clears it.
  void setGreeting(String? greeting);

  /// Installs (true) or removes (false) the SDK listener that feeds [FeedbackFlutterApi].
  void setListenerEnabled(bool enabled);
}

/// Native -> Dart, delivered on the platform thread. Only while the listener is enabled.
@FlutterApi()
abstract class FeedbackFlutterApi {
  /// Messages from the Bugsee dashboard, oldest first. Never empty.
  void onMessagesReceived(List<String> messages);

  /// The user sent a message and the backend accepted it.
  void onMessageSent(String message);
}
