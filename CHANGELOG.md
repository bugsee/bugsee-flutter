## 10.0.0-dev.1

* Rewrite for the Bugsee 7.x native SDKs (in progress, not yet published).
* Public API: `Bugsee.launch`, `stop`, `status`, `statusChanges`, `getStatus`, `isLaunched`,
  `getLaunchOptions`, `getHostLaunchOptions`; `BugseeOptions` with a typed field for every
  option both SDKs register, generated from their published manifests.
* Public API, continued: attributes (`setAttribute`, `getAttribute`, `getAllAttributes`, `clearAttribute`,
  `clearAllAttributes`), the user identifier, `event`, `trace`, `log`, `addBreadcrumb`, `notify`,
  `startBlackout`/`endBlackout`/`isBlackout`, `showReportDialog`, `upload`, `setReportHandler`/`reportHandler`
  with `ReportProxy`, the `lifecycleEvents` stream and the `BugseeSecureView` widget. See `docs/api-surface.md`
  for the inventory of both SDKs, what is left out and why, and what each call does before `launch`.

## 0.0.1

* TODO: Describe initial release.
