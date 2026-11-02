# Public API surface and its inventory

This is the written inventory the public facade was built from: every public method of the
Android 7.4.2 and iOS 7.0.0 SDKs, whether it is cross-platform, one-platform or
wrapper-internal, and what this package does about it. The decisions mirror the converged 7.x React
Native facade (`cross/bugsee-react-native/packages/react-native/src/index.ts`) unless the SDK source
says otherwise; where it does, the source wins and the difference is noted.

Sources read: Android `bugsee/bugsee-android` tag `v7.4.2` (`3b7af6371`):
`library/.../Bugsee.java`, `BugseeInternal.java`, `BugseeAttributes.java`, `BugseeEnvironment.java`,
`docs/api-7.x.md`; iOS `bugsee/bugsee-cocoa` `origin/release@2b88480fa` (7.0.0; the lines below were read at beta7's `0581aa02c`, and 7.0.0 moved the wrapper SPI from `BGSContracts.h` (now a private header that is not shipped) into `BugseeSPI.h` / the `Bugsee.SPI` submodule):
`Bugsee.h`, `Bugsee.m`, `BGSBugseeEnvironment.m`, `BGSContracts.h`. Line numbers below refer to those.

Everything below is implemented. Details that have a page of their own: attachments, annotated screenshots and
`createReport` in [attachments.md](attachments.md); Dart error reporting in [exceptions.md](exceptions.md); network capture in
[network.md](network.md); log capture in [logs.md](logs.md); the Flutter view hierarchy in [view-hierarchy.md](view-hierarchy.md).

## Legend

* **expose**: a cross-platform method with one Dart signature.
* **expose, per platform**: exposed, with a documented difference.
* **skip**: not exposed, with the reason. "later" means the decision is deferred, not made.

## Inventory

### Lifecycle and configuration

| Capability | Android 7.4.2 | iOS 7.0.0 | Decision |
|---|---|---|---|
| launch (token, options) | `launch` x4 (+ manifest auto-init) | `launchWithToken:` x4 | **expose**: `Bugsee.launch`, `waitUntilLaunched` |
| stop | `stop()`, `stop(Runnable)` | `stop:` | **expose**: `Bugsee.stop` |
| status | `getStatus()`, `getLaunched()` | `status`, `launched`, delegate `bugseeDidChangeStatus:` | **expose**: `status`, `statusChanges`, `getStatus`, `isLaunched` (from the lifecycle channel; the delegate is the app's) |
| launch options | `getLaunchOptions()`, `getHostLaunchOptions()` | `getLaunchOptions`, `getHostLaunchOptions` | **expose** |
| relaunch | `relaunch` x4 | `relaunch...` x4 | **skip**: `stop()` then `launch()` is the same thing and applies new options explicitly; relaunch re-reads the saved token/options, which a wrapper that owns them does not need. Not needed by the crash-relaunch recipes of the device harness either (`doc/verification.md`) |
| deleteCollectedDataOnDevice | x2 (SDK must be stopped, refuses otherwise) | x2 | **skip** (later): destructive, needs a stopped SDK, and the two SDKs disagree on what `includingIntermediate` removes (Android 7.3.1 deletes the rolling capture either way). Needs its own design |

### Data the app adds

| Capability | Android | iOS | Decision |
|---|---|---|---|
| attributes: set / get / get all / clear / clear all | `setAttribute(String, Serializable)` (void), `getAttribute`, `getAllAttributes`, `clearAttribute`, `clearAllAttributes` | `setAttribute:withValue:` (BOOL, says YES even for a dropped value), `getAttribute:`, `getAllAttributes`, `clearAttribute:`, `clearAllAttributes` | **expose** (`Bugsee.setAttribute` ... `clearAllAttributes`). Value types = intersection (String, bool, int, double); the SDKs' silent size drops are detected by a read-back |
| user identity | `setUserIdentifier`, `getUserIdentifier`, `clearUserIdentifier` | same three | **expose** (`setUserIdentifier`, `getUserIdentifier`, `clearUserIdentifier`). One field: neither SDK has a separate name or email. Empty string clears |
| event (name, params) | `event(String)`, `event(String, HashMap)` | `event:`, `event:params:` | **expose** `Bugsee.event(name, [params])` |
| trace (name, value) | `trace(String, Object)` | `trace:value:` | **expose** `Bugsee.trace(name, value)` |
| log | `log(String)`, `log(String, LogLevel)`, `log(.., requiresFiltering)` | `log:`, `log:level:`, `log:level:requiresFiltering:` | **expose** `Bugsee.log(message, {level})`. App-level log: bypasses the app's log filter (the default of both SDKs). `requiresFiltering` is **skipped**: an app-level log bypasses the SDK's filters by design; `Bugsee.setLogFilter` applies to the captured `print` / `forwardLog` lines only (see below) |
| breadcrumbs | `addBreadcrumb(Breadcrumb)` + `getExchangeFactory().createBreadcrumb()` | `addBreadcrumb:` + `getExchangeFactory` | **expose** `Bugsee.addBreadcrumb(BugseeBreadcrumb)`; the factory is wrapper-internal. `setBreadcrumbFilter` is **skip**: not exposed (the SDKs' own breadcrumbs, such as Android's `http` ones, are filtered only by a native filter: see `doc/network.md`) |
| notification relay | `notify` x5 | `notifyWithTitle:` x5 | **expose** `Bugsee.notify(title, {body, severity, fields, urgent})` |
| APM: transaction / span | `startTransaction` x2, `startSpan`, `getActiveSpan` | same four, `BGSTransaction`/`BGSSpan` | **skip (justified, later)**: both SDKs return handle objects whose "active span" is a per-thread notion (Android thread-local, iOS pthread TLS, "does not auto-propagate across `dispatch_async`"). Every Pigeon call lands on the platform thread, so a Dart transaction would have to be a native handle with its own lifetime registry, finish/cancel semantics and a story for Dart async code that interleaves on one thread. That is a design of its own, not a method; RN built a `SpanHandles` registry for it. Both SDKs return a no-op when APM is off, so skipping loses nothing silently |

### Privacy

| Capability | Android | iOS | Decision |
|---|---|---|---|
| blackout | `startBlackout`, `endBlackout`, `isBlackout` | same three | **expose** `Bugsee.startBlackout/endBlackout/isBlackout`. 7.x semantics only: **no pause/resume shim** (6.x `pause` also suspended the loggers; blackout does not) |
| secure views (widget) | `addSecureView(View)`, `removeSecureView`, `addSecureWebView`, fragments | `addSecureView:`, `removeSecureView:`, `addSecureWebView:`, `UIView.bugseeProtectedView` | **expose, as a widget**: `BugseeSecureView` (over the internal `BugseeSecureRegion`). Native views and web views are not Flutter widgets |
| secure rectangles | `addSecureRectangle(Rect)` (physical px), `removeSecureRectangle`, `removeAllSecureRectangles`, `getAllSecureRectangles`, `setSystemSecureRects` | `addSecureRectangle:` (points, max 10), remove, removeAll, `getAllSecureRectangles` | **skip**: the wrapper IS the rectangle provider (the SDK pulls them from the wrapper). A second, app-driven set in native units would be a footgun next to a widget that does the same in Flutter units and tracks layout. Use `BugseeSecureView` |
| secure activities | `addSecureActivity`/`removeSecureActivity`/`isSecureActivity` (string and class) | none | **skip**: Android-only and whole-screen; a Flutter app's activity is the whole app. Wrap the root in `BugseeSecureView`, or set `FLAG_SECURE` (`captureRespectFlagSecure`) |
| `resetVideoCapturePermission` | yes (MediaProjection consent) | none | **skip** (later): Android-only, only meaningful for the fullscreen video mode |
| `captureViewHierarchy` | yes | yes | **expose**: `Bugsee.captureViewHierarchy()` flushes the plugin's copy of the Flutter tree, then asks the SDK for a pass; the SDK asks the wrapper for `vh`, which is answered from the native snapshot cache (`doc/view-hierarchy.md`). A no-op before launch, after stop and with `capture.view-hierarchy` off; no launch gate of the wrapper's own |

### Reports

| Capability | Android | iOS | Decision |
|---|---|---|---|
| report handler (before / after) | `setReportHandler(ReportHandler)` | via `setWrapper:` (the wrapper's report handler); iOS has no app-level handler class | **expose** `Bugsee.setReportHandler(BugseeReportHandler?)` + `Bugsee.reportHandler` over the native report-handler pipeline and `ReportProxy`. Attachments and screenshots: below |
| lifecycle events | `setLifecycleEventsListener` | `bugseeLifecycleEvent:` (delegate) | **expose** `Bugsee.lifecycleEvents` (`Stream<LifecycleEvent>`, names unknown to this version preserved). The wrapper owns the SDKs' single listener slot; apps get the stream |
| showReportDialog | x4 | x4 | **expose** `Bugsee.showReportDialog({summary, description, severity, labels})` |
| upload (no UI) | `upload(summary, description[, severity[, labels]])` | `uploadWithSummary:` x3 | **expose** `Bugsee.upload(summary, description, {severity, labels})` |
| createReport / upload(Report) | `createReport(listener)`, `upload(Report[, cb])` | `createReportWithCompletion:`, `uploadReport:` x2 | **expose** `Bugsee.createReport({timeToLive})` -> `CreatedReport` (`upload()` / `discard()`), per platform: iOS hands a legacy `BugseeExtendedReport` (3 in-memory attachments of at most 3 MiB, no id, no annotated flag). See `doc/attachments.md` |
| attachments, annotated screenshot (handler report) | `addAttachment(File/byte[])`, `clearAttachments`, `setScreenshot(.., annotated)`, `isScreenshotAnnotated` | `addAttachmentWith...`, `clearAttachments`, `setScreenshot:...annotated:` | **expose** `ReportProxy.addAttachment` (path-first, `move`), `addAttachmentBytes` (1 MiB), `clearAttachments`, `setScreenshot(path, {annotated})`, `removeScreenshot`, and `attachments` / `screenshots` on the snapshot. `createAndAddAttachment`/`openStream`, per-attachment setters, single removal, async setters, bitmap reads: **skip** (reasons in `doc/attachments.md`) |
| logException / logUnhandledException / onUncaughtException / logError | yes | yes | **expose** `Bugsee.logException(error, [stack])` / `logUnhandledException(error, [stack])` / `reportException(error, {stackTrace, handled, domain})` over `logException` / `logUnhandledException` (never `onUncaughtException`; `logError(NSError)` has no Dart meaning), plus the opt-in handlers `installErrorHandlers` / `runGuarded` / `listenToIsolateErrors`. `skipFrames` and `includeVideo`/`labels` are skipped (they act on the carrier's native stack / are ignored by the SDKs). Before launch and after stop both are dropped (the wrapper gates the iOS unhandled path, which the SDK does not). See `doc/exceptions.md` |
| `testCrash` | yes | yes | **skip**: not a product feature; the device harness has its own crash recipes (`doc/verification.md`) |

### Wrapper-internal, capture-side and extension points

| Capability | Decision |
|---|---|
| `setWrapper` / `BugseeWrapper` | **wrapper-internal** (the plugin registers itself before launch: `doc/architecture.md`) |
| `addNetworkEvent`, `setNetworkEventFilter`, `getDefaultNetworkSanitizer` | **done, not as a one-to-one method**: the wrapper's own capture (`Bugsee.installNetworkCapture`) records `dart:io` and submits through the SDK's wrapper channel (`BugseeWrapperChannel` / `BGSWrapperChannel`, both shipped at the pins) with filtering required; the filter is `Bugsee.setNetworkFilter`, a Dart-side filter that runs BEFORE the SDK's native filter slot (which stays the app's); the default sanitizer is the SDK's (`capture.network.default-sanitizer`). A free-form `addNetworkEvent` for another stack is not exposed. `doc/network.md` |
| `setLogEventFilter`, `setLogFilter` | **done, not as a one-to-one method**: `Bugsee.setLogFilter` is a Dart-side, fail-closed filter on the wrapper's own capture (`Bugsee.installLogCapture`, `forwardLog`), which the SDK then runs through the app's native log filter (`doc/logs.md`). The native slot stays the app's |
| `setBreadcrumbFilter`, `setAdditionalDataCapture` | **skip**: not exposed (the native slots stay the app's) |
| wrapper channel `log(tag, message, level, source)` | **done**: used with source `Custom` only (`Bugsee.installLogCapture` / `forwardLog`); `Bugsee.log` stays the app-sourced route (`source` 4) |
| `getExchangeFactory` | **wrapper-internal** (used to build a breadcrumb) |
| `getAppearance` (Android `Appearance`, iOS `BugseeTheme`) | **skip, deliberately**: the 7.x appearance system is a large per-property colour/string surface that differs between the platforms (Android namespaced keys, iOS properties); RN needed a whole bridge for it, and the 9.x one was larger still. Not a plain SDK method. A later, separate design |
| `ext` / `registerExt` | **skip**: native modules (feedback is a separate package, decision D4: `packages/bugsee_flutter_feedback`, see `packages/bugsee_flutter_feedback/doc/feedback.md`) |
| `getVideoFrameConsumer` | **skip**: native SDK extension point |
| `showVideoCapturePreview` / `hideVideoCapturePreview` (iOS) | **skip**: developer diagnostic |
| `deleteCollectedDataOnDevice`, `relaunch` | see above |
| iOS `delegate`, `BugseeDelegate` | **skip**: the app's native delegate is never taken over |

## What the facade adds, and how each method behaves before `launch`

The wrapper queues nothing and gates nothing: each call reaches the SDK as it is and does what that SDK does
(Dart validates arguments first; native defends again). "Dropped" means the SDK ignores the call; it never throws.

| `Bugsee.` | Android 7.4.2 before launch | iOS 7.0.0 before launch | Result |
|---|---|---|---|
| `setAttribute` and the other attribute calls | works: `BugseeAttributes.getInstance()` is a persisted store (`BugseeAttributes.java`, preferences scope `global_attrs`) | works: `NSUserDefaults` (`BGSBugseeEnvironment.m`, `setAttributeForKey:value:`) | works on both, persisted across launches and stops. Verified on device |
| `setUserIdentifier`, `getUserIdentifier`, `clearUserIdentifier` | works: global preferences (`BugseeEnvironment.setUserIdentifier`) | works: Keychain, `NSUserDefaults` fallback (`Bugsee.m:2057`) | works on both. Verified on device |
| `startBlackout`, `endBlackout`, `isBlackout` | **held and applied at launch**: `BugseeInternal.startBlackout` sets the flag under the lock (`BugseeInternal.java:1421-1443`); the launch announces `BlackoutStarted` right after `Launched` (`:430-437`). `endBlackout` before launch cancels. A blackout lasts launch to `stop`, which ends it; one requested while the SDK is `stopping` is carried into the NEXT launch (`sBlackoutForNextLaunch`, `:105`, `:1432`) | held: not gated on launch, the video provider reads the flag when a recording starts (`Bugsee.m:1958`) | works on both. (The RN docs say Android ignores it before launch: that is stale at 7.4.2, the source and a device run say held.) Verified on device |
| `event`, `trace` | **dropped**: no launch gate (`BugseeInternal.java:1054-1093` only null-check the consumer), but the consumer comes from the capture coordinator, which launch creates. The consumer is cached once found, so after a `stop` a call may still reach the last provider | **dropped**: `bugseeAvailableForUserDumps` is true only for Launching and Launched (`Bugsee.m:1630-1641`); during `launching` the call is retained | dropped before launch; nothing throws. Not queued |
| `log` | dropped: `isStartedOrStarting()` (`BugseeInternal.java:1036`) | dropped: same gate | dropped |
| `addBreadcrumb` | dropped: `isStartedOrStarting()` (`BugseeInternal.java:989`), and the `CaptureBreadcrumbs` option (off by default). The factory's consumer is cached for good, so after `stop` it still hands out a crumb that `addBreadcrumb` then drops | NO launch gate in `+addBreadcrumb:` (`Bugsee.m:2133`); the factory hands back a crumb whatever the option is, and nothing records it when capture is off | the Future completes `false` unless the SDK is Launching/Launched (the wrapper gates on the status, both platforms: before launch and AFTER STOP too) and the option is on |
| `notify` | **ignored with a log line** `You need to call Bugsee.launch() method before Bugsee.notify()` (`BugseeInternal.java:1275-1277`; seen in logcat) | ignored, logged (`Bugsee.m:1818-1819`); `launching` counts | dropped; not queued |
| `showReportDialog` | no-op with a log line (`BugseeInternal.java:1133-1135`; seen in logcat) | needs `Launched` (not `launching`) | no-op |
| `upload` | no-op with a log line (`BugseeInternal.java:1238-1240`; seen in logcat) | ignored, logged (`Bugsee.m:1763-1765`) | no-op |
| `setReportHandler` | the handler is the wrapper's: register it before `launch` to see reports recovered while launching | same | stored natively; works before launch |
| `lifecycleEvents` | events buffered natively until Dart attaches, then replayed in order | same | the first call into the plugin attaches |

Not attached to an engine (the plugin detached, or the app was built without it): every call is a `BugseeException`
("not registered" / `not-attached`), never a crash and never a silent success. On a platform with no SDK (desktop, web)
the facade calls are no-ops that return `null`/empty/`false` with one debug warning, so logging and tracing code does not
break a desktop run; `launch` is the call that throws there.

## Value rules (Dart validates, native defends, a drift guard compares)

* **Attributes**: name non-empty; value `String` (at most 1024 UTF-16 units: Android's hard cap, `BugseeAttributes.CUSTOM_ATTRIBUTE_MAX_LENGTH_LIMIT`; applied to both so a value is not accepted on one platform and dropped on the other), `bool`, `int`, or a finite `double` below `Float.MAX_VALUE` (Android refuses a double at or above it, silently, and persists a non-integer as a 32-bit float; both getters answer with the float's shortest decimal (`3.141592653589793` reads `3.1415927`), because the SDK's own two getters differ, in memory the double and in preferences the float; iOS keeps the double). Android also holds a `Set<String>` that only native code can create; it reads as a sorted `List<String>`. Everything else (`List`, `Map`, `null`, `DateTime`) is refused in Dart.
* **The SDKs drop an over-limit value without saying so** (Android `setAttribute` is void; iOS's `BOOL` is `YES` even when it ignored the value). Native reads the value back after setting it: a value the SDK did not keep is `BugseeAttributeException(AttributeFailure.rejected)` and the previous value stays (Android checks before it changes anything; iOS DELETES the key it was overwriting when the new value overflows the total, `BGSBugseeEnvironment.m:319-328`, so the plugin reads the previous value first and writes it back). Limits differ per platform (measured: Android keeps a 1024-character string and 42 x 600 characters in all; iOS refuses the 1024-character string, its limit is the 1124-byte archive, and 40 x 600).
* **User identifier**: empty string = clear on both (Android alone would store `""`; iOS clears).
* **Event params**: `null`, `bool`, `num` (finite, below 2^63: Android's JSON writer turns a larger double into `Long.MAX_VALUE`), `String`, `List` and `Map<String, ...>` of those; 16 levels at most; a cycle or a non-string key is refused with the path of the bad value (`params.a.b[1]`). The map is copied. A `null` member stays a null member on both.
* **Trace value**: `String`, `bool`, `int`, finite `double` below 2^63. Crosses as the Dart type (Android's provider takes any `Serializable`).
* **Log level**: `LogLevel` (the options enum), crossing as the SDK's internal integer 1..5 (the same on both SDKs per the manifests); Android maps it through `LogLevel.fromRawValue`, never an ordinal.
* **Breadcrumb level**: crosses by NAME (`debug`, `info`, `warning`, `error`, `fatal`): the SDKs number their levels differently (Android debug 1 .. fatal 5; iOS `BugseeLogLevel` error 1 .. debug 4 with no fatal), so no one integer means the same on both. iOS records `fatal` as `error`.
* **Severity** (`notify`, `showReportDialog`, `upload`): `ReportSeverity.value` (1..5), `null` = unset. Without one the SDK applies its default bug priority (iOS's two-argument forms are used for that, since the four-argument form would store 0).
* **Notify fields**: order is kept on Android (the bridge sends ordered pairs, not a map); iOS takes a dictionary.
* No Pigeon enum exists anywhere in the bridge (`test/report_enum_parity_test.dart`).

## Errors

All are `BugseeException` subclasses, delivered through the returned `Future` (the methods are `async`; a bad argument is an
error you can `await`, not a synchronous throw). A message never contains an attribute value or other user data.

| Type | When |
|---|---|
| `BugseeArgumentException` (`argument` names the parameter) | an argument no SDK can honour (empty name, a value outside the accepted domain, a cycle, an empty label, a blank notification title); nothing reached the SDK. Native refuses with `invalid-argument` too |
| `BugseeAttributeException` (`AttributeFailure.invalidName`, `.invalidValue`, `.rejected`), NOT a `BugseeArgumentException` | an attribute call; `invalidName`/`invalidValue` are found before the SDK, `rejected` is the SDK's own refusal found by the read-back above, so `on BugseeArgumentException` keeps meaning "refused before the SDK" |
| `BugseeException` | the SDK threw (`sdk-error`), the plugin is not attached (`not-attached`), the plugin is missing, or the call came from a background isolate |
| `ReportClosedError` (`CreatedReportClosedError`) | a report edit after the handler's report was handed back, or a created report that was uploaded, discarded or expired |
| `ReportAttachmentException` (`ReportAttachmentFailure`) | a file, bytes or image the SDK or the file system refused; `CreateReportException` (`busy`, `timeout`, `rateLimited`, `uploadTimeout`) for `createReport` |

The status vocabulary is unchanged: launch failures stay `BugseeLaunchException`.

## Threading

Every Pigeon handler runs on the platform (main) thread, the thread both SDKs' public API is documented to be used from
(`Bugsee.showReportDialog` presents UI; iOS `Bugsee.m` reads UIKit state in several of these). The plugin holds no state for
these calls and takes no lock; the SDKs serialise their own (Android: `BugseeAttributes` synchronises on its map and writes
preferences asynchronously). An SDK exception cannot escape: Java and Objective-C catch it and report `sdk-error` (an
`NSException` escaping into Swift would crash the app).

## Report handler (public)

`Bugsee.setReportHandler(BugseeReportHandler(onBeforeReportCreated:, onAfterReportCreated:))`, `null` or an empty handler
clears; `Bugsee.reportHandler` reads it back. The handler receives a `ReportProxy`: `id`, `type`, `deliveryId`, `isLive`,
`read()` (a `ReportSnapshot`), `setSummary`, `setDescription`, `setEmail`, `setSeverity`, `replaceLabels`, `addLabels`,
`clearLabels`, `setAttribute`, `removeAttribute`, `clearAttributes`. Attachments and screenshots: `addAttachment`, `addAttachmentBytes`,
`clearAttachments`, `setScreenshot`, `removeScreenshot` (path-first; `doc/attachments.md`). The delivery rules (at-most-once
`onBefore`, at-least-once idempotent `onAfter`, the budget, what is never delivered) are the pipeline's and are
documented on `BugseeReportHandler`.

## Evidence

`example/integration_test/facade_test.dart` ran on an Android emulator (API 33) and an iOS simulator (26.5), next to
`launch_test` and `cold_start_test`:

* attributes (five types) and the user identifier read back from the SDKs before launch; the attribute limits listed above;
  blackout read back before launch and `BlackoutStarted` / `BlackoutEnded` while launched; breadcrumbs `true` for all five
  levels when launched with capture on and `false` before; the public `BugseeSecureView` mounted while launched;
* a real `Bugsee.upload` with the public report handler on both SDKs: `before` and `after` delivered, the handler's
  `setAttribute` / `replaceLabels` visible on the live report through `read()`, with the global attribute and the `critical`
  severity, and the SDK's own `BeforeReportAssembled` / `AfterReportAssembled` / `BeforeReportUploaded` events.

Not verified: write-only calls (`event`, `trace`, `log`, `notify`) have no SDK readback, so on a device they are only shown to
complete without error while launched (JUnit and XCTest show what reaches the SDK seam); there was no valid token, so no
server-side confirmation that events or breadcrumbs arrive; the order of `notify` fields on the wire; iOS `deferred` launches;
tvOS and visionOS. iOS stops a placeholder token itself after the first refused upload (`ReportUploadFailedWithFutureRetry`,
then `Stopping`, `Stopped`), so the integration test uploads first and tolerates later launches being refused. The rest of the
device evidence, including the harness runs, is in [verification.md](verification.md).
