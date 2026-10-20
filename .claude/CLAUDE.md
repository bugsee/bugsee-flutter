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
- The wrapper type (`flutter`, the backend's identifier) and version (pubspec `version:`) are repeated in Dart, Android and iOS because native registers before Dart exists; `test/wrapper_identity_test.dart` compares every copy. Bump the iOS `WrapperIdentity.swift` and Dart `wrapper_identity.dart` with pubspec.
- Secure-rect units differ per platform (Android pixels, iOS points); convert explicitly.
- Never treat lifecycle events as proof that a report exists or was sent.

## Checks

```bash
flutter analyze && flutter test
cd example && flutter build apk --debug          # JDK 17 or 21
flutter build ios --debug --no-codesign
```
