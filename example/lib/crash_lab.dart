// The device verification app's ways to take the process down (and to fail without taking it
// down), one per layer: Dart, the Flutter engine / FFI native code, and the platform's own
// language (Java on Android). Used by `crash <kind>` commands from the harness; nothing in the
// example UI calls it.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:bugsee_flutter/bugsee_flutter.dart';

const MethodChannel _native = MethodChannel('verify/crashlab');

typedef _Raise = int Function(int);
typedef _RaiseC = Int32 Function(Int32);
typedef _Void = void Function();
typedef _VoidC = Void Function();

/// Every kind the harness may ask for, with what is expected of it (the harness repeats this
/// table and a test compares them: scripts/device/core/crash_kinds.dart).
const crashKinds = <String>[
  // The process dies of a signal raised from native code running in it (FFI into libc).
  'ffi-segv',
  'ffi-abort',
  'ffi-fpe',
  'ffi-bus',
  'ffi-ill',
  // Java: an uncaught exception on the main thread, on a worker, with a cause chain (Android).
  'java-main',
  'java-thread',
  'java-nested',
  // iOS: an uncaught Objective-C exception on the main thread and on a worker, a Swift runtime trap.
  'objc-main',
  'objc-thread',
  'swift-trap',
  // Dart: nothing dies; each reaches the installed handlers (or not, by design).
  'dart-sync-framework',
  'dart-async',
  'dart-zone',
  'dart-isolate',
  'dart-isolate-unlistened',
  'dart-platform-dispatcher',
  'dart-timer',
  'dart-stream',
];

Future<void> crash(String kind) async {
  switch (kind) {
    case 'ffi-segv':
      // A real write to address 0 from native code, not a kill from outside.
      Pointer<Int32>.fromAddress(0).value = 1;
    case 'ffi-abort':
      DynamicLibrary.process().lookupFunction<_VoidC, _Void>('abort')();
    case 'ffi-fpe':
      _raise(8);
    case 'ffi-bus':
      _raise(7);
    case 'ffi-ill':
      _raise(4);
    case 'java-main':
      await _native.invokeMethod<void>('javaMain');
    case 'java-thread':
      await _native.invokeMethod<void>('javaThread');
    case 'java-nested':
      await _native.invokeMethod<void>('nested');
    case 'objc-main':
      await _native.invokeMethod<void>('objcMain');
    case 'objc-thread':
      await _native.invokeMethod<void>('objcThread');
    case 'swift-trap':
      await _native.invokeMethod<void>('swiftTrap');
    case 'dart-sync-framework':
      // The framework's own error path: FlutterError.onError.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError('verify-dart-sync-framework'),
          stack: StackTrace.current,
          library: 'verify crash lab',
        ),
      );
    case 'dart-async':
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 10),
        ).then((_) => throw StateError('verify-dart-async')),
      );
    case 'dart-zone':
      // The public way to cover a zone of the app's own.
      Bugsee.runGuarded(
        () => Timer(
          const Duration(milliseconds: 10),
          () => throw StateError('verify-dart-zone'),
        ),
      );
    case 'dart-isolate':
      // An isolate the app spawned, with the public listener added (the only way an error in a
      // spawned isolate reaches Bugsee).
      final isolate = await Isolate.spawn<void>(
        _boomListened,
        null,
        errorsAreFatal: true,
        paused: true,
      );
      Bugsee.listenToIsolateErrors(isolate);
      isolate.resume(isolate.pauseCapability!);
    case 'dart-isolate-unlistened':
      // The same without the listener: by design nothing reports it (the isolate's error is
      // printed by the VM and the isolate dies). The harness pairs this absence with a positive
      // control.
      await Isolate.spawn<void>(_boomUnlistened, null, errorsAreFatal: true);
    case 'dart-platform-dispatcher':
      PlatformDispatcher.instance.onError?.call(
        StateError('verify-dart-platform-dispatcher'),
        StackTrace.current,
      );
    case 'dart-timer':
      Timer(
        const Duration(milliseconds: 10),
        () => throw StateError('verify-dart-timer'),
      );
    case 'dart-stream':
      final c = StreamController<int>();
      c.stream.listen((_) {});
      c.addError(StateError('verify-dart-stream'), StackTrace.current);
    default:
      throw ArgumentError('unknown crash kind $kind');
  }
}

void _boomListened(void _) => throw StateError('verify-dart-isolate');

void _boomUnlistened(void _) =>
    throw StateError('verify-dart-isolate-unlistened');

void _raise(int signal) {
  if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) return;
  DynamicLibrary.process().lookupFunction<_RaiseC, _Raise>('raise')(signal);
}
