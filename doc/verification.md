# Device verification (workbook Part 9)

What was measured on a device, how, with the evidence, and what was NOT covered. The harness that produced it is
in the repository (`scripts/device/`), so every number below can be taken again; this file is the result of one
run of it (environment below), not a promise about other devices.

* [The harness](#the-harness) and the guards it applies by default
* [Environment](#environment)
* [Results at a glance](#results-at-a-glance)
* [Scenarios](#scenarios): 1 registration and artefacts, 2 native crash, 3 report handlers, 4 Dart exceptions,
  5 release and profile, 6 crash across an update, 7 secure rectangles at other densities, 8 hot restart
* [Findings](#findings): defects, doc corrections, observations
* [Not covered](#not-covered)

## The harness

```
dart scripts/device/verify.dart build android [--only debug,releaseA,releaseB,profile]
dart scripts/device/verify.dart android --serial emulator-5554 [--scenarios 1,2,3|all] [--reuse]
dart scripts/device/verify.dart build ios --udid <simulator>
dart scripts/device/verify.dart ios --udid <simulator> [--scenarios ...] [--reuse]
```

`--reuse` runs the builds already in `build/device-verify/`. A run refuses a dirty working tree (`--allow-dirty` snapshots it instead) and asserts `git status` clean again at the end of every scenario; it exits 1 when a scenario failed or was invalid and **2 when one was NOT POSSIBLE** (a skipped run must not read as a pass; `--allow-not-possible` accepts it, as the iOS simulator run needs). A KNOWN-GAP (below) is not a failure. `ffmpeg` and `ffprobe` are required and checked before anything runs. Results are printed with their evidence and written
to `build/device-verify/report-<platform>.json` (and `.log`). The harness is not run in CI (it needs a device and builds the app); its pure core (parsers, assertions,
the guards) is covered by `test/device_harness_test.dart`, which does run, against text taken from these runs and
against text that must make each check fail.

**Physical devices (Android).** The harness was written for an emulator; a phone differs in three ways, each handled and
stated in the report (`env`): (1) the app reaches the host's mock API as `127.0.0.1` through `adb reverse` instead of the
emulator's `10.0.2.2`: build and run with `BUGSEE_VERIFY_HOST=127.0.0.1` (baked into the build, so an emulator build is not
reusable on a phone); (2) a phone has no `adb root`, so a non-debuggable release build's private data cannot be read: build with
`BUGSEE_VERIFY_DEBUGGABLE_RELEASE=1` and the release builds (still R8, `--obfuscate`, the Gradle plugin) are debuggable, read with
`run-as` (an overlay manifest with `android:debuggable` and lint's `HardcodedDebugMode` off, added only then; NOT `isDebuggable` on the
build type, which makes Flutter's Gradle plugin build in DEBUG mode, measured); the report says `releaseDebuggable: true` and a guard proves the build is debuggable; they are not what a store ships,
so a result that depends on a non-debuggable app (the native symbol upload is skipped for a debuggable build) is not made with it;
(3) some phones leave `ApplicationExitInfo.status` at 0 for a native crash (measured on an Android 14 phone): on a device that is
not an emulator a status of 0 is accepted, ONLY with the kernel's `Fatal signal 11` for the same pid in logcat and a native-crash
reason (`exitRecordProblems`, tested to still fail for any other status or reason). Run with
`--serial <adb serial> --allow-dirty --allow-not-possible`.

**Physical iPhone.** `dart scripts/device/verify.dart ios-device --udid <device> --scenarios 10` (with `BUGSEE_VERIFY_MOCK_BIND=<the Mac's LAN
address>`, one address) installs the signed release build with `devicectl`, launches it with its console attached (the child's exit is the proof the
process ended; the console also carries the SDK banner, e.g. `Bugsee IOS SDK ver:7.0.1 build:5c6b9d9db-8`, measured on an iPhone XS) and runs the crash
matrix of scenario 10 against the mock API on the LAN. Only scenario 10 exists for a device (1 to 9 need the simulator's filesystem and `simctl`). The first
launch after an install shows iOS's Local Network prompt, which a script cannot answer: the run prints `PROMPT EXPECTED NOW` and waits `--prompt-wait-minutes N`
(default 3) for a tap; without a launch event the run is INVALID. `--keep-install` (off by default: the clean install is the guarded precondition) does not
uninstall at the start and the end, so a re-run on an install that already holds the permission needs no tap (measured: a 3-minute full run). Its limit: the
install is not clean, so a report an earlier or aborted run left pending is uploaded by the next launch; the run therefore launches once first, lets the SDK hand
that report over and forgets it (the note `--keep-install: drained ...`), but the clean-install precondition is not what ran, so a result that depends on it
needs the default. Each launch gets a token (`VERIFY_LAUNCH_TOKEN`, passed with `devicectl --environment-variables`) that the app puts in every event, and the
launch wait takes only an event with that token; the app numbers its events (`rid`, `seq`) and the mock reader drops a repeat of one. **Status: the
matrix ran to the end on an iPhone XS (iOS 18.7.9) on 2026-11-18, results under scenario 10 (iOS).** Two attempts before it ended INVALID because nobody
tapped within 30 minutes ("The Internet connection appears to be offline" from the SDK; the console shows the wrapper lines and the banner, so the
console does carry the wrapper's `NSLog` lines).

**What it drives.** `example/lib/verify_main.dart` is the example app's second entry point: it launches the SDK
from build flags (`--dart-define=VERIFY_SERVER`, `BUGSEE_ENDPOINT`), registers a report handler that records what
it saw (into the report itself: an attribute, a label, an attached file) and polls `GET /__cmd` on the loopback
mock API (`example/integration_test/support/mock_api.py`, 127.0.0.1 only) for commands (`upload`, `log-handled`,
`create-report`, `secure off`, ...). The same build runs in debug, profile and release, on a device without a
debugger and without `run-as`. Its events leave as `VERIFY|{json}` lines on the console and as `POST /__event`.
Android's release build is not debuggable, so the harness reads its data directory as root (`adb root` works on
the Google APIs emulator image); a debug build is reached with `run-as`, the recipe of workbook 9.3.1/9.3.3, and
the report says which one it used.

**Guards applied by default (9.1).** There is no way to start the app, crash it or read a report that skips them:
they are part of `AndroidSession.launch/crash/airplane/install` and the iOS equivalents, and a failed guard ends the
scenario as `INVALID` (the experiment did not measure what it claims), never as a pass and never as a product
failure.

| 9.1 | What the harness asserts, on every launch |
|---|---|
| 9.1.1 which build | The SDK banner (`Bugsee Android SDK 7.4.2 [3b7af6371]`, `Bugsee IOS SDK ver:7.0.0 build:2b88480fa-7`) matches the version AND the build in `native-versions.json` (`android.sdkBuild`, `ios.sdkBuild`): a version string alone cannot tell two builds of one version apart. The wrapper's own log lines (registered and refined: type `flutter`, the pubspec version, Flutter, Dart, engine, build mode) match the toolchain that built it. The artefact set: Android `./gradlew :app:dependencies` has `bugsee-android` and `bugsee-android-ndk` at the pin, the Gradle plugin in the (private) Gradle home is the pinned 4.0.8 alone, the APK carries the four `libbugsee*.so`, the merged manifest keeps the wrapper provider at `initOrder` 200 (not stripped) ahead of the SDK's 100; iOS: SwiftPM resolved `bugsee/spm` and `bugsee/feedback-spm` at the pinned tag AND revision (`ios.spmRevision`), not a branch or a local path. |
| 9.1.2 launched | The app reported `launch -> launched` and `status launched` before anything is concluded from an absence. |
| 9.1.3 precondition | Staged facts are read back: data wiped (the app is gone), the right `versionCode`/`CFBundleVersion` installed, no retained bundle before a crash, airplane mode really on (`settings get global airplane_mode_on`), the crash data of build N still there after the update. |
| 9.1.4 event | The process died of signal 11: logcat `Fatal signal 11 (SIGSEGV)` for that pid AND `ApplicationExitInfo` reason 5 status 11 (Android); launchd's `exited due to SIGSEGV` (followed by `sent by kill[...]`, iOS simulator). A hot restart really ran (`flutter run` printed it); a report really appeared for the command that should make one. |
| 9.2 absence | Every "nothing arrived" is paired with a positive control in the same setup (a live report DID arrive) and a measured cause. |
| 9.1.5 defaults | The above is the harness, not a run. The working tree must be clean BEFORE anything runs; after each scenario the device is restored (airplane mode off, density reset, app uninstalled, `adb reverse` removed) and `git status` is asserted clean. A missing video, a video that does not decode, or a missing tool is a failed check or a refusal to start, never a skipped one. |

Nothing in the repository is modified by a run: the app is configured with build flags, the example's manifest and
`Info.plist` are untouched, and temporary files live in `build/device-verify/` (ignored by git).

## Environment

| | |
|---|---|
| Host | macOS 26.6.2 (25G83), Darwin 25.6.0, arm64 |
| Flutter / Dart | 3.41.0 stable (engine `3452d735bd`) / Dart 3.11.0 (the floor when these results were made; it is 3.50.0 now) |
| Android toolchain | JDK 21.0.11 (Zulu), Gradle 8.14 (the template's wrapper), Android Gradle Plugin 8.11.1, Bugsee Gradle plugin 4.0.8, private `GRADLE_USER_HOME`, `--no-daemon` |
| Android SDK under test | `com.bugsee:bugsee-android` and `-ndk` 7.4.2 (banner build `3b7af6371`) |
| Android device | AVD `phase7_api30`: Pixel 4 profile, API 30 (Android 11), `google_apis` arm64-v8a userdebug image, 1080x2280 at 440 dpi (2.75), 3 GB RAM, started headless (`-no-window -no-snapshot`), emulator 37.2.12 |
| iOS toolchain | Xcode 27.1 (27A9275), iOS SDK 27.1 |
| iOS SDK under test | `bugsee/spm` 7.0.0 (revision `bbfdda2`, banner `build:2b88480fa-7`), `bugsee/feedback-spm` 7.0.0 (`82054e7`); the results below were taken at 7.0.0-beta7 (`73ed983`, `build:9854b7e50-15`, feedback `40dd3b0`), see "The 7.0.0 pin move" |
| iOS device | simulator `phase7-iphone`: iPhone 18 Pro, iOS 27.0 runtime (24A434), 3x |
| Other tools | ffmpeg 7.1.1 and ffprobe (frames of the report video and screenshots), Python 3.14.6 (the mock API), `apkanalyzer` and `retrace` (cmdline-tools 13.0) |

Test counts of the same tree (all passing): `flutter test` 1344 (35 of them the harness core, `test/device_harness_test.dart`),
the feedback package 22, Android JUnit 396 (core) + 16 (feedback), iOS XCTest 335 (core, `ios/wrapper_tests`) + 23 (feedback),
all run on the devices above where a device is needed (`xcodebuild test -collect-test-diagnostics never`, the simulator's UDID).

The two devices were created for this work and shut down afterwards; other emulators and simulators on the host
were never touched (every command names its own serial or UDID).

### The 7.0.0 pin move (2026-11-01)

The iOS pin moved from 7.0.0-beta7 to the stable 7.0.0 (`bugsee/spm` `bbfdda2`, banner `build:2b88480fa-7`). The iOS part of the
harness was run again on a new simulator (iPhone 17, iOS 26.5, Xcode 27.1) with `--allow-dirty --allow-not-possible`:

* **PASS: 8 (hot restart), 12/12 checks**, and the build, banner (`ver:7.0.0 build:2b88480fa-7`), wrapper identity, SwiftPM
  revision and add-on registration guards of every scenario passed.
* **INVALID: 1, 2, 3, 4, 5, 7**, each at its first `upload` command ("no new bundle reached the mock API in 90 s"). Cause, measured: the SDK
  posts `/v2/issues` (the mock answers 200) but never PUTs the bundle, because its background upload session cannot be created:
  `nsurlsessiond` logs `Process with pid N does not have a bundle ID, rejecting connection` for the app launched by `simctl launch`.
  This is the simulator environment, not the SDK version: the **beta7 build fails the same way on the same simulator today**
  (checked by hand against the mock), and re-signing the app with its bundle identifier did not change it. Scenario 8, whose app is started by
  `flutter run`, uploads normally. So the 4 scenarios that passed with beta7 on 2026-10-22 could not be re-measured here; nothing in them
  failed for a product reason.
* **Crash reporter on the simulator: still none.** The `ios-arm64_x86_64-simulator` slice of `Bugsee.xcframework` 7.0.0 has 0 strings
  matching `BGSCrashManager|PLCrashReporter`, the `ios-arm64` slice 28, so scenario 2 (and a recovered iOS report) remains NOT POSSIBLE
  without a physical iPhone.
* Unit level, all passing: `flutter test` 1357, iOS XCTest 335 (core) + 23 (feedback) on the simulator, `flutter build ios` and the debug APK.

## Results at a glance

| # | Scenario | Android emulator API 30 | iOS 27.0 simulator |
|---|---|---|---|
| 1 | Registration and artefacts | PASS (debug and release) | PASS |
| 2 | Native crash, retained bundle, recovered identity | PASS (debug via `run-as`, release via root) | NOT POSSIBLE: the simulator slice of the SDK has no crash reporter (measured) |
| 3 | Report handlers on a recovered report | PASS (debug, release) | NOT POSSIBLE for the recovered half (same cause); the live half measured |
| 4 | Dart exceptions end to end, obfuscated release, symbolization | PASS (debug; release with R8 and `--obfuscate`) | NOT POSSIBLE: the SDK files no logged exception on a simulator |
| 5 | Release and profile behaviour | PASS (release, profile, debug baseline) | PASS for debug on the simulator + the device release link inspected statically; release/profile cannot run on a simulator |
| 6 | Crash across an app update | PASS | NOT POSSIBLE (no recovered crash on a simulator) |
| 7 | Secure rectangles at density != 1 | PASS (440, 320, 560 dpi; debug and release) | PASS at 3x; a density change at run time is not possible |
| 8 | Hot restart | PASS | PASS |
| 9 | Report screenshot by render mode | PASS at Android 7.5.0: content and the secure box redacted in BOTH modes, screenshot and video (at 7.4.2: KNOWN-GAP, all black in the default SurfaceView mode) | not applicable (the iOS screenshot has content, scenario 7) |
| 10 | Crash and error matrix: native signals, Java, Dart routes | PASS on a physical phone at Android 7.5.1: see section 10 | not run (no iOS device harness yet) |
| 11 | End-to-end symbolication, real backend | UPLOADED, crashed on the phone, read back (apidev, by hand through the staging MCP): everything symbolicated, Java, native and Dart | UPLOADED, crashed on an iPhone XS, read back (apidev, by hand): native frames symbolicated, **Dart exceptions raw** (backend symbol-record collision, fixes in review: bugsee-appserver#280, bugsee-background-worker#182); not re-measured after the fixes |

## Scenarios

### 1. Registration and artefacts

Android, debug and release (R8, `--obfuscate`), a cold start captured for 32 s:

* The wrapper registered before the SDK: the log has `BugseeFlutter: wrapper registered type=flutter version=10.0.0-dev.1` before
  `Bugsee Android SDK 7.4.2 [3b7af6371]`; the merged manifest has `com.bugsee.flutter.FlutterWrapperInitProvider` at
  `android:initOrder="200"` and `com.bugsee.library.BugseeInitProvider` at 100 (the provider was not stripped).
* Artefacts: `./gradlew :app:dependencies` resolves `bugsee-android:7.4.2` and `bugsee-android-ndk:7.4.2`; the Gradle plugin
  in use is 4.0.8; the APK carries `libbugsee-crashcp.so`, `-crashpad-handler.so`, `-crashpad-trampoline.so` and `-native.so`; the
  plugin stamped `assets/bugsee_build_id.properties`, and a crash report's `crash.json uuid` is that id (scenario 2).
* **The four libraries (measured vs inferred, 9.4).** Workbook 1.4.2's measure (`logcat | grep -oE "libbugsee[a-z-]*\.so" | sort -u | wc -l`, at
  least 30 s) saw **1** distinct library after a cold start here (the crashpad trampoline) and 1 to 2 across a whole crash cycle. Measured mechanism:
  the only lines that ever name a library are `avc: granted { execute } for path=".../no_backup/bugsee_crashpad_handler/<id>/libbugsee-crashpad-*.so"`
  audit lines, i.e. libraries **executed from files in the app's data directory**; `libbugsee-native.so` and `libbugsee-crashcp.so` are mapped straight from
  `base.apk` and leave no name in logcat, so the grep can never reach four on this setup, on a correct build. (Which of the pair gets an audit
  line varies between runs; that variation is not explained here, and the kernel's rate limiting, which an earlier draft blamed, was not observed.)
  Used alone, that measure would have read "broken" (9.2). The harness measures instead:
  1. **measured, in the app process:** `libbugsee-native.so` and `libbugsee-crashcp.so`. `/proc/<pid>/maps` shows `base.apk` and a file offset, not a
     name, so each mapping of the package's OWN base.apk (the path from `pm path`; other APKs such as `framework-res.apk` have offsets of their own that
     can fall inside the same range) is resolved against the offsets of the stored `lib/arm64-v8a/*.so` entries in the APK's central directory;
  2. **measured, in the crashpad handler process:** the handler is `exec`ed only when the app crashes, so the harness kills the app and, in the same
     shell, polls `ps` for the child (`linker64 .../libbugsee-crashpad-trampoline.so .../libbugsee-crashpad-handler.so --database=...`, ppid = the crashed app) and reads
     ITS `/proc/<pid>/maps`: both libraries are in it. All four are measured when that race is won (it was, in every run); if it were lost the report
     says "2 measured + 2 inferred" (the pair extracted under `no_backup/bugsee_crashpad_handler/*/` with the APK's sizes, and the minidump the handler wrote in the bundle).
* The identity reaches the report: a live report's `request.json` has `environment.sdk.wrapper` =
  `{"type":"flutter","version":"10.0.0-dev.1","context":{"dart":"3.11.0","flutter":"3.41.0","flutter-engine":"3452d735bd","build-configuration":"debug"|"release"}}`,
  `sdk` `7.4.2` / `3b7af6371`, `app` `1.0.1` (`1`), and no `identity_source` (a live report is not recovered).

iOS (measured at 7.0.0-beta7, banner `build:9854b7e50-15`; the 7.0.0 banner `build:2b88480fa-7` was confirmed in the scenario 1 guards of the 2026-11-01 re-run): the log has `[BugseeFlutter] wrapper registered ...` before the `Bugsee IOS SDK ver:... build:...` banner;
the feedback add-on registered through its `+load`; the build's `workspace-state.json` resolves `spm` and `feedback-spm` at
the pinned version (beta7 then) and revisions; the report's wrapper has the same identity with `build-configuration: debug`.
Not applicable on iOS: manifest provider, NDK artefact, Gradle plugin.

### 2. Native crash (SIGSEGV), retained bundle, recovered identity

Android (debug with `adb shell run-as <pkg> kill -11 <pid>`, release with a root shell, because a release build is not
debuggable): the process died of signal 11 (logcat `Fatal signal 11 (SIGSEGV), code 0 (SI_USER from pid ..., uid ...)`; `dumpsys activity
exit-info`: `reason=5 (APP CRASH(NATIVE)) status=11`). Airplane mode was enabled and read back before the relaunch
(`settings get global airplane_mode_on` = 1), so the bundle stayed on the device (`files/bugsee_data/bundles/*.bundle.zip`). Read
from it:

* manifest entries `minidump`, `crash`, `log`, `video`, `viewtree`, `attachment`...; `crash.json`: `ndkCrash: true`,
  `exception_type: native`, `signal: {name: SIGSEGV, number: 11, code_name: SI_USER}`, `uuid` = the APK's Gradle build id.
* the four libraries, as in scenario 1 (in-process pair from `/proc/PID/maps`, handler pair from the handler process's own maps).
* `environment.sdk.wrapper` is on the **recovered** report with the full identity (the workbook's "fails only on a relaunch after
  a crash" trap does not bite), `environment.identity_source` is `session` (specs `sdk/report-identity`: the identity of the
  producing session, from its persisted `identity.json`), `app.build` is the crashed build, severity 4 (the `crash-priority` option).

iOS simulator: NOT POSSIBLE. A SIGSEGV was proven (launchd: `exited due to SIGSEGV | sent by kill[...]`) and the relaunch
recovered nothing: no crash bundle reached the mock API in 80 s and no `RelaunchedAfterCrash` event. The positive controls are on both sides of the crash: a live
report sent before it arrived, and **a live report sent from the RELAUNCHED process after the 80 s window arrived too** (so that process could upload); the simulator
container was searched as well: the SDK does keep the bundles it could not upload (`Library/Caches/com.bugsee.data/capture/bundles/*.bundle.zip`, so iOS does retain bundle
files), and their `request.json` types are all `bug`, no crash bundle and no `.dmp`/`.plcrash`/crash-report file. Cause, measured: the simulator slice of the SDK
(`Bugsee.xcframework/ios-arm64_x86_64-simulator`) has no crash reporter (0 strings matching `BGSCrashManager|PLCrashReporter`;
the `ios-arm64` slice has 27); the SDK compiles it out under `TARGET_OS_SIMULATOR`. Airplane mode does not exist on a simulator
either; the mock API refusing the upload with 503 (and storing a copy) is the stand-in the task allows, and it is what the
other iOS scenarios read their bundles from. A physical iPhone is needed for everything about a recovered iOS report.

### 3. Report handlers on a recovered report

Android, from the crash cycle of scenario 2 (the wrapper's own log lines, the Dart handler's `VERIFY` lines, the bundle):

| | Measured (debug and release alike) |
|---|---|
| Dart handler ran | `onBefore` once and `onAfter` once, for the recovered report; type `crash`; one `deliveryId` per phase |
| `isTerminating` | not visible to Dart (`ReportProxy` has no such field by design). The observable: the wrapper completes `isTerminating=true` deliveries natively without Dart, and Dart ran, so it was `false`, as workbook 7.1.3 says |
| Thread | the SDK called the native handler on a thread other than main (`phase=before` logged with tid != pid), the wrapper hopped to main for Dart (`delivery gap` and `completed by=dart` on tid == pid). The wrapper gave it the LIVE window (`deadline=20000`), which it grants only to the SDK's `BugseeReportHandlerThread`: **a native-crash report recovered after a normal session is dispatched like a live report, on the waited-for handler thread, not on the bounded early-crash thread and not on main** (the workbook table says main). *Measured vs deduced:* "not main" is measured directly (`tid != pid` in the log line); "it is `BugseeReportHandlerThread`" is DEDUCED from `deadline=20000`, which the wrapper gives only to a thread with that name (the thread name itself was not logged) |
| Timing | across the runs, before at 0.4 to 1.3 s and after at 0.4 to 1.8 s since `main()` of the relaunched process (a loaded host is the slow end); `delivery gap` 113 to 295 ms (the hop to the platform thread), `remaining` ~19.7 s of 20 s |
| Completion | by Dart both times, never by the deadline |
| Enrichment | **lands**: the recovered bundle's manifest has the attributes `verify.before` / `verify.after` the handler set, the label `verify-after`, and the file `verify-enrichment` (content equal to what the handler wrote) |

iOS: the recovered half is NOT POSSIBLE on the simulator (scenario 2). The live half, measured for comparison: `onBefore`/`onAfter`
once each for an `upload`, type `bug`, the Dart handler on the main thread (iOS Dart runs on the platform thread), window 20 s, enrichment
(attribute, label, file) in the bundle. The workbook's iOS recovery claims (off-main, bounded cap, a late completion re-persists
the report) could not be measured.

### 4. Dart exceptions end to end

Android, `Bugsee.logException` (handled), `logUnhandledException` and an uncaught async error caught by `installErrorHandlers`
(`reportAsCrash: false`), in a debug build and in a release build with R8, the Gradle plugin and
`--obfuscate --split-debug-info`:

* each bundle's `crash.json` has `exception.name = com.bugsee.flutter.FlutterManagedException` (intact; `crash.json obfuscated`
  is `true` for the release build, whose other wrapper classes are renamed: its Java frame reads `com.bugsee.flutter.a.a(SourceFile:79)`), and
  the document in `exception.reason` has exactly `internalType, name, reason, signature, frames, originalStackTrace`.
  Report types: handled -> `error`, `handled: true`; unhandled -> `crash`, `handled: false`; async -> `error`.
* the exact build's `mapping.txt` keeps the carrier (`com.bugsee.flutter.FlutterManagedException -> com.bugsee.flutter.FlutterManagedException`, the
  consumer rule), and `retrace` with that mapping turns the renamed Java frames back (`FlutterManagedException.<init>`, `ExceptionOps.log`,
  `ExceptionDispatcher.lambda$submit$1`).
* the release `originalStackTrace` is non-symbolic (`*** *** ***`, `build_id: '7a3ef930...'`, `#00 abs ... _kDartIsolateSnapshotInstructions+0x...`).
  `scripts/verify_symbolization.dart` with that build's `app.android-arm64.symbols` finds the build id and resolves the app
  frames (`Bugsee.logUnhandledException (.../bugsee.dart:638:30)`, `_command`, `verify_main.dart`); with the symbols of **another build** (the
  second release build, a different Dart snapshot) it exits 1: `FAIL: build id ... is not in ...: it is another build's symbols`.

iOS simulator: NOT POSSIBLE. The SDK's own log says `Bugsee: logged exceptions are not filed on the simulator or Mac Catalyst`
(`Bugsee.m`, `#if !TARGET_OS_SIMULATOR`), once per exception command, and none reached the mock API while the control report did;
the Dart side raised no error. The iOS carrier (an `NSException` named `FlutterManagedException`) in a bundle, an obfuscated iOS stack and its symbolization need a
physical iPhone.

### 5. Release and profile behaviour

Android, the same battery in release (R8, obfuscated), profile and debug, each asked of one report or created report:

| Feature | release | profile | debug |
|---|---|---|---|
| view hierarchy (the walk uses `debugVisitOnstageChildren`) | 131 nodes, root `FlutterView`, ratio 2.75; widget names obfuscated (`BS`, `nS`, ...) | 131 nodes, real names | 135 nodes, real names (`_VerifyApp`, `MaterialApp`) |
| network capture (`HttpOverrides`) | the `dart:io` request is in the bundle | same | same |
| log capture (`print`, `debugPrint`) | both markers in `log.json` | same | same |
| secure region redacted | black 100.0 %, none of it shows | same | same |
| attachment from the handler | file in the bundle, content equal | same | same |
| `createReport` | uploaded with its summary | same | same |

Two details of the network check are worth keeping: the request must go to a host that is not the Bugsee endpoint's (that traffic is
never captured, by design: a first version of the harness aimed at the endpoint's own host and read "no capture" in every
mode), and on Android the harness reaches the same mock under a second name with `adb reverse`.

iOS: release and profile cannot run on a simulator. `flutter build ios --simulator --release` says "Release mode is not
supported for simulators"; `flutter build ios --simulator --debug` itself fails on Flutter 3.41 / Xcode 27.1
(`Target debug_unpack_ios failed: Exception: Binary .../Flutter.framework/Flutter does not contain architectures "arm64 x86_64"`
while `lipo -info` prints `x86_64 arm64`: the tool's check is order-sensitive, and the generic simulator destination asks for both
architectures). The harness avoids the tool's check with `flutter build ios --config-only` and an `xcodebuild` for one concrete simulator
and `ARCHS=arm64` (the same thing `flutter run -d <udid>` does). For release, `xcodebuild -sdk iphonesimulator -configuration Release`
gets as far as `Target aot_assembly_release failed: Exception: release/profile builds are only supported for physical devices.
attempted to build for simulator.`; a physical iPhone would be needed. What was verified instead:

* the debug battery on the simulator (view hierarchy 132 nodes, ratio 3.0; log and network capture; the file attached from the
  handler; `createReport`): all present in the bundle the mock stored;
* the **device release link** (`flutter build ios --release --no-codesign --obfuscate --split-debug-info`) built, wrote
  `app.ios-arm64.symbols`, and was inspected statically. **The iOS feedback add-on's dead-strip question:** the Release
  configuration links with `DEAD_CODE_STRIPPING = YES`, and all three `+load` registrars are in the release binary AND in its
  `__objc_nlclslist` (the list of classes with a `+load`, which the runtime calls at launch): `BugseeFeedbackAutoRegister` (the SDK
  add-on's shim), `BGSFlutterFeedbackRegistrar` (this plugin's own reference) and `BGSFlutterWrapperRegistrar`. Static evidence
  only: the registration was not run, because that binary cannot run on a simulator.

### 6. Crash across an app update (9.3.4)

Android, release build N (`versionCode 1`) and N+1 (`versionCode 2`, a different Dart snapshot): install N, launch, crash it
(signal 11, proven), install N+1 over it without wiping data (`files/bugsee_data/ndk` of N still there, asserted), airplane mode on, relaunch.
The recovered bundle has `app.version 1.0.1` / `app.build 1` (the crashed build N, not the installed N+1), `identity_source: session`,
the wrapper identity, and `crash.json uuid` = N's Gradle build id. A live report from N+1 afterwards has `app.build 2` and
no `identity_source`: a different build on each half. (The Gradle build id is the same for the two builds because their Java and Kotlin
code is identical: it identifies the compiled code, not the app version, so it cannot tell these two builds apart; the harness says so.)

iOS: NOT POSSIBLE on the simulator (no recovered crash, scenario 2). The report-identity spec says iOS discards a crash
across an update by a version gate; that was not exercised.

### 7. Secure rectangles at density != 1

Android, `wm density` 440 (the device's, ratio 2.75), 320 (2.0) and 560 (3.5), each time debug and release; the app reports its
secure box in logical pixels and the ratio it sees (`geometry`), then a report is asked with the secure view on and with it off, and the **last frame
of the report's video** (ffmpeg, raw RGB) is compared:

* with the region unsecured its magenta box is found, and it is where its logical box times the ratio puts it in the frame, from the
  video's own layout (`video.aux.json` `paddingH/screenW`): within 3 px at all three densities. That fixes the logical-to-physical
  step independently of the redaction;
* with the region secured, the same box is black, 100.0 % of it, and none of the magenta shows, at all three densities, **and the rest of the frame is the real screen** (at least 95 % of the pixels outside the box grown by 20 px equal the unsecured frame, so a frame blacked out whole cannot pass) and the 14 px ring around the box is not mostly black (at most 50 %; measured 7 to 20 %): **the
  rectangle the SDK pulled is in physical pixels and follows the density without a republish** of the app code (the harness changes
  the density, the next report is correct).
* the transient between a density change and Dart's republish (when the wrapper covers the whole display) was not sampled: only the
  settled state is.
* at Android SDK 7.5.0 the report screenshot has content in the default render mode and is checked in both modes (scenario 9); at 7.4.2 it was black there (history below). The video frame stays the stronger redaction evidence.

iOS: the simulator is 3x and fixed (`wm density` has no iOS equivalent): at 3x (ratio 3.0, physical 1206x2622) the secure box is found in the
report video (416x880, a QuickTime `.mov`) and is black, 100.0 % of it, with the region secured; **the iOS report screenshot has real content** (a 484x1024
JPEG) and shows the same: the box is magenta unsecured and black, none of the colour showing, secured. The iOS video's layout record
(`video.aux.json`: `density: 3`, `frameW: 402`, `frameH: 874`) is not the Android one, so the placement-from-the-logical-box check was not run there; the
redaction check was. A density change at run time is NOT POSSIBLE on a simulator.

### 8. Hot restart

`flutter run -d <device> -t lib/verify_main.dart`, then `R` on its stdin once a report had been made. Android and iOS (debug):

* `flutter run` printed `Performing hot restart`, and the new `main()` ran in the SAME process (same pid);
* the SDK was not launched twice: the new isolate's `Bugsee.launch` returned `alreadyRunning`;
* handlers still flow and are not duplicated: one `onBefore` and one `onAfter` for a report asked after the restart (the previous
  isolate's registration was swept), and the report carries the Dart enrichment;
* lifecycle events of that report (`BeforeReportAssembled`, ...) reach the new isolate once each;
* "wrapper registered" appears once per process (it registers before launch, not per isolate).

See Findings for what the new isolate is and is not told about the status.

### 9. Report screenshot by render mode (Android)

**Re-run at Android SDK 7.5.0 (2026-11-06, emulator API 30, all nine scenarios PASS, banner `Bugsee Android SDK 7.5.0 [8f459d745]`, plugin 4.1.0):
bugsee-android#316 is fixed.** In the default `SurfaceView` mode the screenshot (485x1024) now has content, the secure box is black 100.0 % (magenta 0.0 %) with the region
secured, the pixels outside the box equal the unsecured frame (100.0 %) and the 14 px ring is 6.7 % black; the video frame passes the same checks. The scenario now holds BOTH
modes to those checks (it was a `KNOWN-GAP` arm for SurfaceView), so a regression of the SDK fix fails the harness. The account below is what 7.4.2 did, kept for the
record. Also measured on a physical Android 14 device (not rootable, so no harness): the integration tests listed in PLAN.md, and a log line delayed 3 s by a Dart filter keeps its time
(`log.json`: 1 ms after the line printed just before it, 4005 ms before the next).

The Android report screenshot (`screenshot.bgsfile`, WebP 485x1024) is **entirely black in Flutter's default render mode** (`SurfaceView`), in debug and
release, with the secure region on or off, while the display is not black (`adb exec-out screencap`: mean colour (225, 211, 225); the harness
requires the screencap to be non-flat as a guard) and the report's video frames show the content and the redaction.

**Cause, confirmed by experiment and by SDK source (v7.4.2):**
`ScreenCaptureScreenshot.captureWithPixelCopy` (`library/.../capture/providers/screen/ScreenCaptureScreenshot.java`, l.190-226) calls
`ScreenCapturePixelCopyShared.fillRenderRequestTargets(..., null /* surfaceViewCaptureManager - not used for screenshots */, ...)` (l.226);
`ScreenCapturePixelCopyShared.fillRenderLayerSurfaceViews` (`ScreenCapturePixelCopyShared.java`, l.279) then says SurfaceViews are "captured ONLY via the flag-protected, async
SurfaceViewCapture path" (l.344) and only fills a layer `if (surfaceViewCapture != null)` (l.356): with `null` the SurfaceView is skipped, and the window copy keeps the
black hole where the SurfaceView is punched out. `FlutterActivity` renders into a `SurfaceView` by default, so this should reproduce on every device for a default Flutter app; the
emulator was the only device used here.

**Experiment (the harness, scenario 9):** the same debug build launched with the supported intent extra `background_mode: transparent` (`am start ... --es background_mode
transparent`), which makes `FlutterActivity` use a `TextureView`; SurfaceFlinger's layer list proves the mode (a `SurfaceView - <pkg>` layer exists only in the default mode).
Result in texture mode: the screenshot has real content (mean (201, 209, 201) secured, (224, 210, 224) unsecured), the secure box is black 100.0 % secured, magenta unsecured, the
rest of the frame equals the unsecured screenshot (100.0 %), and the video redaction still passes (100.0 % black box, 100.0 % outside agreement). So **redaction works in screenshots in
texture mode and the black screenshot is the SurfaceView gap, not the emulator, not the wrapper's secure regions.**

**What could and could not be claimed (Android SDK 7.4.2, history).** At 7.4.2 no screenshot-based redaction claim could be made for Android Flutter apps in the default SurfaceView mode: the screenshot carried
no content at all (so it was useless as a report screenshot, and the report editor showed black). The video was unaffected. The workaround was `RenderMode.texture` (override `FlutterActivity.getRenderMode()`, or launch with `background_mode: transparent`), with Flutter's documented trade-offs (an extra composition step for `TextureView`, frame rate and memory, platform views composing differently; none of that was measured here). **At 7.5.0 this is fixed (bugsee-android#316): the default mode captures content and the workaround is not needed.** Scenario 9 now fails when the default-mode screenshot is one flat colour while the display is not (`scripts/device/android_scenarios.dart`), so a regression is a failure, not a known gap.

### 10. Crash and error matrix (Android, physical phone)

Run on a physical Android 14 phone (HONOR/Huawei WOD-LX1, arm64, not rootable) on 2026-11-12 at Android SDK 7.5.1 (banner `[7b2ce1f52]`), Gradle plugin
4.1.1, debug build, `BUGSEE_VERIFY_HOST=127.0.0.1` (see "Physical devices" above). The verification app takes itself down with `crash <kind>` (a crash lab:
`example/lib/crash_lab.dart`, `MainActivity.java`; the kinds and what each must produce are one table, `scripts/device/core/crash_kinds.dart`, compared with
the app's by a test). Every fatal kind must really die (proved from logcat) and the NEXT launch must produce the recovered crash report with the wrapper identity
and the Gradle plugin's build id; 180 of 180 checks passed.

| Kind | How | Result |
|---|---|---|
| `ffi-segv`, `ffi-abort`, `ffi-fpe`, `ffi-bus`, `ffi-ill` | a real signal raised in the process through `dart:ffi` (a write to address 0; `abort`; `raise` of 8, 7 (10 on iOS: Darwin's SIGBUS), 4) | the kernel logs `Fatal signal N`; the report is `ndkCrash: true`, `exception_type: native`, the right signal number and name, with a `crash.tombstone` entry |
| `java-main`, `java-thread`, `java-nested` | an uncaught exception on the main thread, on a worker thread, and with a cause chain, thrown from native Java | `FATAL EXCEPTION` in logcat; the report is a crash that is NOT native and names the exception (and, nested, its cause) |
| `dart-sync-framework`, `dart-async`, `dart-zone`, `dart-isolate`, `dart-platform-dispatcher`, `dart-timer`, `dart-stream` | Dart errors through `FlutterError.reportError`, an unawaited future, `Bugsee.runGuarded`, an isolate with `Bugsee.listenToIsolateErrors`, `PlatformDispatcher.onError`, a `Timer`, a stream error | one error report each, with the carrier and the document checked |
| `dart-isolate-unlistened` | an error in a spawned isolate nobody listened to | **no report, by design** (documented limit), proved against a positive control in the same setup |

Findings: the in-process faults leave a **tombstone**, not a minidump (the minidump entry appears for a kill from outside on an emulator; on this phone the
external SEGV of scenario 2 also leaves the tombstone: scenario 2 accepts either as the crash's native evidence). Not covered: ANR and hang detection,
a Java crash during launch (early crash) or in the background, and native symbolication (needs a release build with its libraries uploaded).

**Re-run on a physical Android phone (2026-11-12, SDK 7.5.1, plugin 4.1.1, WOD-LX1 Android 14, not rootable):** with the release builds made debuggable
(`BUGSEE_VERIFY_DEBUGGABLE_RELEASE=1`, still AOT with R8 and `--obfuscate`) every scenario 1 to 10 PASSED at least once on the final code (the full run: 1, 3,
4, 6, 7, 8, 9, 10; scenarios 2 and 5 after the harness fixes: 50/50 and 73/73). Not clean, and said so: scenario 5 had three failures in the first full run
(the network check, which was a harness error: Bugsee's own traffic is excluded by host and the endpoint and the check were both 127.0.0.1, fixed by sending
the check to `localhost`; and two profile-build pixel checks that did not repeat in the next run, so they are intermittent and not explained), scenario 7 had
one failed pixel check in an earlier run and passed in the full one, and scenarios 2 and 5 were twice INVALID at their first launch ("wrapper registered as
null", "alreadyRunning"; the harness refuses to count that experiment, and the same scenarios passed on the next run). No product failure was found. The startup
hold (`WrapperHold`) was in the build for all of this.

**Re-run on the same phone at Android SDK 7.6.0 (2026-11-17, plugin 4.1.1, Flutter 3.50.0, banner `Bugsee Android SDK 7.6.0 [2a88ea7fbf]`):** scenarios 1 to 10
all PASSED (the full run: 1, 2, 3, 5 to 10; scenario 4 after a harness fix, 49/49; the scenario 10 crash matrix 180/180). Two things were found by the
harness itself, and neither is a product defect. (1) The first full run was INVALID everywhere: the pin held `2a88ea7fb` (9 characters, read from the tag) and the
banner prints 10 (`2a88ea7fbf`); the build guard refused the runs, and the pin now comes from a run. (2) Scenario 4's offline symbolization check failed:
Flutter 3.50's own `flutter symbolize` answers "Cannot locate isolate instructions section in snapshot" on the symbols of a 3.50 build, while
`package:native_stack_traces` 0.7.1 decodes the same file and stack to the app frames (`Bugsee.logUnhandledException`, `_command`, `_poll`); the harness now uses
the package. The backend's `dart_symbolize` was run on 2026-11-18 (see the next paragraph).

**iOS crash matrix on a physical iPhone (2026-11-18; iPhone XS, iOS 18.7.9, release build, iOS SDK 7.1.0, console banner `Bugsee IOS SDK ver:7.1.0
build:b65bdca06-9`, which equals the `ios.sdkBuild` pin; wrapper `flutter/10.0.0-dev.1`).** Three full runs (the first two answered the prompt by hand: 43 and 49 checks;
the third, 63 checks after the expectations below were added, took 3 minutes with `--keep-install` and no tap). Each kind: crash the app, the process ends (devicectl prints `App terminated
due to signal N`), the next launch of the same install uploads the recovered report (entries `crash`, `traces.system`, `video`, `attachment`,
`log.internal`, mostly also `log` and `breadcrumbs`). What `crash.json` holds, per kind (the signal, code and exception data are identical in the last two
runs, the first recorded it only partly; each kind's `crash.json` is saved in the work dir as `ios-crash-<kind>.json`):

| kind | the process died of | report `signal` (name, code) | `exception` block |
| --- | --- | --- | --- |
| `ffi-segv` | 11 | `SIGSEGV`, `SEGV_MAPERR`, addr 0 | none |
| `ffi-abort` | 6 | `SIGABRT`, `#0` | none |
| `ffi-fpe` | 8 | `SIGFPE`, `FPE_NOOP` | none |
| `ffi-bus` | 7 (`SIGEMT` on Darwin: the earlier stimulus, see below) | NO REPORT in 120 s (3 of 3 runs) | - |
| `ffi-ill` | 4 | `SIGILL`, `ILL_ILLTRP` | none |
| `objc-main` | 6 | `SIGABRT`, `#0` | `name: VerifyException`, `reason: verify-objc-main`, 19 frames |
| `objc-thread` | 6 | `SIGABRT`, `#0` | `name: VerifyException`, `reason: verify-objc-thread`, 8 frames |
| `swift-trap` | 5 | `SIGTRAP`, `TRAP_BRKPT` | none (the message `Fatal error: verify-swift-trap` is on the console only) |

Every report that exists has `exception_type: native`, `handled: false`, `code_type: ARM-64`, 18 to 22 threads (varies per run), a `signatures` list of one hash, and an `sdk`
block `{type: IOS, version: 7.1.0, build: b65bdca06-9, wrapper: {type: flutter, version: 10.0.0-dev.1, context: {dart, flutter, flutter-engine,
build-configuration: release}}, options}`. `signal` has `name`, `addr` and `code`, no `number`. The report's summary field is empty. **Found:** an
uncaught Objective-C exception ends in `SIGABRT` with the NSException in `exception` (`reason` exact, `name` the app's class), and a
`raise(7)` leaves no report at all on SDK 7.1.0 although the process dies of it. **That 7 was the wrong stimulus:** signal 7 is `SIGEMT` on Darwin, SIGBUS
is 10 (7 is SIGBUS on Linux/Android only; 8 SIGFPE and 4 SIGILL are the same on both). The app now raises 10 on iOS (`Platform.isIOS ? 10 : 7`), the table
holds `iosSignal: 10`, and the check is an ordinary expectation (the known-gap marker is gone). So the only thing measured is that SDK 7.1.0 records no
report for SIGEMT; a real SIGBUS on iOS has NOT been measured (the simulator has no crash reporter, so it cannot produce a report: a physical run
is needed, and is the next step). **Harness fixes this found:** the
verification app lost its one-shot `launch` event when it was sent while the Local Network prompt was up (it now keeps and resends events the mock did not
take), and the harness read `signal.number`, which does not exist. The wrapper-identity guard works on the console. **Expectations now enforced:** the
terminating signal of every native kind, the report's signal name, `exception_type native`, `handled false`, the `exception.reason` equal to the marker for the
Objective-C kinds and no exception block for the others. **Not covered:** symbolication (the dSYM was not uploaded), `code` values (`#0`, `FPE_NOOP` look
SDK-specific and are recorded, not asserted), frames content, Dart routes on a device, a crash during background or before the first frame, other iOS
versions or devices, SIGBUS (10) on iOS (see above), whether the first launch on a clean install (with the prompt) differs from a keep-install launch beyond the
prompt.

**Backend symbolizer against a Dart 3.14 build (2026-11-18, offline, no device):** the real `exception` entry and `app.android-arm64.symbols` of the Flutter 3.50.0
release build above, run through `dart_symbolize` built from `bugsee-symbolication-aux` `dart-symbolize/` (commit `06db90f`, Dart SDK 2.19.6 as in its `version.txt`,
and also Dart 3.14). Fed what the worker feeds it (`symbolfiles/flutter.py` of `bugsee-background-worker` cuts everything before the first `#00`; untrimmed and trimmed lines both tried, same result), it
returns `Bugsee.logUnhandledException (.../bugsee.dart:638:30)`, `_command`, `_poll`. Fed the stack WITH its header it crashes (`Bad state: Future already
completed`), as `flutter symbolize` 3.50 (`native_stack_traces` 0.6.1) does ("Cannot locate isolate instructions section in snapshot"). Cause: Dart 3.14
symbols have `_kDartSnapshotText`, not `_kDartIsolateSnapshotInstructions` (`llvm-objdump --syms`), which the header-based path of the older decoders needs;
the `native_stack_traces` 0.7.0 changelog reads "Adjusts snapshot readers for the removal of the VM isolate." (0.7.0 itself was not run; 0.6.1 fails, 0.7.1 works), and `dart_symbolize` with 0.7.1 in place of its vendored
copy decodes both forms. The backend works today only because it strips the header and the frames carry a `virt` address. The full table is in
`doc/exceptions.md`. The regression fixture is `test/fixtures/exceptions/real_obfuscated_android_arm64_dart_3_14_trace.txt`.
iOS: a Flutter 3.50 `--release --obfuscate --split-debug-info` build (`example`, `lib/verify_main.dart`, no codesign) writes `app.ios-arm64.symbols`, a Mach-O
file (`file`: "Mach-O 64-bit dSYM companion file arm64") with `LC_UUID` and the symbols `_kDartSnapshotText`, `_kDartSnapshotData` and `_kDartSnapshotBss`.
`dart_symbolize` (and 0.7.1) read it: a SYNTHETIC header-less stack (frames written by hand from the file's own symbol addresses, not captured on a phone)
came out as the right functions with file:line. A real iOS stack and the iOS upload path were measured later, in scenario 11 (a real device stack, uploaded and read back: the `.symbols` decode, but a
second record with the same UUID can make the backend pick the wrong file, see there).

### 11. End-to-end symbolication against a Bugsee backend (2026-11-23)

`scripts/device/e2e_symbolication.dart` (app: `example/lib/e2e_main.dart`; parsers and verdicts: `scripts/device/core/e2e.dart`, tested in
`test/device_harness_test.dart`; `scripts/device/symbols_logged.py` runs the pinned `symbols.py` unchanged and prints each HTTP exchange). No mock.

```bash
# Tokens never go on a command line (shell history, `ps`) or into the repository. Keep them in a private file
# outside the repository (chmod 600) that exports the variables, or type them without echo:
#   set -a; . "$HOME/.config/bugsee-e2e.env"; set +a        # the file holds BUGSEE_IOS_TOKEN=..., BUGSEE_SERVER_TOKEN=..., the app ids
#   read -rs BUGSEE_IOS_TOKEN; export BUGSEE_IOS_TOKEN       # or this, per variable
# Variables the run reads (all optional except the token and the device):
#   BUGSEE_ENDPOINT (e.g. https://apidev.bugsee.com; empty = the default, production, endpoint)
#   BUGSEE_SERVER_TOKEN and BUGSEE_IOS_APP_ID / BUGSEE_ANDROID_APP_ID (to read the backend back; without them the run ends UNVERIFIED, exit 3, never a pass)
#   E2E_DEVLOCK (a device lock script: acquire|release <device> ...; or --devlock <script>, or --no-lock)
dart scripts/device/e2e_symbolication.dart ios --udid "$UDID"            # [--run-id <id>]; --reuse-build needs --run-id and the same app and endpoint
dart scripts/device/e2e_symbolication.dart android --serial "$SERIAL"
```

Per run: a unique build string `9.YYMMDD.HHMMSS` (build name and the symbols' `-v`; a fresh run whose work directory exists is refused, `--reuse-build` needs the `--run-id`); a release build with `--obfuscate --split-debug-info` of the e2e app,
staged into the run's work directory (the app or APK and the dSYMs: install and upload use the staged copy; two runs must not build in one checkout at the same time);
guards that make a run INVALID: the `.symbols` are the platform's format (ELF / Mach-O), the app's own function name is not in the shipped binary (`strings` on
`App.framework/App` for iOS, on `libapp.so` of the APK for Android), the pinned `symbols.py` hash, the upload (see below), the device lock, four launches all `launched` in release mode, two crashes after which the
process really ended of that crash (iOS: devicectl's `terminated due to signal 11` for `ffi-segv`, signal 6 or a non-zero exit with no signal for `objc-main`; Android: the pid of the launch is gone, confirmed by a successful `pidof` and not an adb failure, and logcat has `Fatal signal 11` or the `FATAL EXCEPTION` for that pid). A failed check unwinds through the cleanup (console saved, a failure to save it does not stop the uninstall, app uninstalled, `example/android/bugsee.properties` restored, its mode narrowed to 600 while it holds the token and put back after: a developer's own file is saved to the work directory and put back, a file the run created is deleted) before the exit; an unexpected exception is logged redacted (`FAILED: ...`). **Ctrl-C or kill runs only the synchronous subset**: it kills the active devicectl child, restores `bugsee.properties`, releases the lock and writes `e2e-run.log`; it does not uninstall the app, does not save `console.txt`, and a `flutter build` already running keeps running. A run killed with SIGKILL can leave a token-bearing `example/android/bugsee.properties`, which the next run saves as the developer's own and restores: delete it by hand. The app (`e2e_main.dart`) keeps a phase counter in its temp directory: launch 1 reports a handled error, an uncaught error and `logUnhandledException`
from three sites named `e2eHandledSite`, `e2eUncaughtThrower`, `e2eUnhandledSite`; launch 2 dies of `ffi-segv`; launch 3 (uploads the recovered report) dies of `objc-main`
(iOS) / `java-main` (Android); launch 4 uploads the last recovered report. The token is a `--dart-define` of a local build (an environment variable given to
`devicectl process launch` did not reach the app; Android has none), never printed or saved: every line passes `redact`.

**Where the tokens work: not the default endpoint.** Both app tokens given for this run are unknown to `api.bugsee.com` (`POST /v2/apps/<token>/symbols` answered
`{"ok":false,"error":{"type":"ApplicationNotFoundError","code":11001}}`, with HTTP 200) and known to `https://apidev.bugsee.com` (`ok:true`, a presigned URL). So everything
below went to **apidev**, through `BUGSEE_ENDPOINT` (SDK option `endpoint`, `symbols.py -e`, `bugsee-cli`, Gradle `plugin.endpoint`). A run against production needs production
tokens. The two probe requests of that discovery left one empty `uploading` symbol record per app on apidev (uuid `e2e-probe-0000`, version `probe`).

| | iPhone XS, iOS 18.7.9 (UDID `...2641002E`) | HONOR WOD-LX1 (`AMRJCP4718402860`) |
| --- | --- | --- |
| build | `9.1123.2012`, Flutter 3.50.0, release, `--obfuscate`; guard: `e2eHandledSite` absent from `App` | `9.1123.2016`, Flutter 3.50.0, JDK 21, release APK, R8, `--obfuscate` |
| Dart symbols (`symbols.py`, `-t <token> -v <build> -d <dir> -e https://apidev.bugsee.com/v2/`) | `app.ios-arm64.symbols` (Mach-O, 1.9 MB): POST `.../symbols` 200, PUT of the zip to the presigned S3 URL 200 (`symbols.py` exit 0) | three files (`android-arm64`, `-arm`, `-x64`, ELF): POST 200, PUT 200 (4.2 MB zip), exit 0 |
| native symbols | `bugsee-cli debug-files upload --type dsym` (0.8.0, `BUGSEE_APP_TOKEN` in the environment): exit 0; `App`, `Runner`, `Flutter` dSYMs uploaded, `Bugsee` already on the server | Bugsee Gradle plugin 4.1.1 (`ndk { enabled }`, token and `plugin.endpoint` in the Gradle-root `bugsee.properties`, restored or removed after the build): the plugin prints nothing at the default log level; the R8 `mapping.txt` record exists on the backend, which confirms the plugin's Java MAPPING upload only. The native (NDK) symbol upload is **not confirmed** by it (a mapping file says nothing about native libraries) |
| device run | 4 launches, all `launched`; launch 2 died of signal 11, launch 3 ended after the Objective-C exception (devicectl exit 1); the app's events and the SDK's report-handler lines show reports built in launches 1 to 3 | the same sequence; both crash launches ended (the process was gone within 90 s) |
| the backend's answer (read 2026-11-24, see below) | Dart native crash and Swift crash symbolicated; **Dart exceptions stay raw (backend bug, fix in review)** | everything symbolicated |

**None of the checks added to the e2e run after its first device run has ever run on a device or against the backend: the read-back (`readBack`), the Android pid and logcat evidence, the iOS signal 6 / exit-code rule, the Android `libapp.so` obfuscation guard, the per-run staging and the `bugsee.properties` guard.** Unit tests cover the pure parts only. The verdict reads the issues of the run's build, polls until the expected content is there or `--readback-wait-minutes` (default 15) passes, and is VERIFIED only when two consecutive passes (30 s apart) agree on it and the same number of reports, and no report holds a raw frame, each expected Dart name is in a symbolicated frame (a line with `file:line`; a name in a summary does not count), and a native frame of the ffi crash (`crash_lab.dart`) and one of the platform crash (`AppDelegate.swift` / `MainActivity.java`) are in reports of their own. It reads the recordings of every issue of the build that belong to THIS run (a recording's own `environment.app.version` and `build`; without a version its `created_on` must be at or after the run's start less 2 minutes; with neither the run is INVALID, not verified), so a recording of an older run (or, for a reused build, an earlier attempt) inside the same issue neither satisfies nor fails the verdict. The build is compared as a number (`093015` is the `93015` Android stores as versionCode; a non-number is INVALID, not ignored); `created_on` must carry an offset (the API prints `Z`), else it counts as unknown (INVALID), and a reused build needs it; the 2-minute margin is `recordingMargin` in `core/e2e.dart` (clock skew). A recording whose list entry says `crash_report: false` (the appserver's `formatRecording`; the report endpoint would answer `RecordingDoesNotHaveCrashData`) is skipped, not counted as unread; the HTTP status of that answer was not determined from source, so any other failed read (timeout, 5xx, transport, any status) stays unread and fail-closed. A recording that could not be read, or whose issue's list could not, makes the pass NOT CONFIRMED (the verdict is never given on the readable subset), and no confirming pass is scheduled past the deadline (the run then ends NOT CONFIRMED and says it was one pass short). Expected names are matched as whole identifiers in a frame. A reused build must target the same platform, endpoint and app token (a SHA-256 of the token is stored with the staged build, never the token; written with mode 600, as is the Gradle properties file while it holds the token, by `core/props_guard.dart`, which never deletes a file that existed). It reads from one page of 100 issues, and says so when the page is full (the partner API's paging was not verified here). The results below were read by hand.

**Backend read-back (2026-11-24, via the Bugsee staging MCP, apidev; apps `AFTA` Android flutter and `IFTA` iOS flutter, issues of the two versions above).**

* **Android (9.1123.2016): everything symbolicated**, all five issues `ready`: the unhandled Dart crash shows `Bugsee.logUnhandledException (.../lib/src/bugsee.dart:638:30)`,
  `e2eUnhandledSite (.../e2e_main.dart:52:16)`, `_phases (.../e2e_main.dart:114:13)`; the handled errors show `e2eHandledSite`, `e2eUncaughtThrower`; the Java crash resolves
  to `MainActivity.java:28` (the R8 `mapping.txt` record exists: the Gradle plugin's Java mapping upload works; that says nothing about its native/NDK symbol upload, which is not confirmed); the ffi segfault to `crash (crash_lab.dart:54)`. A Dart 3.14 stack
  with the header stripped by the worker decodes.
* **iOS (9.1123.2012): native crashes symbolicated, Dart exceptions not.** The ffi segfault shows the full chain from `crash (crash_lab.dart:54)` through the Flutter engine
  to UIKit and the Swift crash `AppDelegate.swift:32`. The Dart exceptions (`IFTA-5` handled, `IFTA-6` unhandled) are `ready` but still raw
  (`#00 abs ... _kDartSnapshotText+0x18a287`).
* **Root cause (reproduced with the worker's own code against staging data):** two ready symbol records share the build-id UUID `44db9327...`, both format `dsym`: the
  `App.framework` dSYM and `app.ios-arm64.symbols`. The appserver batch lookup (`formatBatch`) keeps one per format, returned the App dSYM, and `dart_symbolize` on a file without
  Dart information exits 0 echoing its input, so the issue was marked `ready` with raw frames. With the `.symbols` record the same crash document symbolicates. Nothing in the
  wrapper or the upload is at fault (both records are the correct files). Fixes in review: bugsee-appserver#280 (batch returns every record as `candidates`) and
  bugsee-background-worker#182 (tries each, accepts the first that decodes, warns when none does). Until both are deployed, an iOS Dart exception stays raw; not re-measured after the fixes.
* Not verified: the production backend (the tokens exist on apidev only); Flutter 3.41; whether iOS needs the App dSYM at all (it carries no Dart code: uploading only the
  `.symbols` file would also avoid the collision, untested).
* **What a user sees today** is in the README (symbols section) and `doc/exceptions.md` section 5: the documented iOS flow uploads both records.

Findings of the build of this check, each a fact about the toolchain and not about the wrapper:

* **`symbols.py` exits 0 when the registering POST is refused with a non-2xx status** (`_send_request` returns `None` and nothing is printed); it exits 1 with `ok:false` in a 200
  body (`ApplicationNotFoundError` above). The exit code alone is not proof of an upload: the harness requires the POST and the PUT, both 2xx, from the logged exchange.
* On iOS release `print` does not reach `devicectl --console`; `dart:io` `stdout` does. The e2e app writes both.
* Stopping a `devicectl --console` child terminates the app it launched, late: the next launch of the run was killed with SIGTERM 0.2 s after it started. The run waits 10 s.
* The pinned `symbols.py` needs the `requests` package (not installed by default) and prints a `SyntaxWarning` on a current Python (`'^\-+'`).

## Findings

### Defects

None in the wrapper that needed a fix in this PR. One thing the harness found in the example's supporting
files was fixed: `example/integration_test/support/mock_api.py` read request bodies by `Content-Length` only (the harness's
own reports use chunked uploads from `dart:io`); it now reads chunked bodies, and gained the endpoints the harness uses
(`/__cmd`, `/__event`, `/__events`, `/__mode`, `/__reset`, `/__plain`).

For follow-up (SDK or environment, not fixed here):

1. **(Fixed in Android 7.5.0, bugsee-android#316; see scenario 9.)** Android report screenshot was all black in the default SurfaceView render mode at 7.4.2: an SDK gap, root-caused and confirmed (scenario 9, with the SDK source references, the
   texture-mode experiment and the workaround). Issue text for bugsee-android is in the PR description.
2. **iOS: no crash recovery and no logged exceptions on a simulator** are SDK facts (documented in the SDK's source); listed
   here so a missing iOS recovery is never read as a wrapper defect. Everything about recovered iOS reports needs a physical iPhone.

### Doc claims corrected

* `PLAN.md` and `.claude/CLAUDE.md` said Android completes at once on a recovered report because the recovery path runs on
  a spawned `bugsee-report-handler-bounded` thread. That is the SDK's *early-crash* path (a second crash before the first
  `onResume`). A native-crash report recovered after a normal session runs on `BugseeReportHandlerThread` with the live
  window, Dart runs, and its edits land in the recovered bundle (scenario 3). Corrected in both. The workbook's table (Part 7.1.3)
  says "main" for Android: it is not main either (a spec gap, to report).

### Observations

* A debug build's SDK upload to a cleartext `http://10.0.2.2:<port>` endpoint fails before a request leaves
  (`ReportUploadFailedWithFutureRetry`, the bundle stays on the device); the release build's upload reached the mock, which refused it with 503, and the
  SDK dropped its copy. The harness reads both places.
* `adb root` works on the `google_apis` emulator image and not on Play Store images: release builds can only be inspected on the former.
* Status after a hot restart: the new isolate's synchronous `Bugsee.status` is `launched` two seconds after its `main()` (printed as
  `status-sync`), because the plugin replays the latest status when the isolate attaches; the app's own `lifecycleEvents`/`statusChanges`
  listeners, registered after that await, therefore see only later events (the same as on a cold start). `Bugsee.getStatus()` also answers `launched`.
* The Android screenshot flat black (Findings) is not the emulator's display: `adb exec-out screencap` of the same screen has mean colour
  (225, 211, 225).

## Not covered

* iOS on a device beyond the crash matrix: no iOS exception bundle (Dart routes) and no iOS profile run through this harness; the matrix's own
  not-covered list is under scenario 10 (iOS).
* Early-crash recovery on Android (a second crash before the first `onResume`: the bounded thread path), a crash while the app is
  in the background, a crash with the SDK stopped, ANR and exit-info recoveries.
* A handler that overruns the SDK's deadline, and a hot restart while a delivery is in flight.
* The Gradle plugin 4.0.6 broken arm (only the fixed arm was run; the detection is unit-tested).
* x86_64 and armeabi-v7a ABIs, a second display, rotation, split screen, a density change *during* a report.
* Server-side processing: the mock API stands in for the backend in scenarios 1 to 10. Scenario 11 (2026-11-23/24) ran against apidev and read the result back:
  Android (including Dart 3.14 stacks) and iOS native crashes are symbolicated, iOS Dart exceptions stayed raw because of the backend collision described there (fixes in review).
  The default (production) endpoint was not used: the given tokens exist on apidev only.
* Dart `Isolate` errors and `reportAsCrash: true` in a release build.

## Extending it

A scenario is a function over a `Run` (`scripts/device/core/experiment.dart`): `run.guard` for facts about the experiment, `run.expect` for results,
`run.note` for measurements. Put a new pure parser in `scripts/device/core/` with a test that shows it failing; add anything the harness
repeats from the repository (a name, a flag, a command) to the drift guards at the end of `test/device_harness_test.dart`.
