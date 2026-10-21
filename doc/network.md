# Network capture (Phase 5b)

Dart's `dart:io` `HttpClient` is not the platform's networking stack, so neither SDK sees what is built on it
(`package:http`'s default client, `dio`'s default adapter, `Image.network`, the WebSocket handshake, a plain
`HttpClient`). This plugin captures it in Dart, through `HttpOverrides`, and hands each event to the SDK, which
treats it like traffic it intercepted itself. This page is the data flow, the privacy model, the options that apply,
the limits, and the SDK source the decisions were read from.

```dart
void main() {
  Bugsee.installNetworkCapture();      // once, early, before the app makes a request
  runApp(const MyApp());
}
// ... later: Bugsee.launch(...). Nothing is recorded before the SDK is launched.
```

Public API (all on `Bugsee`, `doc/api-surface.md` has the rest): `installNetworkCapture()`,
`uninstallNetworkCapture()`, `networkCaptureInstalled`, `setNetworkFilter(filter, {timeout})`, `networkFilter`,
`networkCaptureStats`; `BugseeNetworkEvent`, `BugseeNetworkFilter`, `NetworkStage`, `NoBodyReason`,
`NetworkCaptureStats`.

## What the SDKs ship at the pins (the injection channel)

Both SDKs expose a way to hand them a network event, and, at the pinned versions, a wrapper-attributed channel:

| | Android 7.4.2 (`v7.4.2`) | iOS 7.0.0-beta7 (`bugsee/spm` 73ed983; SDK `nextgen` `0581aa02c`) |
|---|---|---|
| public route | `Bugsee.addNetworkEvent(event, requiresFiltering)` (`Bugsee.java:1323`) over `BugseeExchangeFactory.createNetworkEvent` | `+[Bugsee addNetworkEvent:requiresFiltering:]` (`Bugsee.m:2154`); `+addNetworkEvent:` is `requiresFiltering:NO` |
| wrapper channel | **shipped**: `BugseeWrapperChannel` (`contracts/internal`), handed to `BugseeWrapper.onWrapperChannelAvailable` by `Bugsee.setWrapper` (`BugseeEnvironment.java:709`); its `addNetworkEvent` is `BugseeWrapperChannelImpl.addNetworkEvent` | **shipped**: `BGSWrapperChannel` / `-[BGSBugseeWrapper onWrapperChannelAvailable:]` (`BGSContracts.h`, `BGSWrapperChannelImpl.m:176`; present in the binary headers of the pinned xcframework) |
| event factory | `createNetworkEvent(...)` x2 (the long overload sets every field) | `createNetworkEvent` answers **nil** ("not wired", `BGSExchangeFactory.m`): build a `BugseeNetworkEvent` directly |
| gate | `BugseeInternal.addNetworkEvent`: `isStartedOrStarting()` (`BugseeInternal.java:975`); the provider only buffers 32 entries until it starts | `currentState == Launched` only (`Bugsee.m:2156`; `Launching` is dropped) |
| attribution | none for network events (the channel only adds a source to `log`) | none (same) |

The wrapper-channel spec (`specs/sdk/wrapper-channel`) is marked **Proposed, unimplemented**; both SDKs have
implemented it by these pins (Android `BugseeWrapperChannelImpl.java`, iOS `BGSWrapperChannelImpl.m`, with tests).
**So the channel is used**: the wrapper stores the channel it is handed (`NetworkChannelHolder`,
`BGSFlutterNetworkChannel`: process-wide, because the wrapper object is replaced when Dart refines the identity and
the SDK retires the old channel at that moment) and submits through it. The channel's `addNetworkEvent` runs the
same internals as the public method, only while its registration is current, so it is safe across the identity
refinement and never writes for a wrapper that was replaced.

**What "attributed to the wrapper" means for network events: nothing is stamped** (source attribution exists for
`log` only), so an event is recognised by its `mechanism` field, `dart:io` (`network.json` `mechanism`; the SDKs'
own are `URLSession`, `okhttp`, ...). The channel's advantage here is the lifetime guarantee above, not a label.

## Data flow

```
 app code ──► HttpClient()  ──► BugseeHttpOverrides.createHttpClient ──► the app's own overrides (chained)
                                         │                                      │ builds the real client
                                         ▼                                      ▼
                               CapturingHttpClient  ◄──────────────────────────┘
                                         │ forwards every call unchanged
                                         ▼
              CapturedRequest / CapturedResponse   (tee: a bounded copy, byte counts, timings)
                                         │ BugseeNetworkEvent (before / redirect / complete / error / abort)
                                         ▼
                              NetworkPipeline.submit            O(1), never blocks, never throws
                                         │ bounded FIFO (512 events / 8 MiB), drops NEW events when full (counted)
                                         ▼   (a later event-loop turn, slices of 4 ms)
                            Dart filter  (fail closed: throw / hang / junk drops the event)
                                         ▼
                batches of <= 32 events / 512 KiB, ONE in flight   ──►  host.addNetworkEvents(batch)   (a serial BACKGROUND thread of the plugin)
                                                                              │
              Android: BugseeExchangeFactory.createNetworkEvent  ──┐          │  gate: Launched && capture.network
              iOS:     BugseeNetworkEvent (built directly)       ──┴──► BugseeWrapperChannel.addNetworkEvent(event, true)
                                                                              ▼
                       SDK: app's native filter (if the app set one) else the default sanitizer; body limits; the bundle
```

* **The app's HTTP path pays for a queue insert.** Everything else (the filter, the encode, the bridge call) happens in
  a later turn of the event loop. A `request.close()` is not delayed, a response chunk is forwarded in the same turn
  it arrives (`StreamController(sync: true)`), `pause`, `resume` and `cancel` reach the real response.
* **Order** is the order the events were captured in; one batch is in flight at a time, so native is never handed a second
  batch before it answered the first, and the native work (the SDK's sanitizer, the app's native filter) runs on a serial
  background thread of the plugin (a Pigeon task queue), never on the main thread. The wrapper channel is documented as
  callable from any thread; the SDK's own interception calls the same entry points from its own threads.
* **A busy native side** shows as a full queue: the new events are dropped and counted
  (`networkCaptureStats.droppedQueueFull`), a warning is printed once in debug builds.
* **Timestamps**: every event carries its age (`ageMs`, from Dart's monotonic clock); native subtracts it from the
  SDK's own clock (Android `BugseeExchangeFactory.currentTimestamp()`, which is not `DateTime.now()` once the device
  clock was corrected, and "stamps from another clock can be dropped"; iOS `CFAbsoluteTime` epoch ms). The age is
  taken just before each batch is sent, so a slow filter does not make an event look older than it is.
* **Ids** are `<8 hex random per isolate>-<counter>`, so a hot restart cannot reuse one.

## What is recorded

One exchange is several entries sharing an id (`reporting/bundle/network.md`):

| stage | when | carries |
|---|---|---|
| `before` | `request.close()` (or `abort`, or a failure first) | method, URL, request headers, request body (+ `no_body_reason`), size |
| `redirect` | one per hop `dart:io` followed (read from `response.redirects`) | the URL that answered and its status (no headers: the next entry's URL says where it went) |
| `complete` | the response body ended (or the app took the socket) | status, reason phrase, response headers, body, size, `redirectedFrom`, timings |
| `error` | no connection, certificate refusal, connection timeout, connection closed mid-body | short and long error text |
| `abort` | the app cancelled the response subscription, or called `request.abort()` | size so far |

* A request is recorded at `close()`, not at `open`: that is when the body is complete and the headers are frozen.
  A request the app never closes is never recorded.
* A response is completed when its body stream ends. A response the app **never listens to** never completes (the
  connection is the app's to drain); `detachSocket()` (a WebSocket upgrade) completes the exchange at once.
* Any HTTP status is a `complete`; `error` is for failures that never produced a response.
* Header names are lower-case (Dart's), a repeated header is one entry joined by `, `.
* `timings` (Android only; iOS has no field): `ttfb` (close to headers), `download` (headers to end), `total`
  (open to end), in milliseconds.
* **Redirects**: Android records each hop (`redirect` stage); iOS has no such stage (its own interception carries the
  original URL on the final event, `redirectedFromURL`), so the Dart side does not create the hop entries there (they
  would be built, filtered, sent and counted as refusals for nothing) and the final `complete` carries `redirectedFrom`.
* A redirect the app follows itself (`followRedirects = false`, then `response.redirect()`) is **a new exchange per response**: the 3xx
  completes on its own (with the body the app read, none if it never listened), and the response `redirect()` returns has its
  own id, `before` and `complete`, with `redirectedFrom` set to the 3xx's URL.
* iOS spells `abort` `cancel` (`BugseeNetworkEventCancel`); native maps it.
* iOS has one error text and no `statusText`; Android stores both texts and the reason phrase.

### Bodies

Bodies follow the SDK's own rules, which Dart applies **before copying anything**, so memory is bounded by the limit
and a binary body is counted and never copied:

* `capture.network.body-size-limit` (default 20480 bytes, both SDKs): a body over the limit is **dropped, not cut**
  (`no_body_reason: size_too_large`). The size is still reported in full. A `Content-Length` over the limit stops the
  copy at the first byte; otherwise the copy is released the moment the count passes the limit; a limit of 0 keeps
  nothing.
* `capture.network.body-without-type` (default off): without it a body needs a `Content-Type` (`no_content_type`)
  that is text (`text/*`, or a subtype containing `json`, `xml` or `x-www-form-urlencoded`:
  `NetworkUtils.isSupportedMediaType`) (`unsupported_content_type`). With it the SDK skips every type check, so does
  this.
* A response still compressed (`autoUncompress` off) is `cant_read_data`; a charset other than UTF-8, Latin-1 or ASCII,
  or bytes that are not valid text, is `cant_read_data`. With `autoUncompress` on (the default) `dart:io` decompresses and
  the body is the text.
* The order of the checks differs for a request and a response, as in the SDK (`NetworkEventsProducer.getRequestBody`
  and `getResponseBody`).
* There is **no separate request-body option** in either SDK: request and response bodies are governed by the same
  three options. A request body is therefore captured under the same rules as a response body, and `capture.network` off
  or a limit of 0 is how to capture none.

### What is never recorded

* anything while the SDK is not `launched` (Android would accept `launching` into a 32-entry buffer, iOS drops it:
  "do not send what the SDK would drop" is the one rule both meet), after `stop`, or with `capture.network` off. A
  request that began before the launch is never recorded, one that began while launched is recorded to its end (the
  pipeline drops what the SDK no longer accepts when it hands it over);
* **Bugsee's own traffic**: any host `bugsee.com` or below, and the host of the configured `endpoint`;
* the frames of a WebSocket (below), a request made in another isolate, a request made through a stack that is not
  `dart:io`.

## Privacy

1. **Raw data stays in the process until it has passed every filter.** Nothing leaves Dart before the Dart filter ran;
   nothing is submitted to the SDK before it.
2. **The Dart filter** (`Bugsee.setNetworkFilter`) sees the raw event (headers, URL with its query, body) and returns the
   event to keep, a modified one, or `null` to drop it. It runs in Dart, so it cannot be bypassed: there is no path
   to the SDK that does not go through it. `id`, `stage`, `method`, `statusCode` and `size` are the exchange's and are
   **ignored if a filter changes them** (a filter cannot break the pairing of the stages); a filter that blanks the
   URL drops the event.
3. **Fail closed.** A filter that throws, returns something other than a `BugseeNetworkEvent` or `null`, or returns a
   future that does not complete within its timeout (default 10 s, the SDK's own filter timeout; at most 5 minutes)
   **drops that event**, like the SDKs (a hung filter drops the event on both). It is reported once in debug builds and
   counted (`filterFailures`). A filter that never answers therefore drops one event per timeout while the queue fills,
   and the queue then drops the rest: capture degrades to nothing, never to unfiltered.
4. **Threading.** The filter runs on the isolate that made the request (normally the UI isolate), one event at a time, in
   order, never inside the HTTP call. A slow synchronous filter takes UI time (the queue yields every 4 ms between
   events); an asynchronous filter does not block anything but its own event's turn. It is handed a **copy** (changing it
   cannot reach what the capture holds). It must not call back into code that waits for the HTTP request it is
   filtering.
5. **Then the SDK's own pipeline runs on what the filter returned, always.** Every event is submitted with
   `requiresFiltering = true` (`false` would skip both of these; the RN wrapper's rule too, "never pass false"):
   * if the app set a filter on the **native** SDK (`Bugsee.setNetworkEventFilter` from Kotlin/Swift), it runs on the
     event after the Dart filter. **Double filtering is by design**: the Dart filter is the wrapper's and runs first,
     the native one is the app's and runs second, the way the RN design orders "wrapper filter -> app filter" (§6.3.1). The
     native filter runs on the plugin's background thread, synchronously, and an exception it throws drops that event (caught
     natively: on Android it reaches the global handler for the SDK's own events, here it must not crash the plugin's thread;
     recorded as "refused by native");
   * otherwise (and only then, Android and iOS both document "applies only when no network event filter is set") the
     **default sanitizer** runs when `capture.network.default-sanitizer` is on (the default): query parameters, header
     values and JSON body values with sensitive keys are redacted. **A Dart filter does not replace it** (the SDK's
     filter slot is the native one): a Dart filter that returns the event with `authorization` untouched still gets it
     redacted by the sanitizer, unless the app turned the option off.
6. **Breadcrumbs see the event after the Dart filter and before the SDK's sanitizer.** With `captureBreadcrumbs` on, the SDK
   records one `http` breadcrumb per `complete`/`error` with the URL. Measured on the same run: **Android records that URL
   verbatim** (`?token=abc123` stays, by the SDK's design: "sanitization is the responsibility of the user's
   `setBreadcrumbFilter`", `BreadcrumbNetworkRequest.java`; it is the same for traffic the SDK intercepts itself) while iOS
   applies the query sanitizer to it (`?token=%3Credacted%3E`). A Dart filter runs first, so redacting the URL there
   protects the breadcrumb on both platforms; a breadcrumb filter is Phase 5 (`setBreadcrumbFilter` is not exposed yet).
7. The default sanitizer's rules are the SDK's and **differ per platform** (measured: the same `x-session: s1` request header
   was redacted on Android and kept on iOS; `authorization`, `set-cookie`, the `token` query parameter and JSON `token` /
   `password` values were redacted on both). Redact in the Dart filter what must be hidden on both.
8. **No URL leaves with userinfo** (`user:password@`, which `dart:io` accepts and turns into Basic auth): it is stripped in Dart
   (up to the LAST `@` of the authority, as `Uri` reads it: a password with a literal `@` goes entirely) from the event's
   `url`, `redirectedFrom`, URL-valued headers and error texts, and once more on the way out whatever a filter returned.
   **Fragments** are dropped from every recorded URL and URL-valued header too (OAuth callbacks put tokens in a redirect's
   `Location#...`; no SDK looks at a fragment). The SDKs strip it from the URL field only; the Android HTTP breadcrumb and error texts would keep it.
9. **URL-valued headers** (`location`, `content-location`, `referer`, `refresh`, request and response) lose userinfo and
   every query VALUE (`?token=abc` becomes `?token=<redacted>`): neither SDK sanitizes a header by its value, only by its
   name. Other headers are the SDK sanitizer's business. Redirect entries carry no headers at all.
10. The error text of an `error` entry never carries a URL's query string or userinfo (`HttpException` prints `uri = ...`;
   the SDK's sanitizer redacts the URL field, not the middle of a message).
11. Request cookies set through `request.cookies` are not captured (serialised by `dart:io` after the headers are read); the
   response's `Set-Cookie` is a response header, so the sanitizer's rules apply to it (redacted on both platforms, measured).

## The options that apply

All are the SDKs' own (`BugseeOptions`, generated from the published manifests; the policy test compares the keys, the
types and the defaults with `test/fixtures/option_manifests`):

| option | default | effect here |
|---|---|---|
| `captureNetwork` (`capture.network`) | on | off: nothing is captured and nothing is sent |
| `captureNetworkBodySizeLimit` | 20480 | see Bodies |
| `captureNetworkBodyWithoutType` | off | see Bodies |
| `captureNetworkDefaultSanitizer` | on | the SDK's sanitizer, see Privacy 5 |
| `captureNetworkOnLaunch` | off | not used: it installs the SDK's native interception early; this capture records nothing before `launched` |
| `endpoint` | the SDK's | the host is Bugsee's own and is never captured |

The policy is read from the SDK (`getLaunchOptions`, so an Android manifest auto-init is honoured too) when the capture is
installed, after every `launch`/`stop` and on every lifecycle status change. A stop takes effect at once, before the
options are read again. A failure to read leaves nothing accepted.

## Hot restart, install, uninstall, chaining

* `installNetworkCapture()` puts `BugseeHttpOverrides` in front of `HttpOverrides.current`. Clients are created by the
  **previous overrides**, whose settings (`badCertificateCallback`, `connectionTimeout`, proxies) stay; `findProxyFromEnvironment`
  is delegated to them; every setter the app uses on the client (`findProxy`, `badCertificateCallback`, credentials,
  `connectionFactory`, `keyLog`, ...) is forwarded to the real client. `CapturingHttpClient implements HttpClient` with
  no `noSuchMethod`, so a member added by a newer SDK fails to compile instead of being silently not forwarded.
* **Idempotent**: while the capture is the one in effect (probed by creating a client) a second call does nothing; after
  the app replaced the overrides without chaining it puts itself back in front of the app's. A client already wrapped by
  another layer of the chain is not wrapped twice.
* **Hot restart**: the overrides, the queue and the policy are per isolate, so a restart starts clean; the new
  isolate's `main` calls `installNetworkCapture()` again, the policy is read from the SDK (the lifecycle replay also
  tells it the SDK is launched), and events of the old isolate that were still queued are gone with it. Native keeps no
  network state.
* `uninstallNetworkCapture()` restores the previous overrides when the capture is still the one set; when the app chained
  over it, it stays in the chain and records nothing. It never touches overrides it did not install. Events captured before
  it (already through the filter) are still submitted: the app asked to stop recording, not to lose what it recorded; the
  SDK's own gate drops them if it is no longer launched.
* Called inside a zone that scopes its own overrides (`HttpOverrides.runZoned`), `installNetworkCapture` throws a
  `BugseeException` instead of making that scope global; call it from `main`. A repeated call probes whether the capture is
  still in effect (a real client is created and closed through the app's overrides) once per set of overrides in effect.
* Call it from the root isolate (a call from another is a `BugseeException`).

## Limits (known, documented, not bugs)

* **Other isolates**: `HttpOverrides.global` is per isolate and a background isolate has no channel to the SDK, so
  requests made there are not captured. Make the request in the root isolate, or record it with your own code there.
* **WebSocket frames**: not captured. The handshake is a normal exchange (`101`, no body). `WebSocket.connect` keeps a
  static `HttpClient` created on its first use; one used before the capture was installed stays unwrapped. Frames would
  need a wrapper around `WebSocket`/`dart:io` sockets that `HttpOverrides` cannot give; a package that wants them can
  record them with `Bugsee.event`/`trace` for now.
* **A client created before `installNetworkCapture`** by code that keeps it (a `static final HttpClient`, an app-wide
  singleton) is not wrapped. Install first, in `main`.
* **An app that replaces `HttpOverrides` without chaining** after installing, or a zone with its own overrides
  (`HttpOverrides.runZoned`/`runWithHttpOverrides` that do not chain), is outside the capture. Call install again to put
  it back in front (a probe says when it is needed).
* A request the app never `close()`s, and a response it never listens to, never completes.
* The app's own timeout (`Future.timeout` on `close()`) does not cancel the request, so the exchange completes when the
  server answers; `request.abort()` records an `abort`.
* **Native stacks** (`cronet_http`, `cupertino_http`, `native_dio_adapter`, a WebView, a platform channel) are captured
  by the SDKs' own interception, not this one; an app that uses both sees each request once, from its own stack.
* iOS: no `statusText`, no timings, no redirect stages; Android: `redirectedFrom` is not a field.
* `before.headers` are the request headers as `dart:io` holds them when the request is closed: the app's, plus the ones
  `dart:io` itself sets (`host`, `user-agent`, `accept-encoding`, `content-length`/`transfer-encoding`). Cookies added
  through `request.cookies` are serialised later and are not in it.
* The queue holds 512 events and 8 MiB; a burst the native side cannot absorb drops the newest events and says so
  in `networkCaptureStats`.
* **A body-size limit above 2 MiB is capped at 2 MiB** (`NetworkPolicy.maxBodyBytes`): memory is the cap times the requests in
  flight, and the queue's byte budget must hold a few events. A body over the cap is `size_too_large`, as if it were over the
  limit; the SDK itself would have kept it (the one place this differs from the option).
* `networkCaptureStats.submittedToSdk` counts events native SUBMITTED to the SDK's wrapper channel. It is not "recorded": the
  SDK still drops silently on a channel it retired or while its provider is stopped.

## Tests

`test/http_capture_test.dart` (real `HttpServer`, a differential test against an unwrapped client), `body_capture_test`,
`network_pipeline_test`, `network_service_test`, `network_facade_test` (the runtime with a fake native side),
`network_drift_test` (`test/fixtures/network_wire.json` against Dart, Java and Objective-C), JUnit `NetworkOpsTest` and
`NetworkWireParityTest`, XCTest `BGSFlutterNetworkOpsTests`. Every one of them was mutation-checked (PLAN.md 5b).
Runtime: `example/integration_test/network_test.dart`.

## Verified on a device

`example/integration_test/network_test.dart` against the real SDKs (Android emulator API 30 arm64, iOS 26.5 simulator),
with the SDK launched against a stand-in for the Bugsee API and a real report (`Bugsee.upload`); the SDK's own bundle
is the readback (`network.json`, `breadcrumbs.json`). 13 real requests from Dart through the installed capture: a JSON GET
with a token in the query and `authorization`/`x-session` headers, a JSON POST with a password in the body, a 404, a
two-hop redirect, a gzip response, a 30 000-byte text body (over the 20 KiB limit), a PNG, a streamed response cancelled
after its first chunk, a refused connection, a request to the SDK's own endpoint, and three requests with the Dart filter on
(one dropped, one with a header removed, one with the body hidden). Results (`Bugsee.networkCaptureStats` and the bundle):

| | Android | iOS |
|---|---|---|
| captured / submitted to the SDK / dropped by the filter / refused by native | 26 / 24 / 2 / 0 | 26 / 22 / 2 / 2 in the first run (the two redirect hops iOS has no stage for; since the review round they are not created on iOS, so 0 refused) |
| `network.json` entries | 24 | 22 |
| request made before launch, request to the SDK's endpoint, the filter-dropped `/secret` | absent | absent |
| redirect chain | `before`, `redirect` 302, `redirect` 301, `complete` (url = `/json`) | `before`, `complete` (url = `/json`, `redirect: true`) |
| cancelled stream | `abort`, size 12 | `cancel`, size 12 |
| refused connection | `error`: `SocketException: Connection refused ...` | the same |
| big text / PNG | `complete`, body null, `size_too_large` (size 30000) / `unsupported_content_type` (3000) | the same |
| gzip | `complete`, size 340, body decoded text, `content-encoding: gzip` header | the same |
| `?token=abc123` in the URL, `authorization`, JSON `password`/`token`, `set-cookie` | all redacted by the SDK sanitizer | the same |
| `x-session: s1` request header, no filter | redacted | **kept** (the SDKs' key lists differ) |
| with the filter: `x-session` removed / request body hidden | absent / `body: null, no_body_reason: cant_read_data` (also on the echoed response, although the filter was removed right after the call: it applies to what was captured under it) | the same |
| `timings` on `complete` | `ttfb`, `download`, `total` | none (no field) |
| `statusText` | `OK`, `Created`, `Not Found` | none |
| HTTP breadcrumb URL | `.../json?token=abc123&q=hello` (raw, see Privacy 6) | `.../json?token=%3Credacted%3E&q=hello` |

Review-round re-run (same harness, 34 requests: a URL with `user:pw@` and a token, a response with `location` /
`content-location` and a request with `referer`, a redirect the app follows itself): no `pw-SECRET`, `user:`, `u:p@` or
`LOCSECRET` anywhere in `network.json` or the breadcrumbs on either platform; the URL-valued headers read
`/final?token=<redacted>&x=<redacted>`, `http://h.example/x?a=<redacted>`, `http://h.example/p?k=<redacted>`; the manual
redirect is two exchanges (`before`+`complete` 302, `before`+`complete` 301, `redirect: true` on iOS); Android 32 of 34
submitted (2 filtered), iOS 30 (2 filtered, 2 redirect hops refused by design).

Not shown on a device: a launched SDK with `capture.network` off (covered by the policy tests), a real server's acceptance of
the upload (the stand-in refuses it on purpose so the bundle stays), the iOS `Launching`-window drop (the Dart gate never sends
then).

## Reading a bundle on Android

```sh
adb shell run-as <package> find files/bugsee_data/bundles
adb exec-out run-as <package> cat files/bugsee_data/bundles/<id>.bundle.zip > b.zip && unzip b.zip   # *.network.json
```

iOS (simulator): `$(xcrun simctl get_app_container <udid> <bundle id> data)/Library/Caches/com.bugsee.data/capture/bundles/*.bundle.zip`
(zstd-compressed: `7zz x`). An Android debug build needs cleartext traffic allowed to reach a stand-in on `http://10.0.2.2`
(`<application android:usesCleartextTraffic="true"/>` in the debug manifest, temporarily); `--dart-define=NET_HOLD=<s>` keeps the
test's app alive while the bundle is read, because the harness uninstalls it. `network.json`'s entries and fields:
`reporting/bundle/network.md` in the specs repository.

## SDK source read

Android `bugsee/bugsee-android` tag `v7.4.2`: `Bugsee.java` (`addNetworkEvent`, `setNetworkEventFilter`,
`getExchangeFactory`), `BugseeInternal.java:975-986` (gate), `BugseeEnvironment.java:709` (`setWrapper`),
`BugseeWrapperChannelImpl.java`, `contracts/internal/BugseeWrapperChannel.java`, `BugseeExchangeFactoryImpl.java`,
`contracts/exchange/NetworkEvent.java`, `capture/providers/network/BugseeCaptureDataProviderNetwork.java`
(`onNetworkEvent`, `applyBodyFilters`, `filterEntry`, `FILTER_CALLBACK_TIMEOUT_MS`), `interception/network/NetworkEventsProducer.java`
(`getRequestBody`, `getResponseBody`), `NetworkUtils.isSupportedMediaType`.
iOS `bugsee/bugsee-ios` `0581aa02c`: `Bugsee.m:2109-2166`, `BGSContracts.h` (`BGSWrapperChannel`),
`BGSWrapperChannelImpl.m`, `BGSExchangeFactory.m`, `BugseeNetworkEvent.{h,m}`, `BugseeConstants.{h,m}`,
`Capture/Providers/BGSCaptureDataProviderNetwork.m`, `BGSCaptureDataEntryNetwork.m`,
`Interception/Network/BGSNetworkInterceptionHelper.m`.
