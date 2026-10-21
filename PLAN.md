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
- Lifecycle delivery limit (3a): guarantees end at the hop into the channel sink. A message sent while the Dart side has no handler is held only by Flutter's channel buffer, which by default keeps ONE message per channel (a restarted isolate may see that one after it sets a handler; any older ones are dropped, and the engine reports an error that native only logs). The hub replays the latest status on re-attach, which recovers status but not report events. Phase 4/6 consumers must not rely on report events surviving a restart.
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
  the whole display; a view known to be off screen serves nothing. Dart (`lib/src/secure`, internal until
  Phase 4): `BugseeSecureRegion`/`RenderSecureRegion` + `SecureRegionRegistry`, measured every frame in a
  post-frame callback, published only when the set changed, ordered by `(epoch, sequence)`. Regions are
  reported UNCLIPPED through every ancestor transform (bounding box, including paint outside their box); a region is dropped only on positive evidence
  (paintsChild, IndexedStack, a clipping viewport); neither a disabled TickerMode nor a detached layer counts as such evidence. An unmeasurable region covers the whole view.
  First-frame exposure of a newly appearing region remains.
  Known limits: see "Secure rectangle limits" in `.claude/CLAUDE.md`.
- Report handlers: always call completion; `isTerminating=true` → synchronous native-only
  work, no round-trip to Dart.

## 4. Phase 4 — Public API and options (Part 8)

- Dart facade mirroring the converged 7.x API (launch, attributes, identity, events/traces,
  breadcrumbs, notify, APM, logging/network, status, blackout, exceptions).
- Options: use `com.bugsee.option.*` from the generated registry, not literals; one place
  normalises the endpoint asymmetry (iOS flat key *with* version, Android `$$ENDPOINT`
  without); hidden options not exposed; `getLaunchOptions` semantics differ per platform.
- Vendored option manifests + CI diff (strict on keys/types/enums). Note: SDKs do not publish
  manifests yet (spec "Proposed") — until they do, generate from `OptionsRegistry` /
  `BGSOptionsRegistry` or track as a blocker.
- Bridge: Pigeon (typed) for method channels + typed event channels; enums by internal value,
  generated from SDK source, compared across **both** platforms (7.4).

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
