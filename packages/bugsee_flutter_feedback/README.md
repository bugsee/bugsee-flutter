# bugsee_flutter_feedback

> **Status: the 7.x rewrite, in progress (10.0.0-dev.1, unpublished).** Released together with
> [`bugsee_flutter`](../../README.md) 10.0.0-dev.1; nothing here works without it.

The in-app feedback chat for [`bugsee_flutter`](../../README.md): your users write to you from inside the
app, with the same session context Bugsee already captures, and you answer from the Bugsee dashboard.

It is a separate package on purpose, like the native SDKs' own split (`bugsee-android-feedback`, and
`feedback-spm` on iOS): apps that never show the chat do not carry it. On iOS it is a SwiftUI screen, on
Android a Jetpack Compose activity (Compose, Material 3 and a rich-text editor come with it); `bugsee_flutter`
itself has neither.

## Install

Add both packages, and nothing else:

```yaml
dependencies:
  bugsee_flutter: ^10.0.0-dev.1
  bugsee_flutter_feedback: ^10.0.0-dev.1
```

Use **the same version of both** (this package's `bugsee_flutter` constraint is `>=10.0.0-dev.1 <10.1.0`, and it
checks at run time that the core is the same major and minor): the two are released together and pin the same
native SDK versions.

Everything `bugsee_flutter` needs applies unchanged (see its README): Flutter 3.41.0 or newer, the
`com.bugsee.android.gradle` Gradle plugin applied in your app, iOS 15.0 or newer, and Swift Package Manager
for iOS (there is no CocoaPods pod: `flutter config --enable-swift-package-manager` where it is not the default).

There is nothing feedback-specific to add to the manifest or to `Info.plist`:

| | |
|---|---|
| Android | `com.bugsee:bugsee-android-feedback` (the same version as the core SDK) is added by this package. Its `FeedbackActivity` and the `INTERNET` permission are merged into your manifest from the AAR; the activity sets its own AppCompat theme, so your app's theme does not matter. minSdk 21 (the SDK's floor). |
| iOS | The `BugseeFeedback` product of [`feedback-spm`](https://github.com/bugsee/feedback-spm), pinned exactly to the core SDK's version, is added through this package's own SwiftPM plugin package. No `Info.plist` keys (the chat sends text only: no camera, microphone or photo access). The add-on ships its own privacy manifest. |

### How the module registers itself

You do not register anything.

* **Android**: the feedback AAR declares its own initialization provider
  (`com.bugsee.library.BugseeFeedbackInitProvider`, merged into your manifest) that registers the module with the
  SDK before your app runs. With the Bugsee Gradle plugin's default `optimizeExtensionsLoading` the plugin strips that
  provider and makes the SDK's own `BugseeInitProvider` call `BugseeFeedback.registerFeedbackExtension()` instead; this
  package works either way, and registers the module itself (idempotently) when the engine attaches if neither
  happened. It adds no provider of its own.
* **iOS**: this package registers `BugseeFeedback` at image load (`+load`) and when its plugin registers. The add-on's
  own `+load` shim could be dead-stripped from a static link; ours is referenced by the plugin's Swift code, so it is
  not.

`await BugseeFeedback.isAvailable()` tells you whether the SDK has the module (use it before offering a "contact
support" button); a call that needs it throws a `BugseeFeedbackException` with reason `notRegistered` otherwise.

## Use

```dart
import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_feedback/bugsee_flutter_feedback.dart';

Future<void> setUpSupport() async {
  await Bugsee.launch('YOUR_APP_TOKEN');

  // The text an empty conversation opens with (null clears it).
  await BugseeFeedback.setGreeting('How can we help?');

  // Present the chat.
  await BugseeFeedback.show();

  // Messages, as text only. The native listener is installed while a stream has a listener.
  final received = BugseeFeedback.messagesReceived.listen((messages) { /* from the dashboard, oldest first */ });
  final sent = BugseeFeedback.messageSent.listen((message) { /* the user sent one */ });
}
```

The streams fire **only while the chat is on screen** (both SDKs poll the backend only then), so they are not a source of
unread-badge or notification signals; neither SDK has one.

That is the whole API, because it is all both SDKs have: show the chat, the greeting, and the listener. Neither
SDK has an unread count, a notification setting, an option key for the chat, or a separate user name or e-mail
(the chat asks the user for an e-mail address itself, and skips that screen when the identifier you set with
`Bugsee.setUserIdentifier` contains an `@`). The chat's colours (`FeedbackAppearance` on Android, `BugseeTheme` on iOS) are
not exposed, like the core's appearance system (see `bugsee_flutter`'s `doc/api-surface.md`): the iOS 7.0.0-beta7 chat does not read
`BugseeTheme` anyway. The details, with source references, are in [doc/feedback.md](doc/feedback.md).

Call it after `Bugsee.launch`: on Android `show()` does nothing before the SDK has launched; on iOS it presents a chat
that cannot reach the backend.

## Errors

Every error is a `BugseeFeedbackException` (a `BugseeException`) with a `reason`:
`notRegistered`, `incompatibleCore` (the `bugsee_flutter` in the build is not the version this package was released with: a
path, git or overridden dependency, or a stale build) or `nativeError` (the plugin is not part of the build, a missing rebuild
after adding the package, or the SDK threw). On a platform without a Bugsee SDK (desktop, web) the calls do nothing.
