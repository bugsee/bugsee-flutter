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
- Lifecycle events: native strips the `com.bugsee.lifecycle.` prefix once, forwards unknown names unchanged, hops to the platform thread before touching Flutter, fans out to every attached engine, buffers (cap 64, drops oldest, drop log rate-limited) only while none is attached, and replays the latest status event to each new receiver. Events in flight to a detached receiver go back to the FRONT of the buffer. Status derives from Launching/Launched/Stopping/Stopped only; never take over the app's delegate/listener. The report-id event set, prefix and cap are repeated in Dart/Java/ObjC and compared by `test/lifecycle_drift_test.dart`.
- The wrapper object is replaced when Dart refines the identity, so state that must survive (secure rectangles, lifecycle hub) lives outside it (`SecureRectangleStore`, `LifecycleHub`, ObjC equivalents). Do not move it into the wrapper.
- iOS Objective-C wrapper tests: `ios/wrapper_tests` (symlinked sources), `xcodebuild test`. Android: JUnit under `android/src/test`.
- Secure rectangles (workbook Part 5; Dart `lib/src/secure`, `SecureRectangleStore` / `BGSFlutterSecureRectangleStore`): Dart publishes Flutter LOGICAL pixels per view, whole state, ordered by `(epoch, sequence)`; native converts. The SDKs' units differ and are read from SDK source: Android 7.4.2 takes PHYSICAL PIXELS in `View.getLocationOnScreen` space (factor = density of the Flutter view's `Resources`, read at every pull), iOS 7.0.0-beta7 takes POINTS in the screen's coordinate space (factor 1; NEVER multiply by `UIScreen.scale`). Scale and add the view's screen position FIRST, then floor l/t and ceil r/b. Versions are derived from what is served (per display, never 0, no-op never moves them); a display that never had a rectangle serves `[0, 0]`. Anything unplaceable, non-finite or mis-scaled serves the WHOLE display (fail closed); only a view known to be off screen serves nothing. Dart reports regions unclipped (never less than the region) and drops those that are not painted. The constants repeated in Java and Objective-C are compared by `test/secure_rects_drift_test.dart`. Every one of these rules has a test that fails when it is broken; keep it that way.
- Secure rectangle limits (known, documented, not bugs): a region that moves is covered one frame late (Dart measures after a frame, then crosses a channel); a rotated region is its bounding box; a region partly clipped is reported whole, so it can cover a few neighbouring pixels the clip hid; an `Offstage`/`IndexedStack` child is not reported while it is not painted; FP noise can add one pixel to an edge; only the implicit view (id 0) is placed on mobile; iOS is verified in portrait only.
- Never treat lifecycle events as proof that a report exists or was sent.

## Checks

```bash
flutter analyze && flutter test
(cd example && flutter build apk --debug)        # JDK 17 or 21
(cd example && flutter build ios --debug --no-codesign)
dart scripts/generate_pigeon.dart --check          # bridge outputs current
(cd example/android && ./gradlew :bugsee_flutter:testDebugUnitTest)
(cd ios/wrapper_tests && xcodebuild test -scheme bugsee_flutter_wrapper_tests -destination 'platform=iOS Simulator,name=<iPhone>')
```
