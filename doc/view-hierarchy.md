# The managed view hierarchy (`vh`)

A Flutter app is one native view, so the SDKs' own view-hierarchy capture sees a single `FlutterView`
and nothing of the UI. When the SDK builds a report it therefore asks the wrapper for the app's own
tree through the internal data-request channel (type `vh`). The wrapper answers with a JSON `String`
that the SDK stores in the report's `viewtree.json` entry (`managed`) **byte for byte, without parsing
or redacting it**. Everything private about that tree is decided here.

Sources of truth, read for this design: `bugsee/specs` `sdk/wrapper-data-requests` (the `vh` flow),
`sdk/wrapper-workbook` Part 5.3 (units) and Part 6 (data requests, 6.7 async replies), `sdk/reporting/bundle/viewtree.md`
(privacy, the node vocabulary), the Android SDK at `v7.4.2` and the iOS SDK at `origin/nextgen@0581aa02c`
(= the 7.0.0-beta7 headers). Where they disagree, the SDK source is followed and the disagreement is listed under
[Spec gaps](#spec-gaps-found).

## What the SDKs do (from source)

| | Android 7.4.2 | iOS 7.0.0-beta7 (nextgen `0581aa02c`) |
|---|---|---|
| asked by | `BugseeCaptureDataProviderViewHierarchy.onBeforeSnapshotCreated` (every report snapshot, not while the process is terminating) and `Bugsee.captureViewHierarchy()`; one request per display, none for a blacked-out display or one with no top activity | `BGSCaptureDataProviderViewHierarchy -onBeforeSnapshotCreatedIsTerminating:` (same exceptions) and `+[Bugsee captureViewHierarchy]` |
| thread of `requestData` | main (`ViewHierarchyBuilder.requestAdditionalData`, `@UiThread`) | main (`requestManagedHierarchyFromWrapper:`) |
| budget | `DataRequestTypes.VIEW_HIERARCHY_TIMEOUT_MS` = 500 ms, a delayed task on the main handler **posted after `requestData` returns** | `BGSManagedHierarchyTimeoutMs` = 500 ms, `dispatch_after` on a global queue after the call returns; after 3 timeouts in a row cut to 50 ms (`BGSManagedHierarchySilentTimeoutMs`) |
| a late reply | ignored (atomic claim) | ignored |
| does the report wait for an async reply? | **Only when the snapshot is made off the main thread** (`SnapshotPassBarrier`, bugsee-android PR #120, commit `ce8529c8b`, 2026-09-21, **an ancestor of the `v7.4.2` tag**: the code is in the tag). When the snapshot is made ON the main thread the barrier is `null` and a late reply "lands in the next report" (the SDK's own comment). | waits up to 500 + 250 ms off the main thread; **on the main thread the wrapper is not asked at all** (`capturePassAskingWrapper:NO`, "a wrapper answering through the main queue would deadlock against this very thread") |
| entry timestamp | `TimeUtils.monotonicWallTimeMillis()` **at the reply**, not at the moment the tree was true | the same, at record time |
| payload limits | none (the string is stored as is; `config.max-data-size` is the whole session's) | none |
| payload type | `String` (`DataRequestResultCallback.onResult(@Nullable String)`) | `NSString`; a non-string is treated as `nil` |
| off switch | `com.bugsee.option.capture.view-hierarchy` (boolean, default true) controls the whole provider | the same key, default `YES` |

`bugsee/specs` still lists the Android reporting wait as "a known defect" (data-requests open item 1b, workbook 6.7
"in flight"). At 7.4.2 it is fixed for snapshots made off the main thread and not for ones made on it; this is
stated as measured below.

## Design: a native snapshot cache

Dart runs on its own isolate and replies through a platform channel, which needs the platform (main) thread. The SDK
asks on that same thread and starts its 500 ms clock when the call returns. So:

* **Waiting for Dart inside `requestData` is a deadlock** (the thread Dart needs is the one waiting). The report pipeline
  already avoids the same trap (`.claude/CLAUDE.md`, "Report handlers").
* **Replying later is fragile**: it is counted against 500 ms of a busy main thread, a reply that arrives after the
  snapshot closed lands in the next report (Android, snapshot on the main thread) or is never asked for (iOS, same case),
  and on iOS a wrapper that misses the budget three times is cut to 50 ms.

So Dart **pushes** the tree to native memory and native **answers synchronously, from memory, on whatever thread
asks** (`ViewHierarchyStore` / `BGSFlutterViewHierarchyStore`). The reply is therefore always inside the
`requestData` call, before the SDK's clock even starts, on every path that asks. The same reasoning as the secure
rectangles (`SecureRectangleStore`): the SDK reads, Dart writes, the state lives outside the wrapper object and is an
immutable snapshot swapped whole.

```
 Dart isolate                                   platform thread (main)         SDK
 -------------------------------                ----------------------         -----------------------
 frame -> post-frame / timer                                                    report snapshot / captureViewHierarchy
   buildViewHierarchy()  (elements + render)                                      |
   same as native's copy? -> nothing                                              v
   Pigeon setViewHierarchy(template+boxes) ---> ViewHierarchyStore.publish     requestData("vh")
                                                 (immutable, per owner)  <----  answer(): placement refresh,
                                                                                convert boxes (shared Mapper),
                                                                                fill in age -> String | null
```

What the pieces are:

* **`lib/src/view_hierarchy/hierarchy_builder.dart`** walks the element tree with its render objects and returns a
  `HierarchySnapshot`: a JSON **template** (text cut at the snapshot's age and at every node's box) plus the boxes in
  the Flutter view's logical pixels.
* **`publisher.dart`** decides when to build and send (below). **`controller.dart`** gates it.
* **Native stores** keep the latest snapshot per Dart isolate, and at answer time convert each box with the same code
  that places the secure rectangles, fill in the age and join the text. No JSON is parsed natively.
* **`Bugsee.captureViewHierarchy()`** (public, mirrors the native call): brings native's copy up to date, then asks the
  SDK for a pass.

Alternatives rejected: answer-on-request over the channel (deadlock/async, above); rendering the final JSON in Dart with
screen coordinates (Dart cannot know the view's current screen position or the density the SDK will read at report time:
the unit/placement logic must be the secure rectangles' one, on the native side, at answer time); parsing and rewriting
JSON natively (cost on the main thread, a second JSON path to keep private).

### When Dart publishes

All three must hold (`controller.dart`), otherwise nothing is built and native's copy is cleared:

1. the SDK is **launched** (`Launched` status; the gate follows the lifecycle stream, and the status Dart already holds
   when it attaches);
2. the SDK's **`capture.view-hierarchy` option is on** (read with `getLaunchOptions` once launched; unreadable counts as off);
3. the app is in the **foreground** (`resumed` or `inactive`; `hidden`, `paused`, `detached` clear native's copy, `resumed` republishes).

While active the publisher (`publisher.dart`):

* builds only in a **post-frame callback or a timer, never inside a frame** (a test records the scheduler phase);
* schedules **no frame of its own** (only the frame that starts it): Flutter draws nothing without a frame, so with the app
  idle nothing runs;
* spaces builds by `max(300 ms, 20 x the cost of the last build)`, capped at 5 s, with a trailing build so the last change
  of a burst is not lost;
* sends **only when the payload changed**; a failed send is retried with a doubling backoff (never given up, 30 s cap), and
  a clear that failed is retried until it lands;
* cuts the walk by a **12 ms budget**, **2000 nodes**, **256 KiB**, **512 element levels** (a provider of data, an `InheritedElement`, is not a level: a Material app has dozens): over a cap the tree is cut
  and the cut nodes carry `"truncated": true` (and the root's `options.truncated`), the answer stays valid; a template over
  the byte cap is dropped, not trimmed.

Measured: a stock Material screen (app bar with tabs, a `TabBarView`, a list of 40 `Card(ListTile(Icon, Text, Checkbox))`) is **771 nodes / 81 KB** (~105 bytes a node) and is not cut at the limits (a regression test builds it with and without caps and compares); the small example screen is 316 nodes / 30.8 KB, and one walk of it took 2.7 ms on the Android emulator and 1.8 ms on the iOS simulator (debug build, JIT, so a ceiling). The walk's byte estimate is the real size within a few percent and stops 1/16 short of the cap; the exact check at the end drops a template that is still over.
30.8 KB on the Android emulator (`integration_test/view_hierarchy_test.dart` prints the cost of one walk).

### What the answer is, and when it is null

`requestData("vh")` answers, synchronously and once: the newest snapshot, rendered for the screen as it is **now**, or
`null`. It is `null` (the SDK records nothing from the wrapper, the native half is still recorded) when there is no
snapshot; when Dart's engine detached (the snapshot is dropped with it: a detached engine serves **nothing**, never a stale
tree); when the Flutter view is not placed or is known off screen; when a placement refresh is stuck (a main thread that is
not answering for 1 s, as for the secure rectangles); when the density/scale the boxes were measured at no longer matches
the display's; when any box is not finite or out of range; when a message was malformed or too large (that clears the
snapshot). Never a partial document. Every other data-request type answers `null`, as before; the wrapper is replaced when
Dart refines its identity and serves the same cache.

### Staleness

A snapshot is as of the **last frame that changed the tree, plus the publisher's throttle** (300 ms by default, more after
an expensive build). Flutter draws only on a frame, so a screen that has not changed is described exactly however old the
snapshot is: there is deliberately **no maximum age**. The exceptions are a UI isolate that is blocked or dead while the app
lives (then native keeps the last snapshot; the only guard is that the engine's detach drops it) and the throttle window
itself (a report made within ~300 ms of a change can carry the screen before it).

The SDK **does not know the age**: it stamps the entry with the time of the reply. So the payload carries it: the root's
`options.age_ms` is `now - the moment native received the snapshot`, computed at every answer (so an old snapshot says it is
old). `Bugsee.captureViewHierarchy()` flushes the publisher first: if a frame is already scheduled (a route just pushed, a `setState` not drawn yet) the flush waits for it, up to 3 frames and 400 ms (a new route is built off stage in one frame and shown by the next; a screen that never draws, or animates forever, never hangs it), then builds at once, ignoring the throttle. So a capture asked for explicitly is as fresh as a walk, except that the wait is bounded.

## Payload

One JSON object, the root node (not an array, not the native `TOPITEM` document). The viewer reads it as a
`RecordingViewTreeNode`. The SDK escapes it as the string value of `managed`; the viewer must parse that string (spec open
item 2, not ours to fix).

| key | type | presence | meaning |
|---|---|---|---|
| `id` | string | always | The node's position in document order within this snapshot (`"0"`, `"1"`, ...). Not stable across snapshots, not derived from anything the app wrote. |
| `class_name` | string | always | The widget's `runtimeType` without generic arguments (`Scaffold`, `Text`, `_LoginState`...), at most 80 characters; the root is `FlutterView`, a secure view is `BugseeSecureView`. Always an identifier (`[A-Za-z_$][A-Za-z0-9_$]*`), **enforced**: a name that is not one (an overridden `runtimeType` whose `toString` says anything) becomes `Widget` (and `RenderObject` for `base_class_name`). Under `--obfuscate` these are minified: the root says so (`options.obfuscated`). |
| `base_class_name` | string | for widgets that own a render object | The render object's type (`RenderPadding`). |
| `bounds` | number[4] | always | `[x, y, width, height]` in **screen coordinates in the unit of the platform's native tree**: physical pixels in the space of `View.getLocationOnScreen` on Android, points in the screen's coordinate space on iOS. Whole numbers, rounded outward. |
| `options` | object | only when something is set | `secure: true` (a secure view), `clickable: true` (something can be tapped: a gesture detector or a `Semantics` tap/long-press action; only that a callback exists is read), `alpha` (an `Opacity`'s value), `content_kind` (`image` for a `RenderImage`, `surface` for a platform view: says pixels exist, nothing about them). The root's: `age_ms`, `device_pixel_ratio`, `obfuscated`, `truncated`. |
| `truncated` | `true` | only on a node whose children a cap cut | as the native tree's marker. |
| `subitems` | node[] | when it has painted children | in **paint order, back to front** (Flutter has no z property; the viewer's tie-break after `layer_zpos` is declaration order). |

Names follow the native view node (`hidden`, `alpha`, `clickable`, `secure`, `content_kind`). There is no `hidden`: a node
that is not painted is not emitted (below).

Source tree: the **element tree walked with its render objects**, not the semantics tree. Elements give a name to every
widget, including the app's own composites (`LoginScreen`); render objects give exact geometry and tell what is painted.
The semantics tree exists for accessibility, carries the user-visible **text** (labels, hints, values), is built lazily
(reading it would also switch on semantics cost), and is the privacy risk the other trees are not.

What is in the tree: **only what is on stage and painted**. Not emitted: an `Offstage`, a `Visibility(visible: false)`, a
zero `Opacity`, an `IndexedStack`'s other children, a route an opaque route covers (the `Overlay` keeps those off stage; a
dialog is a transparent route and the page below stays), a node wholly outside the screen or outside a clip an ancestor
applies (a list item scrolled out of its viewport, found with `RenderObject.describeApproximatePaintClip`), a node that was
never laid out or has no area. A node whose own box is off screen is not emitted, but what it paints below is still walked unless it clips its children to that box (a `Transform` or `FractionalTranslation` can move a child onto the screen); a secure region is never walked into. A node whose render parent is not its element parent (an `OverlayPortal` child lives in the overlay's theater: `MenuAnchor`, `DropdownMenu`, autocomplete options, tooltips) is placed and clipped by its REAL render ancestors, and listed last among its host's children (on top). Known gap: an `OverlayPortal` under an `Offstage` is not walked at all (the element walk does not enter an `Offstage`), so what the overlay paints for a hidden anchor is not described: a gap in the description, never a leak. Inherited elements (`Theme`, `MediaQuery`, ...) have no box and are not nodes. The soft keyboard
and any native window are not Flutter's: the native tree has them. Only the implicit view (id 0) is described on mobile.

## Privacy

The SDK cannot look inside `managed`, so every rule is enforced here, by construction, and tested.

| rule | how it is enforced | test |
|---|---|---|
| no text content (`Text`, `RichText`, `SelectableText`, text fields, chips, list tiles) | the builder never reads a paragraph, editable, span or controller; the only strings it takes from the tree are `runtimeType` names | `view_hierarchy_privacy_test.dart` feeds 31 user-looking strings through every channel and fails on any appearance |
| no `TextEditingController` value, no typed input | not read; checked after `enterText` | same |
| no semantics label, hint, value, identifier, tooltip, `semanticsLabel` | the semantics tree is not used; `Semantics` nodes are described as ordinary nodes; only whether a tap/long-press callback exists is read (`p.onTap != null`) | privacy test, also with the semantics tree switched on; drift guard bans label/hint/value/tooltip reads |
| no `Key` or `ValueKey`, no `Hero` tag, no route name, no `Restoration` id | not read. A key's string is arbitrary app data (a `ValueKey<String>(user.email)`); the spec's own example puts `widget.key.toString()` in `options.key`, which is exactly what is **not** done. `id` is a counter, not a key or a hash (a hash of a short string is reversible). There is deliberately **no developer-opt-in identifier yet**; if one is added it must be an explicit type (`BugseeKey('name')`), never a `ValueKey` | privacy test; drift guard bans `.key`, `Key`, `ValueKey`, `GlobalKey` in the builder |
| never `toString()` of a widget or element (a widget's `toString` may print its text) | the only `toString` is on a `runtimeType` | a widget with an overridden `toString`/`debugFillProperties` in the privacy test; drift guard counts the calls |
| no image data | only `content_kind: image` | privacy test |
| a `BugseeSecureView` subtree is redacted **whole** | the region's own node is emitted with a **fixed** type name (`BugseeSecureView`), `secure: true`, its box exactly as the secure rectangle measures it (so it covers the same area the video masks, including what its children paint outside their box), and **nothing below it, not even the children's type names** | builder tests (keys of the node, no subitems, nothing named inside), privacy test "from inside a secure view", device test |
| every string is an identifier | `class_name`, `base_class_name` match `[A-Za-z_$][A-Za-z0-9_$]*`; options are numbers, booleans and two fixed words | privacy test walks every node of a real tree |
| caps and fail closed | caps above; **any exception returns `null` and sends nothing** (an old snapshot is then taken back); native answers `null` when anything cannot be trusted; nothing throws into the app | builder tests (an exploding render object, a NaN transform, over-cap trees), native tests |
| a blackout | the SDKs ask for nothing for a display under blackout (Android and iOS source); nothing to do here | n/a |

A Dart class name is developer-chosen and not user data; it is the one thing the payload says about the app's own code
(the native tree names Compose functions the same way).

Not covered, as for the secure rectangles: pixels a widget draws outside its own subtree (an `Overlay` tooltip or magnifier) are not
part of the secure node, and appear as ordinary nodes with their type and box; a secure region that has *just appeared*
is described as an ordinary subtree (type names and boxes, never text) until the next snapshot, at most the throttle plus the
frame it appeared in.

## Units and placement

The same code as the secure rectangles, on purpose (workbook 5.3, 6.6): `SecureRectangleStore.Mapper` /
`BGSFlutterPlacementMapper` combines the device pixel ratio the boxes were measured at, the SDK's unit (Android: 1 per
physical pixel; iOS: `1 / UIScreen.scale`, so a logical pixel is exactly one point), the view's own scale on screen and
its position on the screen, and both stores use it. Dart never produces a screen coordinate. The conversion happens **per
answer**, with the placement refreshed first (synchronously when the SDK asks on the main thread, as the main thread is
where the view is read), so a view that moved with no Dart frame (split screen, a window drag) is served where it is. Edges
are scaled first and rounded outward last, like the rectangles. Unplaceable, off screen, a ratio that no longer matches the
display, a stuck refresh: `null` (the secure rectangles cover the whole display in those cases; for a description,
"nothing" is the safe answer).

The origin is the Flutter view's position in the screen (`getLocationOnScreen`; the iOS screen's coordinate space), so a
`FlutterFragment` or an embedded view is offset correctly: this is the spec's open item 6, solved by the shared placement.
Verified on a device only for a view at the origin; the offset is covered by JUnit/XCTest.

## Public surface

`Bugsee.captureViewHierarchy()` mirrors the native `Bugsee.captureViewHierarchy()`: it flushes the publisher (when
publishing is on) and asks the SDK for a pass, which the cache answers. A no-op before launch, after stop and with the
`captureViewHierarchy` option off. Nothing else is public: the rest is driven by the SDK's own option and status.

## Spec gaps found

* `wrapper-data-requests` open item 1b and workbook 6.7 call the Android "wait for the reply" an unfixed defect; at
  `v7.4.2` PR #120 is in, and the wait exists **only for snapshots made off the main thread**. A snapshot made on the main
  thread still records a late reply into the next report (the SDK's comment says so), and iOS does not ask at all there. A
  synchronous reply works on every path, which is why the cache exists. (Measured: with a temporary 50 ms asynchronous reply
  the report made by `Bugsee.upload` still carried the tree, because that snapshot is made off the main thread.)
* The spec's iOS "1000 ms for the main-thread walk" and "500 + 250 ms" are as in source; the 50 ms silent-wrapper backoff
  is not a concern for a wrapper that always answers.
* Open item 6 (Flutter bounds relative to the FlutterView) is fixed here (placement), as is the payload's use of the
  device pixel ratio.
* The spec's example puts `widget.key.toString()` into `options.key`; this wrapper does not (privacy above).

## Not verified / known limits

* A real report on **iOS**: the placeholder token makes the SDK refuse its first upload and stop, so no report bundle is
  assembled on a simulator. The device test reads the SDK's capture buffer instead (the view-hierarchy entries with the
  payload byte for byte); that the entry reaches an uploaded bundle is shown on Android only.
* A Flutter view that is **not at the screen origin** on a device (add-to-app, split screen): JUnit/XCTest only.
* Several displays (Android: presentation, DeX): the SDK sends one request per display, skips a blanked one, and the request
  does not say which display is asking, so the one snapshot of the Flutter view is served to whichever asks. To keep that from
  leaking a screen the SDK blanks, Android answers `null` when the Flutter view's window has `FLAG_SECURE` (the SDK's
  `isActivityFlagSecureBlackOut`, default on through `captureRespectFlagSecure`), when `Bugsee.isBlackout()` is true, or when it
  cannot tell (`ViewHierarchyStore.BlackoutGate`; JUnit only, not exercised on a device). The tree of a Flutter display is still
  served for another display's pass when nothing blanks it: a duplicate entry with the Flutter view's own coordinates. iOS has
  one display.
* Multi-engine: the newest snapshot that can be rendered is served (newest first; a newer one whose view is hidden does not
  hide an older one that is shown).
* `--obfuscate` release builds: names are minified and flagged, not decoded.
* A hot-restarted isolate that publishes nothing leaves the old isolate's snapshot until the engine detaches (debug only).
* The Dart walk is synchronous on the UI isolate and bounded by 12 ms / 2000 nodes, not preemptible: a huge tree is cut, not
  skipped.

## Mutation checks and the mutants that were not killed

Every test of this phase was mutation-checked: the behaviour broken, the test seen failing, the code restored (Dart about 80
mutants, Java 23, Objective-C 23). Twelve Dart mutants survived the first round and led to stronger tests (clip, zero-size
nodes, providers, the obfuscation flag, the trailing build, a stale option read, the lifecycle observer, attach-once,
capture-flush ordering). Left, with the reasoning:

* **Non-finite boxes kept** (`_finite` removed): equivalent. A NaN or infinite box already fails the on-screen test
  (`_touches` is false for it), so the guard is defence in depth that no input can reach alone.
* **Another view's tree walked into** (`ro is RenderView` branch removed): not testable here. `flutter_test` cannot create a
  second `FlutterView` under the first, and mobile has one view. The branch is a guard for add-to-app multi-view.
* **Frame callback builds while inactive** (`_onFrame` without the `_active` check): equivalent. `_consider()` refuses when
  inactive, so the extra callback does nothing.
* **Walking into an off-screen clipping parent** (`_clipsChildren` always false): equivalent in output. What such a parent
  clips is excluded by the clip carried down anyway; the check only saves walking nodes that cannot show.
* **The portal child's real ancestors not asked whether they paint it** (`paintsChild` removed in the fallback placement):
  equivalent today. A render ancestor that does not paint the child is also not painted in the element walk, which stops at the
  first such node before the fallback is reached; the check is there for a framework that separates the two.
