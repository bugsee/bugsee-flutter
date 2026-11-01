# Log capture

What the app prints from Dart (`print`, `debugPrint`, and lines its own logging forwards) is recorded into the
report's log by this plugin, **attributed to the plugin and not to the application**: the SDKs record it with
source `Custom` (98), never as the app's deliberate `Bugsee.log` calls (source `Bugsee`, 4). The channel the SDKs
built for that is the wrapper channel (`specs/sdk/wrapper-channel`), the same one network events use ([network.md](network.md)). This page
is the data flow, the source and level rules, the privacy model (read the "platform echo" section), the options,
the limits, and the SDK source the decisions were read from.

```dart
void main() {
  // The bindings and runApp share one zone, and it is the one that records `print`.
  Bugsee.runWithLogCapture(() {
    WidgetsFlutterBinding.ensureInitialized();
    Bugsee.installLogCapture();            // once, early; opt-in
    runApp(const MyApp());
  });
}
// ... later: Bugsee.launch(...). Lines printed before the SDK is launching/launched are dropped.
```

Public API (all on `Bugsee`, `doc/api-surface.md` has the rest): `installLogCapture({level})`, `uninstallLogCapture()`,
`logCaptureInstalled`, `logCaptureZoneSpecification`, `runWithLogCapture(body)`, `forwardLog(message, {level, tag})`,
`setLogFilter(filter, {timeout})`, `logFilter`, `logCaptureStats`; `BugseeLogEvent`, `BugseeLogFilter`,
`LogCaptureStats`, `logLevelForLoggingValue(int)`. `runGuarded` also records `print` in its zone.
`Bugsee.log` is unchanged: app-sourced, bypasses the filter, not captured by this.

## What the SDKs ship at the pins

| | Android 7.4.2 (`v7.4.2`) | iOS 7.0.0 (SDK read at beta7 `0581aa02c`; release `2b88480fa`) |
|---|---|---|
| route | `BugseeWrapperChannel.log(tag, message, level, source)` -> `BugseeWrapperChannelImpl.log` (:36) -> `BugseeInternal.log` (:1029) | `-[BGSWrapperChannel logWithTag:message:level:source:]` -> `BGSWrapperChannelImpl.m:143` -> `+[Bugsee log:level:timestamp:source:requiresFiltering:YES]` |
| allowed `source` | allow-list: `Custom` 98, `WebView` 5, `StdOut` 1, `StdErr` 2, `Unknown` 0; **every other value is recorded as `Custom`** (`toWrapperSource` :79), reported once per process; a null source is `Custom` silently | the same allow-list (`recordedSourceForClaimedSource:` :99), the same coercion and once-per-process notice |
| reserved (never claimable) | `Bugsee` 4 (the app's `Bugsee.log`), `LogCat` 3, `Internal` 99 | `Bugsee` 4, `OSLog` 3, `Internal` 99 |
| what this plugin claims | **`Custom` only** (`LogOps.WRAPPER_SOURCE`) | **`Custom` only** (`BGSLogEventSourceCustom`) |
| `tag` | recorded (`log.json` `tag`, omitted when empty) | **accepted and dropped**: iOS log events have no tag (`BGSWrapperChannelImpl.m:146`) |
| level numbers | `LogLevel` 1 error, 2 warning, 3 info, 4 debug, 5 verbose | `BugseeLogLevel` the same 1..5 (the breadcrumb levels are the ones that differ) |
| gate | `isStartedOrStarting()` (`BugseeInternal.java:1036`): Launching or Launched | `bugseeAvailableForUserDumps` (`Bugsee.m:1630`): Launching or Launched; plus the channel must be the current registration (`acceptsData`) |
| `capture.logs` | **off drops channel lines** (`mConsoleEventLogger` :312: "the wrapper channel carries output the wrapper captured on its own ... which is automatic capture") | **off drops them** (`BGSWrapperChannelImpl.m:158`) |
| `capture.logs.level` | **not applied** to channel lines (`isLevelAccepted` only guards the logcat dispatcher, :454/:483) | applied (`BGSCaptureDataProviderLog.m:115`) |
| filtering | **always**: `runFilter = logSource != Bugsee \|\| requiresFiltering` (:321); the channel passes `true` anyway | **always**: `requiresFiltering:YES`, and `requiresFilteringForSource` is `source != Bugsee \|\| flag` (:221) |
| the app's filter runs | on the **calling thread**; an exception propagates to the caller (reaches the global handler) | on the calling thread; an exception is caught at `-postEvent:`, the line dropped |
| a filter that never replies | dropped after 10 s (`FILTER_CALLBACK_TIMEOUT_MS`), once-per-process warning | dropped (no timeout) |
| default log sanitizer | **none** (no `capture.logs.*sanitizer` option on either SDK; only the app's own filter redacts a log line) | **none** |
| timestamp | the channel takes none: stamped on receipt (`TimeUtils.monotonicWallTimeMillis`; the timestamp overload is bugsee-android#299, closed upstream by commit `aa9ea4c18` on Android `main`: it is NOT in any tag, not in the pinned `v7.4.2`; bugsee-cocoa#265 is still open) | stamped on receipt (`BugseeGetCurrentTimeStampMs`) |
| message length | no limit | no limit |
| stale channel | `isLive()` / `isCurrentWrapperChannel`: dropped silently | `isCurrent` generation check; reports once after 5 s |

## Data flow

```
 print('x')  ─► zone print hook (Bugsee.logCaptureZoneSpecification) ─► the app's own handlers (parent.print: output FIRST, unchanged)
 debugPrint  ─► chained hook ─► previous debugPrint called with the same arguments (in a zone the capture ignores)
 Bugsee.forwardLog ─┐
                    ▼  all three: O(1) LogPipeline.submit, never blocks, never throws
   gates: installed · policy (launching|launched, capture.logs, capture.logs.level) · own-prefix · FlutterError dump
   rate limit 500 lines/s (burst 1000) ─► cut to 4000 UTF-16 units ─► bounded queue (1000 lines / 2 MiB)
                    ▼   (a later event-loop turn)
   Dart filter (setLogFilter; fail closed; runs in a zone that records nothing)
                    ▼
   batches <= 64 lines / 128 KiB, ONE in flight ─► host.addLogLines(batch)   (serial BACKGROUND thread of the plugin)
                    ▼
   Android: LogLevel.fromRawValue + channel.log(tag, msg, level, LogSource.Custom)
   iOS:     channel logWithTag:message:level:source:BGSLogEventSourceCustom
                    ▼
   SDK: the app's native log filter (if set) · capture.logs gate · (iOS) level gate · log.json
```

* **Original output is never swallowed.** The zone handler calls `parent.print` first; a `debugPrint` hook calls the
  previous callback with the same arguments. An exception of the app's own handler propagates as it would have.
* **Chaining.** Nested hooks record once (an in-progress flag); the `debugPrint` hook is one closure per install, each
  holding the callback it chains to, so an app that wrapped ours and installs again does not recurse; `uninstall`
  restores the previous `debugPrint` only when ours is still current (otherwise it stays in the app's chain and forwards).
* **Order** is print order; one batch in flight; native runs on a serial background thread (a Pigeon task queue) because the
  app's native filter runs on the calling thread and a throw must not reach the platform thread.
* **Timestamps**: neither channel takes one, so a line is stamped when native hands it to the SDK (a few ms after the
  print when the pipeline is idle; a long queue or a slow filter widens it). Unlike network capture there is no `ageMs` (network events are
  backdated by it, so a log line can appear after the request it preceded): the pinned SDKs could not use it. **Pending upstream (a pin condition, PLAN.md "Known gaps")**:
  send `BugseeLogEvent.time` once a release carries the timestamp overload (Android: a tag after `v7.4.2` containing `aa9ea4c18`;
  iOS: bugsee-cocoa#265). A filter that does not answer cannot skew the timeline for long: after three timeouts in a row the filter
  is switched off for 30 s and its lines are dropped at once (fail closed, `droppedFilterCoolDown`), instead of costing a timeout each.
* **Reports**: before an upload, `createReport`, the dialog and every error report (`logException`, `reportException`, the installed
  error handlers) the pending lines are handed to the SDK first, waiting at most 200 ms (a hung filter cannot hold a report back):
  `print('parsing $x'); throw ...` puts the line in the report. A crash the SDK itself catches cannot wait.
* **Error presentation**: `FlutterError.presentError` is chained at install (and `FlutterError.onError` while it is still the
  framework's default, `dumpErrorToConsole`), so whatever they print runs in a zone the capture ignores, however the app's
  `debugPrint` splits or throttles it later (an app that sets its own non-chaining `debugPrint` after the install, and a logger
  package that splits lines, cannot leak the dump piece by piece). Both are restored on uninstall when still ours, and never replace
  the app's own handler. Not covered: an app that calls `FlutterError.dumpErrorToConsole` itself from its own `onError`, with its
  own non-chaining `debugPrint` (the `══╡` header and the single-call dump are still dropped; the pieces of a line-splitting
  replacement are not).
* A repeated `installLogCapture` drops nothing (it keeps the policy in force) and attaches once.
* A throttled `debugPrint` whose timer predates the install prints later, from a zone that carries the hook: pieces of a message
  the hook recorded a moment ago (3 s) are recognised and not recorded again as `print`. The match is narrow: the piece must sit
  at word boundaries and be at least 12 characters (or a whole line of the message), each piece is used up by one print, the
  remembered text is capped like a recorded line, and every such drop is counted (`droppedEchoes`). A short `print` of the app
  ('12', '}') is never taken for an echo; a wrapped tail shorter than 12 characters may be recorded once more as `print`.
* **Hot restart**: hooks, queue and policy are per isolate; the new isolate's `main` installs again. Native keeps no log state.
  Installing over a hook an old service left behind records once.
* Calls from a background isolate: `installLogCapture` throws a `BugseeException`; output of another isolate is not captured.

## What is captured, and what is not

| Dart output | Captured | Why |
|---|---|---|
| `print` inside a zone with the hook (`runWithLogCapture`, `runGuarded`, your `runZoned(zoneSpecification: Bugsee.logCaptureZoneSpecification)`) | yes, tag `print` | `Zone.root` cannot be replaced; a zone spec is the only hook Dart offers |
| `print` in the root zone | **no** | cannot be hooked in Dart |
| `debugPrint` (incl. the framework's own, `FlutterError`'s) | yes, tag `debugPrint`, wherever it is called | the callback is a global variable (chained) |
| `FlutterError` diagnostics dump (`══╡ EXCEPTION CAUGHT ...`, `Another exception was thrown: ...`) | **never by this capture** (see the Android echo: on a real Android app the dump ALSO reaches the SDK's logcat capture, raw; `flutter test` routes `print` to the test reporter, not logcat, so the device runs here cannot show it) | the diagnostics tree carries widget trees and property values; the error itself is reported by `Bugsee.reportException` and the installed error handlers ([exceptions.md](exceptions.md)). Counted in `droppedErrorDumps`. The release-mode `debugPrintStack` output (message + frames) is ordinary text and is recorded |
| the plugin's own `bugsee_flutter: ...` messages | never | a diagnostic that reached the pipeline it is about could meet a failing filter again (the spec's "at most once" rule) |
| `dart:developer` `log()` | **no**, and cannot be hooked | it goes to the VM service, not the console; use `Bugsee.forwardLog` or `Bugsee.log` |
| `package:logging` | via `Bugsee.forwardLog` (no dependency added) | `Logger.root.onRecord.listen((r) => Bugsee.forwardLog('${r.loggerName}: ${r.message}', level: logLevelForLoggingValue(r.level.value), tag: r.loggerName))`; SEVERE/SHOUT error, WARNING warning, INFO info, CONFIG/FINE debug, lower verbose |
| `stdout.write` / `stderr.write` | no | they reach the platform console, where the SDK's own capture may record them (below); claiming `StdOut`/`StdErr` for Dart lines would be wrong: the wrapper did not capture them from the process stream |
| other isolates | no | no channel to the SDK |

**Levels.** `print` and `debugPrint` carry no level: `installLogCapture({level: LogLevel.info})` is the level of both
(tags tell them apart). `forwardLog` takes a level; `logLevelForLoggingValue` maps `package:logging` values.

## The platform echo, and why the Dart filter is not the whole story

The SDKs also capture the process's console on their own: Android reads logcat (source `LogCat` 3), iOS intercepts
stdout/stderr. `print` writes there too, so **the same line can be recorded twice, once per route**, and the SDK's route
does not pass through the Dart filter. Measured on the Android emulator (API 30, a plain app run, not `flutter test`, whose
zone sends `print` to the test reporter instead of the console):

```
source level tag      message
3      3     flutter  ECHO A1 zone print (hooked)                      <- logcat echo (SDK's own capture)
98     3     print    ECHO A1 zone print (hooked)                      <- this plugin
3      3     flutter  ECHO C1 filtered SECRET value                    <- echo: the Dart filter never ran on it
98     3     print    ECHO C1 filtered <redacted> value                <- plugin, after the Dart filter
3      3     flutter  ECHO C2 root zone SECRET value (not hooked)      <- recorded only by the SDK
```

On the iOS 26.5 simulator (`flutter run`, the same demo) **no echo was recorded**: only the three hooked lines appeared
(source 98, no tag), the root-zone lines (`ECHO B1`, `ECHO C2`) were not recorded at all. Flutter's iOS `print` does not
reach the stdout the SDK intercepts there (it goes through the system log, which the SDK captures only with the deprecated
`capture.logs.oslog`, off by default). Not verified on a physical device or in a release build.

What follows for privacy:

* **Android: the Dart filter does not apply to the logcat echo** (source 3, tag `flutter`, raw), and no manifest key turns that route off
  alone (`capture.logs`, `.level` and `.allsources` are the only options). A debug build warns once when a filter is set on Android
  while `capture.logs` is on. The echo also carries the `FlutterError` dump of a real app. Kotlin:
  `Bugsee.setLogEventFilter { e, cb -> if (e.logSource == LogSource.LogCat && e.tag == "flutter") cb.run(null) else cb.run(e) }`.
* The Dart filter governs the lines this plugin records. It cannot reach the SDK's own console capture. Both SDKs run
  **the app's native log filter** on every non-`Bugsee` source, so redaction that must hold for the echo belongs in a
  native filter (`Bugsee.setLogEventFilter` from Kotlin/Swift), or the secret must not be printed. A native filter that
  keeps only the plugin's lines on Android: drop an event whose `getLogSource() == LogSource.LogCat` and whose tag is `flutter`.
* Turning `capture.logs` off stops the echo and this capture together (both are automatic capture); the app's own `Bugsee.log` stays.
* The echo is the SDKs' behaviour and exists with or without this feature; the capture adds attribution, tag, level,
  `forwardLog`, and a Dart-side filter that runs before anything leaves the isolate.

## Privacy model

1. **Raw lines stay in the process until they have passed the Dart filter.** Nothing is handed to native before it ran.
2. **`setLogFilter`** sees a copy of the line (`message`, `level`, `tag`) and returns the event to keep, a modified one, or `null`.
   It runs in Dart, so it cannot be bypassed for captured lines. An empty message drops the line. It runs one line at a time,
   in order, never inside `print`, in a zone that records nothing (a filter that prints cannot loop).
3. **Fail closed**: a filter that throws, returns a non-event, or a future that does not complete within its timeout (default
   10 s, the SDK's; at most 5 min) drops that line, counted (`filterFailures`), reported once in debug builds. A filter removed or
   replaced before the queue drains still applies to what was queued under it.
4. **Then the SDK runs the app's native filter on what the filter returned, always** (the channel has no flag: `requiresFiltering`
   is true inside both). **The SDKs have no default log sanitizer**: unlike network events, nothing redacts a log line by
   rule. Measured: `card 4111111111111111 password=hunter2` printed with no filter is recorded verbatim by both SDKs.
5. A Dart filter that returns the event with the secret untouched leaks it. Recommendation: **filter in Dart**, with an allow-style
   rule where possible, and keep secrets out of `print`.
6. `FlutterError` diagnostics trees are never recorded BY THIS CAPTURE (on Android the SDK's logcat route still records them raw: see above); lines are capped at 4000 UTF-16 units (`...[truncated N]`).
7. Android: an exception thrown by the app's native filter propagates to the plugin's background thread; it is caught per line
   (the line is dropped, the batch goes on). iOS: caught by the SDK.

## The options that apply

| option | default | effect here |
|---|---|---|
| `captureLogs` (`capture.logs`) | on | off: nothing is captured or sent (both SDKs drop channel lines; the app's `Bugsee.log` is not gated) |
| `captureLogsLevel` (`capture.logs.level`) | verbose | lines more verbose than it are not sent (Dart applies it on both; Android's provider would not) |
| `captureLogsAllSources` (Android) | off | the SDK's own logcat capture; not this capture |

The policy is read from the SDK (`getLaunchOptions`) when installed and after every launch, stop and status change. A stop takes
effect at once (before the options are read again); a failure to read leaves nothing accepted.

## Limits (known, documented, not bugs)

* A line printed before `launch` is dropped, not buffered (a buffer would be stamped at flush time: wrong).
* No `print` in the root zone, no `dart:developer`, no `stdout`, no other isolates (table above).
* The platform echo (above) and the timestamp stamped on receipt.
* Rate limit 500 lines/s, burst 1000, queue 1000 lines / 2 MiB: the newest are dropped and counted (`logCaptureStats`); a tight
  loop of 3000 prints in one turn records about 1000.
* The line cap (4000) is this plugin's (neither SDK has one); Android's own logcat path cuts near the same size.
* `submittedToSdk` is not "recorded": the SDK still drops silently on a retired channel or a filter that never replies.
* iOS drops the tag.

## Tests

`test/log_pipeline_test.dart`, `log_capture_test.dart` (zone and `debugPrint` hooks, chaining, nested zones, async errors, the
real throttled `debugPrint`, the real `FlutterError.dumpErrorToConsole`, install/uninstall/restart), `logs_facade_test.dart`
(the runtime with a fake native side, the SDK's gates), `logs_drift_test.dart` (`test/fixtures/log_wire.json` against Dart, Java
and Objective-C and the option manifests), JUnit `LogOpsTest` / `LogWireParityTest` (against the real `LogSource` / `LogLevel`),
XCTest `BGSFlutterLogOpsTests`. Every one was checked with mutation testing (counts in PLAN.md). Runtime: `example/integration_test/logs_test.dart`.

## Verified on a device

`logs_test.dart` against the real SDKs (Android emulator API 30 arm64, iOS 26.5 simulator), SDK launched against
`support/mock_api.py`, a real report; the bundle's `log.json` is the readback (Android `run-as`, iOS the uploaded bundle kept by the stand-in).

| | Android | iOS |
|---|---|---|
| captured / submitted / refused by native | 1017 / 1015 / 0 | 1015 / 1013 / 0 |
| `print` / `debugPrint` / `forwardLog` lines | source 98, level 3, tags `print` / `debugPrint` / `fwd` | source 98, level 3, **no tag** |
| forwarded error / warning | source 98, levels 1 / 2 | the same |
| deliberate `Bugsee.log` | source 4, level 2, no tag | the same |
| debug / verbose forwards (`capture.logs.level` = info) | absent | absent |
| 4020-char line (6000 printed) | cut, `...[truncated]` | the same |
| unicode, multi-line | intact | intact |
| unfiltered secret | recorded verbatim (no SDK sanitizer) | the same |
| with the Dart filter | `card <digits> password=<redacted>`; `internal` line absent; throwing filter: line absent | the same |
| `FlutterError` dump with a marker in its tree | absent | absent |
| line before launch | absent | absent |
| a line printed right before `Bugsee.upload` (re-run after review round 1: captured 1017 / 1016) | present, source 98 | present, source 98 |
| flood of 3000 | 999 recorded, 1952 rate limited, 50 queue-full | 999 recorded |
| platform echo (plain app run) | source 3, tag `flutter`, raw | none (not recorded) |

## SDK source read

Android `bugsee-android` `v7.4.2`: `BugseeWrapperChannelImpl.java`, `contracts/internal/{BugseeWrapperChannel,LogSource}.java`,
`contracts/options/LogLevel.java`, `BugseeInternal.java:1008-1050`, `capture/providers/log_system/BugseeCaptureDataProviderLog.java`
(`mConsoleEventLogger`, `logEventInternal`, `FilterCallbackWrapper`, `isLevelAccepted`), `BugseeCaptureDataEntryLog.java`,
`interception/logs/LogLogcatThread.java`. iOS `0581aa02c` (beta7; the SPI is in `BugseeSPI.h` at 7.0.0, `BGSContracts.h` being private and unshipped): `BGSWrapperChannelImpl.m`, `BGSContracts.h` (`BGSLogEventSource`,
`BGSWrapperChannel`), `BugseeLogEvent.h`, `BugseeLogger.h` (`BugseeLogLevel`), `Capture/Providers/BGSCaptureDataProviderLog.m`,
`Bugsee.m:1630-1700`. Bundle: `specs/sdk/reporting/bundle/log.md`.
