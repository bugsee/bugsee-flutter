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
- Android builds need JDK 17 or 21. JDK 25 breaks the Gradle version in use.
- The Android initialization provider must never be named `Bugsee*InitProvider`.
- Secure-rect units differ per platform (Android pixels, iOS points); convert explicitly.
- Never treat lifecycle events as proof that a report exists or was sent.

## Checks

```bash
flutter analyze && flutter test
cd example && flutter build apk --debug          # JDK 17 or 21
cd example && flutter build ios --debug --no-codesign
```
