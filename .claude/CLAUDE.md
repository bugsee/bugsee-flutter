# CLAUDE.md

Guidance for reviewers and agents working in this repository.

## Project

Bugsee Flutter wrapper for the 7.x native SDKs (Android and iOS). It is a rewrite in
progress; `PLAN.md` is the source of intent. The authoritative wrapper spec is
`sdk/wrapper-workbook` in the `bugsee/specs` repository (refer to it by repo name).

## Rules to enforce

- `native-versions.json` is the single source for every native pin. Each place that must
  repeat a value is compared to it by `test/native_versions_test.dart`. Do not hardcode
  a version elsewhere; update the guard when CI content changes.
- iOS is SwiftPM-only. There is deliberately no podspec (Bugsee publishes no pod). CI
  runs on macOS so SwiftPM can be enabled. Do not add a podspec.
- Flutter floor is 3.41.0 / Dart 3.11 (SwiftPM-only plugin fails `pub get` on Linux/Windows earlier; measured, see PLAN.md D5).
- Android builds need JDK 17 or 21. JDK 25 breaks the Gradle version in use.
- The Android initialization provider must never be named `Bugsee*InitProvider`.
- The wrapper type (`flutter`, the backend's identifier) and version (pubspec `version:`) are repeated in Dart, Android and iOS because native registers before Dart exists; `test/wrapper_identity_test.dart` compares every copy. Bump the iOS `BGSFlutterWrapper.m` and Dart `wrapper_identity.dart` with pubspec.
- The Dart <-> native bridge is Pigeon-generated (`pigeons/bridge.dart`; Dart, Java, Swift outputs committed, pin in `native-versions.json`). Never hand-edit `*.g.dart`, `Messages.java`, `Messages.g.swift`; run `dart scripts/generate_pigeon.dart` (CI checks with `--check`). Nothing in the bridge is exported from `lib/bugsee_flutter.dart` until Phase 4.
- Lifecycle events: native strips the `com.bugsee.lifecycle.` prefix once, forwards unknown names unchanged, hops to the platform thread before touching Flutter, buffers (cap 64, drops oldest) until Dart attaches. Status derives from Launching/Launched/Stopping/Stopped only; never take over the app's delegate/listener. The report-id event set, prefix and cap are repeated in Dart/Java/ObjC and compared by `test/lifecycle_drift_test.dart`.
- The wrapper object is replaced when Dart refines the identity, so state that must survive (secure rectangles, lifecycle hub) lives outside it (`SecureRectangleStore`, `LifecycleHub`, ObjC equivalents). Do not move it into the wrapper.
- iOS Objective-C wrapper tests: `ios/wrapper_tests` (symlinked sources), `xcodebuild test`. Android: JUnit under `android/src/test`.
- Secure-rect units differ per platform (Android pixels, iOS points); convert explicitly.
- Never treat lifecycle events as proof that a report exists or was sent.

## Checks

```bash
flutter analyze && flutter test
cd example && flutter build apk --debug          # JDK 17 or 21
flutter build ios --debug --no-codesign
dart scripts/generate_pigeon.dart --check          # bridge outputs current
cd example/android && ./gradlew :bugsee_flutter:testDebugUnitTest
cd ios/wrapper_tests && xcodebuild test -scheme bugsee_flutter_wrapper_tests -destination 'platform=iOS Simulator,name=<iPhone>'
```
