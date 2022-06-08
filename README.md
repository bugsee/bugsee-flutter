# Bugsee for flutter

Bugsee is a mobile SDK that adds crucial information to your bug and crash reports. Bugsee reports include video of user actions, network traffic, console logs and many other important traces from your app. Now you know what exactly led to the unexpected behavior.

Sign up for a service at https://www.bugsee.com.

## Installation

Install Bugsee plugin into your dart project by adding it to dependecies in your pubspec.yaml

```yaml
dependencies:
  bugsee_flutter: ^99.99.99
```

## Launching

```dart
// For Flutter 3.x and up
import 'package:bugsee_flutter/bugsee.dart';

// For Flutter >=2.5 and <3.0
// import 'package:bugsee_flutter/bugsee_pre30.dart';

// For Flutter <2.5
// import 'package:bugsee_flutter/bugsee_pre25.dart';

Future<void> launchBugsee(void Function(bool isBugseeLaunched) appRunner) async {
  var launchOptions;
  var bugseeToken = "";

  if (Platform.isAndroid) {
    bugseeToken = "<android app token>";
    launchOptions = AndroidLaunchOptions();
  } else if (Platform.isIOS) {
    bugseeToken = "<ios app token>";
    launchOptions = IOSLaunchOptions();
  }

  await Bugsee.launch(bugseeToken,
      appRunCallback: appRunner, launchOptions: launchOptions);
}

Future<void> main() async {
  // This is required to let Bugsee intercept network requests
  HttpOverrides.global = Bugsee.defaultHttpOverrides;

  await launchBugsee((bool isBugseeLaunched) async {
    runApp(const MyApp());
  });
}

class MyApp extends StatelessWidget {
  ....
```

## Custom data

### Events

Events are identified by a string and can have an optional dictionary of parameters that will be stored and passed along with the report.

```dart
// Without any additional parameters
Bugsee.event(name: 'payment_processed');

// ... or with additional custom parameters
Bugsee.event(name: 'payment_processed', parameters: <String, dynamic>{
                'amount': 125,
                'currency': 'USD'});
```

### Traces

Traces may be useful when you want to trace how a specific variable or state changes over time right before the problem happens.

```dart
// Manually set value of 15 to property named "credit_balance"
// any time it changes
Bugsee.trace(name: 'credit_balance', value: 15);
```

## Manual reporting

You can register non fatal exceptions using the following method:

```dart
try {
  some_code_that_throws();
} catch (ex, st) {
  await Bugsee.logException(exception: ex, handled: true, stackTrace: st);
}
```

Bugsee can be further customized. For a complete SDK documentation covering additional options and API's visit [https://docs.bugsee.com/sdk/flutter/](https://docs.bugsee.com/sdk/flutter/installation/)
