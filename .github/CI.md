# CI/CD

Only `release.yml` publishes (pub.dev, on a pushed version tag; see "Releases" below). Nothing else here publishes, tags or
deploys. All workflows except `claude-review.yml` (owned by the org's shared workflow, which needs
`pull-requests`/`issues` write, `id-token` write and a secret) use top-level `permissions: contents: read`
and checkout with `persist-credentials: false`; the one other permission is `id-token: write` on the two publishing jobs of `release.yml`.

## Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | PR, push to `main` | Format, bridge and option codegen, analyze + test + iOS build, Android APK build, `pub publish --dry-run`, the `pana` score, and the aggregate `ci-ok` |
| `native-pins.yml` | weekly (Mon 06:17 UTC), manual | Verifies the pins in `native-versions.json` still exist upstream, and that the vendored option manifests are still the SDKs' published ones (`dart scripts/sync_option_manifests.dart --check`). Network checks live only here, never in PR CI |
| `release.yml` | push of a tag `v<version>`, manual (always a dry run) | The release: gate, then publish `bugsee_flutter`, then `bugsee_flutter_feedback`, to pub.dev with OIDC. See "Releases" |
| `claude-review.yml` | PR opened / updated | Calls the shared org review workflow. Advisory; do not require it (needs an org secret, unavailable to fork PRs). Do not edit it here |

### `ci.yml` jobs and check names

| Job id | Check name(s) | Runner | Notes |
|---|---|---|---|
| `format` | `format` | ubuntu | `dart format --set-exit-if-changed` over `lib test example/lib example/integration_test scripts pigeons packages`, run on the floor Flutter because formatter output changes between Dart releases |
| `bridge-codegen` | `bridge codegen is current` | ubuntu | `dart scripts/generate_pigeon.dart --check` (and the same with `--package packages/bugsee_flutter_feedback` for the feedback package's own bridge, plus `dart analyze` of both generator packages): regenerates the Dart/Java/Swift bridge from `pigeons/bridge.dart` with the pinned pigeon and fails if a committed generated file differs (the tree is left untouched). Runs on the floor Flutter because the generated Dart is `dart format`ted and formatter output varies by release. It also runs `dart analyze` in `pigeons/` (excluded from the root analysis, which has no `pub get` for it). Fix: run `dart scripts/generate_pigeon.dart` and commit |
| `options-codegen` | `option registry is current` | ubuntu | `dart scripts/generate_options.dart --check`: regenerates `lib/src/options/option_registry.g.dart` and `bugsee_options.g.dart` from the vendored manifests (`test/fixtures/option_manifests`) and fails if a committed file differs. Offline. Floor Flutter (the generated Dart is `dart format`ted). Fix: run it without `--check` and commit. See "Option registry" |
| `test` | `analyze + test + ios build (floor)`, `analyze + test + ios build (stable)` | macOS | `flutter analyze`, `flutter test`, the same two in `packages/bugsee_flutter_feedback`, the example's iOS build (it uses both packages), and on the stable leg the XCTest of both iOS wrapper-test packages (`test/feedback_package_drift_test.dart` guards what must agree across the packages) (includes the option registry/parity tests and the drift guards, among them `test/secure_rects_drift_test.dart` for the constants the secure-rectangle store repeats in Java and Objective-C, and `test/report_handlers_drift_test.dart` / `test/report_enum_parity_test.dart` for the report pipeline and the report enums, which read `test/fixtures/report_enums.json`, `test/facade_drift_test.dart` for the failure codes, attribute limits and breadcrumb names the facade repeats in Dart/Java/Objective-C, `test/exceptions_drift_test.dart` for the exception carrier's name and limits and which SDK call each path makes, `test/exceptions_worker_contract_test.dart` (the worker's routing/parsing rules replayed on real captured entries), and `test/logs_drift_test.dart` for the log wire (`test/fixtures/log_wire.json`) and the source-attribution rules, `test/log_pipeline_test.dart` / `log_capture_test.dart` / `logs_facade_test.dart` (hooks, pipeline, runtime), and `test/network_drift_test.dart` for the network wire vocabulary (`test/fixtures/network_wire.json`) the capture repeats in Dart/Java/Objective-C and the option keys it reads (against the vendored manifests), `test/http_capture_test.dart` / `http_capture_fake_test.dart` / `network_pipeline_test.dart` / `network_service_test.dart` / `network_facade_test.dart` / `body_capture_test.dart` (real local `HttpServer`s, no network), `test/public_api_test.dart`, which pins the exported symbols and `Bugsee`'s members so an accidental export fails, `test/view_hierarchy_drift_test.dart` for the managed view hierarchy: the `vh` type and budgets read from SDK source into `test/fixtures/data_requests.json` by `scripts/extract_data_requests.dart`, the answer path never blocking, one place converting units, the builder reading no text), debug iOS build with SwiftPM, and (stable leg only) the XCTests of the Objective-C wrapper target via `xcodebuild test` on a simulator in `ios/wrapper_tests`. macOS is required: SwiftPM and the simulator only exist there |
| `build-android` | `build apk (floor)`, `build apk (stable)` | ubuntu | Debug APK of the example app (both packages), then the JUnit tests of both plugins (`:bugsee_flutter:testDebugUnitTest :bugsee_flutter_feedback:testDebugUnitTest`). Frees runner disk first (otherwise "No space left on device") |
| `publish-check` | `pub publish dry-run` | ubuntu | Runs on the floor Flutter, for BOTH packages: the root, whose archive (`flutter pub publish --to-archive`) is then listed by `scripts/check_pub_archive.sh` and fails on the sibling, any `pigeons/` or `wrapper_tests` tree, `local.properties`, `*.iml`, logs, build output or a lock file; then `scripts/publish_feedback.sh` (a dry-run of the sibling, with the same archive check, from a copy of the workspace made from the TRACKED files only (never the working tree: outside git pub no longer applies the root `.gitignore`, so untracked editor/build files would be published) without `.git`: pub applies every `.pubignore` between the git root and the package, so the root's `/packages/` rule hides the sibling when it is published from its own directory here). Package validity only. Fails on warnings (e.g. CHANGELOG missing the pubspec version, dirty git tree). Never uploads, needs no credentials |
| `pana` | `pana (pub.dev score)` | ubuntu | Scores the CORE the way pub.dev does (`scripts/pana_check.sh`, the floor Flutter). pana and everything it resolves are pinned by the committed `tools/pana/pubspec.lock` (`dart pub get --enforce-lockfile`; raise pana by editing `tools/pana/pubspec.yaml`, running `dart pub get` and committing both). The verdict is per section from pana's JSON: every section must be full, except the dependencies section, which may lose `PANA_DEPENDENCY_ALLOWANCE` points (default 10: "all dependencies on their latest version" moves when a dependency publishes, which no commit of ours causes); a loss anywhere else fails whatever the dependencies scored, and the sections that lost points are printed. 160/160 today. What stays unpinned: the pub.dev data pana reads (latest versions, advisories) and the SDK. The feedback package cannot be scored here: pana resolves its core dependency from pub.dev, so `release.yml` scores it after the core is live |
| `ci-ok` | `ci-ok` | ubuntu | `if: always()`; fails unless every job above succeeded (failed, cancelled and skipped needed jobs all fail it). Deliberately not `!cancelled()`: that would skip `ci-ok` on a cancelled run, and a skipped required check counts as passing |

Concurrency: PR runs of the same ref cancel superseded (running or pending) runs; every
push to `main` has its own group (its SHA), so none is cancelled or replaced. Every job has a `timeout-minutes`. Flutter SDK and pub cache use
`subosito/flutter-action`'s `cache: true`; no build outputs are cached or uploaded.

## Device verification harness (not in CI)

`scripts/device/` (Dart; `doc/verification.md`) builds the verification app (`example/lib/verify_main.dart`),
drives it on an Android emulator and an iOS simulator through the loopback mock API, and asserts the workbook Part 9 recipes
(native `SIGSEGV`, airplane-mode retention, crash across an update, obfuscated builds, secure regions at other densities,
hot restart). It needs a device and builds, so no workflow runs it; what CI runs is its pure core: the parsers, the
assertions and the 9.1 guards are tested in `test/device_harness_test.dart` (part of `flutter test`), together with drift guards
for everything the harness repeats (application id, bundle id, build flags, commands, mock endpoints, the pins it
reads from `native-versions.json`). The harness and its app are in `.pubignore` and in the archive check
(`scripts/check_pub_archive.sh`). Usage and the guards it applies by default are in `doc/verification.md`:

```bash
export VERIFY_GRADLE_HOME=<private gradle home>   # JDK 17/21; the default is build/device-verify/gradle-home
dart scripts/device/verify.dart build android      # debug, release (R8, --obfuscate), a second release, profile
dart scripts/device/verify.dart android --serial emulator-5554 --reuse
dart scripts/device/verify.dart build ios --udid <simulator>
dart scripts/device/verify.dart ios --udid <simulator> --reuse
```

## Device tests (not in CI)

`example/integration_test/{launch,cold_start,facade,exceptions,attachments,view_hierarchy,network,logs}_test.dart` (`network_test.dart` and `logs_test.dart` also need the stand-in API: `ISSUE_OK=1 UPLOAD_STATUS=503 python3 example/integration_test/support/mock_api.py 8196 /tmp/mock.log &` and `--dart-define=BUGSEE_ENDPOINT=http://10.0.2.2:8196`, or `http://localhost:8196` for iOS; it listens on 127.0.0.1 only) need the real SDKs and a device, so they run by hand
(the device harness above drives the verification app, not these): `cd example && flutter test integration_test/facade_test.dart -d <emulator or simulator>`.
`network_test.dart` needs a stand-in for the Bugsee API as the SDK's endpoint (`--dart-define=BUGSEE_ENDPOINT=http://<host>:<port>`; an Android debug build needs cleartext traffic allowed for that, which the example does not do: see `doc/network.md`) and `--dart-define=NET_HOLD=<seconds>` to keep the app alive while its bundle is read with `adb shell run-as`.
`logs_test.dart` needs the same stand-in (`mock_api.py` keeps the uploaded bundle, whose `log.json` is the readback; see `doc/logs.md`) and `--dart-define=LOGS_HOLD=<seconds>`. A plain `flutter test` run does NOT show the SDK's console echo of `print` (its zone sends `print` to the test reporter); use a plain app run for that. They use a placeholder token; iOS's SDK stops itself after the first refused upload, which `facade_test` accounts for (see
`.claude/CLAUDE.md`). `view_hierarchy_test.dart` needs no server: it picks a closed local port as the endpoint itself: on Android the SDK keeps the report bundle and the test reads its `viewtree.json` from the app's own files directory; on iOS it reads the SDK's capture buffer. The facade's own JUnit (`FacadeOpsTest`) and XCTest (`BGSFlutterFacadeOpsTests`) run in the `build-android` and `test` jobs.

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
| `dart scripts/verify_option_manifests.dart ...` and `dart scripts/extract_option_docs.dart ... --check` | by hand | the private SDK checkouts (Android tag, iOS `origin/release`); never CI |

Bumping a native pin: edit `native-versions.json`, run `sync_option_manifests.dart`, the two source scripts, then
`generate_options.dart`, and commit the diff: the review shows exactly which options appeared, changed or went.
The generator and the parity tests fail on anything that needs a decision (a new enum, a type that differs between the
platforms, a new default difference).

## How the floor is tested

`native-versions.json` `flutter.min` (3.50.0) is the Flutter floor and `flutter.dart` its
Dart. The `test` and `build-android` matrices each have a `floor` leg pinned to that
version and a `stable` leg. The `format` and `publish-check` jobs also run on the floor. The drift guard
(`test/native_versions_test.dart`) fails if a workflow's floor version, a `setup-java`
version or the `native-pins.yml` Dart SDK stops matching the JSON, so bumping the floor
means editing the JSON and the workflows together.

The floor cannot go lower on Linux/Windows: the plugin is SwiftPM-only, so
`flutter pub get` fails before 3.41.0 (measured; see PLAN.md, decision D5); the floor is 3.50.0 for other reasons (D5).

## Bridge codegen (Pigeon)

The Dart <-> native bridge is generated by Pigeon from `pigeons/bridge.dart`; the outputs
(`lib/src/bridge/messages.g.dart`, `android/.../Messages.java`,
`ios/.../Messages.g.swift`) are committed. The Pigeon version is pinned in
`native-versions.json` (`pigeon.version`), in `pigeons/pubspec.yaml` and by
`pigeons/pubspec.lock`; the drift guard compares them and the "Autogenerated from Pigeon
(vX)" header of every output. Pigeon lives in its own pure-Dart package (`pigeons/`)
for a reason that no longer holds (it needed a newer `meta` than Flutter 3.41.0 shipped; the 3.50.0 floor ships meta 1.19.0, so it could be a
dev_dependency of the plugin; not changed here). To change the bridge or bump Pigeon: edit, run
`dart scripts/generate_pigeon.dart` (needs network for `pub get`) and commit the result.
The generated Dart is formatted with the `dart` on PATH, so run it on the floor Flutter.

`.pubignore` replaces `.gitignore` for `pub publish`; it repeats the `.gitignore` rules
and drops `pigeons/`, `packages/` (the feedback package is published by itself, from its own directory, which has its own `.gitignore`/`.pubignore`) and `ios/wrapper_tests/` (whose `Sources` is a symlink pub would
publish as a full duplicate of the Objective-C sources).

## Two packages, one workspace

The repository is a pub workspace: the root `pubspec.yaml` lists `packages/bugsee_flutter_feedback` and `example`, so one
`flutter pub get` at the root resolves all three (one lock file at the root, COMMITTED, so CI and the example build resolve the same versions every run and a transitive release cannot break a job without a diff; the example has no lock of its own; `.pubignore` keeps it out of the published archive). Every `flutter pub get` in `ci.yml` is `--enforce-lockfile` (the floor legs of the two matrices, and the single-leg jobs, which run on the floor); the stable legs may move. To change a dependency: `flutter pub get` on the floor Flutter (3.50.0) and commit `pubspec.lock`.
The feedback package depends on `bugsee_flutter` by a hosted constraint that resolves to the sibling inside the workspace. They are
published separately and in order (core, then feedback); both dry-runs are in `publish-check`. The package-local checks run
inside the existing jobs (no job was added for it; the one new job, `pana`, scores the core and is in the `ci-ok` aggregate, so the branch protection needs no change).

## iOS wrapper tests

The plugin's own Swift package cannot host a test target (its Swift target imports
`Flutter`, which only the Flutter tool supplies). `ios/wrapper_tests` is a test-only
package whose `Sources/BugseeFlutterWrapper` is a symlink to the shipped Objective-C
target, so XCTest runs against exactly the shipped code. Locally:
`cd ios/wrapper_tests && xcodebuild test -collect-test-diagnostics never -scheme bugsee_flutter_wrapper_tests -destination 'platform=iOS Simulator,name=iPhone 17'` (without `-collect-test-diagnostics never` a failing run can sit for 10 minutes collecting diagnostics). The secure-rectangle tests need a simulator whose screen scale is not 1 (every current iPhone): two of them assert that and fail rather than pass vacuously on a 1x screen (workbook 5.3.3). The tracker tests create real `UIWindow`/`UIView`s.

## JDK

Android builds need JDK 17 or 21 (`native-versions.json` `android.jdk`). CI uses Zulu 21.
JDK 25 (Android Studio's bundled JBR) is not in the supported set: the example built a debug APK with it on Gradle 9.3.1 (measured), but CI runs 21.
Locally, point `JAVA_HOME` and `GRADLE_OPTS=-Dorg.gradle.java.home=...` at a 17 or 21 JDK.

The example builds with Gradle 9.6.0 and Android Gradle Plugin 9.5.3 (9.5 needs Gradle 9.6 at least) (Flutter 3.50 requires AGP 9), without the `kotlin-android` plugin;
`example/android/gradle.properties` keeps the two opt-outs Flutter's migrator writes (`android.builtInKotlin=false`, `android.newDsl=false`).
The example and tests import `material_ui` (`package:flutter/material.dart` is deprecated since 3.47).

## Runner capacity

The `test` job uses GitHub-hosted `macos-latest`, the scarcest and slowest runner (two
legs, up to 60 minutes each). Expect queueing when many PRs are open; that is why
superseded PR runs are cancelled. The Android repo uses a single shared self-hosted Mac
for its CI (see `bugsee/bugsee-android` `.github/CI.md`); this repo does not, so it
neither competes for that slot nor inherits its dirty workspace. Moving the iOS leg there
is possible later, but only after SwiftPM and Xcode availability on it are confirmed.

## Releases

`release.yml` publishes BOTH packages from one tag, in lock-step (the same version in both pubspecs). The tag form is `v<version>`
(`v10.0.0`, `v10.0.0-beta.1`; the form the 9.x tags use). pub.dev needs a tag pattern with `{{version}}`: `v{{version}}` for each package, and the
workflow's `on.push.tags` matches it. Authentication is pub.dev's automated publishing (GitHub OIDC, [dart.dev docs](https://dart.dev/tools/pub/automated-publishing)):
no secret exists. pub.dev accepts it only from a run triggered by a TAG PUSH, so `workflow_dispatch` (input `dryRun`, default true; false is refused
in the first step) runs the `gate` only (it includes the dry runs of both packages and prints what pub.dev has); the publish jobs do not run, so the environment's tag rule never sees a branch.

| Job | Needs | Permissions | What it does |
|---|---|---|---|
| `gate` | | `contents: read`, `checks: read` | The tag's commit is reachable from `origin/main`; `scripts/check_release.sh` (tag == both pubspec versions == both CHANGELOG top entries; the wrapper identity, the feedback lower bound and the pins are compared by the `flutter test` below); a successful `ci-ok` check run exists on the commit (so the iOS and Android builds were green); then on the floor Flutter: format, both Pigeon checks, the option registry check, `flutter analyze` and `flutter test` (root and feedback package), `flutter pub publish --dry-run`, the core archive through `scripts/check_pub_archive.sh`, `scripts/publish_feedback.sh` (dry run) and the pana score of the core (`scripts/pana_check.sh .`). Holds no token and no environment |
| `publish-core` | `gate`; tag push only | `contents: read`, `id-token: write`; `environment: pub.dev` | `dart-lang/setup-dart` (it exchanges the runner's OIDC token for the pub.dev credential, `PUB_TOKEN`; `subosito/flutter-action` does not), then `flutter pub publish --force` of `bugsee_flutter` (skipped when that version is already live: a re-run is safe) |
| `publish-feedback` | `gate`, `publish-core`; tag push only | the same; same environment | Waits (`scripts/pub_dev_status.sh wait`, 20 minutes) until the core version is live on pub.dev, then the pana score of the feedback package (`scripts/pana_check.sh packages/bugsee_flutter_feedback`: below the bar it stops this package before anything is uploaded), then `dart-lang/setup-dart` (the credential is short-lived, so it is minted after the wait), then `scripts/publish_feedback.sh --publish --yes`: it refuses a dirty tree and publishes from a copy of the TRACKED files (see its header). Skipped with a warning and a step summary when the package does not exist on pub.dev yet (below); skipped when that version is live |

- **Concurrency.** Tag pushes share the group `release`, never cancelled: a running release finishes first. GitHub keeps one running and ONE pending run per group, so a third tag push replaces the pending one (re-push it). A rehearsal has a group of its own (`release-dry-<run id>`) and cannot displace a release.
- **The checked commit is the published one.** The publish jobs check out `github.sha`, not the tag's current target, so a tag moved after the gate publishes nothing unchecked.
- **First version of the feedback package.** pub.dev can enable automated publishing only for a package that already exists, so the very first version
  of `bugsee_flutter_feedback` is published by hand once (PLAN.md, release checklist). Until then `publish-feedback` publishes nothing and says so
  (the core is already out by then). After the manual publish and enabling automated publishing, the next tag publishes it.
- **Guards.** `test/native_versions_test.dart` ("workflows"): only `release.yml` publishes; a publishing job is under `environment: pub.dev`,
  holds `id-token: write`, needs `gate`, and publishes in a step that runs on a tag push only; `id-token: write` appears nowhere else (mutation
  tests show each break failing); the gate repeats `ci.yml`'s format and codegen commands. `test/release_scripts_test.dart` runs both scripts
  (the pub.dev one against a local server). `scripts/pub_dev_status.sh` treats anything but 200/404 as an error, never as "not there".
- **Manual fallback.** From a clean checkout of the tag on the floor Flutter: `flutter pub publish` for the core, wait until it is live, then
  `scripts/publish_feedback.sh --publish`. Never from an agent.

Maintainer setup (nothing here applies it): see the PR description of the release pipeline and PLAN.md, release checklist step 7.

## Default branch

The rewrite lives on `main`, the default branch (it was `nextgen` until 2026-11-23; that branch is kept as the
archive of the per-change history and is no longer used). GitHub reads `dependabot.yml` and fires `schedule:`
triggers only from the default branch, so `native-pins.yml` and `dependabot.yml` work as they are: no
`target-branch`, and `native-pins.yml` checks out the default tree without a `ref`. Without a `target-branch`, the
`com.bugsee*` ignore rules also apply to Dependabot's security updates (GitHub makes the exception only when
`target-branch` is set), so a Bugsee pin is never bumped by Dependabot, security fixes included: such upgrades
are reviewed and made by hand through `native-versions.json`. The 9.x line is the `release` branch.

## Dependabot, templates

`dependabot.yml` bumps GitHub Actions, pub (root, `example`, `packages/bugsee_flutter_feedback`) and Gradle (`android`,
`example/android`, `packages/bugsee_flutter_feedback/android`) weekly. Bugsee's own artifacts are pinned in `native-versions.json`,
which Dependabot cannot read, and `example/android/settings.gradle.kts` repeats the Gradle plugin version literally. Both Gradle entries therefore `ignore` `com.bugsee*`, so Dependabot cannot bump a pin and break the drift guard; pins only change by hand, through the JSON.
`pull_request_template.md` carries the review checklist. There is no `CODEOWNERS`: the
org has no team that clearly owns this repo (teams: admin, android, bugsee, ios, web) and
the Android repo routes to individuals. Add one once an owner is chosen.

## Recommended branch protection (human admin action; not applied by this PR)

For `main`:

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
