# Bugsee Flutter SDK 7.x — implementation plan

Branch `nextgen`, rewritten from scratch. The previous working tree is preserved on
local branch `backup/nextgen-wip-2026-10-20` (a reference only, not a base).

Sources: `specs/sdk/wrapper-workbook` (authoritative order of work), `wrapper-data-requests`,
`wrapper-channel`, `report-contract`, `options`, `report-identity`; reference implementation
`cross/react-native` (design: `docs/superpowers/specs/2026-09-15-bugsee-react-native-7x-design.md`).

## 0. Decisions needed before Phase 1

| # | Question | Recommendation |
|---|---|---|
| D1 | Native pins | **Decided:** Android 7.4.2 (Maven Central); iOS 7.0.0-beta7 via SPM `github.com/bugsee/spm`. |
| D2 | iOS distribution | **Decided:** SPM only (Flutter SPM plugin support). |
| D3 | Compatibility with 9.x | **Deferred.** Phase 1-3 do not depend on it; decide before Phase 4 (public API). |
| D4 | Feedback module | **Decided:** separate package. |
| D5 | Flutter floor | **Decided: Flutter >=3.41.0 / Dart ^3.11.0.** The plugin is SwiftPM-only, so `flutter pub get` fails on Linux/Windows with "only Swift Package Manager compatible" before 3.41.0. Measured on CI (Linux): 3.27.0/3.27.4, 3.29.0/3.29.3, 3.32.0/3.32.8, 3.35.0/3.35.7, 3.38.0/3.38.9/3.38.10 fail; 3.41.0, 3.41.9, 3.44.0, 3.44.9, 3.47.7 pass (no stable 3.39/3.40). Competitor floors (pub.dev, 2026-10-20): Sentry >=3.44, Firebase/Datadog >=3.27, Bugsnag/Shake/Embrace >=3.10, Instabug >=1.17. macOS developers on older Flutter could enable SwiftPM with `flutter config --enable-swift-package-manager`, but that is unsupported. |

## 1. Phase 1 — Foundations (workbook Part 0–1)

1. Read `BugseeWrapper.java`, `BGSContracts.h` and the callers (workbook 0.2); note spec gaps.
2. `native-versions.json` (single source, with provenance): Android core + NDK + feedback,
   Gradle plugin, iOS ref, options-manifest URLs.
3. Drift guard test: Dart pubspec/constants, `android/build.gradle`, SPM `Package.swift`,
   example app, CI matrix all asserted against the JSON. Mutation-check it (1.1.3).
4. Android: declare `bugsee-android` **and `bugsee-android-ndk`** (test asserts it, 1.2.2);
   Gradle plugin **≥ 4.0.7** (1.4); `minSdk 21`; AGP/Gradle compatible with Flutter's template.
5. iOS: deployment target 15.0; privacy manifest.
6. Repo layout: single plugin package + `example/`; CI (analyze, test, drift, option-manifest check).

## 2. Phase 2 — Wrapper registration before launch (Part 2–3) — critical

- **Android:** `ContentProvider` at `initOrder="200"` extending `BugseeExtensionInitProviderBase`;
  calls `Bugsee.setWrapper()` in `onExtensionCreate()`. **Name must not match
  `^.*\.Bugsee[A-Za-z0-9_]+InitProvider$`** (e.g. `FlutterWrapperRegistrar`); regex in a test.
- **iOS:** `+setWrapper:` from the plugin's native construction, before `launchWithToken:`.
- Register type (`flutter`) + version natively; refine with Flutter/Dart/engine/build mode once
  the engine is up. Wrapper type string in one place per platform, with a test that native and
  Dart copies agree. Secure-rect set held **outside** the wrapper object (5.4.2).
- Identity: type/version/build/context (`String→String`, `"unknown"` for missing).
- Verify: relaunch-after-crash run (the only run that exposes a late registration).

## 3. Phase 3 — Minimum viable wrapper (Appendix B, Parts 4–5, 7.1)

- Lifecycle: forward by name, strip the `com.bugsee.lifecycle.` prefix once natively, pass
  unknown names through unchanged, handle off-main-thread delivery, status only from
  Launching/Launched/Stopping/Stopped, never treat an event as proof of a report (4.7).
- Lifecycle delivery limit (3a): guarantees end at the hop into the channel sink. A message sent while the Dart side has no handler is held only by Flutter's channel buffer, which by default keeps ONE message per channel (a restarted isolate may see that one after it sets a handler; any older ones are dropped, and the engine reports an error that native only logs). The hub replays the latest status to each new receiver, flushes report events still in its own buffer and and, when the final receiver detaches, puts its in-flight events back in front of it; only an event already SENT over the channel while Dart has no handler is not retried. Phase 4/6 consumers must not rely on delivery surviving a restart.
- `requestData`: always answer; unknown type → `null`; never throw.
- Secure rectangles (3b, done): pull model, `[version,count,l,t,r,b…]` int32 LE; outward rounding;
  version moves on any change and never on a no-op, per display; immutable snapshots.
  What the pinned SDKs take today (from source, not the workbook's in-flight note): **Android 7.4.2:
  physical pixels in the `View.getLocationOnScreen` space, display = `Display.getDisplayId()`;
  iOS 7.0.0-beta7: points in the screen's coordinate space, display 0 only.** Dart publishes Flutter
  logical pixels per view; native converts (Android: density of the Flutter view's `Resources`, read at every
  pull and matched against the ratio Dart measured at; iOS: ratio / UIScreen.scale = 1, never the screen scale), applies the view's on-screen scale, adds its on-screen position, then floors l/t and
  ceils r/b; a 0.12 s grace window serves each past set for 0.12 s after it stopped being current, together with
  the current one. Versions are derived from what is served (so a density
  or position change moves them with no write), per display, never 0; a display that never had a rectangle
  serves `[0, 0]` (unknown). Fail closed: an unplaceable view, a non-finite rectangle or a bad scale serves
  the whole display; a view known to be off-screen serves nothing. Dart (`lib/src/secure`, internal until
  Phase 4): `BugseeSecureRegion`/`RenderSecureRegion` + `SecureRegionRegistry`, measured every frame in a
  post-frame callback, published when the set changed (and again, with a capped backoff that never gives up, after a failed publish), ordered by `(epoch, sequence)`. Regions are
  reported UNCLIPPED through every ancestor transform (bounding box, including paint outside their box); a region is dropped only on positive evidence
  (an ancestor that does not paint it, an IndexedStack showing another child, or the region and all its paint lying wholly outside a clipping viewport); neither a disabled TickerMode nor a detached layer counts as such evidence. An unmeasurable region covers the whole view.
  First-frame exposure of a newly appearing region remains.
  Known limits: see "Secure rectangle limits" in `.claude/CLAUDE.md`.
- Report handlers (3c, done): native pipeline (`ReportHandlerPipeline` / `BGSFlutterReportHandlerPipeline`) + a Dart
  `ReportProxy` (internal, `lib/src/report`; Phase 4 exposes it). The SDK's completion runs EXACTLY ONCE on every path; the
  pipeline NEVER WAITS (the SDK already waits on its own timer; a native wait for Dart's reply deadlocks when the handler runs
  on the platform thread, which iOS's live path does). `isTerminating` never reaches Dart and the report is not even read.
  No Dart handler registered, or Dart not attached: complete at once. The window is the SDK's budget LESS A MARGIN (a third, at most 10 s), from SDK source (numbers extracted into `test/fixtures/report_enums.json`): Android 7.4.2 waits `ReportHandlerCallbackTimeout` (30 s, option) per handler on thread `BugseeReportHandlerThread`, ours 20 s; its recovery/terminating paths run on other threads, wait 3 s for the handler to RETURN and never for the completion, so Android completes at once there. iOS (nextgen = beta7 headers): live = MAIN thread, 30 s per handler, ours 20 s; recovery = worker thread, 3 s cap, a late completion re-persists the report, ours 2 s. Honest limit: the SDK's per-handler timer starts when it QUEUES the handler, ours at handler entry, and the wait in between (another report's slow handler holding the shared Android dispatch thread, a busy iOS main thread) is NOT observable; the margin absorbs it, and a handler queued behind more than the margin can still overrun, with an edit accepted although the SDK has moved on. What is observable (the hop to the platform thread after entry) is deducted: Dart is told what is LEFT, and a window already over is completed, not offered. An accepted edit is guaranteed to have landed before the completion ran (per-handle lock across check-and-apply). A new isolate (hot restart) completes the previous one's outstanding deliveries. A Dart handler that overruns its budget is reported even if it makes no further edit. The path is told apart by thread
  (Android: name, iOS: main or not) for the time budget ONLY, never passed to Dart, never "this is a recovered crash" (7.2.3).
  The workbook's table says Android recovery runs on main and is waited for; 7.4.2 source says a spawned thread, not awaited
  (inline on the launching thread only when no thread can be started): source wins, spec gap to report.
  Dart: edits are operations keyed by a handle; a late edit throws `ReportClosedError` (a `StateError`) and native ignores it.
  `onAfter` is at-least-once: each delivery carries a stable `deliveryId` (`before|after:<reportId>`) and Dart skips a repeat
  within the isolate (128 remembered). Enums cross by value (the bridge has none; severity is the SDK integer; Dart
  `ReportSeverity.veryLow` = Android name, `low` = iOS alias, value 1). Attachments/screenshots: Phase 6 (TODO seam in `ReportProxy`).
- `requestData` (3c): the stub answers null/nil for every type incl. `vh`, also on the replaced wrapper; tested on both platforms.

## 4. Phase 4 — Public API and options (Part 8)

- Dart facade mirroring the converged 7.x API (launch, attributes, identity, events/traces,
  breadcrumbs, notify, APM, logging/network, status, blackout, exceptions). Clean break from 9.x;
  compatibility with the 9.x Flutter API stays deferred (D3): the facade is isolated in
  `lib/src/bugsee.dart` / `bugsee_runtime.dart` so a compat layer could sit beside it.
- Options: use `com.bugsee.option.*` from the generated registry, not literals; one place
  normalises the endpoint; hidden options not exposed; `getLaunchOptions` semantics per platform.
- Vendored option manifests + CI diff (strict on keys/types/enums).
- Bridge: Pigeon (typed) for method channels + typed event channels; enums by internal value,
  generated from SDK source, compared across **both** platforms (7.4).

### 4a — options, launch, stop, status (done)

The first public API: `Bugsee.launch(token, {options})`, `stop()`, `status`, `statusChanges`,
`getStatus()`, `isLaunched()`, `getLaunchOptions()`, `getHostLaunchOptions()`, `BugseeOptions` (100
typed fields), `waitUntilLaunched()`, `LaunchResult`, `LaunchFailure`, `BugseeException`/`BugseeLaunchException`,
`BugseeStatus`, the option enums and `ReportSeverity`. The report-handler registration API and the
secure-region widget were made public in 4b.

- **The SDKs publish manifests now** (the options spec still says "Proposed"): Android
  `download.bugsee.com/sdk/options/android/7.4.2.json` (generated 2026-10-19; also the golden file in the
  Android repo at v7.4.2) and iOS `.../ios/7.0.0-beta7.json` (2026-10-18), vendored verbatim. Source cross-check
  (`scripts/verify_option_manifests.dart`, 2026-10-21, Android `v7.4.2`, iOS `origin/nextgen@0581aa02c`): keys, hidden
  keys and enum values in the manifests equal what the source declares.
- **Inventory** (Android 87 options = 84 public + 3 hidden; iOS 70 = 69 public + 1 hidden): 49 shared (incl. the hidden
  `$$ENDPOINT`), 38 Android-only (incl. hidden `$$DEBUG`, `$$WRAPPER`), 21 iOS-only. Modules: Android `bugsee-android` 81,
  `bugsee-android-ndk` 2 (`detect.crash-ndk` default `true`, `crash-ndk.tombstone-logs`), `bugsee-android-leak` 4 (not bundled, no
  typed field); iOS `Bugsee` 70. Types: Android 61 boolean, 10 int, 8 enum, 4 float, 3 string, 1 map. Enums (by internal value):
  `LogLevel`, `FrameRate` (Android has `Raw=4`, iOS stops at `High=3`), `VideoQuality`, severity (value 1 is `VeryLow` on Android,
  `Low` on iOS) are shared; `VideoMode` is Android's; `BugseeStyle`, `CrashHandlerType`, `DataEncryptionMode` are iOS's;
  `MemoryLeakMode` (leak module) is string-valued. Defaults differ on exactly two shared keys: `capture.video.adaptive`
  (Android false, iOS true) and `config.max-data-size` (150 vs 50) (listed in the parity test).
- **Endpoint (8.2 is stale at the pins):** both SDKs take the hidden `com.bugsee.option.$$ENDPOINT` and strip a trailing `/v2`
  themselves (iOS commit d33dcc987, 2026-09-17, before beta7), so one version-less value under one key goes to both; runtime
  verified on both (the SDK reports `http://10.0.2.2:8099` / `http://localhost:8099` for `https://.../v2/`).
- **8.3 half stale:** `getLaunchOptions` is merged defaults + overrides on both at the pins; `getHostLaunchOptions` still
  differs (Android everything the app passed, iOS only what differs from the iOS default); documented on the API.
- **Auto-init** (Android, `BugseeInitProvider`): launches before `Application.onCreate` when the manifest has
  `com.bugsee.app-token` (unless `com.bugsee.auto-init` is `false`); a later `Bugsee.launch` is `already-running` and its options
  are dropped (the SDK logs only). Verified on an emulator: auto-init, then `Bugsee.launch` -> `alreadyRunning`, duration 60 not
  20, attach replays `launching, launched`; with `auto-init=false` the same call launches with duration 20. iOS has no auto-init;
  a background launch is deferred by the SDK and reported `deferred`.
- **Runtime evidence** (emulator-5562, Android 7.4.2; iPhone 17 simulator, iOS 7.0.0-beta7): `example/integration_test/launch_test.dart`
  passes on both: `launching, launched, [already running], stopping, stopped, launching, launched, stopping`; the SDK reports our
  option values back (enums as internal integers); a blank token is a typed `invalidToken`.
- Review follow-ups: a stop in flight is marked natively on iOS (the SDK sets Stopping a main-queue hop after `+stop:`; Android sets
  it synchronously, no window); a custom enum NAME is mapped to its number; an unknown severity is left out (the SDK's
  `fromIntValue` answers VeryLow); deprecated options (one: `capture.webview.domain-allowlist`, a documented no-op) have no typed field;
  `deferred` is documented as not-a-failure with `waitUntilLaunched` to settle it. A cold-start `await Bugsee.launch` before `runApp`
  returned `launched` on the iOS simulator (both under the test harness and a real `flutter run` cold start), so `deferred` there needs an
  app that is not yet active (engine started in `didFinishLaunching`); not reproduced.
- Not verified at runtime: launch refused while stopping (a race, covered by JUnit/XCTest/Dart with fakes), iOS background deferral,
  token rejection by the SDK itself (a placeholder token launches), the leak module, tvOS/visionOS.

### 4b — the rest of the public facade (done)

Full inventory of both SDKs (Android 7.4.2, iOS 7.0.0-beta7), per-method decisions with reasons, the before-launch
behaviour table with source line references, value rules, errors and threading: **`doc/api-surface.md`**.

- **Added** (all `Bugsee.` statics, all `async`): `setAttribute`/`getAttribute`/`getAllAttributes`/`clearAttribute`/`clearAllAttributes`,
  `setUserIdentifier`/`getUserIdentifier`/`clearUserIdentifier`, `event`, `trace`, `log`, `addBreadcrumb` (+ `BugseeBreadcrumb`,
  `BreadcrumbLevel`), `notify`, `startBlackout`/`endBlackout`/`isBlackout`, `showReportDialog`, `upload`, `setReportHandler`/`reportHandler`
  (+ `BugseeReportHandler`, `ReportProxy`, `ReportSnapshot`, `ReportClosedError`, `ReportType`), `lifecycleEvents` (+ `LifecycleEvent`,
  unknown names preserved), and the widget `BugseeSecureView`. Errors: `BugseeArgumentException`, `BugseeAttributeException`
  (`AttributeFailure`). 17 new Pigeon methods + `BreadcrumbMessage`; still no Pigeon enum.
- **Skipped, with reasons** (in the doc): APM transactions/spans (native handle registry + per-thread active span, a design of its own),
  appearance (huge per-property system that differs per platform), `relaunch`, secure rectangles/activities (the wrapper IS the
  rectangle provider), `deleteCollectedDataOnDevice`, `resetVideoCapturePermission`, `testCrash`; Phase 5 (filters, network events,
  exceptions, `captureViewHierarchy`) and Phase 6 (`createReport`, attachments).
- **The wrapper queues and gates nothing before `launch`** (source-verified, then device-verified): attributes, user identifier and blackout
  work on both platforms (blackout is HELD on Android 7.4.2 and applied at launch: the RN doc that says Android ignores it is stale);
  event/trace/log/breadcrumb/notify/upload/dialog are dropped by the SDKs (Android logs `You need to call Bugsee.launch() ...` for
  notify/upload/dialog; iOS logs `Bugsee.uploadWithSummary ignored: SDK is not launched`). `addBreadcrumb` answers `false` when capture is off
  (default off on both) or the SDK is not Launching/Launched (before launch AND after stop: gated natively, the SDKs' own gates differ). A platform with no SDK: no-ops, only `launch` throws.
- **An attribute the SDK dropped is only knowable by reading it back** (Android `setAttribute` is void; iOS's `BOOL` is YES for a value it
  ignored): native sets, reads back and reports `attribute-rejected`. The limits differ and were measured on device: Android keeps a
  1024-char string and 42 x 600 chars in all; iOS rejects the 1024-char string (1124-byte archive) and takes 40 x 600. Dart refuses
  > 1024 UTF-16 units on both (Android's hard cap, so a value is not accepted on one platform and dropped on the other).
- **Source findings worth keeping**: Android stores a non-integer attribute as a 32-bit float (in memory the double survives until a
  restart); `Bugsee.event/trace` have no launch gate on Android but their consumer only exists after launch and is cached for good, so a call
  after `stop` may still reach the last provider (iOS gates on Launching/Launched); iOS `upload`/dialog without a severity must use the
  SDK's two-argument form (the four-argument form stores 0); breadcrumb levels differ (Android debug 1..fatal 5, iOS error 1..debug 4, no fatal), so the name crosses.
- **Runtime evidence** (`example/integration_test/facade_test.dart`, Android emulator-5562 API 33; iPhone 17 simulator iOS 26.5; plus
  `launch_test` and `cold_start_test` still green on both): attributes (5 types) and the user identifier read back from the SDKs before
  launch, `getAllAttributes` and the bool/int/double types survive the channel, limits above, blackout read back before launch and the
  `BlackoutStarted`/`BlackoutEnded` events while launched, breadcrumbs `taken: true` for all five levels when launched with capture on
  (and `false` before), the public `BugseeSecureView` mounted while launched, and a **real `Bugsee.upload` with the public report handler
  on both SDKs**: `before:bug`, `after:bug` delivered, the handler's `setAttribute`/`replaceLabels` visible on the live report via `read()`
  with the global attribute and `critical` severity, and the SDK's own `BeforeReportAssembled`/`AfterReportAssembled`/`BeforeReportUploaded` events.
- **What could not be verified**: write-only calls (`event`, `trace`, `log`, `notify`) have no SDK readback, so on device they are shown to
  complete without error with the SDK launched (JUnit/XCTest show what reaches the SDK seam); iOS stops a placeholder token itself after the
  first refused upload (`ReportUploadFailedWithFutureRetry`, `Stopping`, `Stopped`) and a fourth launch/stop cycle with it in one process was
  refused by the SDK (reason in its log, not investigated), so the integration test uploads first and tolerates it; no valid token, so no
  server-side confirmation that events/breadcrumbs arrive; secure rectangles reaching the SDK were verified in Phase 3b, not again; notify fields
  order on the wire; `deferred` iOS launches; tvOS/visionOS.
- **Tests** (every new test was mutation-checked: the behaviour broken, the test seen failing, the code restored): 46 Dart facade tests with a
  mocked bridge (validation, encoding, error mapping, unsupported platform, handler lifecycle, lifecycle stream), 5 widget tests of the public
  `BugseeSecureView` through the real registry and the real generated channel codec, 13 drift tests (failure codes, attribute limits,
  breadcrumb names, log range, bridge methods wired in both natives), 10 public-API-surface tests (pinned exports, `Bugsee` members, no
  pause/resume shim, internals hidden, no re-export), 29 JUnit and 25 XCTest seams. Mutations killed: 18+2 Dart, 19 Android (one survived
  until its test was strengthened), 17 iOS (one survived until strengthened), 7 drift, 20 Dart/native second batch; the survivors found and fixed:
  an unsorted Set (test used an already-sorted HashSet), the raw iOS `getAttribute` (no test of the single read filter), the drift guard's
  prefix match (`FacadeOps::isBlackoutZ` passed), and the code-string test pinned only by symbol.

## 5. Phase 5 — Dart-side capture and data channels

- Wrapper-owned log/network/breadcrumb injection per `wrapper-channel` (attributed to the
  wrapper, filters chained ahead of app filters) — spec is **Proposed, unimplemented on both
  SDKs**; build against the interface, gate on SDK support.
- Dart exceptions: `FlutterError.onError`, `PlatformDispatcher.onError`, isolate errors,
  obfuscation symbolication (debug-info) — port the useful parts of the 9.x `exceptions*`
  and `symbols.py` approach, as new code.
- Network: HttpClient/`HttpOverrides` and package interceptors (dio/http).
- View hierarchy (`vh`): Flutter semantic/render tree → JSON, **no text content or free-text
  labels on secure nodes**, bounds in screen coords in platform units.
  **Blocker (6.7):** Dart runs off the platform thread, so Android's async-reply fix
  (`bugsee-android` PR #120) is required; track it.

## 6. Phase 6 — Reports (Part 7, report-contract)

- `Report` proxy (opaque handle + operations), not flattened; path-first attachments
  (native does the file work); severity by value (Android `VeryLow=1`, iOS `Low=1`);
  `onBefore` at-most-once, `onAfter` idempotent; deadline is the SDK's; no recovery inference.
- Recovered-report identity (`identity_source`) passes through untouched.

## 7. Phase 7 — Device verification (Part 9)

Harness-level assertions (build SHA banner, SDK launched, precondition took, event happened).
Recipes: native `SIGSEGV` (4 distinct `libbugsee*.so`, report produced), airplane-mode bundle
retention + `request.json` read, crash across update, Dart exception, secure-rect redaction on a
3× device, relaunch-after-crash with handlers, release-build/obfuscation symbolication.

## 8. Phase 8 — Feedback package, docs, release

`bugsee_flutter_feedback`; README/migration guide (9.x→7.x API, since it is a clean break);
CHANGELOG; pub.dev publishing scripts (replace old `scripts/`); example app covering all screens.

## Risks / open items

- Flutter floor 3.41 is above several competitors (D5); a podspec was ruled out because Bugsee publishes no pod. Revisit if customers on older Flutter matter.
- iOS beta-only and unpublished → pinning and CI access (D1/D2).
- Wrapper-channel and option-manifest specs unimplemented → schedule dependency.
- Android async-`vh` (#120) and units unification (specs PR #20) in flight.
- Flutter's Android template/AGP may conflict with Gradle plugin 4.0.7 constraints — spike early.

## Suggested order

P1 → P2 → P3 (ship a correct MVP, then device-verify) → P4 → P6 → P5 → P7 → P8.
