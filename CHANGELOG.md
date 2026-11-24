## 10.0.0-dev.1

A rewrite for the Bugsee 7.x native SDKs (Android 7.6.0, iOS 7.1.0). **Not published yet; a prerelease.** Existing 9.x apps
should stay on 9.x: there is no compatibility layer (the decision is open), see `doc/migration-from-9x.md`.

### Known gaps

* Symbolication was exercised end to end on apidev (obfuscated release builds on an iPhone XS and an Android phone): Android, including Dart 3.14 stacks, and iOS native
  crashes are symbolicated; **iOS Dart exceptions stayed raw** because of a backend symbol-lookup collision (fixes in review: bugsee-appserver#280, bugsee-background-worker#182).
  The production endpoint was not used (`doc/verification.md` scenario 11). The harness's own read-back of the backend has not run; the results were read by hand.
  On iOS the Dart `.symbols` file and the `App.framework` dSYM share one UUID, so the documented upload flow can leave Dart frames raw until those fixes are deployed (README, symbols section).

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

* **Log lines keep the time they were printed** on both platforms (the SDKs' wrapper-channel timestamp overloads, bugsee-android#299 and
  bugsee-cocoa#265): a line a slow filter or a long queue delayed is no longer recorded late. Fixed with the Android 7.5.0 move: the black
  `SurfaceView` report screenshot (#316) and the attachment re-check (#309) are fixed in the SDK, and the wrapper's undo of a late add stays as a safety net.

### Requirements

* Flutter 3.50.0 or newer, Dart 3.14 or newer (the 10.0 major moves the floor to the release with Direct Interop, Android Gradle Plugin 9 and `material_ui`; it was 3.41.0 / 3.11, the first where a SwiftPM-only plugin resolves on Linux and Windows).
* Android: the SDK's startup hold is on (`com.bugsee.wrapper-hold`): capture is blacked out from process start until the first Flutter frame is up and the secure rectangles are published (about 1 s after it). Time caps bound the hold (10 s after the last engine that attached before a frame, 20 s with none, 60 s at most), so a hold that a cap ends does not guarantee that Dart had published its secure rectangles: the cap is a safety limit, not a privacy guarantee. The first seconds of a session are not recorded.
* Android: turn on the native symbol upload with `bugsee { ndk { enabled.set(true) } }` (the plugin has it off; without it native crashes
  in release builds are unreadable), see README "Debug symbols" (also the Dart and iOS symbols, which are uploaded by hand).
* Android: `minSdk` 21, JDK 17 or 21, the Bugsee Gradle plugin 4.1.1 applied by the app (mandatory; no Gradle ordering workaround any more,
  [bugsee-android-gradle-plugin#33](https://github.com/bugsee/bugsee-android-gradle-plugin/issues/33) is fixed in 4.1.0).
* iOS: 15.0 or newer, Swift Package Manager only (no CocoaPods).

### Known gaps

* Verified on Android emulators and iOS simulators, plus integration tests (not the device harness) on one physical Android 14 device, an iPhone XS and an iPhone 16 Pro. On the
  phones some tests failed or were not run (`view_hierarchy_test` fails on the debug builds of the Android device and the iPhone XS and passes in profile builds; the iPhone 16 Pro ran only
  `attachments`, `network` and `logs`), and the harness's iOS crash matrix ran on an iPhone XS (recovered reports of native signals, Objective-C exceptions and a Swift trap; a raised signal 7 (SIGEMT on iOS, not SIGBUS) leaves no report; SIGBUS is not yet measured on a device), while iOS exception bundles (the Dart routes) were not run on a phone. The iOS simulator slice has no crash reporter and
  files no logged exceptions. Details: PLAN.md, doc/verification.md.
* Not exposed: APM transactions and spans, the appearance system, `relaunch`.
* See `PLAN.md` for the open decisions and the full list.
