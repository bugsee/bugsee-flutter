# Migrating from 9.x to 10.x

10.0.0-dev.1 is a rewrite for the Bugsee 7.x native SDKs and a **clean break** from the 9.x plugin (9.0.5 on the old `release`
branch, which wrapped the 6.x SDKs: iOS 6.3.2, Android 6.0.4 per its `version.txt`).

**There is no compatibility layer.** Whether to offer one (a thin `bugsee.dart` shim over the 10.x facade) has been deferred by the
project owner and is undecided; nothing here promises one. The facade lives in `lib/src/bugsee.dart` and `lib/src/bugsee_runtime.dart`,
apart from everything else, so a layer could be added beside it later. Until then, existing 9.x apps should stay on 9.x.

Every mapping below was checked against the 10.x source (`lib/bugsee_flutter.dart` and `lib/src/`) and the 9.x source
(`git show origin/release:lib/bugsee.dart` and `lib/src/*.dart`). The 9.x README disagrees with its own code in places (it shows named
arguments for `event` and `trace`); this page follows the code.

## Platform setup

| | 9.x | 10.x |
|---|---|---|
| Flutter / Dart | `>=3.0.0` / `^3.0.0` | **Flutter `>=3.41.0` / Dart `^3.11.0`** (the plugin is SwiftPM-only; older Flutter fails `pub get` on Linux and Windows) |
| Native SDKs | Android 6.x, iOS 6.x | Android **7.4.2**, iOS **7.0.0** |
| Android | `minSdk` 21 | `minSdk` 21; the **Bugsee Gradle plugin 4.0.8 is mandatory** and applied by the app, plus a Gradle ordering workaround (README); JDK 17 or 21 |
| iOS | CocoaPods podspec (and a SwiftPM package), deployment target 11.0 | **SwiftPM only: no podspec, no CocoaPods**; deployment target **15.0** |
| Android launch | from Dart | from Dart, or by the SDK itself before Dart when the manifest has `com.bugsee.app-token` (then `Bugsee.launch` answers `alreadyRunning` and its options are not applied) |
| Wrapper registration | in the SDK options (`wrapper_info`) | natively, before the SDK launches (a content provider on Android, `+load` on iOS), not something your app does |
| Dart dependencies | `crypto`, `convert`, `stack_trace` | `meta`, `stack_trace` |
| Import | `package:bugsee_flutter/bugsee_flutter.dart` (also `bugsee.dart`) | `package:bugsee_flutter/bugsee_flutter.dart` only |
| Feedback chat | part of the plugin | the separate package `bugsee_flutter_feedback` |
| Pause and resume | `Bugsee.pause()` / `resume()` | **removed**: use blackout (below) |
| Symbols upload for `--obfuscate` | `scripts/symbols.py` | unchanged: the same script (`scripts/symbols.py` on the `release` branch) and protocol ([exceptions.md](exceptions.md), section 5) |

## What changed in the model

* **Options are one typed class.** `AndroidLaunchOptions` / `IOSLaunchOptions` (setters over legacy flat keys) are replaced by one
  `BugseeOptions` with a typed field per 7.x option (`captureVideo`, `configDuration`, ...), shared by both platforms. A field you leave
  out keeps the SDK's default (9.x wrote its own defaults into every launch).
* **Every call is stricter.** An invalid argument is a `BugseeException` (`BugseeArgumentException`) through the `Future` of the calls that return one, and thrown at once by the synchronous filter setup calls (`setNetworkFilter`, `setLogFilter`: an invalid `timeout`); `BugseeOptions` problems are an `ArgumentError` from `launch`. 9.x passed most of them on silently.
* **Nothing is queued before launch.** As in 9.x, `event`, `trace`, `log`, `notify` and `upload` before `launch` are dropped by the
  SDKs; attributes, the user identifier and blackout work before launch.
* **The report handler is first-class** (`setReportHandler`): it replaces the 9.x attachments callback.
* **Capture is opt-in and explicit** for what only Dart can see: `installNetworkCapture`, `installLogCapture`, `installErrorHandlers`.
  9.x installed its global error handler inside `launch` and captured `print` only for an `appRunCallback` zone.

## API mapping

`Bugsee.` is the facade class in both versions. "Same" means the same name and meaning; a different signature is noted.

### Execution

| 9.x | 10.x |
|---|---|
| `launch(token, {appRunCallback, launchOptions}) -> Future<bool>` | `launch(token, {options}) -> Future<LaunchResult>` (`launched`, `alreadyRunning`, `deferred`); throws `BugseeLaunchException` on failure. `appRunCallback` is **removed**: `await` the launch, then `runApp` (use `Bugsee.runGuarded` for the zone) |
| `stop()` | same |
| `relaunch([options])` | **removed**: `await Bugsee.stop()` then `Bugsee.launch(...)` |
| `pause()` / `resume()` | **removed**: `startBlackout()` / `endBlackout()` (7.x concept: video, screenshot, touches and the view hierarchy stop; logs and data continue; 9.x `pause` was documented as blacking out the video only) |
| (none) | `status`, `statusChanges`, `getStatus()`, `isLaunched()`, `waitUntilLaunched()`, `getLaunchOptions()`, `getHostLaunchOptions()`, `isBlackout()` |
| `defaultHttpOverrides` | **removed**: `installNetworkCapture()` (chains to `HttpOverrides.current`) |
| `setApplicationVersion(version)` | **removed**: the SDKs read the app version natively |
| `testExceptionCrash()`, `testSignalCrash()` | **removed** (not a product feature) |

```dart
// 9.x
await Bugsee.launch(token, appRunCallback: (launched) => runApp(const MyApp()),
    launchOptions: AndroidLaunchOptions()..maxRecordingTime = 45);

// 10.x
await Bugsee.launch(token, options: const BugseeOptions(configDuration: 45));
runApp(const MyApp());
```

### Data

| 9.x | 10.x |
|---|---|
| `setAttribute(String, dynamic)` / `getAttribute` / `clearAttribute` / `clearAllAttributes` | same names; the value is `String`, `bool`, `int` or finite `double` (anything else is a `BugseeArgumentException`); new `getAllAttributes()`; a value an SDK drops for size is a `BugseeAttributeException` |
| `setEmail` / `getEmail` / `clearEmail` | `setUserIdentifier` / `getUserIdentifier` / `clearUserIdentifier` (one identifier: the SDKs have no separate email; an email-shaped value links reports to a user) |
| `event(name, [Map<String, dynamic>])` | `event(name, [Map<String, Object?>])`: validated (JSON-like values, 16 levels) |
| `trace(name, dynamic)` | `trace(name, Object)`: `String`, `bool`, `int` or finite `double` |
| `log(text, [BugseeLogLevel])` | `log(message, {LogLevel level = LogLevel.info})` |
| `captureViewHierarchy()` | same |
| (none) | `addBreadcrumb(BugseeBreadcrumb)`, `notify(title, ...)` |
| `BugseeLogLevel` (`invalid`, `error`, `warning`, `info`, `debug`, `verbose`) | `LogLevel` (`error`, `warning`, `info`, `debug`, `verbose`; no `invalid`) |

```dart
// 9.x
await Bugsee.setEmail('user@example.com');
await Bugsee.event('checkout', {'items': 3});     // positional, as the code has it

// 10.x
await Bugsee.setUserIdentifier('user@example.com');
await Bugsee.event('checkout', {'items': 3});
```

### Exceptions

| 9.x | 10.x |
|---|---|
| `logHandledException(e, [stack])`, `logException(e, [stack])` (an alias of it) | `logException(error, [stackTrace])` (an error report; answers whether the SDK was handed it) |
| `logUnhandledException(e, [stack])` | same name (a crash report) |
| (via the global handler installed by `launch`) | opt-in `installErrorHandlers({reportAsCrash = false})`; **error reports by default** (9.x reported `FlutterError.onError` as unhandled: pass `reportAsCrash: true` to restore that) |
| `runGuarded(body, errorCallback)` (callback required, positional) | `runGuarded(body, {onError})` (named, optional) |
| `captureChain(body)` | **removed** (`package:stack_trace` is used internally) |
| `BugseeIsolate`, `isolate.addBugseeErrorListener()` / `removeBugseeErrorListener()` | `Bugsee.listenToIsolateErrors(isolate)` returning an `IsolateErrorListener` (`cancel()`) |
| (none) | `reportException(error, {stackTrace, handled, domain})`, `errorHandlersInstalled`, `errorHandlersActive` |

The exception document sent to the backend changed with the SDKs (a `signature` is now part of it; `doc/exceptions.md`), and
`signature` no longer hashes the application version.

### Network and logs

| 9.x | 10.x |
|---|---|
| `HttpOverrides.global = Bugsee.defaultHttpOverrides` | `Bugsee.installNetworkCapture()` (chains to any overrides you set first) |
| `setNetworkFilter(Future<BugseeNetworkEvent?> Function(BugseeNetworkEvent))`; the 9.x event had `type`, `method`, `url`, `redirectUrl`, `body`, `headers` | `setNetworkFilter(filter, {timeout})`; the 10.x event has `id`, `stage`, `method`, `url`, `headers`, `body`, `statusCode`, `redirectedFrom`, ...; a filter that throws or hangs **drops** the event |
| `registerNetworkEvent(eventData)` | **removed** (capture is automatic once installed) |
| `setLogFilter(Future<BugseeLogEvent?> Function(BugseeLogEvent))`; the 9.x event had `text`, `level` | `setLogFilter(filter, {timeout})`; the 10.x event has `message`, `level`, `tag`; applies to `print` / `debugPrint` / `forwardLog`, not to `Bugsee.log` |
| `print` captured when `launch` is given `appRunCallback` (a zone) | opt-in `installLogCapture()` plus `runWithLogCapture` / `runGuarded` |
| (none) | `forwardLog`, `logCaptureStats`, `networkCaptureStats` |

```dart
// 9.x
HttpOverrides.global = Bugsee.defaultHttpOverrides;
Bugsee.setNetworkFilter((e) async { e.headers?.remove('authorization'); return e; });

// 10.x
Bugsee.installNetworkCapture();
Bugsee.setNetworkFilter((e) { e.headers.remove('authorization'); return e; });
```

### Reports, attachments, lifecycle

| 9.x | 10.x |
|---|---|
| `upload([summary, description, severity, labels])` (all optional, positional) | `upload(summary, description, {severity, labels})` (summary and description required) |
| `showReportDialog([summary, description, severity, labels])` | `showReportDialog({summary, description, severity, labels})` (all named) |
| `BugseeSeverityLevel` (`low`, `medium`, `high`, `critical`, `blocker`) | `ReportSeverity` (`veryLow` with the alias `low`, `medium`, `high`, `critical`, `blocker`; same values 1 to 5) |
| `BugseeIssueType` | `ReportType` (`bug`, `crash`, `error`) |
| `setAttachmentsCallback(BugseeAttachmentsCallback)` with `BugseeAttachment(name, filename, data)` | **removed**: `setReportHandler(BugseeReportHandler(...))` and `ReportProxy.addAttachment(path, ...)` / `addAttachmentBytes(bytes, ...)` |
| (none) | `createReport()`, `ReportProxy` edits (summary, description, email, severity, labels, attributes, screenshot) |
| `setLifecycleCallback(void Function(BugseeLifecycleEventType))` | `lifecycleEvents`, a `Stream<LifecycleEvent>` (`name` is the SDK's event name, `reportId` where it carries one); status changes are `statusChanges`. The 9.x enum members `resumed`/`paused` have no 7.x event |

### Privacy

| 9.x | 10.x |
|---|---|
| `BugseeSecureView(child:, enabled:)` (a `MetaData`) | `BugseeSecureView(child:, enabled:)` (a `StatelessWidget`; `child` is required). It is now tracked natively through the wrapper's secure rectangles, with the limits listed in the README |
| `BugseeIgnoreSecureView` | **removed** |
| `addSecureRect` / `removeSecureRect` / `removeAllSecureRects` / `getAllSecureRects` | **removed**: use `BugseeSecureView` (the wrapper is the rectangle provider; native-unit rectangles are not exposed) |

### Feedback

| 9.x | 10.x (`package:bugsee_flutter_feedback`) |
|---|---|
| `showFeedbackUI()` | `BugseeFeedback.show()` |
| `setDefaultFeedbackGreeting(greeting)` | `BugseeFeedback.setGreeting(greeting)` |
| `setNewFeedbackMessagesCallback(callback)` | `BugseeFeedback.messagesReceived` (and `messageSent`) streams; fires only while the chat is on screen |

### Options

| 9.x (`BugseeLaunchOptions`) | 10.x (`BugseeOptions`) |
|---|---|
| `maxRecordingTime` | `configDuration` |
| `shakeToReport` | `reportingTriggersShake` |
| `crashReport` | `detectCrash` |
| `ndkCrashReport` (Android) | `detectCrashNdk` |
| `videoEnabled` | `captureVideo` |
| `videoScale` | `captureVideoScale` |
| `captureLogs` | `captureLogs` (plus `captureLogsLevel`) |
| `monitorNetwork` | `captureNetwork` |
| `screenshotEnabled` | `captureScreenshot` |
| `maxDataSize` | `configMaxDataSize` |
| `reportPrioritySelector` | `reportingUiPrioritySelectorEnabled` |
| `defaultCrashPriority` / `defaultBugPriority` | `reportingDefaultsCrashPriority` / `reportingDefaultsBugPriority` (a `ReportSeverity`) |
| `frameRate` (`BugseeFrameRate`) | `captureVideoFrameRate` (`FrameRate`: `low`, `medium`, `high`, and `raw` on Android only) |
| `wifiOnlyUpload` | `configWifiOnlyUpload` |
| `maxNetworkBodySize` | `captureNetworkBodySizeLimit` |
| `captureDeviceAndNetworkNames` | `captureDeviceNetworkNames` |
| `viewHierarchyEnabled` | `captureViewHierarchy` |
| `reportSummaryRequired` / `reportDescriptionRequired` / `reportEmailRequired` | `reportingUiSummaryRequired` / `reportingUiDescriptionRequired` / `reportingUiEmailRequired` |
| `reportLabelsEnabled` / `reportLabelsRequired` | `reportingUiLabelsEnabled` / `reportingUiLabelsRequired` |
| iOS `style` (`BugseeIosVisualStyle`) | `reportingUiStyle` (`BugseeStyle`: `light`, `dusk`, `basedOnStatusBar`, `system`; different members) |
| iOS `monitorDiskSpace`, `monitorBluetoothStatus`, `captureAVPlayer` | `captureDiskSpace`, `captureBluetoothStatus`, `captureAvPlayer` |
| Android `videoMode` (`BugseeVideoMode`) / `videoQuality` (`BugseeVideoQuality`) | `captureVideoMode` (`VideoMode`) / `captureVideoQuality` (`VideoQuality`) |
| Android `notificationBarTrigger` | `reportingTriggersNotificationBar` |
| iOS `screenshotToReport`, `killDetection`; Android `serviceMode` | no one-to-one typed field verified: search `BugseeOptions` for the 7.x option, or reach it through `BugseeOptions.custom` |
| `setCustomOption(key, value)` | `BugseeOptions(custom: {key: value})` (an unknown key is an `ArgumentError`, not silently dropped) |
| `BugseeFrameRate`, `BugseeVideoQuality`, `BugseeVideoMode` enums | `FrameRate`, `VideoQuality`, `VideoMode`; enums carry the SDK's internal value |
| `BugseeNetworkEventStage`, `BugseeNetworkEventNoBodyReason` | `NetworkStage`, `NoBodyReason` |

The mapping is by meaning (the 9.x names against the 10.x field documentation). The 100 typed fields are generated from the SDKs' own manifests; each field's dartdoc has the option key, the SDK default and the
platforms it applies to (defaults differ between platforms). An option that exists on one platform only is ignored on the other with
a debug warning.

### Removed without a replacement

* **Appearance** (`Bugsee.appearance`, `BugseeAppearance` and its styling surface): the 7.x appearance system differs per platform and
  is not exposed (`doc/api-surface.md`).
* APM transactions and spans, `relaunch`, secure activities, native views: not exposed.
* `BugseeHttpOverrides` as a public class (the capturing client is internal; use `installNetworkCapture`).

## Behaviour changes that can surprise

* A launch that was `true` in 9.x may be `alreadyRunning` or `deferred` in 10.x: check `waitUntilLaunched()` instead of the boolean.
* Android auto-init (a token in the manifest) ignores the options passed to `Bugsee.launch`.
* Nothing is captured from `dart:io`, `print` or Dart errors until you install it.
* The Android report screenshot may be black in Flutter's default `SurfaceView` render mode (README, limits).
* Unhandled Dart errors are error reports, not crash reports, unless `reportAsCrash: true`.
