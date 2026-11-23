// The SDK's status. Public: exported from package:bugsee_flutter.

/// The SDK's status: the four states both SDKs have (`Bugsee.getStatus()` on Android,
/// `-[Bugsee status]` on iOS).
///
/// Android and iOS do not agree on the numbers, so nothing here is a number: it crosses by NAME
/// (`stopped`, `launching`, `launched`, `stopping`) and the Dart order is not a contract.
enum BugseeStatus {
  /// Not launched, or fully stopped.
  stopped,

  /// A launch was accepted and the SDK is starting. Capture is not yet recording; data submitted
  /// now is retained and flushed once it is.
  launching,

  /// Fully running: capture is recording.
  launched,

  /// A stop is in progress. A launch now is refused: launch again once it has completed.
  stopping;

  /// The status for the name the bridge carries, or `null` for one this version does not know.
  static BugseeStatus? fromName(String? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return null;
  }
}
