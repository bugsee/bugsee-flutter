# Attachments, annotated screenshots and `createReport`

The rest of the report surface, on top of the `ReportProxy` and the report handler (see [api-surface.md](api-surface.md)). The normative
sources are `specs/sdk/report-contract` (method matrix, lifetime, "path-first", annotated screenshots) and workbook 7.3.3
(attachments and screenshots do not cross a bridge as bytes: a file PATH crosses and native does the work).

## 1. What exists at the pins (read from SDK source, not from the spec's status line)

| Piece | Android 7.4.2 (`v7.4.2`, `3b7af6371`) | iOS 7.0.0 (`origin/release@2b88480fa`; read at beta7 `0581aa02c`, limits re-extracted at 7.0.0) |
|---|---|---|
| `addAttachment(file, name, mime, move)` | `Report.addAttachment(File,..)` (`contracts/reporting/Report.java`), implemented by `IssueReport.addAttachment` / `IssueReportAttachment.importFile` (rename, else copy+delete; symlink always copied) | `addAttachmentWithFilePath:name:mimeType:move:` (`BugseeSPI.h` (`BGSContracts.h` at beta7), `BGSReport.m`; lstat, rename or copy, hands a refused move back) |
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
arrived through `main`, and `v7.4.2` has them; everything above was read at the tag. iOS closed its gaps on `nextgen`
(now in `origin/release`) as the spec says (#136, #145); beta7 (`0581aa02c`) and 7.0.0 (`2b88480fa`) have them.

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
handler's report) and its subclass `CreatedReportClosedError`, `CreateReportException` (`busy`, `timeout`, `rateLimited`, `uploadTimeout`).

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

**Name and type.** `name`: 1-255 units, not blank (blank = only code points of one explicit set, the same in Dart, Java and
Objective-C: U+0009-000D, U+0020, U+0085, U+00A0, U+1680, U+2000-200A, U+2028/9, U+202F, U+205F, U+3000; not each language's own
`trim`, which differ), no control characters, no `/` or `\` (it is also the file name of a bytes
attachment, and a consumer that saves bundle files must not get `../x`; the SDK's stored name is random). `mimeType`: `null`
or `type/subtype` (RFC 6838 names, no parameters, no trailing newline). The same regular expression is in Dart, Java and
Objective-C (a drift guard compares them).

**Limits.** Files: a SOFT limit of 20 MiB each (`maxAttachmentFileBytes`; neither SDK has one on this path, but a copy is
synchronous I/O in front of every other queued operation and the SDK's handler timer does not wait for it;
`config.max-data-size`, default 150 on both (iOS: 50 up to 7.0.0-beta7), bounds what a report may hold; a native copy, nothing read
into memory), 1000 attachments per report (the SDKs' own, extracted into `test/fixtures/report_enums.json` from source). Bytes: 1 MiB, empty allowed for a handler report. Images:
4096 x 4096 pixels, refused from the header before any pixel is allocated. A refusal never consumes the source: with
`move: true` a refused file stays (verified on both SDKs).

**copy vs move.** Copy is the default. A move of a file the SDK accepted is consumed (renamed into the report's storage,
or copied then deleted). The app should not delete its own file after a move; it should not rely on a copy's source being
untouched by anyone else either.

**Lifetime.** A handler's report is live until the handler's completion. A file operation is claimed on the platform
thread when it is called: a handle live at that moment stays valid for the operation, and the wrapper's completion waits
for the claim to end (`ReportHandlerPipeline.Lease`, `BGSFlutterReportLease`); a call after it is `ReportClosedError` and
changes nothing. The wait is never a blocked thread.

**The SDK's own timer does not wait for the claim, and Android 7.4.2 has a gap there.** The SDK moves on at its per-handler
timer (30 s, `ReportHandlerCallbackTimeout`; 60 s for the chain, `ReportHandlerChain.java:68`) whether or not an add is still
copying. iOS's `BGSReport` re-checks under its lock when it registers the attachment and hands a moved file back
(`BGSReport.m`, `registerCapturedAttachment...`), so a late add is refused and the source is intact. Android 7.4.2 does
NOT: `IssueReport.addAttachment` checks `canAddAttachment` only BEFORE importing the file
(`library/.../reporting/IssueReport.java:292` for a file, `:310` for bytes; `importFile` at `:296`, `importBytes` at `:314`) and
`registerAddedAttachment` (`:361-372`, `mAttachments.add(attachment)` at `:370`) adds WITHOUT checking again, although the SDK's
own comment (`:335`) says an add after processing was scheduled "would be an orphan file with no manifest entry". An add that
outlives the timer returns an `Attachment`, and if it was a `move` the SDK has already renamed the user's file into storage
that is private to it. The wrapper therefore (Android):

* never asks the SDK to rename: a move is a copy, then deleting the source **after** the add is known to have landed; the
  source is never lost, at the price of a copy where a rename would have been free (the observable result is the same);
* asks the lease whether the handler's window (the SDK's budget less our margin, measured from the handler's entry) has closed
  before it starts, and again when the SDK's add returns; an add that returns after the window closed is undone (the stored
  file is deleted with `Attachment.deleteFile`) and answers `rejected` with the source untouched;
* does not start work that was queued behind a slow copy once the window has closed (`not-live`, nothing touched);
* bounds the copy itself with the 20 MiB per-file soft limit, so a copy that long is not the normal case.

Known limit: only `addAttachment` (file and bytes) can be undone. `setScreenshot` has no lifetime check in the SDK at all (a late
one only replaces the report's in-memory picture and its own file, which the already-persisted copy does not read), and
`clearAttachments` deletes files the SDK's export may still need if it runs after processing was scheduled; both are claimed
and refused once the handler's window has closed, but one that STARTED inside the window is not undone.

Verified with a JUnit model of the SDK that registers without re-checking (`FakeReports.duringAdd`), which proves the moved
file survives and the orphan is deleted. The SDK should re-check under its lock like iOS does; that is an SDK issue, the
wrapper does not depend on it being fixed.

**Threads.** A handler report's file work (copy, move, decode, delete) runs on a one-thread worker in call order (bounded queue
of 64; a full queue answers `busy`), never on the platform thread; replies are posted back to it. A created report's
operations, its upload and every discard run on a SECOND worker (Android), so a slow handler copy never holds up the report the
app is filling in; a discard whose queue is full gets a short-lived thread, never the caller's or a timer's. An iOS created
report is an unsynchronised object the SDK uses on main, so what touches the object runs on main, but the file read (up to
3 MiB) and the image decode happen first on a second serial worker, never on the UI thread; the upload hops to main behind
them, so an add the app called before it is in the report when the SDK is handed it.

**Images.** The pixel cap is checked from the file HEADER before anything is decoded: on Android by `ImageHeader` (PNG, JPEG,
GIF, WebP, unit-tested with real image bytes; any other format falls back to `BitmapFactory`'s bounds), on iOS by ImageIO.
A multi-frame file (GIF, APNG, animated WebP) is judged by its canvas and its first frame is stored. **EXIF orientation differs
by platform:** `BitmapFactory` ignores it, `UIImage` applies it, so a JPEG with orientation 6 is stored unrotated on Android and
rotated on iOS (the pixel count, which the cap is about, is the same). Normalise the picture before attaching it if that
matters.

## 4. `createReport`

One at a time **process-wide** (`CreateReportException.busy`), held natively under an opaque handle `cr-N` and **owned by the
engine whose Dart isolate asked**: a second engine (add-to-app, a background isolate) starting up releases only its own, never
another's (`reserve(owner)` / `clearOwner`). Each stage has a deadline: the SDK has 45 s to answer (`timeout`; a late report is
refused by its stamp and discarded), an unfinished report is released after `timeToLive` whatever Dart does, `upload()` has
45 s for the SDK's answer (`CreateReportException.uploadTimeout`: the report may still be sent, do not upload it again; exactly
one answer, a late callback is ignored), and a Dart hot restart releases the restarted engine's report at once.

**The SDKs have no way to cancel a created report** (read on both: no public call on `Bugsee`, `Report`, `BugseeExtendedReport`;
Android's `createAndPrepareBugReport` opens a request and marks it `awaitingUserSubmission`, iOS's `createAndOpenBugReport`
a snapshot; only the next launch's recovery drops an unsubmitted one: `ReportHandler.java:103`). So a discarded, expired or
forgotten created report is simply never sent, but the SDK's opened snapshot stays on disk until then. Android additionally
deletes the attachments the app added; iOS holds them in memory and drops the reference. Because every create therefore costs
storage, the plugin allows **at most 6 starts a minute** (`CreateReportException.rateLimited`). `upload()` ends the handle before
the call crosses; `false` means only that the SDK declined; a report that is gone (uploaded, discarded, expired) is a
`CreatedReportClosedError`.

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

Also shown on both (and, on Android, a JUnit model of the SDK's missing re-check): a copy leaves its source, a move consumes it, a refused one (missing file, directory, URL, bad type,
not-an-image) is typed and changes nothing, a late attach after the handler is `ReportClosedError` and a late `move` does not
consume the file, a second `createReport` is `busy`, a created report nobody completes is released at its time to live,
and a created report's summary, severity, labels and attachments reach `request.json` / the bundle.

Not verified: an iOS device, a real token (server-side processing), huge files on a device, Android scoped-storage paths
outside the app directory, iOS 26.5 (the simulator used runs iOS 27.0).
