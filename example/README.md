# bugsee_flutter_example

A small launch screen for the `bugsee_flutter` public API: launch with a real-looking option set,
watch the status transitions, stop, and read the launch options back from the SDK.

```
flutter run --dart-define=BUGSEE_TOKEN=<your app token>
```

Without a token the placeholder `EXAMPLE-APP-TOKEN` is used: the SDK launches, but nothing it
captures is delivered anywhere. `--dart-define=BUGSEE_ENDPOINT=https://...` points it at an
on-premises or test server.

The Android manifest deliberately has no `com.bugsee.app-token` meta-data: with it the SDK launches
itself before Dart runs and `Bugsee.launch` would be `LaunchResult.alreadyRunning` (see the plugin
README).

`integration_test/launch_test.dart` runs the whole sequence (launch, status transitions, options read
back, launching twice, stop, launch again) against the real SDK:

```
flutter test integration_test/launch_test.dart -d <emulator or simulator id>
```
