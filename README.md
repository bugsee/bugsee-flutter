# bugsee_flutter

> **Status: the 7.x rewrite, in progress (10.0.0-dev.1, unpublished).** Launching, options, `stop`,
> status, attributes, user identity, events and traces, breadcrumbs, notifications, blackout, the
> report handler, the lifecycle event stream, the secure-view widget, Dart error reporting, the Flutter view hierarchy in reports, report
> attachments and `createReport`, the `dart:io` network capture and the `print` / `debugPrint` log capture work on
> Android and iOS. Not yet: APM spans.
> Existing users should stay on the latest published release until the migration guide is available.
> This API is a clean break from 9.x.

## Quick start

```dart
import 'package:bugsee_flutter/bugsee_flutter.dart';

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
  // LaunchResult.launched, .alreadyRunning or .deferred: none of them is a failure (see below)

  runApp(const MyApp());
}
```

`Bugsee.launch` completes when the SDK answers: `launched` once capture started, `alreadyRunning`
at once when the SDK is already launching or launched (your options were not applied), `deferred`
on iOS when the app is not active yet (the SDK starts it later; a plain `await Bugsee.launch` before
`runApp` was `launched` on the simulator, but an engine started during `didFinishLaunching` can see
`deferred`). Use `await Bugsee.waitUntilLaunched()` to know that capture is running; it returns
`false` if the launch failed or nothing happened within its timeout. It throws a
`BugseeLaunchException` (with a `LaunchFailure` reason) when the SDK did not launch: a blank token,
a stop still in progress, a refusal, an exception on the native side, or a platform without an SDK.

```dart
Bugsee.statusChanges.listen((status) => print(status)); // launching, launched, stopping, stopped
await Bugsee.getStatus();       // the SDK's own answer
await Bugsee.stop();            // completes when the SDK has stopped
await Bugsee.getLaunchOptions(); // what is in effect: yours over the SDK's defaults
```

### Options

`BugseeOptions` has a typed, documented field for every option the SDKs register except the leak module's and the
deprecated ones (100 at the pinned versions; `custom` reaches the rest), named after its key: `capture.video.frame-rate` is `captureVideoFrameRate`. A field you
leave out keeps the SDK's own default; several defaults differ between Android and iOS, and each
field's documentation says which. The fields are generated from the manifests the two SDKs publish
(`test/fixtures/option_manifests`), so they cannot drift from the SDKs. Enums carry the SDK's
internal value, never an ordinal.

- **One configuration for both platforms.** Android and iOS share one option namespace. An option
  that exists on one platform only (the video mode is Android's, the AVPlayer capture is iOS's) is
  ignored on the other, with a warning in debug builds, so a shared configuration can set both.
  An enum constant one platform lacks (`FrameRate.raw` on iOS) is ignored the same way.
- **Stricter than the SDKs.** Both SDKs drop an unknown option key, or a value of the wrong type,
  without a word. Here a key neither SDK registers (in `BugseeOptions.custom`, which reaches
  options this version has no field for), an internal key, a wrong type or a bad `endpoint` is an
  `ArgumentError` before anything reaches the SDK.
- **`endpoint`** is for an on-premises or test server. Give the base URL; a trailing slash and a
  `/v2` segment are removed, because both SDKs add the version themselves.
- **Internal options** (`$$ENDPOINT`, `$$WRAPPER`, `$$DEBUG`) are not part of the API, and are never
  returned by `getLaunchOptions`.
- **Not bundled:** the four `bugsee-android-leak` options have no typed field (this plugin does not
  depend on that module); `custom` still reaches them if your app adds it.

### Launching twice, auto-init, and stopping

- On **Android** the SDK launches itself before any Dart code runs when the manifest declares
  `com.bugsee.app-token` meta-data. A later `Bugsee.launch` is then `LaunchResult.alreadyRunning`
  and **its options are not applied** (the SDK only logs it). To launch from Dart, leave the token
  out of the manifest, or add `<meta-data android:name="com.bugsee.auto-init"
  android:value="false"/>`. Events that happened before the first call into the plugin are
  delivered when it attaches (the latest status is replayed), so `statusChanges` still reports
  `launching`, `launched`.
- **iOS** has no auto-init. A launch while the app's state is still background is deferred by the SDK
  until the app is active (`LaunchResult.deferred`); `waitUntilLaunched` settles it.
- `stop()` and `launch()` again is how options change; a launch while a stop is still in progress
  is refused (`LaunchFailure.stopping`), so `await Bugsee.stop()` first (on iOS too, even for a `stop()`
you did not await: the plugin marks the stop before the SDK does).
- `getHostLaunchOptions()` differs between the platforms: Android returns every option you passed,
  iOS only those that differ from the iOS default. `getLaunchOptions()` is the same on both.

## API overview

Every method is a static on `Bugsee` and returns a `Future`. The inventory of both native SDKs,
what is left out and why, and what each call does before `launch`, is in
[doc/api-surface.md](doc/api-surface.md).

```dart
// Attributes: String, bool, int or double; kept by the SDK across launches. Work before launch.
await Bugsee.setAttribute('plan', 'pro');
await Bugsee.getAttribute('plan');          // 'pro'
await Bugsee.getAllAttributes();            // {plan: pro}
await Bugsee.clearAttribute('plan');

// The user: one identifier (an email links reports to a user). An empty string clears it.
await Bugsee.setUserIdentifier('user@example.com');

// Events, traces, logs: dropped before launch, nothing is queued.
await Bugsee.event('checkout', {'items': 3, 'coupon': null});
await Bugsee.trace('cart-size', 3);
await Bugsee.log('payment declined', level: LogLevel.warning);

// Breadcrumbs: capture is off by default on both SDKs, so launch with it on.
await Bugsee.launch(token, options: const BugseeOptions(captureBreadcrumbs: true));
final taken = await Bugsee.addBreadcrumb(
  const BugseeBreadcrumb(category: 'nav', message: 'opened cart', level: BreadcrumbLevel.info),
);

// A notification to your Slack/Teams integration, without a report.
await Bugsee.notify('Deploy finished', body: 'v2.1', severity: ReportSeverity.medium, urgent: true);

// Blackout: video, screenshot, touches and the view hierarchy stop; logs and data continue.
await Bugsee.startBlackout();
await Bugsee.endBlackout();                 // there is no pause/resume

// Reports.
await Bugsee.upload('Summary', 'Description', severity: ReportSeverity.high, labels: ['checkout']);
await Bugsee.showReportDialog(summary: 'Something broke');
await Bugsee.setReportHandler(
  BugseeReportHandler(
    onAfterReportCreated: (report) async {
      await report.replaceLabels(['flutter']);       // idempotent: it may run again
      await report.setAttribute('screen', 'cart');
    },
  ),
);

// Every SDK lifecycle event; a name this version does not know is delivered as it is.
Bugsee.lifecycleEvents.listen((e) => print('${e.name} ${e.reportId ?? ''}'));
```

### Network capture

The SDKs' own network interception cannot see `dart:io` (`package:http`, `dio`'s default adapter,
`Image.network`, a plain `HttpClient`), so this plugin records it in Dart and hands the events to the
SDK. It is opt-in: call it once, early, before the app makes a request.

```dart
void main() {
  // After your own `HttpOverrides.global = ...` if you set one: this chains to it.
  Bugsee.installNetworkCapture();
  runApp(const MyApp());
}

// Optional: runs in Dart BEFORE anything reaches the SDK, so it cannot be bypassed.
Bugsee.setNetworkFilter((event) {
  if (event.url.contains('/internal/')) return null;   // not recorded
  event.headers.remove('x-session');                   // redact in place
  return event;
});
```

Nothing is recorded before the SDK is `launched`. Bodies follow the SDK's own options
(`captureNetworkBodySizeLimit`, 20 KiB by default; `captureNetworkBodyWithoutType`; only text is kept);
the SDK's default sanitizer still redacts what the filter returns (except the URL in Android's HTTP
breadcrumbs when `captureBreadcrumbs` is on, which keeps its query: redact it in the filter, see
[doc/network.md](doc/network.md)); a body-size limit above 2 MiB is capped at 2 MiB; a filter that throws or hangs
**drops the event** (fail closed); requests to Bugsee itself are never recorded. Requests made in other
isolates, WebSocket frames and a client created before the install are not captured. The data flow, the
privacy model and the limits are in [doc/network.md](doc/network.md).

### Log capture

What the app prints from Dart is recorded into the report's log, attributed to the plugin (source `Custom`) and not as
the app's own `Bugsee.log` calls. Opt-in; `print` needs a zone that carries the hook (`Zone.root` cannot be replaced):

```dart
void main() {
  Bugsee.runWithLogCapture(() {            // or Bugsee.runGuarded, or your own runZoned(zoneSpecification: Bugsee.logCaptureZoneSpecification)
    WidgetsFlutterBinding.ensureInitialized();
    Bugsee.installLogCapture();            // print (in the zone) and debugPrint, chained: the original output always happens
    runApp(const MyApp());
  });
}

// Runs in Dart BEFORE anything reaches the SDK. The SDKs have no log sanitizer of their own: redact here.
Bugsee.setLogFilter((event) {
  event.message = event.message.replaceAll(RegExp(r'\d{12,}'), '<number>');
  return event;                            // or null to drop; a filter that throws or hangs drops the line
});
Bugsee.forwardLog('from my logger', level: LogLevel.warning, tag: 'net');   // package:logging adapter: see doc/logs.md
```

Nothing is recorded before the SDK is launching or launched, with `captureLogs` off, or below `captureLogsLevel`. The
SDK's own console capture (Android logcat) records the same `print` again, raw (source `LogCat`, tag `flutter`, the
`FlutterError` dump of a real app included), and **the Dart filter does not apply to that echo**: on Android a native
`Bugsee.setLogEventFilter` that drops `LogSource.LogCat` events tagged `flutter` is needed (a debug build warns once;
Kotlin snippet in [doc/logs.md](doc/logs.md)). `dart:developer` `log`, `stdout` and root-zone `print` are
not captured. Data flow, SDK rules, privacy and limits: [doc/logs.md](doc/logs.md).

Dart errors ([doc/exceptions.md](doc/exceptions.md): the backend contract, what each SDK does, symbols):

```dart
try { risky(); } catch (e, stack) { await Bugsee.logException(e, stack); }   // an error report; the stack is optional
await Bugsee.logUnhandledException(e, stack);                                // a crash report
await Bugsee.reportException(e, domain: 'checkout');                         // with a grouping domain

// Opt in to the errors nobody handled. Chained: Crashlytics/Sentry/your own handlers still run.
// Call it AFTER the tools that assign FlutterError.onError / PlatformDispatcher.onError (Crashlytics replaces them).
Bugsee.installErrorHandlers();                   // FlutterError.onError, PlatformDispatcher.onError, isolate errors
assert(Bugsee.errorHandlersActive);              // false when another tool replaced them
Bugsee.runGuarded(() => runApp(const MyApp()));  // a zone: what escapes it is reported, then printed as usual
final listener = Bugsee.listenToIsolateErrors(isolate);   // an isolate you spawned
```

The installed handlers file **error** reports once per error and rate limited (`reportAsCrash: true` files crash
reports instead: see doc/exceptions.md for why error is the default). Build with
`--obfuscate --split-debug-info=<dir>` and upload `<dir>/*.symbols` for readable stacks (doc/exceptions.md,
section 5). iOS files nothing on a simulator.

Hide a part of the UI from the recording and the report screenshot:

```dart
BugseeSecureView(child: TextField(obscureText: true))
```

It fails closed for what it cannot place, but it is not instant: a region that has just appeared is
recorded in the clear for its first frame or so (Dart can only measure it once layout has placed
it), so for something that must never be captured keep the `BugseeSecureView` mounted and swap its
content, rather than inserting the whole widget at the moment the content appears. The other known
limits are listed on the widget.

The reports also carry the **Flutter widget tree** (the SDK sees a Flutter app as one native view, so
the plugin answers its request for the app's own hierarchy). It is boxes and widget type names only:
no text, labels, field values, keys or semantics, and a `BugseeSecureView` subtree is a single node
with only its box. It is on while the SDK is launched, its `captureViewHierarchy` option is on (the
default) and the app is in the foreground; `Bugsee.captureViewHierarchy()` asks for a capture now.
Design, payload, privacy rules and limits: `doc/view-hierarchy.md`.

Things worth knowing (each is documented on the method):

- **Argument errors are `BugseeException`s.** `BugseeArgumentException` (an empty event name, event params
  the SDKs cannot carry, a blank notification title; it names the parameter; refused before the SDK) and
  `BugseeAttributeException` (`invalidName`, `invalidValue` before the SDK; `rejected` is the SDK's own
  refusal, and the attribute's previous value is kept). It is a `BugseeException` but not a
  `BugseeArgumentException`. Both come through the `Future`. The SDKs drop an attribute over their size
  limits without a word; the plugin reads it back and reports `rejected`.
- **Before `launch`**: attributes, the user identifier and blackout work on both platforms; events,
  traces, logs, breadcrumbs, notifications, `upload` and the dialog are dropped by the SDKs, and the plugin does
  not queue them.
- **No SDK here** (desktop, web): these calls do nothing and return `null`/empty/`false`; only `launch` throws.
- **Register the report handler before `launch`** to see reports the SDK recovers while launching.
  `onBeforeReportCreated` runs at most once and may be skipped; `onAfterReportCreated` runs at least once, so
  make it idempotent. Attach files with `report.addAttachment(path, name: ..., mimeType: ..., move: ...)` (path-first: native copies or moves the file), set an annotated screenshot with `report.setScreenshot(path, annotated: true)`, or build a report yourself with `Bugsee.createReport()`; see `doc/attachments.md`.
- **Left out on purpose**: the 7.x appearance system, `relaunch`, APM transactions and spans, secure
  rectangles and activities, native views (see `doc/api-surface.md`).

## In-app feedback chat

The chat your users write to you in is a separate package, [`bugsee_flutter_feedback`](packages/bugsee_flutter_feedback/README.md),
so apps that never show it do not carry its UI (SwiftUI on iOS, Jetpack Compose on Android). Add it next to this one,
at the same version; there is nothing else to configure:

```dart
await Bugsee.launch('YOUR_APP_TOKEN');   // first: before the SDK has launched Android's show() does nothing
await BugseeFeedback.show();            // import 'package:bugsee_flutter_feedback/bugsee_flutter_feedback.dart';
```

This package works the same without it.

## Requirements

Flutter 3.41.0 or newer (Dart 3.11). Because the plugin is SwiftPM-only, older Flutter
fails `flutter pub get` on Linux and Windows. macOS developers on older versions could
enable SwiftPM, but those versions are unsupported.

## iOS: Swift Package Manager

The iOS side is distributed through Swift Package Manager only (Bugsee publishes
no CocoaPods pod, and this plugin has no podspec). On Flutter versions where
SwiftPM is not enabled by default, run this once before building for iOS:

```
flutter config --enable-swift-package-manager
```

## iOS deployment target

The plugin requires iOS 15.0. Older Flutter app templates default to a lower
deployment target, so integrators must raise it to 15.0 or later.

## Android: Gradle ordering workaround

Apps apply the `com.bugsee.android.gradle` plugin themselves. On Gradle 8.14 (the
current Flutter template) its `injectBugsee<Variant>BuildId` tasks write into the
assets that Flutter's `copyFlutter<Variant>Assets` produces without declaring that
ordering, and the build is rejected. Until the plugin fixes this
([bugsee-android-gradle-plugin#33](https://github.com/bugsee/bugsee-android-gradle-plugin/issues/33)),
add this to the app's `android/app/build.gradle.kts`:

```kotlin
tasks.matching { it.name.startsWith("injectBugsee") && it.name.endsWith("BuildId") }.configureEach {
    val variant = name.removePrefix("injectBugsee").removeSuffix("BuildId")
    mustRunAfter("copyFlutterAssets$variant")
}
```

## Developing

The example app (`example/`) has a launch screen, a data screen that calls every method above and a
network screen; `example/integration_test/launch_test.dart`, `facade_test.dart`, `network_test.dart` and `logs_test.dart`
run them against the real SDKs on a device or simulator.
See [PLAN.md](PLAN.md) for the implementation plan and `.github/CI.md` for the checks.
