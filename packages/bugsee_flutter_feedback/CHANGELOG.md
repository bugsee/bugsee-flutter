## 10.0.0-dev.1

The first version, released in lock-step with `bugsee_flutter` (same version number). **Not published yet; a prerelease.**

* The in-app feedback chat as a separate package, so apps that never show it do not carry its UI (SwiftUI on iOS, Jetpack Compose on Android).
* `BugseeFeedback.show`, `setGreeting`, `isAvailable`, and the `messagesReceived` and `messageSent` streams (they fire only while the chat is
  on screen), over the feedback modules of the 7.x SDKs (`com.bugsee:bugsee-android-feedback` 7.4.2, `feedback-spm` 7.0.0). Errors are
  `BugseeFeedbackException`s with a `reason` (`notRegistered`, `incompatibleCore`, `nativeError`).
* Replaces the 9.x `Bugsee.showFeedbackUI`, `setDefaultFeedbackGreeting` and `setNewFeedbackMessagesCallback`.
* Nothing to configure beyond adding the package next to `bugsee_flutter` at the same version: the module registers itself (Android through the
  SDK's own provider or the Gradle plugin's injected call, iOS through its own `+load` registrar).
* Requirements are those of `bugsee_flutter` (Flutter 3.41.0, the Bugsee Gradle plugin on Android, iOS 15.0 with Swift Package Manager).
* Known gaps: verified on an Android emulator and an iOS simulator only (no real token: sending and receiving messages was not exercised);
  the chat's appearance is not exposed; bugsee-cocoa#291 (listener ordering in the add-on) is worked around.
