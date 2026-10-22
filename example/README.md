# bugsee_flutter_example

The example app for `bugsee_flutter` and `bugsee_flutter_feedback`, one tab per feature: **Launch** (launch with a real-looking option set,
watch the status transitions, stop, read the launch options back from the SDK), **Data** (every attribute, user, event, trace, breadcrumb,
blackout, upload, dialog and report-handler call), **Errors** (Dart error reporting and the installed handlers), **Files** (report attachments,
annotated screenshots, `createReport`), **Network**, **Logs**, **Chat** (the separate feedback package) and **Hierarchy** (the Flutter widget
tree the SDK stores in a report, with a secure view).

```
flutter run --dart-define=BUGSEE_TOKEN=<your app token>
```

Without a token the placeholder `EXAMPLE-APP-TOKEN` is used: the SDK launches, but nothing it captures is delivered anywhere.
`--dart-define=BUGSEE_ENDPOINT=https://...` points it at an on-premises or test server. Use Flutter 3.41.0 or newer and a JDK 17 or 21.

The Android app shows the integration the main README describes: the Bugsee Gradle plugin applied in `android/settings.gradle.kts` and
`android/app/build.gradle.kts`, with the ordering workaround. Its manifest deliberately has no `com.bugsee.app-token` meta-data: with it the
SDK launches itself before Dart runs and `Bugsee.launch` would be `LaunchResult.alreadyRunning` (see the plugin README).

## Integration tests (need a device; not in CI)

They run against the real SDKs on an emulator or simulator:

```
flutter test integration_test/launch_test.dart -d <emulator or simulator id>
```

`launch_test` (launch, status transitions, options read back, launching twice, stop, launch again), `cold_start_test` (a launch before
`runApp`), `facade_test`, `exceptions_test`, `attachments_test`, `view_hierarchy_test`, `network_test`, `logs_test` and `feedback_test` are in
`integration_test/`. `network_test`, `logs_test` and `attachments_test` also need the loopback stand-in for the Bugsee API
(`integration_test/support/mock_api.py`) and `--dart-define=BUGSEE_ENDPOINT=http://<host>:<port>` (`10.0.2.2` from an Android emulator,
`localhost` from an iOS simulator); the exact commands and the other flags (`NET_HOLD`, `LOGS_HOLD`) are in
[`.github/CI.md`](../.github/CI.md) and the header of each test. `view_hierarchy_test` needs no server.

The Chat tab uses the separate `bugsee_flutter_feedback` package: set the greeting, show the SDK's native chat screen, ask whether the module is
registered, and log the messages the listener streams deliver. Launch on the first tab first (on Android the chat refuses to open before the
SDK has launched).

## The verification app

`lib/verify_main.dart` is a second entry point driven by the device verification harness (`scripts/device/`, results in
[`doc/verification.md`](../doc/verification.md)). It is not part of the published package.
