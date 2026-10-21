# Dart errors (Phase 5a)

How a Dart error reaches the Bugsee backend, what the two SDKs do with it, what the installed handlers
do (and never do), and how an obfuscated build is symbolicated. Everything below was read from source
and, where it says so, measured on a device. Source refs: worker `bugsee/worker` @ `0b987619`
(`crash/managed/__init__.py`, `crash/managed/dart.py`, `crash/managed/common.py`, `symbolfiles/flutter.py`,
`jobs/symbols.py`), Android SDK `v7.4.2` (`3b7af6371`), iOS SDK `origin/nextgen` (`0581aa02c`, the 7.0.0-beta7
headers), the 9.x plugin (`origin/release`: `lib/src/exceptions*.dart`, `scripts/symbols.py`).

## 1. The backend contract

The worker routes on a literal and parses a JSON document; nothing else about a Flutter exception is
negotiated.

* **Routing** (`crash/managed/__init__.py:37`, `crash/processors/__init__.py:30`): an exception is Flutter when
  `'FlutterManagedException' in name`, or `in reason`, or `type == 'flutter'`. So the carrier is named
  `FlutterManagedException` on both platforms (Android: the class `com.bugsee.flutter.FlutterManagedException`;
  iOS: the `NSException` name) and the document itself says `"internalType":"FlutterManagedException"`, so a
  build that renamed the Android class (R8) is still routed by the reason. `android/consumer-rules.pro` keeps the
  name (`-keepnames`; seen kept in a release build's `mapping.txt`). **Never rename it.**
* **The document** (`dart.py:159-176`) is the exception's reason: the SDK writes the carrier's message verbatim
  (Android `ExceptionSerializer.java:147`; iOS `reason`). The worker strips an optional `...FlutterManagedException:`
  prefix and anything before the first `{` (an obfuscated build has no readable prefix), then `json.loads`:

  | key | used for |
  |---|---|
  | `internalType` | routing fallback (above) |
  | `name` | the exception type the dashboard shows and the signature hashes |
  | `reason` | the message (hashed into the signature) |
  | `frames` | `[{trace, module, user, data{source, member, line, column, package, library, isCore}}]`; `trace` is `member (location)`: the worker hashes the first non-hidden user frame's `trace` into the signature, and decides `user` itself from `(package:flutter` / `(dart:` |
  | `originalStackTrace` | `stack.toString()`: where the worker finds the **build id** and, for a non-symbolic stack, the frames it symbolicates |

  9.x also sent `signature` (a SHA-1 of the app version and the locations): the worker never reads it, so it is
  gone. Keys are exactly those (`test/exception_payload_test.dart`, `test/exceptions_worker_contract_test.dart`).
* **Handled or not** is not in the document: the worker reads it from crash.json (`dart.py:154`:
  `is_handled`/`handled`), which each SDK writes from the call it received. Handled exceptions hash the word
  `handled` into the signature and the summary reads `Handled <type> at <location>` (`common.py`, `dart.py:243`).
* **Symbolication** (`dart.py:188-197`): the build id is `build_id: '...'` in `originalStackTrace` (else in the first
  nine frames); the symbols are looked up by it (`api.get_symbol_files(org, app, [{'uuid': build_id}])`) and the
  trace goes through `dart_symbolize` (`symbolfiles/flutter.py`) after cutting everything before `#00`. A stack that
  has no `#00` (a symbolic one) is used as the frames in the document.
* Verified three ways: the rules ported into `test/exceptions_worker_contract_test.dart`; the worker's real
  `dart.py`/`common.py` run on **entries written by the real Android SDK** (`scripts/verify_worker_contract.py`, local,
  needs a worker checkout: type `flutter`, name, reason, frames and summary come out); and a stack from a real
  obfuscated release build symbolized with the worker's own `dart_symbolize` (section 5).

What differs from 9.x, deliberately: a `FlutterError` contributes its summary only (section 4); the type table
checks `IndexError`/`RangeError` before `ArgumentError` and `FlutterError` before `AssertionError` (9.x checked them
after their superclasses, so they never matched); `AsyncError` is `AsyncError` (9.x said `FutureTimeout`); a string
that arrives from an isolate listener is typed by the VM's own message prefixes instead of by building sample errors;
file paths of the developer's machine are reduced to the file name; `signature` is not sent; handled/unhandled go
through the SDKs' own APIs (9.x used `onUncaughtException(Thread, ...)`).

## 2. Public API

```dart
Future<bool> Bugsee.logException(Object error, StackTrace? stackTrace, {bool handled = true, String? domain})
void Bugsee.installErrorHandlers({bool flutterErrors = true, bool platformErrors = true, bool isolateErrors = true, bool reportAsCrash = true})
void Bugsee.uninstallErrorHandlers();   bool Bugsee.errorHandlersInstalled
R? Bugsee.runGuarded<R>(R Function() body, {void Function(Object, StackTrace)? onError})
IsolateErrorListener Bugsee.listenToIsolateErrors(Isolate isolate)   // .cancel()
```

* `logException` mirrors the SDKs' `logException`/`logUnhandledException` and RN's. **No severity**: neither SDK
  takes one for an exception (Android `ExceptionOptions` has `domain` and `skipFrames` only; iOS the same). Set it
  in a report handler (`Bugsee.setReportHandler`: it runs for error and crash reports). **No `skipFrames`**: the
  SDKs apply it to the Java/Objective-C stack of the carrier, which is not the app's; the Dart frames are in the document.
* `domain` (1 to 256 characters) is the SDK's grouping domain. iOS has no domain on its unhandled path: dropped there.
* Any object can be thrown in Dart: `error` is `Object`. A `null` stack takes `StackTrace.current` at the call, minus the plugin's own leading frames.
* The answer is whether the SDK was handed the error (section 3). Argument errors (`domain`) are
  `BugseeArgumentException`s, failures to reach native `BugseeException`s; never because of `error` itself.

## 3. What each SDK does, before launch and after stop

| | Android 7.4.2 | iOS 7.0.0-beta7 |
|---|---|---|
| handled | `Bugsee.logException(Throwable, domain, skipFrames)`: an **error** report, built on the SDK's aux thread (`BugseeInternal.java:1339-1356`, `BugseeIssueReportingCoordinator.java:458`) | `+logException:reason:domain:skipFrames:completion:`: an error report (`Bugsee.m:1517-1575`) |
| unhandled | `Bugsee.logUnhandledException(Throwable, Map)`: a **crash** report, `isTerminating` false (the capture keeps running), written **synchronously on the calling (main) thread** (`BugseeInternal.java:1358-1410`; the SDK's own comment names the Flutter cost and the main-thread I/O: `BugseeIssueReportingCoordinator.java:338`) | `+logUnhandledException:reason:completion:`: writes a PLCrashReporter report to disk that the **next launch** sends, one at a time (`Bugsee.m:1578`, `BGSCrashManager.m:296`); with a debugger attached it falls back to the handled path with `handled=NO` |
| before launch | dropped, log line (`isRunningOrStaring`, `:1344`, `:1370`) | handled: dropped, `NSLog` (`Bugsee.m:1544`); **unhandled: not gated by the SDK** |
| after stop | dropped | handled: dropped; unhandled: **not gated** (the crash manager outlives a stop) |
| simulator | n/a | **nothing is filed** (`Bugsee.m:1555`, logs `logged exceptions are not filed on the simulator`) |

The wrapper queues nothing (same rule as every other call) and gates **both** paths on both platforms on the SDK
being Launching or Launched, so the answer `false` means "not handed over" and iOS's ungated unhandled path cannot
write a crash report with the SDK stopped. A call made while launched and answered `true` can still be dropped by
the SDK later (a blacklisted signature: the SDK computes its signature from the carrier, which is the same for every
Dart error, and the dashboard's ignore list is server-side; **ignoring a Flutter issue in the dashboard does not
reach the device**).

Measured on a device (`example/integration_test/exceptions_test.dart`): Android emulator API 29 (arm64) with a local
HTTP server standing in for the API, so the real bundles could be read: an error report for a handled call, crash
reports for an unhandled call, a `FlutterError`, an uncaught error in the root zone, a guarded zone and a spawned
isolate; each bundle's crash.json has `exception.name = com.bugsee.flutter.FlutterManagedException`, the document as
`reason`, `handled` false/true, `domain` for the handled call with a domain. All of those were also seen by the
report handler as `error`/`crash` reports. After `stop` and before `launch` both calls answered `false`. iOS 26.5
simulator: the calls reached the SDK (its log says it files nothing on a simulator). **Not verified: an iOS device**
(no device here; the next-launch delivery and the one-slot behaviour are read from source), the main-thread cost on
a real Android device, and the real server's processing (the worker module was run offline, section 1).

## 4. The installed handlers

`Bugsee.installErrorHandlers` is opt-in and never called by `launch`. Design, each point with a test
(`test/error_capture_test.dart`):

* **Chains, never replaces**: ours runs first, then the handler that was installed (the app's, Crashlytics',
  Sentry's), whatever ours did (it runs even if reporting threw). `PlatformDispatcher.onError` returns the previous
  handler's answer; with none it answers `false`, so the engine reports as it would have. An exception of the
  previous handler is the app's: not swallowed.
* **Uninstall restores** the previous handlers only if ours are still the current ones. If another tool wrapped ours
  since, they cannot be unlinked: ours turn into inert pass-throughs and the chain below keeps running.
* **Idempotent**: a second install does nothing. **Hot restart** is a new isolate: statics are fresh, nothing to clean.
* **Once per error**: an object is reported once per process (Expando); text from an isolate listener and anything
  else by fingerprint (reason + top frames), so the same error through `FlutterError` and an isolate listener is one
  report. The same fingerprint at most once in 30 s, at most 10 reports in 60 s, 64 fingerprints remembered (a render
  error that repeats every frame opens one report). Explicit `logException` is not limited.
* **Never throws, never blocks**: our part of each handler is guarded; the report is sent without waiting and a failure
  is swallowed; an error raised while reporting does not report itself.
* **Unhandled**: reported as **crash** reports by default (what 9.x did for `FlutterError.onError`, what RN does for
  fatal errors and what the Android SDK documents Flutter's hooks as); `reportAsCrash: false` files error reports. Costs, from
  section 3: Android does disk I/O on the main thread per crash report (hence the limiter), iOS delivers at the next
  launch and keeps one. `FlutterErrorDetails.silent` errors are skipped. Nothing is reported while the last launch
  made through `Bugsee.launch` had `detect.crash: false` (an auto-init or native launch is not seen: default on).
* **Privacy**: only the exception and its stack are read from `FlutterErrorDetails`: not `informationCollector` (the
  widget trees), `context` or `library`. A `FlutterError` contributes its **summary**; its full message carries the
  framework's diagnostics (widget descriptions, property dumps) and unstable text. Any other object contributes its
  `toString()`, which is whatever the app put in its error (the same as the native SDKs report for their exceptions;
  the SDK's own filters do not apply to exception text). File paths are reduced to the file name.
* **Zones and isolates**: `FlutterError.onError` and `PlatformDispatcher.onError` are the framework's; errors in a zone the
  app creates need `Bugsee.runGuarded`, in isolates it spawns `listenToIsolateErrors` (start the isolate paused, listen,
  resume). The root isolate listener is installed with `isolateErrors`; on Android API 29 an uncaught root-zone error
  reached the report once, not twice.

## 5. Obfuscation and `--split-debug-info`

A release build with `--split-debug-info` (with or without `--obfuscate`) prints stacks in the VM's non-symbolic
format: a header (`build_id: '...'`, the DSO bases) and `#00 abs ... virt ... _kDartIsolateSnapshotInstructions+0x...`
lines. The wrapper sends `stack.toString()` **byte for byte** in `originalStackTrace` (cut at a line boundary above
64 KiB, header first), one frame per `#NN` line; it never rewrites it. The backend finds the build id, fetches the
build's symbols and symbolizes. `--obfuscate` also renames classes: the type table uses `is` checks, and an unknown
type is named from its message when that starts with `Name:` (the convention of `Exception.toString`), else it is the
obfuscated runtime type (`bx`).

**Uploading the symbols.** The bugsee-cli does not do Flutter yet (its README lists Flutter as planned; `--type elf`
is for NDK libraries and needs a `--uuid`), and this package does not ship an uploader. The legacy protocol the 9.x
plugin used is still what the backend takes (`appserver` `symbols.service.js` accepts its single-element `uuid`
array; `worker/jobs/symbols.py` reads the zip's `manifest.json`, `target: flutter`, and parses each `.symbols` file as
ELF itself to get the build id): build, then run the 9.x script with the app token:

```bash
flutter build apk --release --obfuscate --split-debug-info=build/symbols     # also: ios, appbundle
git show origin/release:scripts/symbols.py > symbols.py    # or the copy in a 9.x release of the package
python3 symbols.py --token <APP_TOKEN> --version <pubspec version> --symdir build/symbols [--endpoint https://api.bugsee.com/v2/]
```

It zips `build/symbols/*.symbols` with a manifest (`{'target':'flutter','items':[{arch, uuid, entry, version, build}]}`),
`POST {endpoint}apps/{token}/symbols` (`{uuid, version, build}`), then `PUT`s the zip to the presigned URL it
returns. Keep the symbols of every release you ship; the build id ties a stack to them.

**Verifying a build's symbols against a captured stack, offline** (the same tool the worker runs):

```bash
dart scripts/verify_symbolization.dart --symbols build/symbols/app.android-arm64.symbols \
   --entry <crash.json exception entry or a trace.txt> --expect main,level1 \
   [--tool <dart-symbolize>/dist/Darwin-arm64/dart_symbolize]
```

Measured: a release arm64 build of a probe app (`--obfuscate --split-debug-info`) threw an error through
`Bugsee.logException` and the root-zone hook on the emulator; the bundle was read; its `originalStackTrace` (vendored:
`test/fixtures/exceptions/real_obfuscated_android_arm64_trace.txt`, the whole entry in
`android_7_4_2_obfuscated_entry.json`) has build id `7a3ef930...`, which is inside that build's `.symbols` file, and
both `dart_symbolize` (worker's tool) and `flutter symbolize` turn it into `level3 / level2 / level1 (obf_main.dart:12..14)`.
The same script fails (`build id ... is another build's symbols`) with another build's symbols file. The symbols file
is not committed (it holds the build machine's paths).

## 6. Limits (known, not bugs)

* iOS: the simulator files nothing; an unhandled error is a crash report delivered at the next launch, one at a time (source-read).
* Android: an unhandled error writes its report on the main thread; the limiter is what bounds it.
* An error before `launch` (or after `stop`) is dropped, not queued; install the handlers before `launch` anyway, they
  cost nothing until an error happens, but the first reports start when the SDK does.
* A launch made natively (Android manifest auto-init) is not seen by `detect.crash` gating.
* Several engines or isolates: the handlers are Dart statics of one isolate; an engine started later needs its own install.
* The SDK's own signature (blacklist) cannot tell Dart errors apart (section 3).
* A custom exception class of an obfuscated build whose message does not start with its name is reported as `Exception`
  or the obfuscated name; the stack is symbolicated regardless.
