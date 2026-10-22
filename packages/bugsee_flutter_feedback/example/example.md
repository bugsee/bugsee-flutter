# Example

A complete app that uses both packages is the example of the repository:
[`example/lib/feedback_screen.dart`](https://github.com/bugsee/bugsee-flutter/blob/nextgen/example/lib/feedback_screen.dart).

The whole of it:

```dart
import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_feedback/bugsee_flutter_feedback.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Bugsee.launch('YOUR_APP_TOKEN');
  await BugseeFeedback.setGreeting('How can we help?');
  runApp(const MyApp());
}

// Behind a "Contact support" button:
Future<void> contactSupport() async {
  if (await BugseeFeedback.isAvailable()) {
    await BugseeFeedback.show();
  }
}
```
