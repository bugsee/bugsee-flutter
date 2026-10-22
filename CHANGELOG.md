## 10.0.0-dev.1

A rewrite for the Bugsee 7.x native SDKs (Android 7.4.2, iOS 7.0.0-beta7). **Not published yet; a prerelease.** Existing 9.x apps
should stay on 9.x: there is no compatibility layer (the decision is open), see `doc/migration-from-9x.md`.

### Features

* **Launch and configuration.** `Bugsee.launch(token, {options})` returning `LaunchResult` (`launched`, `alreadyRunning`, `deferred`),
  `waitUntilLaunched`, `stop`, `status`, `statusChanges`, `getStatus`, `isLaunched`, `getLaunchOptions`, `getHostLaunchOptions`.
  `BugseeOptions` has a typed, documented field for each of the 100 options the SDKs register, generated from the manifests they
  publish (enums carry the SDK's internal value); an unknown key or a wrong type is an `ArgumentError` before the SDK sees it.
* **Data.** Attributes (`setAttribute`, `getAttribute`, `getAllAttributes`, `clearAttribute`, `clearAllAttributes`), the user identifier,
  `event`, `trace`, `log`, `addBreadcrumb`, `notify`, blackout (`startBlackout`, `endBlackout`, `isBlackout`), `showReportDialog`, `upload`.
* **Reports.** `setReportHandler` / `reportHandler` with `ReportProxy` (before and after callbacks, edits to summary, description,
  severity, labels and attributes), report attachments and annotated screenshots (path-first, no bytes cross the bridge, `addAttachmentBytes`
  up to 1 MiB), `Bugsee.createReport({timeToLive})` returning a `CreatedReport`, and the `lifecycleEvents` stream.
* **Privacy.** The `BugseeSecureView` widget, and the Flutter widget tree in reports (boxes and type names only, no text, keys or semantics;
  a secure view is one node) answered synchronously from a native snapshot cache; `Bugsee.captureViewHierarchy()`.
* **Dart errors.** `logException`, `logUnhandledException`, `reportException`; opt-in `installErrorHandlers` (chained, restored, once per
  error, rate limited, **error reports by default**, `reportAsCrash: true` for crash reports), `errorHandlersActive`, `runGuarded`,
  `listenToIsolateErrors`; obfuscated (`--split-debug-info`) stacks are sent untouched for the backend to symbolicate.
* **Network.** Opt-in `installNetworkCapture` records `dart:io` HTTP traffic (`package:http`, dio's default adapter, `Image.network`, ...)
  and hands it to the SDK through the wrapper channel with the SDK's body options and sanitizer; `setNetworkFilter` is a Dart-side,
  fail-closed filter that runs first; `networkCaptureStats`.
* **Logs.** Opt-in `installLogCapture` records `print` (in a zone: `runWithLogCapture`, `runGuarded`) and `debugPrint`; `forwardLog` for your
  own logging; `setLogFilter` (fail closed); `logCaptureStats`. Recorded with the plugin's own source (`Custom`), not as `Bugsee.log`.
* `bugseeFlutterVersion`, so the feedback package can check it runs with the core it was released with.
* The in-app feedback chat is the separate package `bugsee_flutter_feedback`, released in lock-step.
* The wrapper registers with the SDK before it can launch (an Android content provider at `initOrder` 200; iOS `+load`), so reports recovered
  after a crash carry the wrapper identity.
* Development only: the device verification harness (`scripts/device/`) and the verification app are not published; its results are in `doc/verification.md`, which ships with the package like the other pages in `doc/`.

### Breaking changes from 9.x

* A new API: `Bugsee.launch` returns `LaunchResult` and takes `BugseeOptions` (no `AndroidLaunchOptions` / `IOSLaunchOptions`, no
  `appRunCallback`); email becomes the user identifier; attachments move to the report handler; secure rectangles are replaced by
  `BugseeSecureView`; `pause` / `resume` are replaced by blackout; `relaunch`, the appearance system, `setApplicationVersion`,
  `registerNetworkEvent`, `BugseeIgnoreSecureView` and the test-crash calls are removed. Network, log and error capture are opt-in.
  The full mapping is in `doc/migration-from-9x.md`.
* The Dart log, network and lifecycle types are new (`BugseeLogEvent.message` instead of `text`, `LifecycleEvent` instead of
  `BugseeLifecycleEventType`, `ReportSeverity` instead of `BugseeSeverityLevel`).

### Requirements

* Flutter 3.41.0 or newer, Dart 3.11 or newer (the plugin is SwiftPM-only).
* Android: `minSdk` 21, JDK 17 or 21, the Bugsee Gradle plugin 4.0.8 applied by the app (mandatory), and the Gradle ordering workaround
  for [bugsee-android-gradle-plugin#33](https://github.com/bugsee/bugsee-android-gradle-plugin/issues/33).
* iOS: 15.0 or newer, Swift Package Manager only (no CocoaPods).

### Known gaps

* Verified on an Android emulator and iOS simulators only; no physical device yet. The iOS simulator slice has no crash reporter and
  files no logged exceptions, so those paths are unverified on iOS.
* The Android report screenshot is black in Flutter's default `SurfaceView` render mode (SDK issue
  [bugsee-android#316](https://github.com/bugsee/bugsee-android/issues/316)); render with a `TextureView` as the workaround.
* Not exposed: APM transactions and spans, the appearance system, `relaunch`.
* See `PLAN.md` for the open decisions and the full list.
