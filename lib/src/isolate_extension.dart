import 'dart:isolate';

import 'exceptions.dart';

/// Extension methods for [Isolate] to add and remove the Bugsee error listener.
extension BugseeIsolateExtension on Isolate {
  /// Adds the specialized Bugsee error listener to this [Isolate]. Store
  /// the returned [RawReceivePort] if you want to remove the attached listener
  /// later.
  ///
  /// Since isolates run concurrently, it's possible for it to exit before the
  /// error listener is established. To avoid this, start the isolate paused,
  /// add the listener and then resume the isolate.
  RawReceivePort addBugseeErrorListener() {
    return BugseeExceptionHandler.defaultHandler.addIsolateErrorListener(this);
  }

  /// Pass the [receivePort] returned from [addBugseeErrorListener] to remove
  /// the Bugsee error listener.
  void removeBugseeErrorListener(RawReceivePort receivePort) {
    removeErrorListener(receivePort.sendPort);
  }
}
