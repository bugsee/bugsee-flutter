## What and why

<!-- One or two sentences. Link the workbook section or the PLAN.md decision it touches. -->

## Checklist

- [ ] Native versions change only in `native-versions.json`; every other copy is asserted by `test/native_versions_test.dart` (no literal Bugsee version anywhere else).
- [ ] No Android provider or class named `Bugsee*InitProvider` (it would match the SDK's own provider regex).
- [ ] Secure-rect values are converted explicitly to the platform unit (Android pixels, iOS points) before rounding; no unit assumed.
- [ ] Lifecycle events are never treated as proof that a report exists or was sent.
- [ ] No podspec added (iOS is SwiftPM-only); Flutter floor and JDK (17 or 21) unchanged, or `native-versions.json` and CI updated together.
- [ ] New or changed tests were mutation-checked: I broke the code, saw the test fail, and restored it.
- [ ] `flutter analyze`, `flutter test` and `dart format` are clean; the `ci-ok` check is green.

## Mutation checks

<!-- Which assertion, how you broke it, what failed. -->

## What was NOT verified

<!-- Platforms, devices, Flutter versions, or paths you did not run. "Nothing" is rarely true. -->
