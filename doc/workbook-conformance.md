# Conformance with the wrapper workbook

The authoritative guide for a Bugsee wrapper is the wrapper workbook (`sdk/wrapper-workbook` in the `bugsee/specs` repository). This page
maps each of its steps, traps (Appendix A) and minimum-viable-wrapper items (Appendix B) to where this plugin implements it, how it is
guarded, and how it was verified. It is derived from the code, the tests and [verification.md](verification.md); where something was
only verified on an emulator or simulator, or not at all, it says so.

How to read the columns:

* **Where**: the implementation (Java and Objective-C paths are under `android/src/main/java/com/bugsee/flutter/` and
  `ios/bugsee_flutter/Sources/bugsee_flutter_wrapper/`).
* **Guard**: tests and drift guards that fail when it breaks (`test/` is Dart, `JUnit` is `android/src/test/java/com/bugsee/flutter/`,
  `XCTest` is `ios/wrapper_tests/Tests/BugseeFlutterWrapperTests/`). CI runs the Dart tests, the JUnit tests and the XCTests.
* **Device**: the scenario of the device harness in [verification.md](verification.md) (1 registration, 2 native crash, 3 report
  handlers, 4 exceptions, 5 release and profile, 6 crash across an update, 7 secure rectangles at other densities, 8 hot restart,
  9 screenshot by render mode). The harness is **not** run in CI, and every scenario ran on an Android emulator (API 30) or an iOS
  simulator (27.0): **no physical device**.

## Parts

| Step | Where | Guard | Device | Gap |
|---|---|---|---|---|
| **0.2** read the SDK source, not the doc comment | each doc page lists the SDK source it was read from; SDK facts are extracted into `test/fixtures/{report_enums,data_requests}.json` (`scripts/extract_*.dart`) | the parity tests compare the extracted facts with Dart, Java and Objective-C | | The extraction scripts need the private SDK checkouts: local, not CI |
| **0.3** floors (Android SDK 7.2+, iOS beta2+, Gradle plugin 4.0.7+, minSdk 21, iOS 15) | `native-versions.json`; `android/build.gradle`; `ios/bugsee_flutter/Package.swift` | `test/native_versions_test.dart` | 1 | Host-framework floor chosen from measurement (PLAN.md, D5), not download data (0.3.1: see PLAN.md) |
| **1.1** one pin file, a drift guard, seen failing | `native-versions.json` | `test/native_versions_test.dart` (Gradle, `Package.swift`, `Package.resolved`, example, CI matrix, Pigeon pin, JDK, workflows), `test/feedback_package_drift_test.dart`, `scripts/check_native_pins.dart` (weekly `native-pins.yml`) | 1 (banner version **and build**, SwiftPM tag and revision) | |
| **1.2** declare the NDK artefact | `android/build.gradle` (`bugsee-android` and `bugsee-android-ndk`, `api`) | `test/native_versions_test.dart` ("declares the NDK artefact next to the core", 1.2.2) | 1, 2 (`./gradlew :app:dependencies`; a real `SIGSEGV` produces a report) | |
| 1.2.3 four `libbugsee*.so` | | | 1, 2: **measured** from `/proc/PID/maps` and the crashpad handler's maps, not by the workbook's logcat grep (which reads 1 to 2 on a correct build; specs#65) | Android emulator only |
| **1.3** optional modules | only `bugsee-android` and `-ndk` are bundled; the feedback chat is the separate `packages/bugsee_flutter_feedback` | `test/feedback_package_drift_test.dart` (the core never mentions feedback) | feedback: Android registration and the chat opened (see `packages/bugsee_flutter_feedback/doc/feedback.md`) | The leak module is not bundled (no typed option fields) |
| **1.4** Gradle plugin 4.0.7 or later | the app applies `com.bugsee.android.gradle` (pin 4.0.8, not autolinkable): README, `example/android` | `test/native_versions_test.dart` ("example applies the Gradle plugin at the pinned version") | 1 (the plugin in use is the pinned one alone; provider kept at `initOrder` 200) | The broken 4.0.6 arm was **not run**; only the fixed arm. The ordering bug [bugsee-android-gradle-plugin#33](https://github.com/bugsee/bugsee-android-gradle-plugin/issues/33) needs an app-side workaround (README) |
| **2.1** register before launch, not from the managed runtime | `FlutterWrapperInitProvider.java`; iOS `BGSFlutterWrapperRegistrar` `+load` (`BGSFlutterWrapper.m`) | `test/wrapper_registration_test.dart`; JUnit `FlutterWrapperInitProviderTest`; XCTest `BGSFlutterWrapperTests` | 1 (the wrapper's log line precedes the SDK banner on both platforms), **2** (the recovered report carries the wrapper: the run that exposes a late registration) | The recovery run is Android only (the iOS simulator has no crash reporter) |
| **2.2** Android `ContentProvider`, `initOrder` 200, base class, `onExtensionCreate`; the name must not match `Bugsee*InitProvider` | `android/src/main/AndroidManifest.xml`, `FlutterWrapperInitProvider` | `test/wrapper_registration_test.dart` (attributes, the regex against the class name, no other provider; 2.2.4, 2.2.5); the feedback package asserts it adds no provider | 1 (merged manifest has the provider at 200 ahead of 100) | |
| **2.3** iOS: register before `launch` | `+load` registrar, before `main` and before the engine exists | `test/wrapper_registration_test.dart` ("registers at image load, not only from the engine"); XCTest | 1 | |
| **2.4** identity natively at construction, refined later; one spelling of the type | `wrapperType` in `lib/src/wrapper_identity.dart`, the Java and Objective-C copies; Dart refines before the SDK launches (`lib/src/bridge/runtime_facts.dart`) | `test/wrapper_identity_test.dart` (type and version in every copy, no other spelling, Gradle reads `pubspec.yaml`); JUnit `FlutterWrapperTest` | 1 (the report's `environment.sdk.wrapper`) | |
| **3.1** identity methods | `FlutterWrapper.java`, `BGSFlutterWrapper.m` | JUnit `FlutterWrapperTest`; XCTest `BGSFlutterWrapperTests` | 1, 2, 6 (identity on live and recovered reports) | |
| **3.2** `context` is `String` to `String`, non-strings dropped | same | JUnit `contextDropsNonStringsRatherThanStringifyingThem`; XCTest | | |
| **3.3** `"unknown"`, never empty | same | JUnit `missingFactsAreUnknownNotEmpty`, `refinedIdentityWithMissingFactsIsUnknown`; XCTest | | |
| **3.4** identity in launch options too (`wrapper_info`, `$$WRAPPER`) | **Not done, by design**: the wrapper object registered before launch is the identity; the plugin never sends `$$WRAPPER` / `$$DEBUG` (they are internal and refused as options) | `test/launch_options_test.dart` (internal keys rejected) | 2 (recovered report has the identity without it) | Deliberate gap: the workbook marks the consumer wiring as in flight |
| **4.1** forward lifecycle events by name | `LifecycleHub.java`, `BGSFlutterLifecycleHub.m`, `lib/src/lifecycle_event.dart` | `test/lifecycle_drift_test.dart` (names and constants equal across Dart, Java, Objective-C; both wrappers forward to the hub); JUnit `LifecycleHubTest`; XCTest `BGSFlutterLifecycleHubTests` | 1, 8 | |
| **4.2** strip the prefix once, natively | hub | `test/lifecycle_drift_test.dart` ("the prefix is the SDKs and is stripped natively, once") | | |
| **4.3** unknown names forwarded unchanged | `LifecycleEvent.name` keeps any string | `test/bridge_test.dart`; JUnit and XCTest hub tests | | |
| **4.4** events arrive off the main thread | the hub hops to the platform thread before touching Flutter | `test/lifecycle_drift_test.dart` ("delivery hops to the platform thread") | 8 | |
| **4.5** report-id events | the set is repeated in Dart, Java and Objective-C | `test/lifecycle_drift_test.dart` ("report-id events: Dart == Java == Objective-C") | 3, 8 (`BeforeReportAssembled`, ... reach Dart once each) | |
| **4.6** status from the channel only; never take the app's delegate or listener | status from `Launching`, `Launched`, `Stopping`, `Stopped` only | `test/lifecycle_drift_test.dart` ("the app's own delegate and listener are never taken over (4.6)", "status transition events"); `test/launch_drift_test.dart` | 1 | |
| **4.7** an event is not proof of a report | no code infers a report from an event; documented on `LifecycleEvent` | review rule (`.claude/CLAUDE.md`); the report path never passes the path or `isTerminating` to Dart (`test/report_handlers_drift_test.dart`) | 3 (handlers verified on the recovered report itself) | A rule, not a mechanical guard |
| **5.1** buffer `[version, count, l, t, r, b ...]`, exclusive `r`/`b`, outward rounding | `SecureRectangleStore.java`, `SecurePlacement.java`, `BGSFlutterSecureRectangleStore.m` | `test/secure_rects_drift_test.dart` (header, units, grace window, version never 0, ordering); JUnit `SecureRectangleStoreTest`; XCTest `BGSFlutterSecureRectangleStoreTests` | 7 | |
| **5.2** version contract: any change moves it, a no-op does not, per display | versions derived from what is served | same tests; mutation-checked (PLAN.md) | 7 (a rectangle follows the density without a republish) | |
| **5.3** units: Android physical pixels, iOS points; scale before rounding; per call; non-1 scale mocked | `ViewScale.java`, `SecurePlacement.java`; iOS `BGSFlutterSecurePlacementTracker.m`; the ratio is read at every pull | `test/secure_rects_drift_test.dart` ("units: ..."); JUnit `ViewScaleTest`; XCTest (two tests fail on a 1x screen rather than pass vacuously, 5.3.3) | 7: Android at 440, 320 and 560 dpi, debug and release; iOS at 3x | Not on a physical device; iOS portrait and 3x only; a run-time density change on iOS is not possible on a simulator; the transient between a density change and Dart's republish was not sampled |
| **5.4.1** immutable snapshots | the stores publish immutable values | JUnit and XCTest store tests | | |
| **5.4.2** store outside the wrapper | `SecureRectangleStore` / `BGSFlutterSecureRectangleStore` (process-wide) | `test/lifecycle_drift_test.dart` ("secure rectangles come from the process-wide store"); JUnit `replacingTheWrapperKeepsTheSecureRectangleSet`, `refiningTheIdentityReplacesTheWrapperAndKeepsTheSet` | 7 | |
| **6.1** always answer, `null` for unknown, never throw | `FlutterWrapper.requestData` | JUnit `requestDataAnswersNullWhenThereIsNothingAndNeverThrows`; XCTest | 5 | |
| **6.2, 6.3** only `vh`; a `String`, privacy is ours | `lib/src/view_hierarchy/` (builder, publisher, controller), `ViewHierarchyStore.java`, `BGSFlutterViewHierarchyStore.m` | `test/view_hierarchy_privacy_test.dart`, `test/view_hierarchy_drift_test.dart` (allow-list of reads, no text channel); JUnit `ViewHierarchyStoreTest`; XCTest `BGSFlutterViewHierarchyStoreTests` | 5 (131 to 135 nodes, release names obfuscated); `example/integration_test/view_hierarchy_test.dart` | iOS report bundle not verifiable on a simulator (the test reads the capture buffer) |
| **6.4, 6.5** 500 ms budget from return; main thread | answered synchronously from a native cache; the 500 ms and the 50 ms iOS back-off are extracted into `test/fixtures/data_requests.json` | `test/view_hierarchy_drift_test.dart`; JUnit `vhIsAnsweredFromTheCacheSynchronouslyOnTheCallingThread` | 5 | |
| **6.6** screen coordinates in the platform's unit | the stores convert per answer with the secure rectangles' one mapper | `test/view_hierarchy_drift_test.dart` (one place converts units) | `view_hierarchy_test.dart` (Android physical pixels, iOS points) | A view off the screen origin is covered by JUnit and XCTest, not a device |
| **6.7** asynchronous replies on Android | **Sidestepped**: never async | `test/view_hierarchy_drift_test.dart` | 5 | The workbook still calls the Android wait unfixed; it is in 7.4.2 for off-main snapshots only (specs#64) |
| **7.1.1, 7.1.2** terminating: no round trip; always complete | `ReportHandlerPipeline.java`, `BGSFlutterReportHandlerPipeline.m`: complete exactly once on every path, never wait | `test/report_handlers_drift_test.dart` (no blocking primitive on the report path, `isTerminating` decided before touching Dart); JUnit `ReportHandlerPipelineTest`; XCTest `BGSFlutterReportHandlerPipelineTests` | 3 | |
| **7.1.3** `false` is not "take your time"; path told apart by thread, for the budget only | the budget is the SDK's less a margin; the path is never passed to Dart | `test/report_handlers_drift_test.dart` (SDK numbers extracted into `test/fixtures/report_enums.json`, compared with the wrapper) | 3: **Android** recovered report measured (not main; edits land) | The workbook's table disagrees with 7.4.2 and the device (specs#61). **iOS recovery** thread, cap and re-persist: **not measured** (simulator has no crash reporter) |
| **7.2** `onBefore` at most once, `onAfter` at least once and idempotent; no recovery inference | stable `deliveryId`, 128 remembered per isolate (`lib/src/bridge/bridge.dart`) | `test/report_handlers_test.dart`, `test/report_handlers_drift_test.dart` | 3, 8 (one `onBefore` and one `onAfter` after a hot restart) | The id is recorded before the handler runs: a handler that threw is not retried in-process |
| **7.3** proxy, path-first attachments, live until completion, the deadline is the SDK's | `lib/src/report/`, `ReportOps.java`, `ReportFileFlow.java`, `BGSFlutterReportFiles.m` | `test/report_attachments_drift_test.dart`, `test/created_report_test.dart`; JUnit `ReportFileFlowTest`, `ReportOpsFilesTest`; XCTest `BGSFlutterReportFileFlowTests`, `BGSFlutterReportFilesTests` | 3 (file lands in the recovered bundle), `attachments_test.dart`; 5 | Android 7.4.2 does not re-check after an import (bugsee-android#309): the wrapper undoes a late add, a JUnit model proves it; iOS device not run |
| **7.4** enums by value; extracted from source; compared across both platforms | the bridge declares no enum; `lib/src/report/report_enums.dart` | `test/report_enum_parity_test.dart` (fixture extracted from both SDKs by `scripts/extract_report_enums.dart`); JUnit `ReportEnumParityTest`; XCTest against the real SDK enums | `launch_test.dart` (the SDK reports enums back as integers) | |
| **8.1** `com.bugsee.option.*` from the registry | `lib/src/options/option_registry.g.dart`, `bugsee_options.g.dart`, generated from the SDKs' published manifests | `test/option_manifests_test.dart`, `test/options_registry_test.dart`; `dart scripts/generate_options.dart --check` in CI; weekly `sync_option_manifests.dart --check` | `launch_test.dart` | |
| **8.2** endpoint asymmetry | **Stale at the pins**: both SDKs take the hidden `$$ENDPOINT` and strip `/v2`; one place normalises (`lib/src/options/endpoint.dart`) | `test/endpoint_test.dart` | Observed by hand during development (the SDKs reported the endpoint back); **not asserted by `launch_test.dart`**, so repeatable evidence is the manifests and SDK source | |
| **8.3** `getLaunchOptions` semantics | `getLaunchOptions` is merged on both at the pins; `getHostLaunchOptions` still differs and is documented | `test/launch_drift_test.dart`, JUnit `LaunchOpsTest`, XCTest `BGSFlutterLaunchOpsTests` | `launch_test.dart` | |
| **8.4** hidden options not in uploaded `sdk.options` | the plugin never sends `$$WRAPPER` or `$$DEBUG`; `$$ENDPOINT` only through `BugseeOptions.endpoint` | `test/launch_options_test.dart` | | The SDKs' stripping of `$$ENDPOINT` from uploads is by their manifests and source, not observed on a device |
| **9.1.1** assert the build (banner SHA) | `scripts/device/` (`Run.guard`), `native-versions.json` `*.sdkBuild`, `ios.spmRevision` | `test/device_harness_test.dart` (parsers, and text that must fail each check) | all | |
| **9.1.2 to 9.1.5** launched, preconditions, the event happened, defaults | in `AndroidSession` / the iOS equivalents: not skippable | `test/device_harness_test.dart` | all | Not run in CI |
| **9.2** absence needs a positive control | every "nothing arrived" is paired with one | `test/device_harness_test.dart` | 2, 4, 5 | |
| **9.3.1 to 9.3.5** recipes | `kill -11` (debug via `run-as`, release as root); airplane mode; bundle read; update across N and N+1; `retrace` with the exact build's `mapping.txt` | harness | 2, 6, 4 | iOS: none of these is possible on a simulator |
| **9.4** report findings: measured vs inferred | `doc/verification.md` separates them (for example the "BugseeReportHandlerThread" deduction in scenario 3) | | | Issue text for the SDK gaps is in the PR descriptions and PLAN.md |

## Appendix A: traps

| Trap | Implemented as | Guard | Device |
|---|---|---|---|
| NDK artefact not declared (1.2) | `bugsee-android-ndk` is an `api` dependency of the plugin | `test/native_versions_test.dart` | 1, 2 |
| Gradle plugin 4.0.6 (1.4) | the app applies 4.0.8 (README); the feedback package registers its module itself as a safety net | `test/native_versions_test.dart`; `test/feedback_package_drift_test.dart` | 1 (fixed arm only; the broken arm was not run) |
| Provider named `Bugsee*InitProvider` (2.2) | `FlutterWrapperInitProvider` | `test/wrapper_registration_test.dart` (the regex against the class name) | 1 |
| Wrapper registered from the managed runtime (2.1) | registered natively at process start; Dart only refines | `test/wrapper_registration_test.dart`; `test/wrapper_identity_test.dart` | 2 (recovered report has the wrapper), 6 |
| Secure rectangles in the wrong unit (5.3) | per-platform conversion at every pull | `test/secure_rects_drift_test.dart`; JUnit `ViewScaleTest`; XCTest | 7 (emulator densities; iOS 3x) |
| Lifecycle event read as proof of a report (4.7) | no inference anywhere | a documented rule; handlers verified on a report that really existed | 3 |
| Enum mapped by ordinal or name (7.4) | by SDK internal value; no Pigeon enum | `test/report_enum_parity_test.dart`, JUnit and XCTest parity | `launch_test.dart` |
| Async `vh` reply on Android (6.7) | the reply is synchronous, from a native cache | `test/view_hierarchy_drift_test.dart`; JUnit | 5 |
| Version range beats local `-SNAPSHOT` (9.1) | exact pins; no SNAPSHOT | `test/native_versions_test.dart` ("no SNAPSHOT pins"); the banner SHA is asserted on every harness launch | all |

## Appendix B: minimum viable wrapper

| # | Item | State |
|---|---|---|
| 1 | Versions in one file, with a drift guard | Done (`native-versions.json`, `test/native_versions_test.dart`) |
| 2 | NDK artefact declared and verified on a device | Done; verified on an Android emulator (scenarios 1 and 2) |
| 3 | Gradle plugin 4.0.7 or later | Done (4.0.8); the 4.0.6 failure arm not run |
| 4 | Registered before launch, provider correctly named | Done; guarded; verified on a recovered Android report; iOS registration verified, iOS recovery not possible on a simulator |
| 5 | Identity: type, version, context | Done |
| 6 | Lifecycle events forwarded, unknown names included | Done |
| 7 | `requestData` answers; `null` is valid | Done (and `vh` is real) |
| 8 | Secure rectangles with the version contract and the right unit | Done; emulator and simulator only |
| 9 | Report handlers that always complete and never block a dying process | Done; the iOS recovery path is not measured |

Beyond the minimum, the workbook's "can follow" items 6.7, 7.3 and Part 8 are implemented as described above.

## Open gaps in one list

1. No physical device has been used (Android or iOS).
2. iOS: recovered-crash reports, logged-exception bundles, crash across an update, release and profile runs and a run-time density
   change cannot be done on a simulator (the SDK's simulator slice has no crash reporter and files no logged exceptions).
3. The Gradle plugin 4.0.6 failure arm was not run.
4. Android release builds were inspected only on the `google_apis` emulator image (root); `x86_64`, `armeabi-v7a`, a second display,
   rotation and split screen were not run.
5. Spec gaps filed against `bugsee/specs`: #61 (7.1 Android recovered-report row), #63 (wrapper channel "not implemented"), #64
   (`vh` async wait), #65 (the four-library logcat grep).
6. SDK defects filed: bugsee-android#309 (attachment re-check), bugsee-android#316 (black SurfaceView screenshot), bugsee-cocoa#291
   (feedback listener ordering); the Gradle plugin ordering bug (#33).
