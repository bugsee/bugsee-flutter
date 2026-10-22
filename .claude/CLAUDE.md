# CLAUDE.md

Guidance for reviewers and agents working in this repository.

## Project

`bugsee_flutter`: the Flutter wrapper for the Bugsee 7.x native SDKs (Android 7.4.2, iOS 7.0.0-beta7), version `10.0.0-dev.1`,
unpublished, plus the separate `packages/bugsee_flutter_feedback`. The implementation is complete and merged into `nextgen`;
`PLAN.md` is the status, the decisions (D1 to D12), the open questions and the release checklist. The authoritative wrapper spec is
`sdk/wrapper-workbook` in the `bugsee/specs` repository (refer to it by repo name); `doc/workbook-conformance.md` maps it to the code.

Where to look: `doc/README.md` (index), `doc/architecture.md` (layers and rules), `doc/design-rules.md` (the detailed rules per area, the
long form of everything below), `doc/api-surface.md`, `doc/verification.md` (device evidence), `.github/CI.md` (checks), `README.md` (users).

## Rules to enforce

- `native-versions.json` is the single source for every native pin. Each place that must repeat a value is compared to it by
  `test/native_versions_test.dart`. Do not hardcode a version elsewhere; update the guard when CI content changes.
- iOS is SwiftPM-only. There is deliberately no podspec (Bugsee publishes no pod). CI runs on macOS so SwiftPM can be enabled. Do not add a podspec.
- Flutter floor is 3.41.0 / Dart 3.11 (the SwiftPM-only plugin fails `pub get` on Linux/Windows earlier; measured, PLAN.md D5).
- Android builds need JDK 17 or 21. JDK 25 breaks the Gradle version in use. The app applies Bugsee Gradle plugin 4.0.8 (mandatory).
- The Android initialization provider must never be named `Bugsee*InitProvider` (the Gradle plugin deletes it).
- The wrapper type (`flutter`) and version (pubspec `version:`) are repeated in Dart, Android and iOS because native registers before Dart
  exists; `test/wrapper_identity_test.dart` compares every copy. Bump the iOS `BGSFlutterWrapper.m`, Dart `wrapper_identity.dart` and the
  feedback package's `feedback_version.dart` with pubspec.
- The Dart <-> native bridge is Pigeon-generated (`pigeons/bridge.dart`; Dart, Java, Swift outputs committed, pin in `native-versions.json`).
  Never hand-edit `*.g.dart`, `Messages.java`, `Messages.g.swift`; run `dart scripts/generate_pigeon.dart` (CI runs `--check`). Nothing in
  the bridge is exported from `lib/bugsee_flutter.dart`. The bridge declares no enum (Pigeon sends ordinals): enums cross by SDK value or name.
- Lifecycle events: native strips the `com.bugsee.lifecycle.` prefix once, forwards unknown names unchanged, hops to the platform thread
  before touching Flutter, fans out to every attached engine, buffers (cap 64, drops oldest) only while none is attached, replays the latest
  status to each new receiver; status derives from Launching/Launched/Stopping/Stopped only; never take over the app's delegate/listener.
  The repeated sets are compared by `test/lifecycle_drift_test.dart`.
- The wrapper object is replaced when Dart refines the identity, so state that must survive (secure rectangles, lifecycle hub, view-hierarchy
  snapshot, network channel) lives outside it in process-wide stores. Do not move it into the wrapper.
- Tests: Dart `flutter test` (includes the drift guards); Android JUnit under `android/src/test`; iOS XCTest in `ios/wrapper_tests` (symlinked
  sources, `xcodebuild test`). A rule below with a guard must stay guarded: change the guard in the same PR, with the reason.

### Areas (invariants; full text in `doc/design-rules.md`)

- **Secure rectangles** (Part 5): Dart publishes Flutter LOGICAL pixels with the ratio measured, ordered by `(epoch, sequence)`; Android takes
  PHYSICAL pixels, iOS POINTS (never multiply by `UIScreen.scale`); scale, add position, THEN floor l/t and ceil r/b; versions derived from what is
  served (per display, never 0, no-op never moves them); anything unplaceable serves the WHOLE display (fail closed), only a view known off-screen
  serves nothing; a failed publish is retried and never abandoned. Known limit: a newly appearing region is in the clear for its first frame.
- **Report handlers** (Part 7): the SDK completion runs exactly once on every path and the pipeline NEVER blocks (iOS runs the handler on the
  main thread, which Dart's reply needs); `isTerminating` never reaches Dart; the window is the SDK's budget less a margin (numbers extracted from SDK
  source into `test/fixtures/report_enums.json`, not copied from the wrapper); `onBefore` at-most-once, `onAfter` at-least-once with a stable
  `deliveryId`; an Android native-crash report recovered after a normal session is dispatched on `BugseeReportHandlerThread` with the live window
  (device-measured), the early-crash path completes at once; a late edit is `ReportClosedError`. Guard: `test/report_handlers_drift_test.dart`.
- **View hierarchy** (`vh`): answered SYNCHRONOUSLY from a native cache Dart keeps current; never wait for Dart or post the answer (the SDK calls it on the main
  thread with a 500 ms budget from the call's return). Privacy is ours (the SDK stores the string unread): only `runtimeType` names and structure, never text, controllers, semantics, keys,
  tags, route names or `toString()`; a `BugseeSecureView` subtree is one node; any error sends nothing. Guard: `test/view_hierarchy_drift_test.dart`
  (allow-list of reads, one place converts units).
- **Options and launch** (Part 8): the SDKs' published manifests are vendored (`test/fixtures/option_manifests`); `BugseeOptions` and the registry
  are generated (`dart scripts/generate_options.dart`, never hand-edit `.g.dart`); ONE flat `com.bugsee.option.*` map goes to both platforms; a key
  or enum constant the other platform lacks is skipped with a debug warning, an unknown key, hidden key, wrong type or bad endpoint is an
  `ArgumentError` before native. The endpoint is normalised in one place (`lib/src/options/endpoint.dart`). Launch reads the status FIRST
  (auto-init and a second launch drop the options: answered `already-running`), marks an iOS stop before the main-queue hop, and answers the SDK
  callback once. `getHostLaunchOptions` differs per platform: documented, not normalised.
- **Facade**: every call crosses the bridge once on the platform thread, with the SDK behind a seam; Dart validates, native defends again, failure
  codes are repeated and compared by `test/facade_drift_test.dart`; the wrapper queues and gates nothing before `launch` (each SDK does what it does;
  the table is in `doc/api-surface.md`: change table and docs together); an attribute the SDK dropped is only knowable by reading it back (keep the
  read-back). `test/public_api_test.dart` PINS the exported symbols and `Bugsee`'s members: adding API means editing that list in the same change.
- **Network capture**: a chaining `HttpOverrides`; it must never change what the app sees or its timing, never throw into the app, never hold
  unbounded memory. Dart filter first and FAIL CLOSED; events always submitted with `requiresFiltering = true` (the SDK sanitizer still runs); gate
  on `launched` + `capture.network` in Dart and native; `addNetworkEvents` runs on a background queue; requests to Bugsee itself are never captured.
  Wire vocabulary in `test/fixtures/network_wire.json`, compared by `test/network_drift_test.dart`.
- **Log capture**: `print` via a zone, `debugPrint` via a chained global; lines go through the wrapper channel with source `Custom` ONLY (never `Bugsee`);
  the original output always happens first; the SDKs have NO log sanitizer and Android's logcat capture echoes `print` raw (the Dart filter does not
  cover it: documented). Wire in `test/fixtures/log_wire.json`, `test/logs_drift_test.dart`. Do not rename `NetworkChannelHolder` without the guards.
- **Dart errors**: the backend routes on the literal `FlutterManagedException` (carrier name, kept by `android/consumer-rules.pro`; NEVER rename) and
  reads the document keys `internalType, name, reason, signature, frames, originalStackTrace` only; the document MUST carry `signature` (both SDKs hash
  it); `originalStackTrace` is `stack.toString()` untouched for non-symbolic stacks. `reportAsCrash` defaults to FALSE (PLAN.md D9). Handlers chain,
  restore only if still current, never throw/block. Guard: `test/exceptions_drift_test.dart`.
- **Report files**: path-first; file work on a one-thread worker, NEVER the platform thread; a handler's report is claimed (lease) so the SDK completion
  waits for the claim without blocking; Android 7.4.2 does not re-check after an import (bugsee-android#309), so the wrapper undoes a late add; created
  reports are per-engine, one at a time, at most 6 starts a minute. Guard: `test/report_attachments_drift_test.dart`.
- **Feedback package**: separate (PLAN.md D4), a workspace member, lock-step version, hosted constraint `>=<core> <next minor>` (never exact, never a
  path or an override); the core must never mention it; its own Pigeon bridge; native pins are literals compared by
  `test/feedback_package_drift_test.dart`; it adds no Android provider; publish only through `scripts/publish_feedback.sh`, core first.
- **Device harness** (`scripts/device/`, not in CI): its guards are on by default and must stay so; a new check goes through `Run.guard` / `Run.expect`, a
  new parser in `scripts/device/core/` with a test that shows it failing (`test/device_harness_test.dart`). A NOT POSSIBLE scenario exits 2.
- **Docs**: a doc claim about code (a name, default, limit, command, path) is checked against the code; `README.md`, `CHANGELOG.md` (the newest entry is
  the pubspec version: `test/native_versions_test.dart`), `PLAN.md` and the pages in `doc/` change with the behaviour they describe.

## Checks

```bash
flutter analyze && flutter test                      # Flutter 3.41.0 (the floor); the default 3.38 cannot read the pubspec
dart scripts/generate_pigeon.dart --check            # bridge outputs current (add --package packages/bugsee_flutter_feedback)
dart scripts/generate_options.dart --check           # option registry + BugseeOptions current (offline)
dart scripts/sync_option_manifests.dart --check      # network: the vendored manifests are the SDKs' published ones
(cd example && flutter build apk --debug)            # JDK 17 or 21
(cd example && flutter build ios --debug --no-codesign)
(cd example/android && ./gradlew :bugsee_flutter:testDebugUnitTest :bugsee_flutter_feedback:testDebugUnitTest)
(cd ios/wrapper_tests && xcodebuild test -collect-test-diagnostics never -scheme bugsee_flutter_wrapper_tests -destination 'platform=iOS Simulator,name=<iPhone>')
flutter pub publish --dry-run && scripts/publish_feedback.sh    # dry runs only; never publish from an agent
```

Device and source-reading checks (not CI): `example/integration_test/*_test.dart` (`-d <emulator or simulator>`, some need `support/mock_api.py`
and `--dart-define=BUGSEE_ENDPOINT=...`; see `.github/CI.md`), `dart scripts/device/verify.dart ...` (`doc/verification.md`),
`scripts/verify_option_manifests.dart`, `scripts/extract_report_enums.dart`, `scripts/extract_data_requests.dart` (need the private SDK checkouts).
Between `facade_test` and `launch_test` on iOS run `xcrun simctl uninstall <udid> com.bugsee.bugseeFlutterExample` (pending reports make iOS stop a
later launch of the same install).
