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
  | `reason` | the message (hashed into the worker's signature) |
  | `signature` | **read by both SDKs, not by the worker**: see below |
  | `frames` | `[{trace, module, user, data{source, member, line, column, package, library, isCore}}]`; `trace` is `member (location)`: the worker hashes the first non-hidden user frame's `trace` into the signature, and decides `user` itself from `(package:flutter` / `(dart:` |
  | `originalStackTrace` | `stack.toString()`: where the worker finds the **build id** and, for a non-symbolic stack, the frames it symbolicates |

  **`signature` is load-bearing although the worker ignores it.** Android hashes the carrier's class name, this
  key (`ExceptionSignature.updateMessageDigestFromThrowable`: `extractFromReason`) and the Java stack of the
  calling thread; iOS the name, this key (`BGSExceptionSignature.m` `extractSignatureFromReason`) and the exception's
  frames (none for an `NSException` made from a name and a reason). The Java stack and the name are the same for
  EVERY Dart error, so without this key every Dart error has one signature. That matters: Android sends it in
  `signatures` (`IssueReportingRequest.java:1366`), the appserver matches issues on `signatures: {$in}` before the
  worker looks at anything (`code/components/app/issue/issue.service.js:1355-1435`), and once the first Flutter issue reaches its recording
  limit every later Dart error of ANY type gets `SimilarCrashExistsError` (12003) and is dropped by the device
  (`ReportUploadExecutor.java:790-798`); past the server's hard cap (12004) the device blacklists that signature for good
  (`IssueReportingPreferences.storeBlacklistedReportSignature`) and sends no Dart error again. So the key is a
  SHA-1 (`exceptionSignature`) over the type, the first line of the reason with what varies between runs removed
  (hex addresses, UUIDs, numbers of three digits or more), and the top five user frames by location (a non-symbolic
  frame by its `virt` address and symbol, which are stable, not by `abs`, which moves with ASLR): different errors
  differ, one error on two days is one. 9.x hashed the application version too; the plugin cannot read it. Tests: the
  Dart builder (`test/exception_payload_test.dart`, group "the signature"), and the SDKs' OWN signature code fed
  the same documents (`ExceptionSignatureTest`, which calls `BugseeExceptionProcessor.generateSignature` of the
  shipped 7.4.2 AAR, and `BGSFlutterExceptionSignatureTests`, which calls `BGSExceptionSignature` of the pinned
  framework): equal errors share a signature, different ones do not, and without the key all of them would share one
  (both tests prove that too). Measured: the real bundles' `signatures` differ for every error
  (`test/fixtures/exceptions/android_7_4_2_crash_entry.json` keeps one). Keys are exactly the table's
  (`test/exception_payload_test.dart`, `test/exceptions_worker_contract_test.dart`).
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
file paths of the developer's machine are reduced to the file name; `signature` no longer hashes the application version; handled/unhandled go
through the SDKs' own APIs (9.x used `onUncaughtException(Thread, ...)`).

## 2. Public API

```dart
Future<bool> Bugsee.logException(Object error, [StackTrace? stackTrace])            // an error report
Future<bool> Bugsee.logUnhandledException(Object error, [StackTrace? stackTrace])   // a crash report
Future<bool> Bugsee.reportException(Object error, {StackTrace? stackTrace, bool handled = true, String? domain})
void Bugsee.installErrorHandlers({bool flutterErrors = true, bool platformErrors = true, bool isolateErrors = true, bool reportAsCrash = false})
void Bugsee.uninstallErrorHandlers();   bool Bugsee.errorHandlersInstalled;   bool Bugsee.errorHandlersActive
R? Bugsee.runGuarded<R>(R Function() body, {void Function(Object, StackTrace)? onError})
IsolateErrorListener Bugsee.listenToIsolateErrors(Isolate isolate)   // .cancel()
```

* `logException` / `logUnhandledException` mirror the SDKs' and React Native's; `Bugsee.logException(e)` works as in
  9.x and `catch (e, s) { Bugsee.logException(e, s); }` is the usual call. Dart cannot mix an optional positional
  stack with named options, so `domain` (and `handled` as a flag) live on `reportException`. **No severity**: neither
  SDK takes one for an exception (Android `ExceptionOptions` has `domain` and `skipFrames` only; iOS the same). Set it
  in a report handler (`Bugsee.setReportHandler`: it runs for error and crash reports). **No `skipFrames`**: the
  SDKs apply it to the Java/Objective-C stack of the carrier, which is not the app's; the Dart frames are in the document.
* `domain` (1 to 256 characters) is the SDK's grouping domain. iOS has no domain on its unhandled path: dropped there.
* Any object can be thrown in Dart: `error` is `Object`. A missing stack is `StackTrace.current` at the call, minus the
  plugin's own frame: by package name in a symbolic stack, and by position (exactly one, the three methods are
  `@pragma('vm:never-inline')`) in a non-symbolic one, where no name exists to match. Measured on a release
  `--obfuscate` arm64 build: `#0 Bugsee.logException`, `#1` the caller, for stack-less calls at two sites.
* The answer is whether the SDK was handed the error (section 3). A bad `domain` is a `BugseeArgumentException('domain')`;
  a refusal of the document by native names the document (`argument: 'error'`), never the domain; failures to reach
  native are `BugseeException`s; never because of `error` itself.

## 3. What each SDK does, before launch and after stop

| | Android 7.4.2 | iOS 7.0.0-beta7 |
|---|---|---|
| handled | `Bugsee.logException(Throwable, domain, skipFrames)`: an **error** report, built on the SDK's aux thread (`BugseeInternal.java:1339-1356`, `BugseeIssueReportingCoordinator.java:458`) | `+logException:reason:domain:skipFrames:completion:`: an error report (`Bugsee.m:1517-1575`) |
| unhandled | `Bugsee.logUnhandledException(Throwable, Map)`: a **crash** report, `isTerminating` false (the capture keeps running), written **synchronously on the calling thread**, which snapshots the capture ring ("up to a couple of seconds": `BugseeInternal.java:1358-1410`; the SDK's own comment names the Flutter cost: `BugseeIssueReportingCoordinator.java:329-346`) | `+logUnhandledException:reason:completion:`: writes a PLCrashReporter report to disk that the **next launch** sends, one at a time (`Bugsee.m:1578`, `BGSCrashManager.m:296`); with a debugger attached it falls back to the handled path with `handled=NO` |
| before launch | dropped, log line (`isRunningOrStaring`, `:1344`, `:1370`) | handled: dropped, `NSLog` (`Bugsee.m:1544`); **unhandled: not gated by the SDK** |
| after stop | dropped | handled: dropped; unhandled: **not gated** (the crash manager outlives a stop) |
| simulator | n/a | **nothing is filed** (`Bugsee.m:1555`, logs `logged exceptions are not filed on the simulator`) |

The wrapper queues nothing (same rule as every other call) and gates **both** paths on both platforms on the SDK
being Launching or Launched, so the answer `false` means "not handed over" and iOS's ungated unhandled path cannot
write a crash report with the SDK stopped.

**Threads.** The bridge method is `@async`. **Android** runs the SDK call on its own single daemon thread
(`ExceptionDispatcher`) with a bounded queue of 32: the SDK writes an unhandled report on the thread that calls it,
and on the platform thread a snapshot of up to a couple of seconds is jank or an ANR (the installed handlers allow ten
a minute). A full queue drops the call, counts it and answers `false`; the launch gate runs on that thread, when the
SDK call does; the reply goes back to the platform thread. **iOS** keeps the call on the main queue: the SDK's public
API reads UIKit state (the report is built with the view hierarchy), and nothing in its source says it may be called
elsewhere, so moving the PLCrashReporter write off main is not done blind; its cost on a device is **not measured**
(unhandled errors are rare by default now: section 4).

Measured on a device (`example/integration_test/exceptions_test.dart`): Android emulator API 29 (arm64) with a local
HTTP server standing in for the API, so the real bundles could be read: an error report for a handled call, a crash
report for `logUnhandledException`, error reports for a `FlutterError`, an uncaught error in the root zone, a guarded
zone and a spawned isolate (the default), a crash report with `reportAsCrash: true`; each bundle's crash.json has
`exception.name = com.bugsee.flutter.FlutterManagedException`, the document as `reason`, `handled` false/true,
`domain` for the handled call with a domain, and a DIFFERENT SDK `signatures` entry per error. All were also seen by the
report handler as `error`/`crash` reports. After `stop` and before `launch` both calls answered `false`. iOS 26.5
simulator: the calls reached the SDK (its log says it files nothing on a simulator). **Not verified: an iOS device**
(no device here; the next-launch delivery and the one-slot behaviour are read from source), the main-thread cost of
the iOS write, hot restart on a device, and the real server's processing (the worker module was run offline, section 1).

## 4. The installed handlers

`Bugsee.installErrorHandlers` is opt-in and never called by `launch`. Design, each point with a test
(`test/error_capture_test.dart`):

* **Chains, never replaces**: the handler that was installed (the app's, Crashlytics', Sentry's) is still called and
  its answer is returned; with none, `PlatformDispatcher.onError` answers `false`, so the engine reports as it would
  have. For `FlutterError.onError` ours runs first (it reports even if the previous handler throws). For
  `PlatformDispatcher.onError` the previous handler runs first, because its answer decides what the error is (below);
  the report is made in a `finally`, so it is made when that handler throws, and its exception goes on to the app.
* **Install AFTER the tools that assign these handlers.** Crashlytics' documented setup
  (`FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError`,
  `PlatformDispatcher.instance.onError = ...`) REPLACES whatever is there, so a Bugsee installed before it is dropped
  from the chain and reports nothing; Sentry's `init` wraps what is there and keeps ours. `Bugsee.errorHandlersInstalled`
  says only that it was called; **`Bugsee.errorHandlersActive`** says that ours are still the current handlers (false
  also when a tool wrapped them: that case reports whenever the wrapper calls through, and cannot be told from here), and
  a debug build prints a warning at `Bugsee.launch` when they are not.
* **Uninstall restores** the previous handlers only if ours are still the current ones. If another tool wrapped ours
  since, they cannot be unlinked: ours turn into inert pass-throughs and the chain below keeps running.
* **Idempotent**: a second install does nothing. **Hot restart** is a new isolate: statics are fresh, nothing to clean.
* **Once per error, and floods are limited**: the same throw arriving by two routes within a second (an uncaught
  root-zone error reaches `PlatformDispatcher.onError` and the isolate listener; a thrown `String` in `runGuarded` is
  seen by the zone and by `FlutterError.reportError`) is ONE report and is neither counted as suppressed nor warned
  about: the object by identity (an Expando holding WHEN it was seen, so `throw const FormatException('x')`, the same
  object every time, is not remembered for good), anything else by fingerprint. The fingerprint is the first line of the
  reason and the top frames, so the object route (a `FlutterError`'s summary) and the isolate-text route (its whole
  `toString`) agree. After that the same fingerprint at most once in 30 s, at most 10 reports in 60 s, 64 fingerprints
  remembered (a render error that repeats every frame opens one report). The clock is a monotonic `Stopwatch`: a wall
  clock moved backwards would never let the window empty. Explicit `logException` is not limited.
* **Never throws, never blocks**: our part of each handler is guarded; the report is sent without waiting and a failure
  is swallowed; an error raised while reporting does not report itself.
* **Error reports by default (`reportAsCrash: false`), crash reports on request.** A Dart error never ends the app
  (neither SDK terminates it); React Native files only FATAL errors as crashes (`handlers.ts:5-7`); a crash report counts
  against crash-free sessions, so every non-silent `FlutterError` (an image failing to load offline) would; and on iOS
  each unhandled call replaces the single stored crash report (`BGSCrashManager.m:308`), so ten a minute still deliver
  only the last, at the next launch. An error the previous `PlatformDispatcher` handler answers `true` for (the app
  handled it) is never a crash, whatever the flag. Neither SDK has an "unhandled but not a crash" call (Android's
  internal `asHandled` is not public), so the handled error path is used. 9.x reported `FlutterError.onError` as
  unhandled: `reportAsCrash: true` restores that, and the default is a one-line flip (`installErrorHandlers`, the
  example screen, `ErrorCapture.install`). `FlutterErrorDetails.silent` errors are skipped. Nothing is reported while the
  last launch made through `Bugsee.launch` had `detect.crash: false` (an auto-init or native launch is not seen: default on).
* **Privacy**: only the exception and its stack are read from `FlutterErrorDetails`: not `informationCollector` (the
  widget trees), `context` or `library`. A `FlutterError` contributes its **summary**; its full message carries the
  framework's diagnostics (widget descriptions, property dumps) and unstable text. Any other object contributes its
  `toString()`, which is whatever the app put in its error (the same as the native SDKs report for their exceptions;
  the SDK's own filters do not apply to exception text). File paths are reduced to the file name.
* **Zones and isolates**: `FlutterError.onError` and `PlatformDispatcher.onError` are the framework's; errors in a zone the
  app creates need `Bugsee.runGuarded`, in isolates it spawns `listenToIsolateErrors` (start the isolate paused, listen,
  resume). The root isolate listener is installed with `isolateErrors`; on Android API 29 an uncaught root-zone error
  reached the SDK once.

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
* Android: the SDK call runs on the plugin's own thread (bounded queue of 32, drops and counts beyond it).
* iOS: the SDK call runs on the main queue; the PLCrashReporter write's cost is not measured.
* An error before `launch` (or after `stop`) is dropped, not queued; install the handlers before `launch` anyway, they
  cost nothing until an error happens, but the first reports start when the SDK does.
* A launch made natively (Android manifest auto-init) is not seen by `detect.crash` gating.
* Several engines or isolates: the handlers are Dart statics of one isolate; an engine started later needs its own install.
* The document's `signature` does not include the application version (the plugin cannot read it): the same error in two app versions is one issue.
* A custom exception class of an obfuscated build whose message does not start with its name is reported as `Exception`
  or the obfuscated name; the stack is symbolicated regardless.
