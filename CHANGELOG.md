## 10.0.0-dev.1

* Rewrite for the Bugsee 7.x native SDKs (in progress, not yet published).
* Public API: `Bugsee.launch`, `stop`, `status`, `statusChanges`, `getStatus`, `isLaunched`,
  `getLaunchOptions`, `getHostLaunchOptions`; `BugseeOptions` with a typed field for every
  option both SDKs register, generated from their published manifests.
* Public API, continued: attributes (`setAttribute`, `getAttribute`, `getAllAttributes`, `clearAttribute`,
  `clearAllAttributes`), the user identifier, `event`, `trace`, `log`, `addBreadcrumb`, `notify`,
  `startBlackout`/`endBlackout`/`isBlackout`, `showReportDialog`, `upload`, `setReportHandler`/`reportHandler`
  with `ReportProxy`, the `lifecycleEvents` stream and the `BugseeSecureView` widget. See `doc/api-surface.md`
  for the inventory of both SDKs, what is left out and why, and what each call does before `launch`.

* Dart errors: `Bugsee.logException(error, [stackTrace])` (an error report), `logUnhandledException(error,
  [stackTrace])` (a crash report) and `reportException(error, {stackTrace, handled, domain})`; the opt-in
  `installErrorHandlers` / `uninstallErrorHandlers` (chained to existing handlers, restored, once per error, rate
  limited, error reports by default), `errorHandlersActive`, `runGuarded` and `listenToIsolateErrors`. The document
  sent to the SDKs is the backend's `FlutterManagedException` one (with the `signature` both SDKs hash), and a
  non-symbolic (obfuscated / `--split-debug-info`) stack is sent untouched. See `doc/exceptions.md`.

* Report attachments and screenshots: `ReportProxy.addAttachment(path, {name, mimeType, move})` (path-first: the file
  never crosses the bridge), `addAttachmentBytes` (up to 1 MiB), `clearAttachments`, `setScreenshot(path, {displayId,
  annotated})`, `removeScreenshot`, and `attachments` / `screenshots` on `ReportSnapshot`; typed errors
  (`ReportAttachmentException`). `Bugsee.createReport({timeToLive})` returns a `CreatedReport` to fill in and `upload()`
  (one at a time, released at its time to live). See `doc/attachments.md` for what differs on iOS.

## 0.0.1

* TODO: Describe initial release.
