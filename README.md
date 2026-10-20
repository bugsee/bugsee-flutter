# bugsee_flutter

> **Status: Phase 1 foundation of the 7.x rewrite. This is not a usable SDK yet.**
> The Bugsee launch API and SDK behaviour are not implemented in this revision.
> Existing users should stay on the latest published release until the migration
> guide is available.

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

See [PLAN.md](PLAN.md) for the implementation plan.
