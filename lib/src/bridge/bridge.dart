// The Dart end of the native bridge. Internal: not exported from
// package:bugsee_flutter; the public `Bugsee` facade (lib/src/bugsee.dart) is built on it.
import 'dart:async';

import 'package:flutter/foundation.dart'
    show ErrorDescription, FlutterError, FlutterErrorDetails;
import 'package:flutter/services.dart' show BinaryMessenger;

import '../report/report_handler.dart';
import '../report/report_proxy.dart';
import '../status.dart';
import 'lifecycle.dart';
import 'messages.g.dart';
import 'runtime_facts.dart';

export '../report/report_handler.dart' show ReportHandler;

/// Receives the SDK's lifecycle events from native, delivers report-handler
/// requests, and refines the wrapper identity.
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
  bool _attached = false;
  bool _identitySent = false;
  bool _phasesSent = false;
  BugseeStatus? _status;
  ReportHandler? _onBefore;
  ReportHandler? _onAfter;
  final Set<String> _delivered = <String>{};

  /// How many delivery ids are remembered for de-duplication. Old ones are
  /// forgotten first.
  static const int deliveredCapacity = 128;

  /// Every lifecycle event, in the order native delivered them, including names
  /// this version does not know. A broadcast stream: a listener sees events from
  /// when it subscribes; [status] keeps the latest transition for later readers.
  Stream<LifecycleEvent> get lifecycleEvents => _events.stream;

  /// A status change, only when a Launching/Launched/Stopping/Stopped event
  /// arrives; every other event produces nothing here.
  Stream<BugseeStatus> get statusChanges =>
      _events.stream.map(statusForEvent).where((s) => s != null).cast();

  /// The latest status transition seen, or `null` if none has arrived. Kept
  /// whether or not anyone listened, so a late reader is not misled by a missed
  /// broadcast event. `null` means unknown, not stopped.
  BugseeStatus? get status => _status;

  /// Attaches to native and refines the wrapper identity. Idempotent while it
  /// succeeds: later calls return the first call's future. If either step fails
  /// the error is thrown (after both were tried) and the next call retries.
  ///
  /// The handler is registered BEFORE native is told to flush, or the flushed
  /// events would arrive at nothing.
  ///
  /// It also tells native which report-handler phases have a Dart handler now (none, for
  /// a new isolate), so a hot restart is not waited on for a handler it has not registered.
  Future<void> start({RuntimeFacts? facts, String? build}) =>
      _started ??= _start(facts ?? RuntimeFacts.current(), build);

  Future<void> _start(RuntimeFacts facts, String? build) async {
    BugseeBridgeFlutterApi.setUp(this, binaryMessenger: _messenger);
    // Independent: a failure to attach must not stop the identity from being sent,
    // nor the other way round. A retry repeats only the step that has not succeeded:
    // attaching again would make native replay events this bridge already got.
    Object? error;
    StackTrace? stack;
    if (!_attached) {
      try {
        await _host.attachLifecycle();
        _attached = true;
      } catch (e, s) {
        error = e;
        stack = s;
      }
    }
    if (!_phasesSent) {
      try {
        // This isolate is new (a hot restart makes a fresh one): native completes what it had
        // handed to the previous isolate instead of leaving each report to wait for its deadline.
        await _host.resetReportHandlers();
        await _host.setReportHandlerPhases(_onBefore != null, _onAfter != null);
        _phasesSent = true;
      } catch (e, s) {
        error ??= e;
        stack ??= s;
      }
    }
    if (!_identitySent) {
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
        _identitySent = true;
      } catch (e, s) {
        error ??= e;
        stack ??= s;
      }
    }
    if (error != null) {
      // Not cached: a later start() tries the failed step again.
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

  /// Registers the report handlers (either may be `null`: no handler for that phase).
  ///
  /// With a phase unregistered native completes the SDK's callback at once and never
  /// calls Dart for it. `onBefore` is at most once and may be skipped; `onAfter` is at
  /// least once and may run again, in a later process, for a report that already carries
  /// part of the first run's contribution (workbook 7.2): the handler must be idempotent.
  /// Within this isolate a second delivery of the same report and phase is not run again
  /// (see [deliveredCapacity]); it is completed at once.
  Future<void> setReportHandlers({
    ReportHandler? onBefore,
    ReportHandler? onAfter,
  }) async {
    _onBefore = onBefore;
    _onAfter = onAfter;
    // The receiver first, then the flag: native must not call before Dart can answer.
    BugseeBridgeFlutterApi.setUp(this, binaryMessenger: _messenger);
    await _host.setReportHandlerPhases(onBefore != null, onAfter != null);
    _phasesSent = true;
  }

  @override
  void onReportHandlerRequest(ReportHandlerRequestMessage request) {
    // Native does not wait for this reply; the SDK's completion runs when this
    // isolate completes the handle (or the deadline passes). Return at once.
    unawaited(_deliverReport(request));
  }

  Future<void> _deliverReport(ReportHandlerRequestMessage request) async {
    final handler = request.after ? _onAfter : _onBefore;
    if (handler == null || !_remember(request.deliveryId)) {
      // Nothing to run (a stale flag natively) or this report and phase was already
      // handled here: do not run the handler twice, and do not leave the SDK waiting.
      await _complete(request.handle);
      return;
    }
    final proxy = ReportProxy.internal(
      id: request.reportId,
      typeName: request.type,
      deliveryId: request.deliveryId,
      handle: request.handle,
      host: _host,
    );
    // Native closes the report at its deadline whatever Dart does; closing here too
    // makes a late edit fail without a round trip. `deadlineMs` is what native had left
    // when it sent the request, so this closes no later than native does.
    var overran = false;
    final deadline = Timer(Duration(milliseconds: request.deadlineMs), () {
      overran = true;
      proxy.markCompleted();
    });
    try {
      await handler(proxy);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'bugsee_flutter',
          context: ErrorDescription('while running a Bugsee report handler'),
        ),
      );
    } finally {
      deadline.cancel();
      if (overran) {
        // Not only an edit that failed: a handler that ran past the budget and made no further
        // edit would otherwise look like a success.
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: StateError(
              'A Bugsee report handler for report ${request.reportId} ran past its '
              '${request.deadlineMs} ms budget (the SDK deadline less a margin). The SDK '
              'carried on without it and any edit it made after that was not applied.',
            ),
            library: 'bugsee_flutter',
            context: ErrorDescription('while running a Bugsee report handler'),
          ),
        );
      }
      // Closed BEFORE the completion crosses, so nothing a stray continuation does
      // afterwards can be sent as if it were still live.
      proxy.markCompleted();
      await _complete(request.handle);
    }
  }

  /// Whether this delivery id is new. Remembers it either way.
  bool _remember(String deliveryId) {
    if (!_delivered.add(deliveryId)) {
      // Most recently seen last, so the oldest is the one forgotten.
      _delivered
        ..remove(deliveryId)
        ..add(deliveryId);
      return false;
    }
    if (_delivered.length > deliveredCapacity) {
      _delivered.remove(_delivered.first);
    }
    return true;
  }

  Future<void> _complete(String handle) async {
    try {
      await _host.completeReportHandler(handle);
    } catch (_) {
      // Native completes on its own deadline: nothing more to do from here.
    }
  }
}
