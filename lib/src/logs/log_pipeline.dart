// Between the capture and the bridge: the rate limit, a bounded queue, the Dart-side filter,
// batches. Internal; the twin of `lib/src/network/network_pipeline.dart`.
import 'dart:async';
import 'dart:collection' show Queue;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import '../bridge/messages.g.dart';
import '../network/body_capture.dart' show utf8Length;
import '../network/network_event.dart' show monotonicMicros;
import '../options/bugsee_options.g.dart' show LogLevel;
import 'log_event.dart';
import 'log_policy.dart';
import 'log_suppress.dart';

/// The numbers shared with native or chosen for the cost of the capture; the ones native repeats
/// are compared by `test/logs_drift_test.dart` (`test/fixtures/log_wire.json`).
abstract final class LogWire {
  /// The source native records a line with: `Custom`, "the host runtime's own logs" (the wrapper
  /// channel spec; the same value on both SDKs). A constant of native code, repeated here for the
  /// drift guard and the docs.
  static const source = 98;

  /// The SDK's level range (`LogLevel` 1..5 on Android, `BugseeLogLevel` 1..5 on iOS).
  static const minLevel = 1;
  static const maxLevel = 5;

  /// The longest line recorded, in UTF-16 units; a longer one is cut and says so. Neither SDK limits
  /// the length of a channel line (Android: none; iOS: none); this bounds what crosses the bridge and
  /// what one `print` of a large payload can cost. Android's own logcat path cuts at about 4000.
  static const maxLineLength = 4000;

  /// A filter's default time to answer: the SDK's own log filter timeout (Android
  /// `BugseeCaptureDataProviderLog.FILTER_CALLBACK_TIMEOUT_MS`, v7.4.2).
  static const defaultFilterTimeout = Duration(seconds: 10);

  /// The longest a filter may be given.
  static const maxFilterTimeout = Duration(minutes: 5);

  /// This many filter timeouts in a row switch the filter off for [filterCoolDown]: its lines are
  /// dropped at once (fail closed, counted) instead of costing a timeout each, which would delay every
  /// later line by that much (the SDK stamps a line when it arrives).
  static const filterTimeoutsBeforeCoolDown = 3;
  static const filterCoolDown = Duration(seconds: 30);

  /// A burst of this many lines is taken, then [linesPerSecond] a second.
  static const burstLines = 1000;
  static const linesPerSecond = 500;

  static const maxQueuedLines = 1000;
  static const maxQueuedBytes = 2 * 1024 * 1024;
  static const maxBatchLines = 64;
  static const maxBatchBytes = 128 * 1024;

  /// What a truncated line ends with (`N` is how many UTF-16 units were cut).
  static const truncationMarker = ' ...[truncated ';
}

/// A token bucket on a monotonic clock.
final class LogRateLimiter {
  LogRateLimiter({
    this.burst = LogWire.burstLines,
    this.perSecond = LogWire.linesPerSecond,
    int Function()? clockMicros,
  }) : _clock = clockMicros ?? monotonicMicros,
       _tokens = burst.toDouble() {
    _last = _clock();
  }

  final int burst;
  final int perSecond;
  final int Function() _clock;
  double _tokens;
  late int _last;

  bool tryTake() {
    final now = _clock();
    final elapsed = now - _last;
    _last = now;
    if (elapsed > 0) {
      _tokens = (_tokens + elapsed * perSecond / 1e6)
          .clamp(0, burst)
          .toDouble();
    }
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }
}

/// [text] cut to [limit] UTF-16 units (never between the halves of a surrogate pair), with a marker
/// saying how much was cut. Unchanged when it fits.
String capLine(String text, [int limit = LogWire.maxLineLength]) {
  if (text.length <= limit) return text;
  var end = limit;
  final unit = text.codeUnitAt(end - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) end--;
  return '${text.substring(0, end)}${LogWire.truncationMarker}${text.length - end}]';
}

/// Sends a batch to native; completes with how many lines the SDK was handed.
typedef LogSend = Future<int> Function(List<LogLineMessage> batch);

/// Takes lines from the capture without ever blocking it, runs the filter, and hands them to native
/// in order, one batch in flight at a time.
///
/// [submit] is O(1) and never throws: the `print` of the app pays for a queue insert. A flood is
/// limited by a token bucket, a full queue drops the NEW line (counted), a filter that throws or
/// hangs drops that line (counted): fail closed.
final class LogPipeline {
  LogPipeline({
    required this.send,
    required this.policy,
    this.maxQueuedLines = LogWire.maxQueuedLines,
    this.maxQueuedBytes = LogWire.maxQueuedBytes,
    this.maxBatchLines = LogWire.maxBatchLines,
    this.maxBatchBytes = LogWire.maxBatchBytes,
    this.sliceBudget = const Duration(milliseconds: 4),
    LogRateLimiter? limiter,
    int Function()? clockMicros,
    void Function(String)? warn,
  }) : _limiter = limiter ?? LogRateLimiter(),
       _clock = clockMicros ?? monotonicMicros,
       _warn = warn ?? _debugWarn;

  final LogSend send;
  final LogPolicy Function() policy;
  final int maxQueuedLines;
  final int maxQueuedBytes;
  final int maxBatchLines;
  final int maxBatchBytes;
  final Duration sliceBudget;
  final LogRateLimiter _limiter;
  final int Function() _clock;
  int _consecutiveTimeouts = 0;
  int _coolDownUntil = 0;
  final void Function(String) _warn;

  static void _debugWarn(String message) {
    if (kDebugMode) debugPrint('bugsee_flutter: $message');
  }

  BugseeLogFilter? _filter;
  Duration _filterTimeout = LogWire.defaultFilterTimeout;

  BugseeLogFilter? get filter => _filter;

  void setFilter(BugseeLogFilter? filter, Duration timeout) {
    _filter = filter;
    _filterTimeout = timeout;
  }

  final Queue<_Queued> _queue = Queue<_Queued>();
  int _queuedBytes = 0;
  bool _scheduled = false;
  bool _draining = false;
  bool _warnedFull = false;
  bool _warnedRate = false;
  bool _warnedFilter = false;
  bool _warnedSend = false;

  int _captured = 0;
  int _submitted = 0;
  int _truncated = 0;
  int _droppedFull = 0;
  int _droppedRate = 0;
  int _droppedNotAccepting = 0;
  int _droppedBelowLevel = 0;
  int _droppedErrorDumps = 0;
  int _droppedEchoes = 0;
  int _droppedByFilter = 0;
  int _filterFailures = 0;
  int _droppedCoolDown = 0;
  int _refused = 0;
  int _sendFailures = 0;

  LogCaptureStats get stats => LogCaptureStats(
    captured: _captured,
    submittedToSdk: _submitted,
    truncated: _truncated,
    droppedQueueFull: _droppedFull,
    droppedRateLimited: _droppedRate,
    droppedNotAccepting: _droppedNotAccepting,
    droppedBelowLevel: _droppedBelowLevel,
    droppedErrorDumps: _droppedErrorDumps,
    droppedEchoes: _droppedEchoes,
    droppedByFilter: _droppedByFilter,
    filterFailures: _filterFailures,
    droppedFilterCoolDown: _droppedCoolDown,
    refusedByNative: _refused,
    sendFailures: _sendFailures,
  );

  /// How many lines wait (for a test).
  int get queued => _queue.length;

  /// Counts a `FlutterError` dump that the capture refused to record.
  void noteErrorDump() => _droppedErrorDumps++;

  /// Counts a `print` line that was the later output of a `debugPrint` already recorded.
  void noteEchoDrop() => _droppedEchoes++;

  /// Called by the capture for every line. Never throws, never waits.
  void submit(String message, LogLevel level, String? tag) {
    try {
      final current = policy();
      if (!current.accepting) {
        _droppedNotAccepting++;
        return;
      }
      if (level.value > current.maxLevel.value) {
        _droppedBelowLevel++;
        return;
      }
      if (message.isEmpty) return;
      if (!_limiter.tryTake()) {
        _droppedRate++;
        if (!_warnedRate) {
          _warnedRate = true;
          _warn(
            'log capture is limited to ${LogWire.linesPerSecond} lines a second '
            '(a burst of ${LogWire.burstLines}); the rest are dropped '
            '(Bugsee.logCaptureStats counts them)',
          );
        }
        return;
      }
      final capped = capLine(message);
      // O(1): two bytes a unit is the most a Dart string takes (the batch limit counts UTF-8 later,
      // off the print path).
      final bytes = 64 + 2 * capped.length + 2 * (tag?.length ?? 0);
      if (_queue.length >= maxQueuedLines ||
          _queuedBytes + bytes > maxQueuedBytes) {
        _droppedFull++;
        if (!_warnedFull) {
          _warnedFull = true;
          _warn(
            'log capture queue is full: native is not keeping up, lines are being dropped '
            '(Bugsee.logCaptureStats counts them)',
          );
        }
        return;
      }
      if (!identical(capped, message)) _truncated++;
      // The filter in force NOW travels with the line: one removed or replaced before the line is
      // processed must not let it through unfiltered.
      _queue.add(
        _Queued(
          BugseeLogEvent(message: capped, level: level, tag: tag),
          bytes,
          _filter,
          _filterTimeout,
        ),
      );
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

  /// Completes when everything queued so far was handed to native (or dropped). For tests and for a
  /// caller that wants to flush before an upload.
  Future<void> flush() async {
    while (_queue.isNotEmpty || _draining) {
      if (_draining) {
        // One shared future, no timer: a waiter that gave up (a report's time limit) costs nothing.
        await _drainDone!.future;
      } else {
        await _drain();
      }
    }
  }

  Completer<void>? _drainDone;

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    _drainDone = Completer<void>();
    try {
      while (_queue.isNotEmpty) {
        final batch = <LogLineMessage>[];
        var batchBytes = 0;
        final slice = Stopwatch()..start();
        while (_queue.isNotEmpty &&
            batch.length < maxBatchLines &&
            batchBytes < maxBatchBytes) {
          final queued = _queue.removeFirst();
          _queuedBytes -= queued.bytes;
          final message = await _prepare(queued);
          if (message != null) {
            batch.add(message);
            batchBytes +=
                32 +
                utf8Length(message.message) +
                utf8Length(message.tag ?? '');
          }
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
      final done = _drainDone;
      _drainDone = null;
      if (done != null && !done.isCompleted) done.complete();
      if (_queue.isNotEmpty) _schedule();
    }
  }

  Future<LogLineMessage?> _prepare(_Queued queued) async {
    if (!policy().accepting) {
      _droppedNotAccepting++;
      return null;
    }
    // Every filter that applies, in order: the one in force when the line was captured, then the one
    // in force now if it is another. Removing a filter never lets an already captured line through
    // unfiltered, and setting one covers what was queued.
    final chain = <(BugseeLogFilter, Duration)>[
      if (queued.filter != null) (queued.filter!, queued.timeout),
      if (_filter != null && !identical(_filter, queued.filter))
        (_filter!, _filterTimeout),
    ];
    if (chain.isNotEmpty && _coolDownUntil != 0) {
      if (_clock() < _coolDownUntil) {
        _droppedCoolDown++;
        return null;
      }
      _coolDownUntil = 0;
    }
    var event = queued.event;
    for (final (filter, timeout) in chain) {
      final BugseeLogEvent? next;
      try {
        // In a zone the capture ignores: what a filter prints is not a log line (it would be
        // filtered in turn, forever).
        final handed = event.copy();
        final Object? answer = runSuppressed(() => filter(handed));
        final Object? resolved = answer is Future
            ? await answer.timeout(timeout)
            : answer;
        if (resolved == null) {
          _droppedByFilter++;
          return null;
        }
        if (resolved is! BugseeLogEvent) {
          throw StateError(
            'the log filter returned a ${resolved.runtimeType}, not a BugseeLogEvent or null',
          );
        }
        next = resolved;
        _consecutiveTimeouts = 0;
      } catch (error) {
        // A filter that throws, hangs or answers nonsense drops the line: a redaction boundary fails
        // closed, like the SDKs'.
        _filterFailures++;
        if (error is TimeoutException &&
            ++_consecutiveTimeouts >= LogWire.filterTimeoutsBeforeCoolDown) {
          _consecutiveTimeouts = 0;
          _coolDownUntil = _clock() + LogWire.filterCoolDown.inMicroseconds;
          _warn(
            'the log filter did not answer ${LogWire.filterTimeoutsBeforeCoolDown} times in a row; '
            'its lines are dropped for ${LogWire.filterCoolDown.inSeconds} s (fail closed) instead of '
            'delaying the ones behind them',
          );
        }
        if (!_warnedFilter) {
          _warnedFilter = true;
          _warn(
            'the log filter failed (${error.runtimeType}); the line was dropped. Reported once; '
            'Bugsee.logCaptureStats counts every failure.',
          );
        }
        return null;
      }
      event = next;
    }
    return _toMessage(event, queued.event.message);
  }

  LogLineMessage? _toMessage(BugseeLogEvent event, String captured) {
    final text = event.message;
    if (text.isEmpty) {
      _droppedByFilter++;
      return null;
    }
    final tag = event.tag;
    return LogLineMessage(
      // A filter may have made the line longer; a line it left alone was cut at capture (cutting
      // it again would cut the marker).
      message: identical(text, captured) ? text : capLine(text),
      level: event.level.value,
      tag: tag == null || tag.isEmpty ? null : capLine(tag, 256),
    );
  }

  Future<void> _send(List<LogLineMessage> batch) async {
    try {
      final handed = await send(batch);
      _submitted += handed;
      if (handed < batch.length) _refused += batch.length - handed;
    } catch (error) {
      _sendFailures += batch.length;
      if (!_warnedSend) {
        _warnedSend = true;
        _warn(
          'log lines could not be handed to the SDK (${error.runtimeType}); the batch was '
          'dropped. Reported once.',
        );
      }
    }
  }
}

/// A line waiting in the queue, with the filter that was in force when it was captured.
final class _Queued {
  _Queued(this.event, this.bytes, this.filter, this.timeout);

  final BugseeLogEvent event;
  final int bytes;
  final BugseeLogFilter? filter;
  final Duration timeout;
}
