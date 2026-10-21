# CI/CD

Nothing here publishes, tags or deploys. Releases to pub.dev are a separate, human-run
step (PLAN.md Phase 8). All workflows except `claude-review.yml` (owned by the org's shared workflow, which needs
`pull-requests`/`issues` write, `id-token` write and a secret) use `permissions: contents: read`
and checkout with `persist-credentials: false`.

## Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | PR, push to `nextgen` / `main` | Format, analyze + test + iOS build, Android APK build, `pub publish --dry-run`, and the aggregate `ci-ok` |
| `native-pins.yml` | weekly (Mon 06:17 UTC), manual | Verifies the pins in `native-versions.json` still exist upstream. Network checks live only here, never in PR CI |
| `claude-review.yml` | PR opened / updated | Calls the shared org review workflow. Advisory; do not require it (needs an org secret, unavailable to fork PRs). Do not edit it here |

### `ci.yml` jobs and check names

| Job id | Check name(s) | Runner | Notes |
|---|---|---|---|
| `format` | `format` | ubuntu | `dart format --set-exit-if-changed` over `lib test example/lib scripts`, run on the floor Flutter because formatter output changes between Dart releases |
| `test` | `analyze + test + ios build (floor)`, `analyze + test + ios build (stable)` | macOS | `flutter analyze`, `flutter test` (includes the drift guard), debug iOS build with SwiftPM. macOS is required: SwiftPM only exists there |
| `build-android` | `build apk (floor)`, `build apk (stable)` | ubuntu | Debug APK of the example app. Frees runner disk first (otherwise "No space left on device") |
| `publish-check` | `pub publish dry-run` | ubuntu | Runs on the floor Flutter. Package validity only. Fails on warnings (e.g. CHANGELOG missing the pubspec version, dirty git tree). Never uploads, needs no credentials |
| `ci-ok` | `ci-ok` | ubuntu | `if: always()`; fails unless every job above succeeded (failed, cancelled and skipped needed jobs all fail it). Deliberately not `!cancelled()`: that would skip `ci-ok` on a cancelled run, and a skipped required check counts as passing |

Concurrency: PR runs of the same ref cancel superseded (running or pending) runs; every
push to `nextgen`/`main` has its own group (its SHA), so none is cancelled or replaced. Every job has a `timeout-minutes`. Flutter SDK and pub cache use
`subosito/flutter-action`'s `cache: true`; no build outputs are cached or uploaded.

## How the floor is tested

`native-versions.json` `flutter.min` (3.41.0) is the Flutter floor and `flutter.dart` its
Dart. The `test` and `build-android` matrices each have a `floor` leg pinned to that
version and a `stable` leg. The `format` and `publish-check` jobs also run on the floor. The drift guard
(`test/native_versions_test.dart`) fails if a workflow's floor version, a `setup-java`
version or the `native-pins.yml` Dart SDK stops matching the JSON, so bumping the floor
means editing the JSON and the workflows together.

The floor cannot go lower on Linux/Windows: the plugin is SwiftPM-only, so
`flutter pub get` fails before 3.41.0 (measured; see PLAN.md D5).

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

`dependabot.yml` bumps GitHub Actions, pub (root and `example`) and Gradle (`android`,
`example/android`) weekly. Bugsee's own artifacts are pinned in `native-versions.json`,
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
