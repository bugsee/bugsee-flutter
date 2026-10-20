// The Dart end of the native bridge. Internal: not exported from
// package:bugsee_flutter; Phase 4 builds the public API on it.
import 'dart:async';

import 'package:flutter/services.dart' show BinaryMessenger;

import 'lifecycle.dart';
import 'messages.g.dart';
import 'runtime_facts.dart';

/// Receives the SDK's lifecycle events from native and refines the wrapper
/// identity.
///
/// Native keeps events in a bounded buffer until [start] attaches (see
/// `LifecycleHub` / `BGSFlutterLifecycleHub`: capacity 64, oldest dropped), then
/// flushes them in order, so `Launching`/`Launched` that happened before Dart
/// was up are not lost.
class BugseeBridge implements BugseeBridgeFlutterApi {
  BugseeBridge({BugseeBridgeHostApi? host, BinaryMessenger? messenger})
    : _host = host ?? BugseeBridgeHostApi(binaryMessenger: messenger),
      _messenger = messenger;

  final BugseeBridgeHostApi _host;
  final BinaryMessenger? _messenger;
  final StreamController<LifecycleEvent> _events =
      StreamController<LifecycleEvent>.broadcast();
  Future<void>? _started;
  SdkStatus? _status;

  /// Every lifecycle event, in the order native delivered them, including names
  /// this version does not know. A broadcast stream: a listener sees events from
  /// when it subscribes; [status] keeps the latest transition for later readers.
  Stream<LifecycleEvent> get lifecycleEvents => _events.stream;

  /// A status change, only when a Launching/Launched/Stopping/Stopped event
  /// arrives; every other event produces nothing here.
  Stream<SdkStatus> get statusChanges =>
      _events.stream.map(statusForEvent).where((s) => s != null).cast();

  /// The latest status transition seen, or `null` if none has arrived. Kept
  /// whether or not anyone listened, so a late reader is not misled by a missed
  /// broadcast event. `null` means unknown, not stopped.
  SdkStatus? get status => _status;

  /// Attaches to native and refines the wrapper identity. Idempotent while it
  /// succeeds: later calls return the first call's future. If either step fails
  /// the error is thrown (after both were tried) and the next call retries.
  ///
  /// The handler is registered BEFORE native is told to flush, or the flushed
  /// events would arrive at nothing.
  Future<void> start({RuntimeFacts? facts, String? build}) =>
      _started ??= _start(facts ?? RuntimeFacts.current(), build);

  Future<void> _start(RuntimeFacts facts, String? build) async {
    BugseeBridgeFlutterApi.setUp(this, binaryMessenger: _messenger);
    // Independent: a failure to attach must not stop the identity from being sent,
    // nor the other way round.
    Object? error;
    StackTrace? stack;
    try {
      await _host.attachLifecycle();
    } catch (e, s) {
      error = e;
      stack = s;
    }
    final identity = WrapperIdentity.from(facts, build: build);
    try {
      await _host.setWrapperIdentity(
        WrapperIdentityMessage(
          type: identity.type,
          version: identity.version,
          build: identity.build,
          context: identity.context,
        ),
      );
    } catch (e, s) {
      error ??= e;
      stack ??= s;
    }
    if (error != null) {
      // Not cached: a later start() tries again.
      _started = null;
      Error.throwWithStackTrace(error, stack!);
    }
  }

  @override
  void onLifecycleEvent(LifecycleEventMessage event) {
    final e = LifecycleEvent(
      event.name,
      reportId: event.reportId,
      data: {
        for (final entry in (event.data ?? const <String, String>{}).entries)
          entry.key: entry.value,
      },
    );
    final s = statusForEvent(e);
    if (s != null) _status = s;
    _events.add(e);
  }
}
