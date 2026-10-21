# Attachments, annotated screenshots and `createReport` (Phase 6)

The rest of the report surface, on top of the Phase 3c `ReportProxy` and the Phase 4b report handler. The normative
sources are `specs/sdk/report-contract` (method matrix, lifetime, "path-first", annotated screenshots) and workbook 7.3.3
(attachments and screenshots do not cross a bridge as bytes: a file PATH crosses and native does the work).

## 1. What exists at the pins (read from SDK source, not from the spec's status line)

| Piece | Android 7.4.2 (`v7.4.2`, `3b7af6371`) | iOS 7.0.0-beta7 (`origin/nextgen@0581aa02c`) |
|---|---|---|
| `addAttachment(file, name, mime, move)` | `Report.addAttachment(File,..)` (`contracts/reporting/Report.java`), implemented by `IssueReport.addAttachment` / `IssueReportAttachment.importFile` (rename, else copy+delete; symlink always copied) | `addAttachmentWithFilePath:name:mimeType:move:` (`BGSContracts.h`, `BGSReport.m`; lstat, rename or copy, hands a refused move back) |
| `addAttachment(bytes, name, mime)` | `Report.addAttachment(byte[],..)` | `addAttachmentWithData:name:mimeType:` |
| list / clear | `getAttachments()`, `clearAttachments()` (deletes the files) | `attachments`, `clearAttachments` |
| lifetime | `IssueReport.isAcceptingAttachments` (reporting stage `< PROCESSING_SCHEDULED`) | `stopAcceptingAttachments` / `_closedToAttachments` |
| count cap | `IssueReport.MAX_ATTACHMENTS = 1000` | `kBGSMaxReportAttachments = 1000` |
| size cap on this path | none | none |
| annotated screenshot | `setScreenshot(displayId, Bitmap, annotated)`, `isScreenshotAnnotated(displayId)` | `setScreenshot:displayId:annotated:`, `screenshotAttributesForDisplayId:` -> `annotated` |
| display ids | `getScreenshotDisplayIds()` (ascending, null set removes: PR #178, in `v7.4.2`) | `screenshotDisplayIds` |
| `Bugsee.createReport` | `Bugsee.createReport(ReportCreationListener)` + `Bugsee.upload(Report[, cb])` (`BugseeInternal.createReport`: runs the before handler, then hands the app the **real** `Report`) | `+createReportWithCompletion:` + `+uploadReport:[completion:]`, but the object is the legacy **`BugseeExtendedReport`** (not a `BGSReportContract`): see 4 |

**The spec's "Android implements on branch `feat/report-contract-parity`" is stale for the pin:** that branch is NOT
merged into `v7.4.2` (`git merge-base --is-ancestor` fails) but the contract's pieces (PR #117 path-first, #136, #178)
arrived through `main`, and `v7.4.2` has them; everything above was read at the tag. iOS closes its gaps on `nextgen`
as the spec says (#136, #145) and beta7 = `0581aa02c` has them.

## 2. Public API

`ReportProxy` (a handler's report) gained:

* `addAttachment(path, {name, mimeType, move = false})`, `addAttachmentBytes(bytes, {name, mimeType})`
  (at most `maxAttachmentBytes` = 1 MiB; below any platform-channel concern, and the spec keeps bytes "for small
  payloads only"), `clearAttachments()`;
* `setScreenshot(path, {displayId = 0, annotated = false})` (the image is decoded NATIVELY from the file; at most
  `maxScreenshotPixels` = 4096 x 4096), `removeScreenshot({displayId})`;
* `ReportSnapshot.attachments` (`ReportAttachment`: name, mimeType, fileName) and `.screenshots`
  (`ReportScreenshot`: displayId, annotated). Metadata only.

`Bugsee.createReport({timeToLive = 10 min}) -> Future<CreatedReport?>` and `CreatedReport` (`read`, `setSummary`,
`setDescription`, `setSeverity`, `replaceLabels`, `setAttribute`, `removeAttribute`, `clearAttributes`, `addAttachment`
(copy only), `addAttachmentBytes`, `clearAttachments`, `setScreenshot(path, {annotated})`, `upload()`, `discard()`,
`isLive`).

Errors: `BugseeArgumentException` (found in Dart before anything crosses; native defends again with `invalid-argument`),
`ReportAttachmentException(reason)` (`ReportAttachmentFailure`: fileNotFound, notAFile, unreadable, tooLarge,
limitReached, rejected, busy, unsupported, imageUndecodable, imageTooLarge), `ReportClosedError` (a late call on a
handler's report, as in 3c) and its subclass `CreatedReportClosedError`, `CreateReportException` (`busy`, `timeout`).

**Left out, with the reason:** `createAndAddAttachment` / `Attachment.openStream()` (a stream cannot cross a bridge, and the
spec says callers should not use it on an imported file); mutating a returned `Attachment` (`setName`, `setMimeType`,
`setFileName`: name and type are set at add time); removing ONE attachment (not in the contract; `clearAttachments` is);
the iOS `addAttachment:` object form (superseded for wrappers); async screenshot setters (their completion thread differs by
platform and the call already runs off the platform thread); `getScreenshot` / `enumerateScreenshots` / `updateFrom` /
`exportVideo` (bitmaps and video do not cross, and nothing needs them); the legacy `BugseeAttachment` delegate path.

## 3. Rules

**Paths.** An absolute file system path (`File.path`). `file:` / `content:` URLs, relative paths, control characters and
paths over 4096 units are `BugseeArgumentException`. The OS and sandbox decide what is readable: the app's own
directories always are; on Android 10+ a path outside them (shared storage) is usually `unreadable` or `fileNotFound`;
a `content://` URI is never accepted (the SDK takes a `File`). A symbolic link is followed and **copied by content, never
moved**; with `move` only the link is removed. The plugin applies no sandbox of its own: the path is the app's, like every
handle (same trust model as the SDK).

**Name and type.** `name`: 1-255 units, not blank, no control characters, no `/` or `\` (it is also the file name of a bytes
attachment, and a consumer that saves bundle files must not get `../x`; the SDK's stored name is random). `mimeType`: `null`
or `type/subtype` (RFC 6838 names, no parameters, no trailing newline). The same regular expression is in Dart, Java and
Objective-C (a drift guard compares them).

**Limits.** Files: no size limit (a native copy, nothing read into memory); 1000 attachments per report (the SDKs' own,
extracted into `test/fixtures/report_enums.json` from source). Bytes: 1 MiB, empty allowed for a handler report. Images:
4096 x 4096 pixels, refused from the header before any pixel is allocated. A refusal never consumes the source: with
`move: true` a refused file stays (verified on both SDKs).

**copy vs move.** Copy is the default. A move of a file the SDK accepted is consumed (renamed into the report's storage,
or copied then deleted). The app should not delete its own file after a move; it should not rely on a copy's source being
untouched by anyone else either.

**Lifetime.** A handler's report is live until the handler's completion (3c). A file operation is claimed on the platform
thread when it is called: a handle live at that moment stays valid for the operation, and the SDK's completion waits for
the claim to end (`ReportHandlerPipeline.Lease`, `BGSFlutterReportLease`), so an accepted add landed before the
completion; a call after it is `ReportClosedError` and changes nothing. The wait is never a blocked thread. An add that is
still copying when the SDK's own timer completes the report is refused by the SDK (stage check) and answers `rejected`.

**Threads.** File work (copy, move, decode, delete) runs on a one-thread worker in call order (bounded queue of 64; a full
queue answers `busy`), never on the platform thread; replies are posted back to it. An iOS created report is an
unsynchronised object the SDK uses on main, so its (bounded) operations run on main.

## 4. `createReport`

One at a time (`CreateReportException.busy`), held natively under an opaque handle `cr-N`, with a deadline at each stage:
the SDK has 45 s to answer (`timeout`; a late report is refused by its stamp and discarded), and an unfinished report is
released after `timeToLive` whatever Dart does (Android: its attachments are deleted; the SDKs cannot cancel a created
report, it is simply never sent, and an unsubmitted one is discarded by the SDK at the next launch). A Dart hot restart
releases it at once. `upload()` ends the handle before the call crosses and answers whether the SDK scheduled it
(Android: its callback; iOS: handed off).

| | Android | iOS |
|---|---|---|
| object | the real `Report` (id, type, email) | `BugseeExtendedReport`: no id, type, e-mail |
| attachments | into the report's storage at once (copy) | in memory until upload; the SDK keeps at most **3**, each at most **3 MiB**, non-empty, no MIME type (`ATTACHMENTS_LIMIT`, `MAX_SIZE_ATTACHMENT`): refused here instead of dropped silently |
| screenshot | any display, `annotated` supported | one (display 0), `annotated: true` is `unsupported` |
| handler | before runs inside `createReport`, after at `upload` | both at `upload` (the SDK applies the object to the real report first, so a handler's labels replace the app's) |

## 5. Evidence

`example/integration_test/attachments_test.dart` (Android emulator API 30, iOS simulator) with the stand-in API
`example/integration_test/support/mock_api.py` (answers the issue request with an upload URL and refuses the upload, so the
bundle stays on disk (Android) or is captured by the server (iOS)). Bundle excerpt, Android (the same five entries, hashes
equal to the sources, on iOS):

```
attachment name=notes  attrs={name: notes, fileName: notes.txt, mimeType: text/plain} size=1200 sha256=3e2577ea...
attachment name=copied attrs={name: copied, fileName: copied.log, mimeType: null}      size=30   sha256=1f4cc4b3...
attachment name=moved  attrs={name: moved, fileName: moved.log, mimeType: null}        size=29   sha256=f1101d86...
attachment name=raw    attrs={name: raw, fileName: raw, mimeType: application/octet-stream} size=300 sha256=43f9b5d5...
screenshot entry: {displayId: 0, annotated: true}
```

Also shown on both: a copy leaves its source, a move consumes it, a refused one (missing file, directory, URL, bad type,
not-an-image) is typed and changes nothing, a late attach after the handler is `ReportClosedError` and a late `move` does not
consume the file, a second `createReport` is `busy`, a created report nobody completes is released at its time to live,
and a created report's summary, severity, labels and attachments reach `request.json` / the bundle.

Not verified: an iOS device, a real token (server-side processing), huge files on a device, Android scoped-storage paths
outside the app directory, iOS 26.5 (the simulator used runs iOS 27.0).
