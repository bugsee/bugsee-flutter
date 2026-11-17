# Direct Interop spike (Pigeon native-interop mode, Flutter 3.50 / Dart 3.14)

Question: should 10.0 replace the Pigeon platform-channel bridge with Direct Interop? Answer for **Pigeon's interop mode** (the first spike,
2026-11-12): **not for 10.0**, revisit when it leaves preview. Answer for the **stable generators** (JNIgen and FFIgen without Pigeon, the
second spike below): **not for 10.0 either**, and a candidate for the secure-rectangle store once a frame-capture measurement shows a gain (that
measurement has not been made). Measured 2026-11-12; sources: the
[3.50 post](https://flutter.dev/blog/whats-new-in-flutter-3-50), the [interop docs](https://docs.flutter.dev/interop) and the guide shipped in
Pigeon 30.0.2 (`native_interop_guide.md`). The spike app is the files in `doc/interop-spike/` (`.txt`, so analysis ignores them): a fresh
`flutter create` app with Pigeon 30.0.2 (we pin 29.x, `native-versions.json` `pigeon.version`), `jni`, `objective_c`, `jnigen` 1.0.1, `ffigen`, `swift2objc`, `swiftgen`, one
`@HostApi` (ping, echo, an `Int32List` and a `List<int>` of 256), one `@FlutterApi`, one `@HostApi` that fires the FlutterApi from native.

## Measured (release builds, main isolate, awaited calls, 2000 calls after 200 warm-up, two rounds)

| | Android, Honor WOD-LX1 (Android 14) | iPhone XS (iOS 18.7.9) |
|---|---|---|
| `MethodChannel` ping / echo / 256 ints | 378 to 776 / 315 to 648 / 415 to 605 us | 30 / 30 / 30 to 39 us |
| interop ping / echo | 1.4 / 1.7 us | 0.6 to 0.7 / 1.1 to 1.2 us |
| interop `Int32List` 256 | 14 to 15 us | 1.6 to 1.8 us |
| interop `List<int>` 256 (buffered) | 132 to 139 us | 23 to 26 us |

The channel baseline is a plain `MethodChannel` (Pigeon's channel mode adds a codec of similar cost); the channel calls are awaited futures and the
interop calls are synchronous on the main isolate, so the ratio overstates what an app would see. Scalar calls are about 250 to 550 times faster on
Android and 20 to 45 times on the iPhone; a `List` payload narrows the gap to 3 to 4 times on Android and 1.3 to 1.7 times on the iPhone (it is
buffered), and the typed list is about ten times faster than the `List<int>` on both. Both ran on the main thread (`thread()` returns `main`).
None of our paths is limited by call latency: secure rectangles, the view-hierarchy cache, network events and log lines publish at most
once per frame or per event, and the native SDK work dominates.

## Findings that decide it

1. **Preview.** The docs: "Pigeon with native interop is in preview and isn't stable for production use". The Pigeon example pins
   `objective_c` to a two-patch window because of a debug-validity bug on the simulator. A crash and bug SDK should not sit on that.
2. **Kotlin only on Android.** `useJni` generates Kotlin; our Android wrapper is Java (`Messages.java` and the wrapper classes). Adopting it
   means rewriting the Android side in Kotlin (or wrapping), which touches every area the device harness verified.
3. **Needs the toolchain at generation time.** JNIgen needs the compiled Kotlin and the Android SDK; FFIgen needs Xcode/LLVM. The generation
   is a two-pass loop (generate, compile, generate again: the first run fails with "Error running JNIgen" until the new classes compile).
4. **Native to Dart callbacks block the calling native thread until the Dart handler runs.** `@FlutterApi` calls from a native worker thread
   worked on the Android phone (single run: the worker blocked about 1.5 ms; 3 ms when called from the main thread). Nothing deadlocked in the
   spike; that a blocking cross-thread call CAN deadlock is read from our rules (the SDK calls us on the main thread and Dart's reply needs it),
   not measured, and the report-handler and view-hierarchy paths were not run. Our channel design never blocks. (The second spike measured
   the same blocking call at 219 ms on the same phone: see below; the two runs are unreconciled.)
5. **iPhone XS: registering a `@FlutterApi` hung** (the last line the app wrote before the hang was `B api`, after
   `SpikeApi.createWithNativeInteropApi()` and before `SpikeEvents.setUp(...)` returned, in a release build on iOS 18.7.9; the host-API
   interop worked). One device, one OS version, not diagnosed, and it may be a spike error (the spike's `AppDelegate.swift` registers no
   native `SpikeEvents` implementation, the native side reads Dart's through `SpikeEventsRegistrar`). It weighs less than findings 1 to 3.
6. **Multi-engine.** The docs warn that registration routes to the most recent engine unless the engine is known; Pigeon 30 added per-engine
   keys (the generated Kotlin registrar takes the engine). Our wrapper fans out to every attached engine and replays state per receiver; the
   rules (and tests) for that are written for channels.
7. **Swift.** FFIgen reads Objective-C, so Swift needs `@objc` shapes; the iOS side of a SwiftPM-only plugin also needs the extra
   Objective-C target when a `.m` is generated.
8. **Version.** The spike used Pigeon 30.0.2 (we pin 29.x, `native-versions.json` `pigeon.version`); moving the pin is a decision of its own.

## What is worth trying later

* Typed-list payloads (`Int32List`) for secure rectangles, if interop reaches stable: it removes the one place where a `List<int>` is
  buffered. The same schema can generate both transports (`createWithNativeInteropApi()` next to the channel constructor), so a switch
  could be per API and reversible.
* Re-run this spike (the files in `doc/interop-spike/`) when Pigeon's interop mode is stable, on the Android phone and the iPhone, and
  add the multi-engine and report-handler cases before deciding.
* The stable generators (second spike below) for one narrow thing, the secure-rectangle publish, after the frame-capture measurement.

## Second spike: the stable generators, without Pigeon (2026-11-17)

JNIgen 1.0.1 on a Java class and FFIgen 23 on an Objective-C class, each a process-wide static store with the shape of ours
(`ping`, `echo`, a 256-int publish, a listener); sources in `doc/interop-spike/stable/` (`.txt`). Release builds on the same phone and iPhone XS.

| | Android phone (WOD-LX1) | iPhone XS |
|---|---|---|
| empty call / echo | 0.6 / 0.8 us | 0.01 / 0.01 us |
| 256 ints, array built per call | 13 us | 0.12 us (copied to native memory per call) |
| 256 ints, array or pointer reused | 0.7 us | 0.02 us |
| `NSData` of 1024 bytes built per call | n/a | 1.1 to 1.4 us |
| the channel for comparison (section above) | 315 to 776 us | 30 to 39 us |

Synchronous, so these are calls that return with the work done, not futures. What the run showed:

* **Dart to native is a plain static call:** no engine routing (a process-wide store has none), the same thread as Dart (`main`), a Java exception
  arrives as a `JThrowable`, a background isolate can call it (no setup), and the call works from the main thread inside the same frame.
* **Native to Dart, blocking (JNIgen, Android phone, single runs):** the main thread inside a Dart call took 1 ms; a **worker thread blocked 219 ms**
  on the phone while the main isolate sat idle in a `Future.delayed` (1.2 ms on an emulator, and about 1.5 ms for Pigeon's interop in the first spike
  on this same phone: unexplained, one run each). On the iPhone a blocking block called from the main thread worked and one from a worker thread
  returned, but the time was NOT captured (the app's `NSLog` of it was not read). So "no usable bound" is shown for Android only. Both generators
  have a non-blocking mode (JNIgen `onEvent$async: true`, 0.4 ms on the phone; FFIgen `.listener` is fire-and-forget and ran on a background
  thread on the iPhone), and that is the one to use.
* **Build facts:** a release build strips the Java class without a keep rule (`ClassNotFoundException` at the first call; a `-keep` rule fixed it);
  FFIgen parses Xcode 27.1's Foundation only with `-isysroot <SDK>` and `-target arm64-apple-ios15.0`, and needs `objectiveC: const ObjectiveC()`
  (without it the output is empty and nothing says why); jnigen 1.0 changed its API and deprecates the YAML config; FFIgen emits an Objective-C file for
  blocks that the Runner must compile.

### Decision input

A synchronous call removes the queue hop: the native store is current when Dart's call returns. For secure rectangles that could shorten the
first-frame exposure our docs list as a known limit, if Dart registers during layout or paint rather than after the frame. That is a hypothesis: nothing
here measured frames. A synchronous call into Dart cannot help the calls the SDK makes on the main thread (the view-hierarchy answer, the iOS report
handler): Dart's isolate is that thread, so a helper thread waiting for it deadlocks. **Decided:** the stable generators are not used in 10.0
either, and stay a candidate for the secure-rectangle store only. The next measurement, if wanted: capture frames of a newly
appearing secure view on the phone and count the unredacted ones, with the channel and with a direct call.
