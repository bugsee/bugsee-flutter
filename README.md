# bugsee_flutter

Bugsee for Flutter. Crash, error and bug reports that carry the video, network traffic, console logs and
traces that led up to them, from an Android or iOS Flutter app.

It wraps the native Bugsee 7.x SDKs (it is not a reimplementation), so a report from a Flutter app is the report a
native app produces, plus what only Dart can see: the widget tree, `dart:io` network traffic, `print` output and Dart
errors.

> **Version 10.0.0-dev.1, not published yet.** This is a clean rewrite for the 7.x native SDKs and a **breaking change from
> 9.x**: see [doc/migration-from-9x.md](doc/migration-from-9x.md). Whether a 9.x compatibility layer is offered has not been
> decided. Everything below was verified on an Android emulator and an iOS simulator; no physical device has been used yet
> (see [Platform support and limits](#platform-support-and-limits)).

## Requirements

| | |
|---|---|
| Flutter / Dart | 3.41.0 or newer / 3.11 or newer |
| Android | `minSdk` 21; JDK 17 or 21 for the build (JDK 25 breaks the Gradle 8.14 of the Flutter template); the Bugsee Gradle plugin **4.0.8** (mandatory, see below) |
| iOS | 15.0 or newer; Swift Package Manager only (no CocoaPods: Bugsee publishes no pod and this plugin has no podspec) |
| Native SDKs | Android `7.4.2`, iOS `7.0.0-beta7` (pinned in [`native-versions.json`](native-versions.json)) |
| Not covered | web, desktop (the calls do nothing there), tvOS, visionOS, the Android leak module |

The Flutter floor is 3.41.0 because the plugin is SwiftPM-only: `flutter pub get` fails on Linux and Windows with
"only Swift Package Manager compatible" on older Flutter (measured on CI from 3.27 to 3.38).

## Install

```yaml
dependencies:
  bugsee_flutter: ^10.0.0-dev.1
```

### Android

1. **Apply the Bugsee Gradle plugin.** It is mandatory for the 7.x SDK and a Flutter plugin cannot apply it for you, so the app
   does. In `android/settings.gradle.kts`, next to the other plugins:

   ```kotlin
   plugins {
       id("dev.flutter.flutter-plugin-loader") version "1.0.0"
       id("com.android.application") version "8.11.1" apply false
       id("org.jetbrains.kotlin.android") version "2.2.20" apply false
       id("com.bugsee.android.gradle") version "4.0.8" apply false   // must be 4.0.7 or newer; 4.0.8 is what this release is tested with
   }
   ```

   and in `android/app/build.gradle.kts`, after the Android and Flutter plugins:

   ```kotlin
   plugins {
       id("com.android.application")
       id("kotlin-android")
       id("dev.flutter.flutter-gradle-plugin")
       id("com.bugsee.android.gradle")
   }
   ```

   (Groovy: `id 'com.bugsee.android.gradle' version '4.0.8' apply false` in `settings.gradle`, `id 'com.bugsee.android.gradle'` in `app/build.gradle`.)

2. **Add the Gradle ordering workaround** at the end of `android/app/build.gradle.kts`. On Gradle 8.14 (the current Flutter
   template) the plugin's `injectBugsee<Variant>BuildId` tasks write into the assets that Flutter's `copyFlutter<Variant>Assets`
   produces without declaring that ordering, and Gradle rejects the build. Still open upstream as
   [bugsee-android-gradle-plugin#33](https://github.com/bugsee/bugsee-android-gradle-plugin/issues/33); remove the snippet when
   a plugin release fixes it:

   ```kotlin
   tasks.matching { it.name.startsWith("injectBugsee") && it.name.endsWith("BuildId") }.configureEach {
       val variant = name.removePrefix("injectBugsee").removeSuffix("BuildId")
       mustRunAfter("copyFlutterAssets$variant")
   }
   ```

3. Build with a JDK 17 or 21 (`JAVA_HOME`, and `org.gradle.java.home` in `gradle.properties` if Android Studio's bundled JDK is 25).

Nothing else is needed: the plugin declares `bugsee-android` **and** the separate `bugsee-android-ndk` artefact (native crash
detection), registers its wrapper from a content provider that runs before the SDK can launch, and ships consumer ProGuard
rules. The working example is [`example/android`](example/android).

### iOS

The iOS side is distributed through Swift Package Manager only. Where SwiftPM is not on by default, run once:

```sh
flutter config --enable-swift-package-manager
```

Raise the app's **iOS deployment target to 15.0** (Xcode: Runner target, General, Minimum Deployments; or
`IPHONEOS_DEPLOYMENT_TARGET = 15.0` in `ios/Runner.xcodeproj`). Older Flutter app templates default to a lower one. No
`Info.plist` keys are required.

### Launch

```dart
import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:flutter/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final result = await Bugsee.launch(
    'YOUR_APP_TOKEN',
    options: const BugseeOptions(
      captureVideo: true,
      captureLogsLevel: LogLevel.info,
      configDuration: 45,
      detectHang: true,
      reportingDefaultsCrashPriority: ReportSeverity.critical,
    ),
  );
  // launched, alreadyRunning and deferred are all "not a failure"; see below.

  runApp(const MyApp());
}
```

`Bugsee.launch` completes when the SDK answers: `launched` once capture started, `alreadyRunning` at once when the SDK is already
launching or launched (**your options were not applied**), `deferred` on iOS when the app is not active yet (the SDK starts
later). `await Bugsee.waitUntilLaunched()` settles all three: it returns `false` if the launch failed or nothing happened within its
timeout. A launch that did not happen throws a `BugseeLaunchException` with a `LaunchFailure` reason (a blank token, a stop still in
progress, a refusal, an exception on the native side, a platform without an SDK).

```dart
Bugsee.statusChanges.listen(print);   // launching, launched, stopping, stopped
await Bugsee.getStatus();             // the SDK's own answer
await Bugsee.getLaunchOptions();      // what is in effect: yours over the SDK's defaults
await Bugsee.stop();                  // completes when the SDK has stopped; stop() then launch() is how options change
```

## Options

`BugseeOptions` has a typed, documented field for every option the SDKs register, except the leak module's and the deprecated ones
(100 at the pinned versions; `custom` reaches the rest), named after its key: `capture.video.frame-rate` is `captureVideoFrameRate`.
A field you leave out keeps the SDK's own default (several defaults differ between Android and iOS; each field says which). The fields
are generated from the manifests the two SDKs publish (`test/fixtures/option_manifests`), so they cannot drift from the SDKs. Enums
carry the SDK's internal value, never an ordinal.

- **One configuration for both platforms.** An option that exists on one platform only (the video mode is Android's, the AVPlayer
  capture is iOS's) is ignored on the other, with a debug warning. An enum constant one platform lacks (`FrameRate.raw` on iOS) too.
- **Stricter than the SDKs.** Both SDKs silently drop an unknown key or a value of the wrong type. Here an unknown key in
  `BugseeOptions.custom`, a wrong type or a bad `endpoint` is an `ArgumentError` before anything reaches the SDK.
- **`endpoint`** is for an on-premises or test server: give the base URL (a trailing slash and a `/v2` segment are removed).
- `$$ENDPOINT`, `$$WRAPPER` and `$$DEBUG` are internal and never returned by `getLaunchOptions`.

### Launching twice, auto-init, and stopping

- On **Android** the SDK launches itself before any Dart code when the manifest declares `com.bugsee.app-token` meta-data. A later
  `Bugsee.launch` is then `alreadyRunning` and its options are not applied. To launch from Dart, leave the token out of the manifest
  or add `<meta-data android:name="com.bugsee.auto-init" android:value="false"/>`. Events from before the first call into the
  plugin are delivered when it attaches (the latest status is replayed).
- **iOS** has no auto-init.
- A launch while a stop is still in progress is refused (`LaunchFailure.stopping`): `await Bugsee.stop()` first.
- `getHostLaunchOptions()` differs between the platforms (Android: everything you passed; iOS: only what differs from the iOS
  default); `getLaunchOptions()` is the same on both.

## Features

Every method is a static on `Bugsee` and returns a `Future`. What each call does before `launch`, what is left out and why:
[doc/api-surface.md](doc/api-surface.md). All the pages: [doc/README.md](doc/README.md).

### Data you add

```dart
await Bugsee.setAttribute('plan', 'pro');            // String, bool, int or double; persisted; works before launch
await Bugsee.setUserIdentifier('user@example.com');  // one identifier; an email links reports to a user
await Bugsee.event('checkout', {'items': 3, 'coupon': null});   // events, traces, logs: dropped before launch
await Bugsee.trace('cart-size', 3);
await Bugsee.log('payment declined', level: LogLevel.warning);
await Bugsee.notify('Deploy finished', body: 'v2.1', severity: ReportSeverity.medium);   // to your Slack/Teams integration

// Breadcrumb capture is off by default on both SDKs: launch with it on.
await Bugsee.launch('YOUR_APP_TOKEN', options: const BugseeOptions(captureBreadcrumbs: true));
final taken = await Bugsee.addBreadcrumb(
  const BugseeBreadcrumb(category: 'nav', message: 'opened cart', level: BreadcrumbLevel.info),
);
await Bugsee.upload('Summary', 'Description', severity: ReportSeverity.high, labels: ['checkout']);
await Bugsee.showReportDialog(summary: 'Something broke');
```

Argument errors are `BugseeException`s through the `Future` (`BugseeArgumentException`; `BugseeAttributeException` when an SDK refuses
an attribute over its size limits). Calls on a platform without an SDK (desktop, web) do nothing; only `launch` throws.

### Dart errors ([doc/exceptions.md](doc/exceptions.md))

```dart
try {
  risky();
} catch (e, stack) {
  await Bugsee.logException(e, stack);                  // an error report
  await Bugsee.logUnhandledException(e, stack);         // a crash report
  await Bugsee.reportException(e, domain: 'checkout');  // an error report with a grouping domain
}

// Opt in to the errors nobody handled. Chained: Crashlytics, Sentry and your own handlers still run.
// Call it AFTER the tools that assign FlutterError.onError / PlatformDispatcher.onError (Crashlytics replaces them).
Bugsee.installErrorHandlers();
assert(Bugsee.errorHandlersActive);               // false when another tool replaced them
Bugsee.runGuarded(() => runApp(const MyApp()));   // a zone: what escapes it is reported, then printed as usual
```

The installed handlers file **error** reports (once per error, rate limited); `installErrorHandlers(reportAsCrash: true)` files crash
reports instead (why error is the default: doc/exceptions.md). For readable stacks build with
`--obfuscate --split-debug-info=<dir>` and upload `<dir>/*.symbols` (doc/exceptions.md, section 5).

### Network ([doc/network.md](doc/network.md))

The SDKs' network interception cannot see `dart:io` (`package:http`, dio's default adapter, `Image.network`, a plain `HttpClient`), so
this plugin records it in Dart and hands the events to the SDK. Opt-in, once, early:

```dart
void main() {
  Bugsee.installNetworkCapture();   // after your own HttpOverrides.global = ..., if any: this chains to it

  // Optional. Runs in Dart BEFORE anything reaches the SDK, so it cannot be bypassed.
  Bugsee.setNetworkFilter((event) {
    if (event.url.contains('/internal/')) return null;   // not recorded
    event.headers.remove('x-session');                   // redact in place
    return event;
  });
  runApp(const MyApp());
}
```

### Logs ([doc/logs.md](doc/logs.md))

`print` needs a zone that carries the hook (`Zone.root` cannot be replaced); `debugPrint` is chained globally. Opt-in:

```dart
void main() {
  Bugsee.runWithLogCapture(() {          // or Bugsee.runGuarded, or your runZoned(zoneSpecification: Bugsee.logCaptureZoneSpecification)
    WidgetsFlutterBinding.ensureInitialized();
    Bugsee.installLogCapture();

    // The SDKs have no log sanitizer of their own: redact here. Return null to drop.
    Bugsee.setLogFilter((event) {
      event.message = event.message.replaceAll(RegExp(r'\d{12,}'), '<number>');
      return event;
    });
    runApp(const MyApp());
  });
}

// An adapter for package:logging and your own loggers: recorded like `print`, not as Bugsee.log.
void myLogger(String line) => Bugsee.forwardLog(line, level: LogLevel.warning, tag: 'net');
```

### Report handler, attachments, `createReport` ([doc/attachments.md](doc/attachments.md))

```dart
// Register BEFORE launch to see reports the SDK recovers while launching.
await Bugsee.setReportHandler(
  BugseeReportHandler(
    onAfterReportCreated: (report) async {    // at least once: make it idempotent
      await report.replaceLabels(['flutter']);
      await report.setAttribute('screen', 'cart');
      await report.addAttachment('/path/to/notes.txt', name: 'notes', mimeType: 'text/plain');
    },
  ),
);

// Or build a report yourself.
final report = await Bugsee.createReport();
if (report != null) {
  await report.setSummary('Checkout failed');
  await report.addAttachmentBytes(Uint8List.fromList([104, 105]), name: 'note');
  await report.upload();
}
```

`onBeforeReportCreated` runs at most once and may be skipped. Attachments are path-first (native copies or moves the file). The
handler's report is live only until the handler returns: await every edit. Every SDK lifecycle event is a stream:
`Bugsee.lifecycleEvents.listen((e) => print(e.name))`.

### Secure views

```dart
Widget build(BuildContext context) => Column(
  children: [
    const Text('Card number'),
    // Blanked in the recorded video and in the report screenshot; the user sees it as usual.
    BugseeSecureView(child: TextField(obscureText: true)),
  ],
);
```

It fails closed for what it cannot place, but it is not instant: a region that has just appeared is recorded in the clear for its
first frame or so (Dart can only measure it once layout has placed it). For something that must never be captured keep the
`BugseeSecureView` mounted and swap its content instead of inserting the whole widget when the content appears. The other limits
are on the widget's dartdoc. The reports also carry the **Flutter widget tree** ([doc/view-hierarchy.md](doc/view-hierarchy.md)); see the
privacy model below.

### Feedback chat ([packages/bugsee_flutter_feedback](packages/bugsee_flutter_feedback/README.md))

The chat your users write to you in is a separate package, so apps that never show it do not carry its UI (SwiftUI on iOS,
Jetpack Compose on Android). Add it next to this one, at the same version; there is nothing else to configure:

```dart
// import 'package:bugsee_flutter_feedback/bugsee_flutter_feedback.dart';
await Bugsee.launch('YOUR_APP_TOKEN');   // first: before the SDK has launched, Android's show() does nothing
await BugseeFeedback.show();
```

## Privacy model

Bugsee records what makes a bug reproducible, so decide what must not be recorded. What is captured, and the control for each:

| Captured | Control |
|---|---|
| Video and report screenshot of the app | `BugseeSecureView`; `Bugsee.startBlackout()` / `endBlackout()` (video, screenshot, touches and the view hierarchy stop; logs and data continue); the `capture.video` / `capture.screenshot` options |
| Flutter widget tree (boxes and widget type names only: no text, labels, field values, keys, semantics or route names; a `BugseeSecureView` subtree is one node) | `captureViewHierarchy: false`; built only while the SDK is launched and the app is in the foreground |
| `dart:io` network traffic (opt-in) | `installNetworkCapture` is never called by `launch`; `setNetworkFilter` runs first and **fails closed** (a throw, a wrong type or a hang drops the event); the SDK's default sanitizer still runs after it; text bodies only, up to `captureNetworkBodySizeLimit` (20 KiB default, capped at 2 MiB); requests to Bugsee itself are never recorded |
| `print` / `debugPrint` (opt-in) and `Bugsee.log` | `setLogFilter` (fails closed), `captureLogsLevel`; **the SDKs have no log sanitizer** |
| Dart errors (exception text and stack) | the text is whatever your error says (a `FlutterError` contributes its summary only); the SDKs' filters do not apply to it |
| Attributes, events, traces, breadcrumbs, user identifier | what you pass |
| Everything the SDK itself captures (device and OS info, SDK logs, touches, crashes) | the SDK's options |

Know these limits:

- **Android logcat echo.** The SDK's own console capture records the same `print` again, raw, as source `LogCat` with tag `flutter`
  (the `FlutterError` dump of a real app included), and **the Dart log filter does not apply to that echo**. On Android add a native
  `Bugsee.setLogEventFilter` that drops `LogSource.LogCat` events tagged `flutter` (a debug build warns once; the Kotlin snippet is in
  [doc/logs.md](doc/logs.md)). iOS recorded no echo on the simulator.
- **Android HTTP breadcrumbs** (with `captureBreadcrumbs` on) keep the URL's query as given; the SDK relies on a breadcrumb filter. Redact the
  URL in the network filter, which runs first.
- **Secure views** do not cover a region's first frame, pixels drawn outside its subtree (an `Overlay` magnifier or tooltip), and are
  verified in portrait on iOS only; see the widget's dartdoc.
- Nothing is recorded, and nothing is queued, before the SDK is launching or launched.

## Platform support and limits

| Area | State |
|---|---|
| Android | API 21+. Verified on emulators (API 28 to 33): launch, auto-init, crash recovery, handlers, exceptions (debug and R8 `--obfuscate` release), view hierarchy, network, logs, attachments, `createReport`, secure regions at three densities, hot restart |
| iOS | 15.0+. Verified on simulators (iOS 26.5 and 27.0) for everything the simulator permits |
| iOS simulator | The SDK's simulator slice has **no crash reporter** (no recovered crash reports) and files **no logged exceptions**, so Dart error reports and crash recovery cannot be tried there; use a physical iPhone. Release and profile builds cannot run on a simulator |
| Android report screenshot | Flutter's default `SurfaceView` render mode gives an **all black report screenshot** (an SDK gap: [bugsee-android#316](https://github.com/bugsee/bugsee-android/issues/316); the video is right). Workaround: render with a `TextureView` (override `FlutterActivity.getRenderMode()` to return `RenderMode.texture`), at the cost Flutter documents for it |
| Secure regions | Not covered for the first frame of a newly appearing region; only the implicit view (id 0) is placed |
| Isolates | The API works from the main isolate: a call from a background isolate is a `BugseeException`. Network and log capture and the error handlers belong to the isolate that installed them; `listenToIsolateErrors` reports an isolate you spawn. Hot restart is handled (a new isolate takes over) |
| Web, desktop | The calls do nothing; `launch` throws |
| tvOS, visionOS | Not covered |
| Real devices | **Not exercised yet.** All evidence is from emulators and simulators ([doc/verification.md](doc/verification.md), including what was not covered) |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Android build fails Gradle task validation on `injectBugsee...BuildId` | The ordering workaround of the Android step 2 is missing |
| No native crashes on Android, build green | The `bugsee-android-ndk` artefact is not on the classpath (this plugin declares it: check `./gradlew :app:dependencies \| grep bugsee-android-ndk`) or `detect.crash-ndk` is off |
| Android extensions (e.g. the feedback chat) silently never register | The Gradle plugin is older than 4.0.7 (4.0.6 strips the extension providers and injects nothing): use 4.0.8 |
| `Bugsee.launch` answers `alreadyRunning` and options are ignored | Android auto-init: the manifest has `com.bugsee.app-token`; see "Launching twice" |
| Wrapper identity missing from a report recovered after a crash | The wrapper must be registered natively before the SDK launches, which this plugin does from a content provider (initOrder 200). Do not add a provider of your own named `Bugsee<Anything>InitProvider`: the Gradle plugin deletes it from the APK |
| `flutter pub get` fails with "only Swift Package Manager compatible" | Flutter older than 3.41.0 |
| iOS: package resolution or deployment target error | Raise the deployment target to 15.0; run `flutter config --enable-swift-package-manager` where it is not the default |
| Gradle cannot parse the JDK version | JDK 25 (Android Studio's bundled JBR): use 17 or 21 |
| Black Android report screenshot | Default `SurfaceView` render mode: see the table above |
| Events, traces, logs, notifications or uploads vanish | They are dropped before `launch` and after `stop`; nothing is queued |
| Dart errors are not reported | `installErrorHandlers` was called before Crashlytics (it replaced the handlers): check `Bugsee.errorHandlersActive`; or the call was before launch |
| Obfuscated stacks are not readable | Upload the `--split-debug-info` symbols of that exact build (doc/exceptions.md, section 5) |
| iOS: nothing arrives from the simulator | The simulator has no crash reporter and files no logged exceptions (above) |

Option values read back from the SDK (`getLaunchOptions`) show enums as the SDK's internal integers: that is intended
(enums cross the bridge by value, never by ordinal). Secure-rectangle units, the native lifecycle and the other workbook traps are
handled inside the plugin; where and how they are guarded is in [doc/workbook-conformance.md](doc/workbook-conformance.md).

## More

- [doc/README.md](doc/README.md): every documentation page. [doc/architecture.md](doc/architecture.md): how the plugin is built.
- [doc/migration-from-9x.md](doc/migration-from-9x.md): from the 9.x plugin.
- [PLAN.md](PLAN.md): project status, decisions, open questions and the release checklist. [CHANGELOG.md](CHANGELOG.md).
- [example/](example/README.md): the example app (launch, data, network, logs, exceptions, attachments, view hierarchy, feedback).
  The device verification harness is [`scripts/device/`](scripts/device) (not run in CI). [.github/CI.md](.github/CI.md): the checks.
