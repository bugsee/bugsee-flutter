# CI/CD

Nothing here publishes, tags or deploys. Releases to pub.dev are a separate, human-run
step (PLAN.md Phase 8). All workflows except `claude-review.yml` (owned by the org's shared workflow, which needs
`pull-requests`/`issues` write, `id-token` write and a secret) use `permissions: contents: read`
and checkout with `persist-credentials: false`.

## Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | PR, push to `nextgen` / `main` | Format, bridge and option codegen, analyze + test + iOS build, Android APK build, `pub publish --dry-run`, and the aggregate `ci-ok` |
| `native-pins.yml` | weekly (Mon 06:17 UTC), manual | Verifies the pins in `native-versions.json` still exist upstream, and that the vendored option manifests are still the SDKs' published ones (`dart scripts/sync_option_manifests.dart --check`). Network checks live only here, never in PR CI |
| `claude-review.yml` | PR opened / updated | Calls the shared org review workflow. Advisory; do not require it (needs an org secret, unavailable to fork PRs). Do not edit it here |

### `ci.yml` jobs and check names

| Job id | Check name(s) | Runner | Notes |
|---|---|---|---|
| `format` | `format` | ubuntu | `dart format --set-exit-if-changed` over `lib test example/lib example/integration_test scripts pigeons packages`, run on the floor Flutter because formatter output changes between Dart releases |
| `bridge-codegen` | `bridge codegen is current` | ubuntu | `dart scripts/generate_pigeon.dart --check` (and the same with `--package packages/bugsee_flutter_feedback` for the feedback package's own bridge, plus `dart analyze` of both generator packages): regenerates the Dart/Java/Swift bridge from `pigeons/bridge.dart` with the pinned pigeon and fails if a committed generated file differs (the tree is left untouched). Runs on the floor Flutter because the generated Dart is `dart format`ted and formatter output varies by release. It also runs `dart analyze` in `pigeons/` (excluded from the root analysis, which has no `pub get` for it). Fix: run `dart scripts/generate_pigeon.dart` and commit |
| `options-codegen` | `option registry is current` | ubuntu | `dart scripts/generate_options.dart --check`: regenerates `lib/src/options/option_registry.g.dart` and `bugsee_options.g.dart` from the vendored manifests (`test/fixtures/option_manifests`) and fails if a committed file differs. Offline. Floor Flutter (the generated Dart is `dart format`ted). Fix: run it without `--check` and commit. See "Option registry" |
| `test` | `analyze + test + ios build (floor)`, `analyze + test + ios build (stable)` | macOS | `flutter analyze`, `flutter test`, the same two in `packages/bugsee_flutter_feedback`, the example's iOS build (it uses both packages), and on the stable leg the XCTest of both iOS wrapper-test packages (`test/feedback_package_drift_test.dart` guards what must agree across the packages) (includes the option registry/parity tests and the drift guards, among them `test/secure_rects_drift_test.dart` for the constants the secure-rectangle store repeats in Java and Objective-C, and `test/report_handlers_drift_test.dart` / `test/report_enum_parity_test.dart` for the report pipeline and the report enums, which read `test/fixtures/report_enums.json`, `test/facade_drift_test.dart` for the failure codes, attribute limits and breadcrumb names the facade repeats in Dart/Java/Objective-C, `test/exceptions_drift_test.dart` for the exception carrier's name and limits and which SDK call each path makes, `test/exceptions_worker_contract_test.dart` (the worker's routing/parsing rules replayed on real captured entries), and `test/network_drift_test.dart` for the network wire vocabulary (`test/fixtures/network_wire.json`) the capture repeats in Dart/Java/Objective-C and the option keys it reads (against the vendored manifests), `test/http_capture_test.dart` / `http_capture_fake_test.dart` / `network_pipeline_test.dart` / `network_service_test.dart` / `network_facade_test.dart` / `body_capture_test.dart` (real local `HttpServer`s, no network), `test/public_api_test.dart`, which pins the exported symbols and `Bugsee`'s members so an accidental export fails), debug iOS build with SwiftPM, and (stable leg only) the XCTests of the Objective-C wrapper target via `xcodebuild test` on a simulator in `ios/wrapper_tests`. macOS is required: SwiftPM and the simulator only exist there |
| `build-android` | `build apk (floor)`, `build apk (stable)` | ubuntu | Debug APK of the example app (both packages), then the JUnit tests of both plugins (`:bugsee_flutter:testDebugUnitTest :bugsee_flutter_feedback:testDebugUnitTest`). Frees runner disk first (otherwise "No space left on device") |
| `publish-check` | `pub publish dry-run` | ubuntu | Runs on the floor Flutter, for BOTH packages: the root (and fails if its archive would contain `bugsee_flutter_feedback`), then `scripts/publish_feedback.sh` (a dry-run of the sibling from a copy of the workspace without `.git`: pub applies every `.pubignore` between the git root and the package, so the root's `/packages/` rule hides the sibling when it is published from its own directory here). Package validity only. Fails on warnings (e.g. CHANGELOG missing the pubspec version, dirty git tree). Never uploads, needs no credentials |
| `ci-ok` | `ci-ok` | ubuntu | `if: always()`; fails unless every job above succeeded (failed, cancelled and skipped needed jobs all fail it). Deliberately not `!cancelled()`: that would skip `ci-ok` on a cancelled run, and a skipped required check counts as passing |

Concurrency: PR runs of the same ref cancel superseded (running or pending) runs; every
push to `nextgen`/`main` has its own group (its SHA), so none is cancelled or replaced. Every job has a `timeout-minutes`. Flutter SDK and pub cache use
`subosito/flutter-action`'s `cache: true`; no build outputs are cached or uploaded.

## Device tests (not in CI)

`example/integration_test/{launch,cold_start,facade,exceptions,attachments,network}_test.dart` (the last also needs the stand-in API: `ISSUE_OK=1 UPLOAD_STATUS=503 python3 example/integration_test/support/mock_api.py 8196 /tmp/mock.log &` and `--dart-define=BUGSEE_ENDPOINT=http://10.0.2.2:8196`, or `http://localhost:8196` for iOS; it listens on 127.0.0.1 only) need the real SDKs and a device, so they run by hand
(Phase 7 owns a device harness): `cd example && flutter test integration_test/facade_test.dart -d <emulator or simulator>`.
`network_test.dart` needs a stand-in for the Bugsee API as the SDK's endpoint (`--dart-define=BUGSEE_ENDPOINT=http://<host>:<port>`; an Android debug build needs cleartext traffic allowed for that, which the example does not do: see `doc/network.md`) and `--dart-define=NET_HOLD=<seconds>` to keep the app alive while its bundle is read with `adb shell run-as`.
They use a placeholder token; iOS's SDK stops itself after the first refused upload, which `facade_test` accounts for (see
`.claude/CLAUDE.md`). The facade's own JUnit (`FacadeOpsTest`) and XCTest (`BGSFlutterFacadeOpsTests`) run in the `build-android` and `test` jobs.

## Option registry

Both SDKs publish an immutable options manifest per release (`https://download.bugsee.com/sdk/options/<sdk>/<version>.json`,
format in bugsee/specs `sdk/options`), generated from their live option registry. The two for the pins in
`native-versions.json` are vendored verbatim in `test/fixtures/option_manifests/{android,ios}.json`, so everything
reads them offline: `scripts/generate_options.dart` (the typed `BugseeOptions`, its enums, the registry), the Dart
parity tests (`test/option_manifests_test.dart`: strict on keys, types and enum values across platforms, default
differences listed explicitly), the JUnit test of the Android enum table and the XCTest against the real iOS
framework. Four checks, by where their inputs live:

| Check | Where | Inputs |
|---|---|---|
| `dart scripts/generate_options.dart --check` | PR CI (`options-codegen`) | the committed manifests and `docs.json` |
| `flutter test` (`option_manifests_test`, `options_registry_test`, `launch_options_test`, `launch_drift_test`) | PR CI (`test`) | the committed manifests |
| `dart scripts/sync_option_manifests.dart --check` | weekly `native-pins.yml`, or by hand | the network (the published manifests) |
| `dart scripts/verify_option_manifests.dart ...` and `dart scripts/extract_option_docs.dart ... --check` | by hand | the private SDK checkouts (Android tag, iOS `origin/nextgen`); never CI |

Bumping a native pin: edit `native-versions.json`, run `sync_option_manifests.dart`, the two source scripts, then
`generate_options.dart`, and commit the diff: the review shows exactly which options appeared, changed or went.
The generator and the parity tests fail on anything that needs a decision (a new enum, a type that differs between the
platforms, a new default difference).

## How the floor is tested

`native-versions.json` `flutter.min` (3.41.0) is the Flutter floor and `flutter.dart` its
Dart. The `test` and `build-android` matrices each have a `floor` leg pinned to that
version and a `stable` leg. The `format` and `publish-check` jobs also run on the floor. The drift guard
(`test/native_versions_test.dart`) fails if a workflow's floor version, a `setup-java`
version or the `native-pins.yml` Dart SDK stops matching the JSON, so bumping the floor
means editing the JSON and the workflows together.

The floor cannot go lower on Linux/Windows: the plugin is SwiftPM-only, so
`flutter pub get` fails before 3.41.0 (measured; see PLAN.md D5).

## Bridge codegen (Pigeon)

The Dart <-> native bridge is generated by Pigeon from `pigeons/bridge.dart`; the outputs
(`lib/src/bridge/messages.g.dart`, `android/.../Messages.java`,
`ios/.../Messages.g.swift`) are committed. The Pigeon version is pinned in
`native-versions.json` (`pigeon.version`), in `pigeons/pubspec.yaml` and by
`pigeons/pubspec.lock`; the drift guard compares them and the "Autogenerated from Pigeon
(vX)" header of every output. Pigeon lives in its own pure-Dart package (`pigeons/`)
because it needs a newer `meta` than Flutter 3.41.0 ships, so it cannot be a
dev_dependency of the plugin. To change the bridge or bump Pigeon: edit, run
`dart scripts/generate_pigeon.dart` (needs network for `pub get`) and commit the result.
The generated Dart is formatted with the `dart` on PATH, so run it on the floor Flutter.

`.pubignore` replaces `.gitignore` for `pub publish`; it repeats the `.gitignore` rules
and drops `pigeons/`, `packages/` (the feedback package is published by itself, from its own directory, which has its own `.gitignore`/`.pubignore`) and `ios/wrapper_tests/` (whose `Sources` is a symlink pub would
publish as a full duplicate of the Objective-C sources).

## Two packages, one workspace

The repository is a pub workspace: the root `pubspec.yaml` lists `packages/bugsee_flutter_feedback` and `example`, so one
`flutter pub get` at the root resolves all three (one lock file at the root, gitignored; the example has no lock of its own).
The feedback package depends on `bugsee_flutter` by a hosted constraint that resolves to the sibling inside the workspace. They are
published separately and in order (core, then feedback); both dry-runs are in `publish-check`. The package-local checks run
inside the existing jobs (no job was added, so the `ci-ok` aggregate and the branch protection need no change).

## iOS wrapper tests

The plugin's own Swift package cannot host a test target (its Swift target imports
`Flutter`, which only the Flutter tool supplies). `ios/wrapper_tests` is a test-only
package whose `Sources/BugseeFlutterWrapper` is a symlink to the shipped Objective-C
target, so XCTest runs against exactly the shipped code. Locally:
`cd ios/wrapper_tests && xcodebuild test -collect-test-diagnostics never -scheme bugsee_flutter_wrapper_tests -destination 'platform=iOS Simulator,name=iPhone 17'` (without `-collect-test-diagnostics never` a failing run can sit for 10 minutes collecting diagnostics). The secure-rectangle tests need a simulator whose screen scale is not 1 (every current iPhone): two of them assert that and fail rather than pass vacuously on a 1x screen (workbook 5.3.3). The tracker tests create real `UIWindow`/`UIView`s.

## JDK

Android builds need JDK 17 or 21 (`native-versions.json` `android.jdk`). CI uses Zulu 21.
JDK 25 (Android Studio's bundled JBR) breaks the Gradle 8.14 in the Flutter template.
Locally, point `JAVA_HOME` and `GRADLE_OPTS=-Dorg.gradle.java.home=...` at a 17 or 21 JDK.

## Runner capacity

The `test` job uses GitHub-hosted `macos-latest`, the scarcest and slowest runner (two
legs, up to 60 minutes each). Expect queueing when many PRs are open; that is why
superseded PR runs are cancelled. The Android repo uses a single shared self-hosted Mac
for its CI (see `bugsee/bugsee-android` `.github/CI.md`); this repo does not, so it
neither competes for that slot nor inherits its dirty workspace. Moving the iOS leg there
is possible later, but only after SwiftPM and Xcode availability on it are confirmed.

## Default branch caveat

The default branch is `main`, but this rewrite lives on `nextgen`. GitHub reads
`dependabot.yml` and fires `schedule:` triggers only from the default branch, and shows
the `workflow_dispatch` button only for workflows present there. So `native-pins.yml` and
`dependabot.yml` must also exist on `main` (or `nextgen` must become the default) before
the weekly check and Dependabot do anything. Every Dependabot entry sets
`target-branch: nextgen` so its PRs land on the rewrite, and `native-pins.yml` checks out `ref: nextgen` because a scheduled run would otherwise use `main`'s tree, which has neither `native-versions.json` nor the script. Dependabot *security* updates ignore `target-branch` and use the default branch, where the `com.bugsee*` ignore does not apply; `main` does not hold these pins, so this is not a risk today.

## Dependabot, templates

`dependabot.yml` bumps GitHub Actions, pub (root, `example`, `packages/bugsee_flutter_feedback`) and Gradle (`android`,
`example/android`, `packages/bugsee_flutter_feedback/android`) weekly. Bugsee's own artifacts are pinned in `native-versions.json`,
which Dependabot cannot read, and `example/android/settings.gradle.kts` repeats the Gradle plugin version literally. Both Gradle entries therefore `ignore` `com.bugsee*`, so Dependabot cannot bump a pin and break the drift guard; pins only change by hand, through the JSON.
`pull_request_template.md` carries the review checklist. There is no `CODEOWNERS`: the
org has no team that clearly owns this repo (teams: admin, android, bugsee, ios, web) and
the Android repo routes to individuals. Add one once an owner is chosen.

## Recommended branch protection (human admin action; not applied by this PR)

For `nextgen` and `main`:

- Require a pull request before merging; require at least 1 approving review; dismiss
  stale approvals on new commits.
- Require status checks to pass, with **only `ci-ok`** as the required check; require the
  branch to be up to date before merging.
- Block force pushes and branch deletion; include administrators if the plan allows.
- Do not require `claude-review` or `native-pins`.
- Plan limits apply: on the free plan some of these (required reviews, required checks on
  private repos) may be unavailable; the Android repo documents the same constraint.

`native-pins` failing is a signal to act (a pin disappeared or an upstream is down), not a
merge gate. Run it from the Actions tab (`workflow_dispatch`) after changing a pin.

## Not verified outside GitHub

Workflows only run on GitHub. Locally they are checked with `actionlint`, a YAML parse,
and the drift guard; the script behind `native-pins.yml` is run against the real pins with
`dart scripts/check_native_pins.dart`.
