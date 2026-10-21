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
- Secure rectangles (workbook Part 5; Dart `lib/src/secure`, `SecureRectangleStore` / `BGSFlutterSecureRectangleStore`): Dart publishes Flutter LOGICAL pixels per view WITH the device pixel ratio it measured them at, whole state, ordered by `(epoch, sequence)` where the epoch is a RANDOM id (never a clock): a new epoch is a new isolate and wins, a retired one is a dead isolate's straggler and is ignored. The SDKs' units differ and are read from SDK source: Android 7.4.2 takes PHYSICAL PIXELS in `View.getLocationOnScreen` space (factor = the message's ratio, which must equal the density of the Flutter view's `Resources` read at every pull), iOS 7.0.0-beta7 takes POINTS in the screen's coordinate space (factor = ratio / `UIScreen.scale` = 1; NEVER multiply by `UIScreen.scale`). A ratio that does not match the display now (density changed natively before Dart laid out again) covers the whole display until Dart republishes. Scale (including the view's own on-screen scale from its and its ancestors' transforms), then add the view's screen position, THEN floor l/t and ceil r/b. Versions are derived from what is served (per display, never 0, no-op never moves them); a display that never had a rectangle serves `[0, 0]`. Anything unplaceable, non-finite, mis-scaled, rotated/skewed or without an activity/view controller serves the WHOLE display (fail closed); only a view known to be off screen (iOS: in no window) serves nothing. A grace window (`GRACE_MS` = 0.12 s, in both stores, compared by the drift guard) serves each past set for that long AFTER IT stopped being current (not from the last change, so a long movement does not widen the cover to its path), so a moving region leaves no strip; the union shrinking back is itself a version change. Dart reports regions unclipped, including what their descendants paint outside the box, and drops one ONLY on positive evidence that it is not on screen (an ancestor that does not paint it, an IndexedStack showing another child, a clipping viewport it and what it paints lie wholly outside of). A disabled TickerMode is NOT evidence (it only stops animations). A detached layer is NOT such evidence (SnapshotWidget, the Zoom page transition). Every one of these rules has a test that fails when it is broken; keep it that way.
- Secure rectangle limits (known, documented, not bugs): a region that has just APPEARED is recorded in the clear for its first frame or so (it has no previous place to union with, and Dart cannot publish before layout has placed it; publishing from the build phase would only publish a guess); a rotated region is its bounding box; a region partly clipped is reported whole, so it can cover a few neighbouring pixels the clip hid; pixels drawn outside the region's subtree (an Overlay magnifier or tooltip) are not known to Flutter and not covered; FP noise can add one pixel to an edge; only the implicit view (id 0) is placed on mobile; a hot-restarted isolate that has no regions publishes nothing, so the old isolate's rectangles stay served until the engine detaches (debug only, over-covers); a region with more than 2000 descendants is not dropped by the viewport test (over-covers); iOS is verified in portrait only.

## Checks

```bash
flutter analyze && flutter test
(cd example && flutter build apk --debug)        # JDK 17 or 21
(cd example && flutter build ios --debug --no-codesign)
dart scripts/generate_pigeon.dart --check          # bridge outputs current
(cd example/android && ./gradlew :bugsee_flutter:testDebugUnitTest)
(cd ios/wrapper_tests && xcodebuild test -scheme bugsee_flutter_wrapper_tests -destination 'platform=iOS Simulator,name=<iPhone>')
```
