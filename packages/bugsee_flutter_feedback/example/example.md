# Example

A complete app that uses both packages is the example of the repository:
[`example/lib/feedback_screen.dart`](https://github.com/bugsee/bugsee-flutter/blob/nextgen/example/lib/feedback_screen.dart).

The whole of it:

```dart
import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_feedback/bugsee_flutter_feedback.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // First: before the SDK has launched, Android's show() does nothing.
  await Bugsee.launch('YOUR_APP_TOKEN');
  await BugseeFeedback.setGreeting('How can we help?');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: TextButton(
          // Hide the button when the add-on is not registered.
          onPressed: () async {
            if (await BugseeFeedback.isAvailable()) {
              await BugseeFeedback.show();
            }
          },
          child: const Text('Contact support'),
        ),
      ),
    ),
  );
}
```
