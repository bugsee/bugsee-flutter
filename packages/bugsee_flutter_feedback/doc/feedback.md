# The feedback package: what the SDKs offer, what is exposed, how it registers

Phase 8a of PLAN.md (decision D4: a separate package, mirroring the native split and the React Native SDK's
`@bugsee/react-native-feedback`). Sources read: Android `bugsee/bugsee-android` tag `v7.4.2` (`3b7af6371`), module
`feedback/` and `.claude/rules/extensions.md`; iOS `bugsee/feedback-spm` tag `7.0.0-beta7` (`40dd3b0`, the same sources
as `bugsee/bugsee-ios` `feedback/`); the Bugsee Gradle plugin `bugsee-android-gradle-plugin`
(`instrumentation/extensions_init/ExtensionSpec.kt`, `BugseePluginExtension.kt`).

## What the SDKs expose

| Capability | Android (`com.bugsee.library.contracts.extensions.Feedback`) | iOS (`BugseeFeedbackExtension`) | Decision |
|---|---|---|---|
| show the chat | `showFeedbackActivity()` (`BugseeFeedback.kt:120`, returns at once when the SDK is not launched) | `showFeedbackUI()` (`BugseeFeedback.swift:145`, no launch check; presents over the topmost view controller of the key window) | **expose** `BugseeFeedback.show()` |
| greeting | `setDefaultFeedbackGreeting(String?)` (stored in preferences, survives restarts; a dashboard greeting wins: `FeedbackPreferences.getEffectiveGreeting`) | `setGreeting(String?)` (in memory) | **expose** `setGreeting`, difference documented |
| listener | `setOnNewFeedbackListener(FeedbackListener?)`: `onNewMessagesReceived(List<String>)` on a worker thread, `onNewMessageSent(String)` | `setListener(BugseeFeedbackListener?)` (held WEAKLY by the SDK), same two callbacks on the main thread | **expose** as two streams, native listener installed while any is listened to |
| unread count, notification settings | none | none | not invented |
| option keys | none: the published options manifests (`test/fixtures/option_manifests`) list modules `bugsee-android`, `bugsee-android-leak`, `bugsee-android-ndk` only | none | nothing to type |
| user identity | reads `Bugsee.setUserIdentifier`: a value containing `@` pre-fills the e-mail and skips the e-mail screen (`BugseeFeedback.prefillEmailFromUserIdentifier`) | same (`FeedbackEmailPreferences.prefill(fromUserIdentifier:)`) | documented; `Bugsee.setUserIdentifier` is the core's |
| appearance | `FeedbackAppearance` keys through `Bugsee.getAppearance()` | `BugseeTheme.feedback*` (the 7.0.0-beta7 SwiftUI chat does not read it) | **skip**, like the core's appearance system |
| lifecycle events | `BeforeFeedbackShown` / `AfterFeedbackShown` (`FeedbackLifecycleEvents`) are dispatched | declared (`BugseeLifecycleEventBeforeFeedbackShown`) but "not dispatched yet" (`BugseeConstants.h`) | already carried as names by the core's `lifecycleEvents` stream; nothing added |
| message objects | `FeedbackMessage` / `FeedbackMessageType` (contract types, not delivered by the listener) | `BugseeFeedbackMessage` (Swift only, not delivered) | **skip**: the listeners deliver text only |

The package is therefore thin: three operations and one listener, no invented API.

## Registration

* **Android.** `BugseeFeedbackInitProvider` (in the AAR, `initOrder=200`, before the core's `BugseeInitProvider`) calls
  `BugseeFeedback.registerFeedbackExtension()`, which registers the instance in `BugseeExtensions` keyed by the
  `Feedback` interface (`Bugsee.ext(Feedback.class)`). The Bugsee Gradle plugin (`optimizeExtensionsLoading`, on by
  default) strips that provider from the merged manifest when its FQN is in `ExtensionSpec.KNOWN`
  (`com.bugsee.library.BugseeFeedbackInitProvider`) and rewrites `BugseeInitProvider#initializeExtensions()` to call
  `com.bugsee.library.BugseeFeedback.registerFeedbackExtension()` (`register<Name>Extension` on `Bugsee<Name>`,
  derived by the table). Plugin 4.0.6 stripped providers and injected nothing (the core pins >= 4.0.7). The core
  plugin's provider (`FlutterWrapperInitProvider`) is not in the table and is left alone; this package adds NO
  provider (a guard asserts it, and that no class of it matches `^.*\.Bugsee[A-Za-z0-9_]+InitProvider$`).
  Because the SDK already does the work in both modes, the package's own call is a safety net:
  `BugseeFeedbackSdk.registerIfMissing()` runs when the engine attaches, logs which path had registered the module, and
  registers it (the SDK's own idempotent method) only when the SDK had not.
* **iOS.** `BugseeFeedback.register()` (`Bugsee.registerExt(shared)`) must run before `Bugsee.launch`, or the add-on misses
  the launch fan-out (a late registration is launched at once if the SDK is already `Launched`, and `launch` is idempotent
  in the add-on). The product vends an Objective-C shim, `BugseeFeedbackAutoRegister`, whose `+load` calls it, and its header
  says that a static link without `-ObjC` may dead-strip it. This package does not rely on it: its own
  `BGSFlutterFeedbackRegistrar` has the same `+load` and is referenced by the Swift plugin class (`register(with:)`), so the
  translation unit is kept; `dispatch_once` makes it idempotent with the shim.

## Versions and publishing

* Layout: `packages/bugsee_flutter_feedback`, a member of the repository's **pub workspace** (root `pubspec.yaml`
  `workspace:`, with `example`). Inside the workspace the feedback package's hosted constraint on `bugsee_flutter`
  resolves to the sibling; outside it (an app, pub.dev) to the hosted package. A path dependency would not be
  publishable, and `dependency_overrides` would have to be repeated in every consumer. The root `.pubignore` drops
  `/packages/`, so the root package does not ship the sibling. Publish the core first, then the feedback package.
* Versions: the same number as the core, released together. The constraint is `>=<core version> <next minor>` (pub warns
  about an exact pin, and `^` would let a newer core minor with other native pins in); at run time the Dart side also
  compares its own version with the core's (`BugseeFeedbackFailure.incompatibleCore`). `test/feedback_package_drift_test.dart`
  asserts all of it.
* Native pins: the Android artifact and the iOS exact pins are literals in the package's `build.gradle` / `Package.swift`
  (a published copy has no `native-versions.json` next to it); the same test compares them to `native-versions.json`.
