# Direct Interop spike (Pigeon native-interop mode, Flutter 3.50 / Dart 3.14)

Question: should 10.0 replace the Pigeon platform-channel bridge with Direct Interop? Answer from this spike: **not for 10.0**;
revisit when Pigeon's interop mode leaves preview. Measured 2026-11-12; sources: the
[3.50 post](https://flutter.dev/blog/whats-new-in-flutter-3-50), the [interop docs](https://docs.flutter.dev/interop) and the guide shipped in
Pigeon 30.0.2 (`native_interop_guide.md`). The spike app is the files in `doc/interop-spike/` (`.txt`, so analysis ignores them): a fresh
`flutter create` app with Pigeon 30.0.2 (we pin 29.0.11), `jni`, `objective_c`, `jnigen` 1.0.1, `ffigen`, `swift2objc`, `swiftgen`, one
`@HostApi` (ping, echo, an `Int32List` and a `List<int>` of 256), one `@FlutterApi`, one `@HostApi` that fires the FlutterApi from native.

## Measured (release builds, main isolate, awaited calls, 2000 calls after 200 warm-up, two rounds)

| | Android, Honor WOD-LX1 (Android 14) | iPhone XS (iOS 18.7.9) |
|---|---|---|
| `MethodChannel` ping / echo / 256 ints | 378 to 776 / 315 to 648 / 415 to 605 us | 30 / 30 / 30 to 39 us |
| interop ping / echo | 1.4 / 1.7 us | 0.6 to 0.7 / 1.1 to 1.2 us |
| interop `Int32List` 256 | 14 to 15 us | 1.6 to 1.8 us |
| interop `List<int>` 256 (buffered) | 132 to 139 us | 23 to 26 us |

The channel baseline is a plain `MethodChannel` (Pigeon's channel mode adds a codec of similar cost). Interop is two to three orders of
magnitude faster per call and the typed list is ten times faster than a `List<int>`. Both ran on the main thread (`thread()` returns `main`).
None of our paths is limited by call latency: secure rectangles, the view-hierarchy cache, network events and log lines publish at most
once per frame or per event, and the native SDK work dominates.

## Findings that decide it

1. **Preview.** The docs: "Pigeon with native interop is in preview and isn't stable for production use". The Pigeon example pins
   `objective_c` to a two-patch window because of a debug-validity bug on the simulator. A crash and bug SDK should not sit on that.
2. **Kotlin only on Android.** `useJni` generates Kotlin; our Android wrapper is Java (`Messages.java` and the wrapper classes). Adopting it
   means rewriting the Android side in Kotlin (or wrapping), which touches every area the device harness verified.
3. **Needs the toolchain at generation time.** JNIgen needs the compiled Kotlin and the Android SDK; FFIgen needs Xcode/LLVM. The generation
   is a two-pass loop (generate, compile, generate again: the first run fails with "Error running JNIgen" until the new classes compile).
4. **Native to Dart callbacks block the native thread.** `@FlutterApi` calls from a native worker thread worked on Android (the worker
   blocked about 1.5 ms until the main isolate ran the handler; from the main thread 3 ms). That is a hard conflict with our report-handler
   and view-hierarchy rules (the SDK calls us on the main thread and Dart's reply needs it; a blocking cross-thread call can deadlock).
   Our channel design never blocks.
5. **iPhone XS: registering a `@FlutterApi` hung** (`SpikeEvents.setUp` never returned in a release build on iOS 18.7.9; the host-API
   interop worked). Not diagnosed: it may be a spike error, but it is a failure a plain app hit on first use.
6. **Multi-engine.** The docs warn that registration routes to the most recent engine unless the engine is known; Pigeon 30 added per-engine
   keys (the generated Kotlin registrar takes the engine). Our wrapper fans out to every attached engine and replays state per receiver; the
   rules (and tests) for that are written for channels.
7. **Swift.** FFIgen reads Objective-C, so Swift needs `@objc` shapes; the iOS side of a SwiftPM-only plugin also needs the extra
   Objective-C target when a `.m` is generated.
8. **Version.** Interop wants Pigeon 30 (we pin 29.0.11); the pin is a decision in `native-versions.json`.

## What is worth trying later

* Typed-list payloads (`Int32List`) for secure rectangles, if interop reaches stable: it removes the one place where a `List<int>` is
  buffered. The same schema can generate both transports (`createWithNativeInteropApi()` next to the channel constructor), so a switch
  could be per API and reversible.
* Re-run this spike (the files in `doc/interop-spike/`) when Pigeon's interop mode is stable, on the Android phone and the iPhone, and
  add the multi-engine and report-handler cases before deciding.
