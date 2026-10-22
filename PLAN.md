# Bugsee Flutter SDK 10.x: project status

The 7.x rewrite of `bugsee_flutter` (package version `10.0.0-dev.1`, unpublished) on branch `nextgen`, plus the separate
`bugsee_flutter_feedback` package. **The implementation is feature complete and merged**; what remains is the owner's decisions, the
known gaps below and the release itself. Sources: the wrapper workbook (`sdk/wrapper-workbook` in `bugsee/specs`, the authoritative
order of work; how it is met: [doc/workbook-conformance.md](doc/workbook-conformance.md)), the wrapper, options, report and identity specs in the
same repository, and the React Native 7.x SDK as the reference design.

Contents: [Status](#status) | [Decisions taken](#decisions-taken) | [Open decisions](#open-decisions-for-the-owner) |
[Known gaps and filed issues](#known-gaps-and-filed-issues) | [Release checklist](#release-checklist) |
[Phase record](#phase-record) | [Test and mutation record](#test-and-mutation-record)

## Status

| Area | State | Docs |
|---|---|---|
| Foundations: pins, drift guards, CI, wrapper registration before launch, identity | Done | [architecture](doc/architecture.md), [CI.md](.github/CI.md) |
| Pigeon bridge, lifecycle, secure rectangles, report handlers | Done | [architecture](doc/architecture.md) |
| Options (100 typed fields), launch, stop, status | Done | [README](README.md) |
| Public facade: attributes, user, events, traces, logs, breadcrumbs, notify, blackout, upload, dialog, lifecycle stream, `BugseeSecureView` | Done | [api-surface](doc/api-surface.md) |
| Dart exceptions and obfuscated-stack support | Done | [exceptions](doc/exceptions.md) |
| `dart:io` network capture | Done | [network](doc/network.md) |
| `print` / `debugPrint` log capture | Done | [logs](doc/logs.md) |
| Flutter view hierarchy (`vh`) | Done | [view-hierarchy](doc/view-hierarchy.md) |
| Attachments, annotated screenshots, `createReport` | Done | [attachments](doc/attachments.md) |
| Feedback package `bugsee_flutter_feedback` | Done | [its README](packages/bugsee_flutter_feedback/README.md) |
| Device verification harness (emulator and simulator) | Done, not in CI | [verification](doc/verification.md) |
| Documentation pass, migration guide | Done (this pass) | [doc/README.md](doc/README.md) |
| **Not exposed on purpose** | APM transactions and spans, the appearance system, `relaunch`, secure rectangles and activities (replaced by `BugseeSecureView`), `deleteCollectedDataOnDevice`, native views | [api-surface](doc/api-surface.md) |
| **Not verified** | any physical device; iOS recovered crash reports and exception bundles (simulator limits); a valid token and the production backend | [verification](doc/verification.md) |

## Decisions taken

| # | Decision | Reason |
|---|---|---|
| D1 | **Native pins:** Android 7.4.2 (Maven Central), iOS 7.0.0-beta7 via SwiftPM `github.com/bugsee/spm`; every pin in `native-versions.json` with provenance | one source, compared by tests |
| D2 | **iOS is SwiftPM only**, no podspec | Bugsee publishes no CocoaPods pod |
| D3 | **Compatibility with the 9.x Dart API: deferred** to the owner (see below). The facade is isolated in `lib/src/bugsee.dart` / `bugsee_runtime.dart` so a layer could sit beside it | |
| D4 | **The feedback chat is a separate package**, mirroring the native split and React Native | apps that never show it do not carry SwiftUI / Compose |
| D5 | **Flutter floor 3.41.0 / Dart 3.11.0.** The plugin is SwiftPM-only, so `flutter pub get` fails on Linux and Windows with "only Swift Package Manager compatible" before 3.41.0. Measured on CI (Linux): 3.27.0/3.27.4, 3.29.0/3.29.3, 3.32.0/3.32.8, 3.35.0/3.35.7, 3.38.0/3.38.9/3.38.10 fail; 3.41.0, 3.41.9, 3.44.0, 3.44.9, 3.47.7 pass (no stable 3.39 or 3.40). Competitor floors (pub.dev, 2026-10-20): Sentry >=3.44, Firebase and Datadog >=3.27, Bugsnag, Shake and Embrace >=3.10, Instabug >=1.17. macOS developers on older Flutter could enable SwiftPM by hand; unsupported | the floor is a consequence of D2, not a choice |
| D6 | **A clean break from 9.x**: a new facade, typed `BugseeOptions`, `LaunchResult`; migration guide instead of a shim ([doc/migration-from-9x.md](doc/migration-from-9x.md)) | the 9.x API wraps 6.x SDK concepts (pause/resume, appearance, flat option keys) |
| D7 | **Pigeon** for the bridge (typed host API, Dart/Java/Swift committed, version pinned); **no Pigeon enum**: enums cross by SDK value or name | Pigeon sends ordinals; workbook 7.4 |
| D8 | **The app applies the Bugsee Gradle plugin** (4.0.8, mandatory, not autolinkable), with the ordering workaround until upstream fixes #33 | a Flutter plugin cannot apply a plugin to the app |
| D9 | **Dart errors are filed as error reports by default** (`reportAsCrash: false`; `true` is an opt-in) | Dart errors never end the app; crash reports count against crash-free sessions and replace iOS's single stored crash report; RN files only fatal errors as crashes |
| D10 | **Capture of what only Dart sees is opt-in and explicit** (`installNetworkCapture`, `installLogCapture`, `installErrorHandlers`), filters run in Dart first and fail closed | privacy; nothing changes for an app that does not call them |
| D11 | **One pub workspace, two packages published separately** (core first, then feedback), one committed `pubspec.lock` at the root with `--enforce-lockfile` in CI, a hosted (not path) constraint between them, lock-step versions | lets the feedback package depend on the core without a path dependency or overrides |
| D12 | **A native wrapper replaced on identity refinement; process-wide stores outside it** (secure rectangles, lifecycle hub, view-hierarchy snapshot, network channel) | workbook 5.4.2 |

## Open decisions for the owner

1. **A 9.x compatibility layer** (D3): offer a `bugsee.dart`-style shim over the 10.x facade, or none. The migration guide is written for
   "none".
2. **Whether to publish**, and when. The iOS pin is a beta (`7.0.0-beta7`): publish a stable `10.0.0` only against a stable iOS SDK,
   or ship `10.0.0-dev.N` / `-beta` first.
3. **pub.dev name and ownership.** `bugsee_flutter` exists on pub.dev (latest `9.0.4`, publisher `bugsee.com`), so 10.x continues that
   package. `bugsee_flutter_feedback` does not exist yet (checked 2026-10-22) and must be created under the same publisher.
4. **Versioning of the first release**: `10.0.0` against `10.0.0-dev.1`. The versions in `pubspec.yaml` (both packages), `wrapper_identity.dart`,
   the iOS `BGSFlutterWrapper.m` and `feedback_version.dart` must move together (a drift guard checks it).
5. **The default branch.** `main` still holds 9.x work; `nextgen` is the rewrite. `native-pins.yml` and Dependabot only run from the
   default branch (see `.github/CI.md`, "Default branch caveat"). Decide when `nextgen` becomes `main`, and what happens to the `release` branch
   (the 9.x line). Open PR #1 targets `release`.
6. **Required checks and CODEOWNERS** (`.github/CI.md`): branch protection with only `ci-ok`, and an owner team.
7. **Real-device verification** before a stable release (below).

## Known gaps and filed issues

State checked with `gh issue view` on 2026-10-22.

| Issue | State | What |
|---|---|---|
| [bugsee-android-gradle-plugin#33](https://github.com/bugsee/bugsee-android-gradle-plugin/issues/33) | open | `injectBugsee<Variant>BuildId` fails Gradle task validation in Flutter apps; the README carries the workaround |
| [bugsee-android#316](https://github.com/bugsee/bugsee-android/issues/316) | open | the report screenshot is entirely black in a `SurfaceView` (Flutter's default render mode); texture mode works |
| [bugsee-android#309](https://github.com/bugsee/bugsee-android/issues/309) | open | `IssueReport.addAttachment` does not re-check the stage after `importFile`; the wrapper undoes a late add itself |
| [bugsee-cocoa#291](https://github.com/bugsee/bugsee-cocoa/issues/291) | open | `BugseeFeedback.setListener` runs clear and set in unordered `Task`s; the wrapper never sets nil |
| [bugsee-cocoa#265](https://github.com/bugsee/bugsee-cocoa/issues/265) / [bugsee-android#299](https://github.com/bugsee/bugsee-android/issues/299) | iOS open; Android closed, on `main` (`aa9ea4c18`), in no tag, not in 7.4.2 | a timestamp argument for the wrapper channel's `log`. **Pin condition:** when `native-versions.json` moves to releases that have it, pass the capture time (`BugseeLogEvent.time`) so a delayed line keeps its time |
| [specs#61](https://github.com/bugsee/specs/issues/61) | open | workbook 7.1: the Android recovered-report row disagrees with 7.4.2 (measured: not main, edits land) |
| [specs#63](https://github.com/bugsee/specs/issues/63) | open | the wrapper-channel README says "not implemented"; both SDKs ship it |
| [specs#64](https://github.com/bugsee/specs/issues/64) | open | `vh` spec and workbook 6.7 still call the Android wait unfixed; PR #120 is in 7.4.2 |
| [specs#65](https://github.com/bugsee/specs/issues/65) | open | workbook 1.4.2: the four-library logcat grep cannot reach 4 for APK-mapped libraries |

Other gaps, none with an issue:

* **No physical device has been used.** Everything was verified on an Android emulator (API 28 to 33) and iOS simulators (26.5 and 27.0).
* **The iOS simulator slice of the SDK has no crash reporter and files no logged exceptions**: recovered iOS crash reports, iOS exception
  bundles, crash across an update, and release or profile runs need a physical iPhone. The workbook's iOS recovery claims (off-main, capped,
  a late completion re-persists) were not measured.
* The Gradle plugin 4.0.6 failure arm was not run; `optimizeExtensionsLoading=false` and the feedback safety-net path were not run.
* A real token and the production backend: the harness uses a loopback stand-in; server-side symbolication was run offline with the
  worker's own tool.
* Secure views do not cover the first frame of a newly appearing region (documented on the widget); iOS verified in portrait only.
* The Android logcat echo of `print` is not governed by the Dart log filter (needs a native filter; documented).
* `tvOS`, `visionOS`, the Android leak module, `x86_64` and `armeabi-v7a` ABIs, a second display, rotation and split screen were not covered.
* Lifecycle delivery limit: guarantees end at the hop into the channel sink. A message sent while the Dart side has no handler is held only by
  Flutter's channel buffer, which by default keeps ONE message per channel; the hub replays the latest status to each new receiver, flushes
  report events still in its own buffer and, when the final receiver detaches, puts its in-flight events back in front of it. Consumers
  must not rely on delivery surviving an isolate restart.

## Release checklist

Nothing in this repository publishes, tags or deploys by itself; a maintainer does all of this by hand.

1. **Decide** the open questions above (publish or not, name and publisher, the first version, the default branch).
2. **Pins final.** If a native pin moves, edit `native-versions.json`, then run `dart scripts/sync_option_manifests.dart`, the two
   source-reading scripts (`scripts/verify_option_manifests.dart`, `scripts/extract_report_enums.dart` / `extract_data_requests.dart` with
   the private SDK checkouts) and `dart scripts/generate_options.dart`; commit the diff (see `.github/CI.md`, "Option registry"). Re-run the device harness.
3. **Version.** Set the same version in `pubspec.yaml`, `packages/bugsee_flutter_feedback/pubspec.yaml` (and its `bugsee_flutter` lower bound),
   `lib/src/wrapper_identity.dart`, `ios/bugsee_flutter/Sources/bugsee_flutter_wrapper/BGSFlutterWrapper.m`, and the feedback package's
   `feedback_version.dart`; add the `## <version>` entry at the top of both `CHANGELOG.md` files (the tests require it to be the pubspec version).
4. **Verify on real hardware** at least one Android and one iOS device (the harness: `doc/verification.md`; iOS recovery and exception bundles
   need a device), then update `doc/verification.md`.
5. **CI green** on the release commit: `format`, codegen checks, `analyze + test` on the floor and stable legs, `build apk`, `pub publish dry-run`, `ci-ok`.
6. **Dry runs, clean tree, Flutter 3.41.0** (the floor):
   ```sh
   flutter pub get --enforce-lockfile
   flutter pub publish --dry-run              # the core: 0 warnings
   scripts/publish_feedback.sh                # the feedback package: a dry run by default, then the archive check
   flutter pub publish --to-archive=/tmp/core.tar.gz && scripts/check_pub_archive.sh /tmp/core.tar.gz
   ```
7. **Publish in order:** the core first (`flutter pub publish` from the repository root), wait until it is live on pub.dev, then the feedback package
   (`scripts/publish_feedback.sh --publish`, which refuses a dirty tree and publishes from a copy of the tracked files).
8. **Tag** the release commit (`v<version>`, the form the 9.x tags use) and write the GitHub release notes from the CHANGELOG.
9. **After:** check the pub.dev pages (README rendering, scores, the Platforms and SDK tabs), install from pub.dev into a clean app on both platforms,
   and make `main` hold the release (see open decision 5).

## Phase record

All phases are merged into `nextgen`. Per-phase detail lives in the docs listed in Status; this is only the map.

| Phase | PR | Scope |
|---|---|---|
| 1 Foundations (workbook Part 0 and 1) | #3 | `native-versions.json`, drift guards, Android NDK artefact and Gradle plugin, iOS 15 and the privacy manifest |
| CI/CD | #4 | format gate, publish dry-run, `ci-ok`, weekly pin check, Dependabot |
| 2 Registration before launch (Part 2 and 3) | #5 | Android provider at `initOrder` 200, iOS `+load` registrar, identity |
| 3a Bridge and lifecycle (Part 4) | #6 | Pigeon, lifecycle hub, identity refinement |
| 3b Secure rectangles (Part 5) | #7 | pull model, units per platform, `BugseeSecureView` internals |
| 3c Report handlers (Part 7) | #8 | native pipeline, `ReportProxy`, `requestData` |
| 4a Options, launch, status | #9 | `BugseeOptions`, `launch`, `stop`, `status` |
| 4b The rest of the facade | #10 | attributes, user, events, breadcrumbs, notify, blackout, reports, lifecycle stream, secure view |
| 5a Dart exceptions | #11 | `logException`, installed handlers, obfuscated stacks |
| 5b Network capture | #12 | `HttpOverrides`, wrapper channel |
| 5c View hierarchy | #15 | `vh` data request, native snapshot cache |
| 5d Log capture | #16 | `print`, `debugPrint`, `forwardLog` |
| 6 Reports | #13 | attachments, annotated screenshots, `createReport` |
| 7 Device verification (Part 9) | #17 | the harness and `doc/verification.md` |
| 8a Feedback package | #14 | `bugsee_flutter_feedback` |
| 8b Documentation | this pass | README, doc index, architecture, conformance, migration, plan |

Facts worth keeping from the work (each is in the doc named):

* **SDK facts read from source, not the workbook** (the SDKs are authoritative): secure rectangles take Android physical pixels in
  `View.getLocationOnScreen` space and iOS points; both SDKs ship the wrapper channel at the pins and both take the hidden `$$ENDPOINT` and strip
  `/v2`; `getLaunchOptions` is merged on both while `getHostLaunchOptions` still differs; bugsee-android PR #120 is in 7.4.2 but the report waits only for
  off-main snapshots; the SDK's report-handler budget is 30 s per handler live (ours 20 s) and 3 s on iOS recovery (ours 2 s)
  (`doc/api-surface.md`, `doc/view-hierarchy.md`, `.claude/CLAUDE.md`).
* **Measured on a device (Phase 7):** a native-crash report recovered after a normal Android session is dispatched on `BugseeReportHandlerThread` with the live
  window, so the Dart handler runs and its edits land (the workbook table says main; the early-crash recovery path is the one that completes at once).
* **Option manifests cross-check** (`scripts/verify_option_manifests.dart`, 2026-10-21, Android `v7.4.2`, iOS `origin/nextgen@0581aa02c`): keys, hidden
  keys and enum values in the vendored manifests equal what the SDK source declares. Inventory: Android 87 options (84 public, 3 hidden), iOS 70 (69
  public, 1 hidden), 49 shared; the leak module's four options and one deprecated option have no typed field; defaults differ on exactly two shared keys
  (`capture.video.adaptive`, `config.max-data-size`).
* **Pre-existing, worked around:** `flutter build ios --simulator` fails on Flutter 3.41 / Xcode 27.1 (an order-sensitive architecture check); the harness
  builds with `--config-only` plus `xcodebuild` for one simulator.

## Test and mutation record

Counts from the last full run of the tree (see `doc/verification.md`, "Environment"): `flutter test` about 1350 tests (1355 in the run for this pass), the feedback package 22, Android JUnit
396 (core) + 16 (feedback), iOS XCTest 335 (core) + 23 (feedback).

Every test added in the feature phases was mutation-checked: the behaviour broken in a copy, the test seen failing, the code restored. Survivors were
either real gaps (and the test was strengthened) or equivalent mutants, recorded in the docs.

| Area | Mutants (all killed in the end, except the recorded equivalent ones) |
|---|---|
| Facade (4b) | 18 + 2 Dart, 19 Android, 17 iOS, 7 drift, 20 second batch |
| Exceptions (5a) | 63 Dart/drift, 8 Java, 7 Objective-C; review round 24 Dart, 8 dispatcher, 4 drift |
| Network (5b) | 110 Dart, 24 Android, 21 iOS |
| View hierarchy (5c) | about 80 Dart, 23 Java, 23 Objective-C (five Dart equivalents listed in `doc/view-hierarchy.md`) |
| Logs (5d) | 66 Dart, 14 Android, 13 iOS |
