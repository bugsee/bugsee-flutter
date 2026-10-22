// Runs on a device or simulator (it needs the native SDKs):
//
//   cd example && flutter test integration_test/feedback_test.dart -d <device>
//
// The feedback module is registered with the real SDK by the time Dart runs (nothing here
// registers it: the SDK's init provider / the Gradle plugin's injected call on Android, the
// package's `+load` on iOS), the SDK accepts the greeting, and a listener can be installed and
// removed. Showing the chat is not asserted: it is a native screen, and it needs a launched SDK
// on Android (see the screenshots in the PR).

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_example/main.dart';
import 'package:bugsee_flutter_feedback/bugsee_flutter_feedback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the feedback module is registered, takes a greeting and a listener',
    (tester) async {
      expect(
        await BugseeFeedback.isAvailable(),
        isTrue,
        reason: 'the SDK has no feedback module registered',
      );

      await BugseeFeedback.setGreeting('How can we help?');
      await BugseeFeedback.setGreeting(null);

      // Installing and removing the native listener must not fail; no message arrives without a
      // backend (a real token), so only the plumbing is shown here.
      final received = BugseeFeedback.messagesReceived.listen((_) {});
      final sent = BugseeFeedback.messageSent.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await received.cancel();
      await sent.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Launched, then show: the call is accepted (the screen appears natively).
      await Bugsee.launch(defaultToken, options: exampleOptions());
      await BugseeFeedback.show();
      debugPrint('integration: feedback shown');
      await Future<void>.delayed(const Duration(seconds: 2));
      await Bugsee.stop();
    },
  );
}
