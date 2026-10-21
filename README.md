# bugsee_flutter

> **Status: the 7.x rewrite, in progress (10.0.0-dev.1, unpublished).** Launching, options,
> `stop` and status work on Android and iOS. Attributes, events, breadcrumbs, report handlers and
> the secure-region widget are not public yet. Existing users should stay on the latest published
> release until the migration guide is available. This API is a clean break from 9.x.

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
  // LaunchResult.launched, .alreadyRunning or .deferred (see below)

  runApp(const MyApp());
}
```

`Bugsee.launch` completes once the SDK reports that capture started. It throws a
`BugseeLaunchException` (with a `LaunchFailure` reason) when the SDK did not launch: a blank token,
a stop still in progress, a refusal, an exception on the native side, or a platform without an SDK.

```dart
Bugsee.statusChanges.listen((status) => print(status)); // launching, launched, stopping, stopped
await Bugsee.getStatus();       // the SDK's own answer
await Bugsee.stop();            // completes when the SDK has stopped
await Bugsee.getLaunchOptions(); // what is in effect: yours over the SDK's defaults
```

### Options

`BugseeOptions` has a typed, documented field for every option the SDKs register (101 at the pinned
versions), named after its key: `capture.video.frame-rate` is `captureVideoFrameRate`. A field you
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
- **iOS** has no auto-init. A launch while the app is in the background is deferred by the SDK until
  the app is active (`LaunchResult.deferred`).
- `stop()` and `launch()` again is how options change; a launch while a stop is still in progress
  is refused (`LaunchFailure.stopping`), so `await Bugsee.stop()` first.
- `getHostLaunchOptions()` differs between the platforms: Android returns every option you passed,
  iOS only those that differ from the iOS default. `getLaunchOptions()` is the same on both.

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

The example app (`example/`) is a small launch screen using this API;
`example/integration_test/launch_test.dart` runs the whole sequence on a device or simulator.
See [PLAN.md](PLAN.md) for the implementation plan and `.github/CI.md` for the checks.
