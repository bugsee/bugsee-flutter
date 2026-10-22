## 10.0.0-dev.1

* First version: the in-app feedback chat as a separate package, released in lock-step with `bugsee_flutter`.
* `BugseeFeedback.show`, `setGreeting`, `isAvailable`, and the `messagesReceived` / `messageSent` streams, over the
  feedback modules of the 7.x SDKs (`bugsee-android-feedback` 7.4.2, `feedback-spm` 7.0.0-beta7). Errors are
  `BugseeFeedbackException`s.
