# CLAUDE.md

Guidance for reviewers and agents working in this repository.

## Project

`bugsee_flutter`: the Flutter wrapper for the Bugsee 7.x native SDKs (Android 7.6.1, iOS 7.1.0), version `10.0.0-beta.1`,
the first public beta (not yet on pub.dev until the maintainer pushes the tag), plus the separate `packages/bugsee_flutter_feedback`. The implementation is complete and merged into `main`
(the default branch, formerly `nextgen`); `PLAN.md` is the status, the decisions (D1 to D14), the open questions and the release checklist. The authoritative wrapper spec is
`sdk/wrapper-workbook` in the `bugsee/specs` repository (refer to it by repo name); `doc/workbook-conformance.md` maps it to the code.

Repo map: `lib/` (Dart facade and capture), `android/` and `ios/` (the wrapper, iOS as a Swift package), `pigeons/` (bridge definition and its generator
package), `packages/bugsee_flutter_feedback/` (separate package, own bridge), `scripts/` (codegen, release and pub.dev helpers; `scripts/device/` is the
device harness), `tools/pana/` (locked pana toolchain, never published), `test/` (unit tests and the drift guards), `example/` (app and device tests),
`native-versions.json` (the pins), `.github/` (workflows, `CI.md`).

Where to look: `doc/README.md` (index), `doc/architecture.md` (layers and rules), `doc/design-rules.md` (the detailed rules per area, the
long form of everything below), `doc/api-surface.md`, `doc/verification.md` (device evidence), `.github/CI.md` (checks), `README.md` (users).

## Rules to enforce

- `native-versions.json` is the single source for every native pin. Each place that must repeat a value is compared to it by
  `test/native_versions_test.dart`. Do not hardcode a version elsewhere; update the guard when CI content changes.
- iOS is SwiftPM-only. There is deliberately no podspec (Bugsee publishes no pod). CI runs on macOS so SwiftPM can be enabled. Do not add a podspec.
- Flutter floor is 3.50.0 / Dart 3.14 (moved from 3.41.0 for the 10.0 major: Direct Interop, AGP 9, `material_ui`; PLAN.md D5). The SwiftPM-only plugin needs 3.41.0 at least.
- Android builds need JDK 17 or 21. JDK 25 is not in the supported set (the example built with it, unsupported). The app applies Bugsee Gradle plugin 4.1.1 (mandatory).
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
  Releases: only `.github/workflows/release.yml` publishes (tag `v<version>`, OIDC, `environment: pub.dev`, after its gate; guarded in `test/native_versions_test.dart`); `workflow_dispatch` there is a dry run (pub.dev refuses non-tag publishing).
- **Device harness** (`scripts/device/`, not in CI): its guards are on by default and must stay so; a new check goes through `Run.guard` / `Run.expect`, a
  new parser in `scripts/device/core/` with a test that shows it failing (`test/device_harness_test.dart`). A NOT POSSIBLE scenario exits 2.
- **Docs**: a doc claim about code (a name, default, limit, command, path) is checked against the code; `README.md`, `CHANGELOG.md` (the newest entry is
  the pubspec version: `test/native_versions_test.dart`), `PLAN.md` and the pages in `doc/` change with the behaviour they describe.

- **Release and publishing** (`.github/workflows/release.yml`, `.github/CI.md` "Releases", PLAN.md "Release checklist"): ONLY a pushed tag `v<version>`
  publishes, core first, then the feedback package, over pub.dev's GitHub OIDC (no secret). The gate (read-only: tag on `main`, tag == both pubspecs
  and both CHANGELOG tops, `ci-ok` green on the commit, format, codegen, analyze, test, dry runs, archive check, pana) runs before the two publish jobs,
  which use the `pub.dev` environment (required reviewers). A manual `workflow_dispatch` is always a dry run. Tags `v*` are protected by a ruleset. Both are GitHub settings, not repo files (set up 2026-11: environment `pub.dev` with required reviewers and `v*` tags only, tag ruleset "Release tags (v*)"): before relying on them, check with `gh api repos/bugsee/bugsee-flutter/rulesets` and `gh api repos/bugsee/bugsee-flutter/environments/pub.dev`; PLAN.md step 0 lists how to recreate them. **An agent
  never tags, pushes a tag, approves the environment or publishes**; it may run the dry run and report. `test/native_versions_test.dart` fails if the
  workflow is weakened: change the guard in the same PR, with the reason. The first version of a new package is a manual publish
  (`scripts/publish_feedback.sh --publish`); the Flutter version in every job is the floor, 3.50.0.
- **pana** (the pub.dev score): `scripts/pana_check.sh .` (CI job `pana`, and the release gate), every section full, the dependencies section may lose
  10. pana and its dependencies are pinned by `tools/pana/pubspec.lock` (`--enforce-lockfile`); the feedback package is scored in the release only after
  the core is live (pana resolves the core from pub.dev), so it cannot be scored earlier.

## Updating the underlying SDKs (native pins)

The wrapper follows the native Bugsee SDKs (Android, iOS). When either releases, the wrapper adopts it in one PR. Do this in order; the drift guards
(`flutter test`) fail on whatever you miss, so read their messages instead of guessing.

### The launch-options golden file

Every SDK release publishes an **immutable options manifest** (the golden file) to our CDN, written by the SDK's own build and deploy jobs from its live option
registry (so it is complete: extension modules, options registered with a null default, hidden `$$` options, which a read of the source cannot see):

`https://download.bugsee.com/sdk/options/<sdk>/<version>.json` (`<sdk>` is `android` or `ios`; template in `native-versions.json` `optionsManifest.urlTemplate`;
format `manifestVersion` 1, spec in the `bugsee/specs` repository, `sdk/options`)

- It never changes once published, so a fetched copy is the authority for the keys, types, enum values (by the SDK's INTERNAL value, never an ordinal) and defaults of
  that version. If `sync_option_manifests.dart --check` fails, the pin moved without a re-sync or a fixture was edited by hand; upstream did not change.
- Shape: `{manifestVersion, sdk, sdkVersion, buildConfiguration, generatedAt, options: [{key, type, default, module, hidden, enum?}]}`; an enum option carries `enum: {name, values: {constant: internal value}}`.
- Every SDK that embeds a native SDK (this wrapper, and the other cross-platform wrappers) reads the manifest of the version it pins and adopts the differences in its own
  launch options. Nothing here is written from memory of the SDK: the manifest is the input.
- Where it is read: `scripts/sync_option_manifests.dart` fetches it and vendors it VERBATIM as `test/fixtures/option_manifests/{android,ios}.json` (the only network
  step, also run weekly by `native-pins.yml --check`). `scripts/generate_options.dart` then writes `lib/src/options/option_registry.g.dart` and `bugsee_options.g.dart` (the typed
  `BugseeOptions` and its enums) from the manifests plus `docs.json` (the SDKs' own prose, `scripts/extract_option_docs.dart`, private SDK checkouts). One flat `com.bugsee.option.*` map
  goes to both platforms; a key or enum constant only one platform has is skipped on the other with a debug warning.
- How it is analysed: diff the new manifest against the vendored one (`diff <(python3 -m json.tool new.json) <(python3 -m json.tool test/fixtures/option_manifests/<sdk>.json)`)
  BEFORE overwriting, and write down what appeared, went, or changed type, default or enum values. Then `generate_options.dart` fails loudly on anything that needs a decision (a NEW enum
  must be named in `enumFamilies`; a key with different types on the two platforms; one value with two names must be listed in `knownNameDivergences`), and
  `test/option_manifests_test.dart` is STRICT on keys, types and enum values across platforms: a new default difference or one-sided enum member fails until you list it, with the reason.
  The counts there (Android 88 / iOS 72 options) change deliberately with a changed surface. Also adapt the native side when needed: the Android enum table
  (`LaunchOptionValuesTest.java`) and the iOS XCTest (`BGSFlutterLaunchOpsTests.m`).
- A changed default is a behaviour change for users: say it in `CHANGELOG.md` and `doc/migration-from-9x.md` (for example the shake and notification-bar triggers off by default since
  Android 7.6.0 / iOS 7.1.0).

### Steps

1. **Find and verify the version.** Android: Maven Central `com.bugsee:bugsee-android`, `-android-ndk` and `-android-feedback` (all three at the same version; the Gradle plugin `gradlePlugin`
   moves separately and must be >= 4.0.7). iOS: the tag of `github.com/bugsee/spm` and `github.com/bugsee/feedback-spm` (use the same tag; the iOS source repository has no 7.x tag). `scripts/check_native_pins.dart`
   (weekly in `native-pins.yml`) reports a newer Android 7.x. Read what changed (the SDK's change notes or the tag-to-tag compare): the wrapper SPI (`BugseeWrapperChannel` and friends) and
   the options manifest are what can break the wrapper; SDK-internal fixes need only the pin.
2. **`native-versions.json`**, the single source: `android.sdk`, `android.sdkBuild` (10 characters of the tag commit until a real run's banner replaces it), `ios.sdk`, `ios.sdkBuild`,
   `ios.spmRevision`, `ios.feedbackSpmRevision` (`git ls-remote <spm url> <tag>`), and the `provenance` text (date, source, what changed, what is NOT verified). Never hardcode a version elsewhere.
3. **The golden files.** `dart scripts/sync_option_manifests.dart` (analyse the diff as above), then `dart scripts/generate_options.dart`; commit the regenerated `.g.dart` files.
4. **Fixtures read from SDK source** (private checkouts; run when the SDK changed, and update the `pins` or `sources` line when it did not): `scripts/extract_report_enums.dart` -> `test/fixtures/report_enums.json`,
   `scripts/extract_data_requests.dart` -> `data_requests.json`, `scripts/extract_option_docs.dart` -> `docs.json`, and `scripts/verify_option_manifests.dart` as the independent read of the manifests.
5. **Repeated literals** (a published copy has no `native-versions.json`): `packages/bugsee_flutter_feedback/android/build.gradle` (`feedbackSdkVersion`); iOS `Package.swift` of `ios/bugsee_flutter`,
   `ios/wrapper_tests` and both feedback packages (`exact:` tags); the example's `Package.resolved` files (revisions); the harness test fixtures in `test/device_harness_test.dart` (banner text, Gradle
   dependency lines); `test/option_manifests_test.dart` (counts and one message). The Android core reads `native-versions.json` itself.
6. **Docs** that name a version: `README.md` (table), `CHANGELOG.md` (the newest entry and Requirements), `packages/bugsee_flutter_feedback/CHANGELOG.md`, `PLAN.md` (D1 and the open-decision text), this file, `doc/README.md`,
   `doc/architecture.md`, `doc/migration-from-9x.md`. Do NOT rewrite statements about the version something happened in or was measured at (`doc/verification.md`, "since 7.6.0"): they are history.
7. **Verify.** `flutter analyze && flutter test`, both `--check` generators, `build apk` and the iOS build in CI, then the device harness (`doc/verification.md`) which reads the banner and fixes `sdkBuild`.
   State in the PR what was NOT run (a device, a backend).
8. **Wrapper identity is separate**: the wrapper version (pubspec `version:`) does not change with a native bump; only a wrapper release changes it (PLAN.md "Release checklist", step 3).

## Checks

```bash
flutter analyze && flutter test                      # Flutter 3.50.0 (the floor); an older default cannot read the pubspec
dart scripts/generate_pigeon.dart --check            # bridge outputs current (add --package packages/bugsee_flutter_feedback)
dart scripts/generate_options.dart --check           # option registry + BugseeOptions current (offline)
dart scripts/sync_option_manifests.dart --check      # network: the vendored manifests are the SDKs' published ones
(cd example && flutter build apk --debug)            # JDK 17 or 21
(cd example && flutter build ios --debug --no-codesign)
(cd example/android && ./gradlew :bugsee_flutter:testDebugUnitTest :bugsee_flutter_feedback:testDebugUnitTest)
(cd ios/wrapper_tests && xcodebuild test -collect-test-diagnostics never -scheme bugsee_flutter_wrapper_tests -destination 'platform=iOS Simulator,name=<iPhone>')
flutter pub publish --dry-run && scripts/publish_feedback.sh    # dry runs only; never publish from an agent
scripts/pana_check.sh .                              # the pub.dev score (needs jq; pana runs from tools/pana)
scripts/check_release.sh v<version>                  # tag vs both pubspecs and CHANGELOGs
```

Environment notes: the Flutter 3.50.0 SDK is not on PATH by default (`~/fvm/versions/3.50.0/bin`). CI's recurring flake is a Maven Central 429 in the
`build apk` jobs: re-run only the failed jobs of the NEWEST run (re-running an old run cancels the newest). Real devices only through the device lock script.
The end-to-end symbolication run against a backend (`scripts/device/e2e_symbolication.dart`) needs app tokens and a device; its results are in `doc/verification.md`.

Device and source-reading checks (not CI): `example/integration_test/*_test.dart` (`-d <emulator or simulator>`, some need `support/mock_api.py`
and `--dart-define=BUGSEE_ENDPOINT=...`; see `.github/CI.md`), `dart scripts/device/verify.dart ...` (`doc/verification.md`),
`scripts/verify_option_manifests.dart`, `scripts/extract_report_enums.dart`, `scripts/extract_data_requests.dart` (need the private SDK checkouts).
Between `facade_test` and `launch_test` on iOS run `xcrun simctl uninstall <udid> com.bugsee.bugseeFlutterExample` (pending reports make iOS stop a
later launch of the same install).
