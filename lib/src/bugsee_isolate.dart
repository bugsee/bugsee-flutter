import 'dart:isolate';

import 'package:bugsee_flutter/src/exceptions.dart';

class BugseeIsolate {
  /// Calls [Isolate.spawn] with an error listener from the Bugsee SDK.
  ///
  /// If `onError` is provided, it will be used instead of the default Bugsee
  /// error listener.
  static Future<Isolate> spawn<T>(
      void Function(T message) entryPoint, T message,
      {bool paused = false,
      bool errorsAreFatal = true,
      SendPort? onExit,
      SendPort? onError,
      String? debugName}) async {
    return Isolate.spawn(
      entryPoint,
      message,
      paused: paused,
      errorsAreFatal: errorsAreFatal,
      onExit: onExit,
      onError: onError ??
          BugseeExceptionHandler.defaultHandler
              .createErrorHandlingPort()
              .sendPort,
      debugName: debugName,
    );
  }
}
