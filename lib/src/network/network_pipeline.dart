// Between the capture and the bridge: a bounded queue, the Dart-side filter, batches. Internal.
import 'dart:async';
import 'dart:collection' show Queue;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import '../bridge/messages.g.dart';
import 'network_event.dart';
import 'network_policy.dart';

/// The wire constants shared with native (`NetworkOps.java`, `BGSFlutterNetworkOps`); compared by
/// `test/network_drift_test.dart`.
abstract final class NetworkWire {
  /// What the SDK is told produced the event (`mechanism` in `network.json`).
  static const mechanism = 'dart:io';

  /// The oldest an event may claim to be when native stamps it, in milliseconds.
  static const maxAgeMs = 60 * 60 * 1000;

  /// A filter's default time to answer; the SDK's own network filter timeout (Android
  /// `FILTER_CALLBACK_TIMEOUT_MS`, v7.4.2).
  static const defaultFilterTimeout = Duration(seconds: 10);
}

/// Counters of what happened to the events, for diagnosis. A snapshot.
final class NetworkCaptureStats {
  const NetworkCaptureStats({
    this.captured = 0,
    this.handedToSdk = 0,
    this.droppedQueueFull = 0,
    this.droppedNotAccepting = 0,
    this.droppedByFilter = 0,
    this.filterFailures = 0,
    this.refusedByNative = 0,
    this.sendFailures = 0,
  });

  /// Events the capture produced and the queue took.
  final int captured;

  /// Events native handed to the SDK (the rest of what was sent was refused there: the SDK is not
  /// launched, `capture.network` is off, an app filter threw).
  final int handedToSdk;

  /// Events dropped because the queue was full: native could not keep up.
  final int droppedQueueFull;

  /// Events dropped because the SDK was not accepting them any more by the time they were handed
  /// over (a stop, or `capture.network` off).
  final int droppedNotAccepting;

  /// Events the filter answered `null` for.
  final int droppedByFilter;

  /// Events dropped because the filter threw, returned something unusable or did not answer in
  /// time (fail closed).
  final int filterFailures;

  /// Events handed to native and not taken by the SDK.
  final int refusedByNative;

  /// Events lost with a batch the bridge failed to deliver.
  final int sendFailures;

  @override
  String toString() =>
      'NetworkCaptureStats(captured $captured, handedToSdk $handedToSdk, '
      'droppedQueueFull $droppedQueueFull, droppedNotAccepting $droppedNotAccepting, '
      'droppedByFilter $droppedByFilter, filterFailures $filterFailures, '
      'refusedByNative $refusedByNative, sendFailures $sendFailures)';
}

/// Sends a batch to native; completes with how many events the SDK was handed.
typedef NetworkSend = Future<int> Function(List<NetworkEventMessage> batch);

/// Takes events from the capture without ever blocking it, runs the filter, and hands them to
/// native in order, one batch in flight at a time.
///
/// [submit] is O(1) and never throws: the HTTP path of the app pays for a queue insert and nothing
/// else. Everything else happens in a later turn of the event loop, in small slices so a long
/// queue does not starve the UI. A full queue drops the NEW event (counted); a filter that throws
/// or hangs drops that event (counted): fail closed.
final class NetworkPipeline {
  NetworkPipeline({
    required this.send,
    required this.policy,
    this.maxQueuedEvents = 512,
    this.maxQueuedBytes = 8 * 1024 * 1024,
    this.maxBatchEvents = 32,
    this.maxBatchBytes = 512 * 1024,
    this.sliceBudget = const Duration(milliseconds: 4),
    void Function(String)? warn,
  }) : _warn = warn ?? _debugWarn;

  final NetworkSend send;
  final NetworkPolicy Function() policy;
  final int maxQueuedEvents;
  final int maxQueuedBytes;
  final int maxBatchEvents;
  final int maxBatchBytes;
  final Duration sliceBudget;
  final void Function(String) _warn;

  static void _debugWarn(String message) {
    if (kDebugMode) debugPrint('bugsee_flutter: $message');
  }

  BugseeNetworkFilter? _filter;
  Duration _filterTimeout = NetworkWire.defaultFilterTimeout;

  BugseeNetworkFilter? get filter => _filter;

  void setFilter(BugseeNetworkFilter? filter, Duration timeout) {
    _filter = filter;
    _filterTimeout = timeout;
  }

  final Queue<_Queued> _queue = Queue<_Queued>();
  int _queuedBytes = 0;
  bool _scheduled = false;
  bool _draining = false;
  bool _warnedFull = false;
  bool _warnedFilter = false;
  bool _warnedSend = false;

  int _captured = 0;
  int _handed = 0;
  int _droppedFull = 0;
  int _droppedNotAccepting = 0;
  int _droppedByFilter = 0;
  int _filterFailures = 0;
  int _refused = 0;
  int _sendFailures = 0;

  NetworkCaptureStats get stats => NetworkCaptureStats(
    captured: _captured,
    handedToSdk: _handed,
    droppedQueueFull: _droppedFull,
    droppedNotAccepting: _droppedNotAccepting,
    droppedByFilter: _droppedByFilter,
    filterFailures: _filterFailures,
    refusedByNative: _refused,
    sendFailures: _sendFailures,
  );

  /// How many events wait (for a test).
  int get queued => _queue.length;

  /// A rough size of an event for the queue's byte budget: what it carries, plus a fixed
  /// allowance for its fields.
  static int estimateBytes(BugseeNetworkEvent event) {
    var bytes = 512 + event.url.length + (event.body?.length ?? 0);
    event.headers.forEach((k, v) => bytes += k.length + v.length);
    return bytes;
  }

  /// Called by the capture for every event. Never throws, never waits.
  void submit(BugseeNetworkEvent event) {
    try {
      if (!policy().accepting) {
        _droppedNotAccepting++;
        return;
      }
      final bytes = estimateBytes(event);
      if (_queue.length >= maxQueuedEvents ||
          _queuedBytes + bytes > maxQueuedBytes) {
        _droppedFull++;
        if (!_warnedFull) {
          _warnedFull = true;
          _warn(
            'network capture queue is full: native is not keeping up, events are '
            'being dropped (Bugsee.networkCaptureStats counts them)',
          );
        }
        return;
      }
      // The filter in force NOW travels with the event: one removed or replaced before the event
      // is processed (a toggle in the UI) must not let it through unfiltered.
      _queue.add(_Queued(event, _filter, _filterTimeout));
      _queuedBytes += bytes;
      _captured++;
      _schedule();
    } catch (_) {
      // Capture must never throw into the app.
    }
  }

  void _schedule() {
    if (_scheduled || _draining) return;
    _scheduled = true;
    Timer.run(() {
      _scheduled = false;
      unawaited(_drain());
    });
  }

  /// Completes when everything queued so far was handed to native (or dropped). For tests and for
  /// a caller that wants to flush before an upload.
  Future<void> flush() async {
    while (_queue.isNotEmpty || _draining) {
      if (_draining) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      } else {
        await _drain();
      }
    }
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final batch = <NetworkEventMessage>[];
        var batchBytes = 0;
        final slice = Stopwatch()..start();
        while (_queue.isNotEmpty &&
            batch.length < maxBatchEvents &&
            batchBytes < maxBatchBytes) {
          final queued = _queue.removeFirst();
          _queuedBytes -= estimateBytes(queued.event);
          final message = await _prepare(queued);
          if (message != null) {
            batch.add(message);
            batchBytes += estimateBytes(queued.event);
          }
          // Yield between events once the slice is used up, so a long queue (or a slow filter)
          // never holds the isolate for long at a time.
          if (slice.elapsed > sliceBudget) {
            await Future<void>.delayed(Duration.zero);
            slice.reset();
          }
        }
        if (batch.isNotEmpty) await _send(batch);
        // Let the UI have the loop between batches.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _draining = false;
      if (_queue.isNotEmpty) _schedule();
    }
  }

  Future<NetworkEventMessage?> _prepare(_Queued queued) async {
    final original = queued.event;
    if (!policy().accepting) {
      _droppedNotAccepting++;
      return null;
    }
    // Every filter that applies, in order: the one in force when the event was captured, then the
    // one in force now if it is another (set later, or swapped). Removing a filter therefore never
    // lets an already captured event through unfiltered, and setting one covers what was queued.
    final chain = <(BugseeNetworkFilter, Duration)>[
      if (queued.filter != null) (queued.filter!, queued.timeout),
      if (_filter != null && !identical(_filter, queued.filter))
        (_filter!, _filterTimeout),
    ];
    var event = original;
    for (final (filter, timeout) in chain) {
      final BugseeNetworkEvent? next;
      try {
        final Object? answer = filter(event.copy());
        final Object? resolved = answer is Future
            ? await answer.timeout(timeout)
            : answer;
        if (resolved == null) {
          _droppedByFilter++;
          return null;
        }
        if (resolved is! BugseeNetworkEvent) {
          throw StateError(
            'the network filter returned a ${resolved.runtimeType}, not a BugseeNetworkEvent or null',
          );
        }
        next = resolved;
      } catch (error) {
        // A filter that throws, hangs or answers nonsense drops the event: a redaction boundary
        // fails closed, like the SDKs'.
        _filterFailures++;
        if (!_warnedFilter) {
          _warnedFilter = true;
          _warn(
            'the network filter failed (${error.runtimeType}); the event was dropped. '
            'Reported once; Bugsee.networkCaptureStats counts every failure.',
          );
        }
        return null;
      }
      event = next;
    }
    return _toMessage(original, event);
  }

  /// The wire message. What the filter may change is taken from [filtered]; what describes the
  /// exchange (id, stage, method, status, size) always comes from [original], so a filter cannot
  /// break the pairing of the stages.
  NetworkEventMessage? _toMessage(
    BugseeNetworkEvent original,
    BugseeNetworkEvent filtered,
  ) {
    final url = filtered.url;
    if (url.isEmpty) {
      // Nothing the SDK could record: a filter that blanked the URL has dropped the event.
      _droppedByFilter++;
      return null;
    }
    final ageUs = monotonicMicros() - original.monotonicUs;
    final age = ageUs ~/ 1000;
    final body = filtered.body;
    return NetworkEventMessage(
      id: original.id,
      stage: original.stage.name,
      mechanism: NetworkWire.mechanism,
      method: original.method,
      url: url,
      ageMs: age < 0
          ? 0
          : age > NetworkWire.maxAgeMs
          ? NetworkWire.maxAgeMs
          : age,
      size: original.size,
      statusCode: original.statusCode,
      headers: <String, String>{...filtered.headers},
      body: body,
      // A body and a reason about its absence are exclusive.
      noBodyReason: body == null ? filtered.noBodyReason?.wire : null,
      statusText: filtered.statusText,
      errorShortMessage: filtered.error,
      errorDescription: filtered.errorDescription,
      redirectedFromUrl: filtered.redirectedFrom,
      timings: filtered.timings == null
          ? null
          : <String, double>{...filtered.timings!},
    );
  }

  Future<void> _send(List<NetworkEventMessage> batch) async {
    try {
      final handed = await send(batch);
      _handed += handed;
      if (handed < batch.length) _refused += batch.length - handed;
    } catch (error) {
      _sendFailures += batch.length;
      if (!_warnedSend) {
        _warnedSend = true;
        _warn(
          'network events could not be handed to the SDK (${error.runtimeType}); the batch was '
          'dropped. Reported once.',
        );
      }
    }
  }
}

/// An event waiting in the queue, with the filter that was in force when it was captured.
final class _Queued {
  _Queued(this.event, this.filter, this.timeout);

  final BugseeNetworkEvent event;
  final BugseeNetworkFilter? filter;
  final Duration timeout;
}
