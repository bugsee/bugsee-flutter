// The log line the Dart capture produces and a filter sees, plus the stats. Public.
import 'dart:async' show FutureOr;

import '../options/bugsee_options.g.dart' show LogLevel;

/// One line of Dart output the log capture recorded, as the SDK will see it.
///
/// This is what a [BugseeLogFilter] receives, **before** the line reaches the SDK. The line is
/// attributed to the plugin (the SDK records it with source `Custom`, never as the app's own
/// `Bugsee.log`), which is not the filter's to change.
final class BugseeLogEvent {
  BugseeLogEvent({required this.message, this.level = LogLevel.info, this.tag})
    : time = DateTime.now();

  /// The text, cut to the capture's line cap. A filter redacts it by assigning a new value; an empty
  /// message drops the line (both SDKs do).
  String message;

  /// The level the line is recorded at. A filter may change it.
  LogLevel level;

  /// Where the line came from: `print`, `debugPrint`, or what the caller passed to
  /// `Bugsee.forwardLog`. Recorded by Android (`log.json` `tag`); iOS has no tag field and drops it.
  String? tag;

  /// When the line was captured, on the device clock. Informational: the SDK stamps a line when it
  /// receives it (neither SDK takes a timestamp on the wrapper channel).
  final DateTime time;

  /// A copy: what a filter is handed, so that nothing it does reaches what the capture holds.
  BugseeLogEvent copy() => BugseeLogEvent._copy(this);

  BugseeLogEvent._copy(BugseeLogEvent o)
    : message = o.message,
      level = o.level,
      tag = o.tag,
      time = o.time;

  @override
  String toString() => 'BugseeLogEvent(${level.name}, tag $tag)';
}

/// A log filter: sees every captured line before it is handed to the SDK.
///
/// Return the event (modified in place, or a copy) to record it, or `null` to drop it. A filter that
/// throws, returns anything else, or returns a future that does not complete within the timeout
/// given to `Bugsee.setLogFilter` DROPS the line: a redaction boundary fails closed. Runs on the
/// isolate that printed, one line at a time and in order, never inside the `print` call. Anything
/// the filter itself prints is not captured.
typedef BugseeLogFilter =
    FutureOr<BugseeLogEvent?> Function(BugseeLogEvent event);

/// The SDK [LogLevel] for a `package:logging` `Level.value` (or any severity on its scale).
///
/// `package:logging` is not a dependency of this plugin; this is the mapping to use in an adapter
/// (`Logger.root.onRecord.listen((r) => Bugsee.forwardLog(r.message, level:
/// logLevelForLoggingValue(r.level.value), tag: r.loggerName))`): `SEVERE` (1000) and `SHOUT`
/// (1200) are errors, `WARNING` (900) a warning, `INFO` (800) info, `CONFIG` (700) and `FINE` (500)
/// debug, `FINER` (400), `FINEST` (300) and anything lower verbose. Anything above `SHOUT` is an
/// error.
LogLevel logLevelForLoggingValue(int value) {
  if (value >= 1000) return LogLevel.error;
  if (value >= 900) return LogLevel.warning;
  if (value >= 800) return LogLevel.info;
  if (value >= 500) return LogLevel.debug;
  return LogLevel.verbose;
}

/// Counters of what happened to the captured lines, for diagnosis. A snapshot.
final class LogCaptureStats {
  const LogCaptureStats({
    this.captured = 0,
    this.submittedToSdk = 0,
    this.truncated = 0,
    this.droppedQueueFull = 0,
    this.droppedRateLimited = 0,
    this.droppedNotAccepting = 0,
    this.droppedBelowLevel = 0,
    this.droppedErrorDumps = 0,
    this.droppedByFilter = 0,
    this.filterFailures = 0,
    this.refusedByNative = 0,
    this.sendFailures = 0,
  });

  /// Lines the capture produced and the queue took.
  final int captured;

  /// Lines native SUBMITTED to the SDK's wrapper channel (the rest of what was sent was refused
  /// there: the SDK is not launching or launched, `capture.logs` is off, the app's log filter threw).
  /// Submitted is not recorded: the SDK still drops a line on a channel it retired, while its
  /// provider is stopped, or when the app's native filter never answers, and says nothing.
  final int submittedToSdk;

  /// Captured lines that were cut to the line cap ([captured] includes them).
  final int truncated;

  /// Lines dropped because the queue was full: native could not keep up.
  final int droppedQueueFull;

  /// Lines dropped by the rate limit (a flood).
  final int droppedRateLimited;

  /// Lines dropped because the SDK was not accepting them: not launching or launched, or
  /// `capture.logs` off. The count includes everything printed before `Bugsee.launch`.
  final int droppedNotAccepting;

  /// Lines dropped because they are more verbose than `capture.logs.level`.
  final int droppedBelowLevel;

  /// `FlutterError` diagnostics dumps that were not recorded (they carry widget trees).
  final int droppedErrorDumps;

  /// Lines the filter answered `null` or an empty message for.
  final int droppedByFilter;

  /// Lines dropped because the filter threw, returned something unusable or did not answer in time
  /// (fail closed).
  final int filterFailures;

  /// Lines handed to native and not taken by the SDK.
  final int refusedByNative;

  /// Lines lost with a batch the bridge failed to deliver.
  final int sendFailures;

  @override
  String toString() =>
      'LogCaptureStats(captured $captured, submittedToSdk $submittedToSdk, truncated $truncated, '
      'droppedQueueFull $droppedQueueFull, droppedRateLimited $droppedRateLimited, '
      'droppedNotAccepting $droppedNotAccepting, droppedBelowLevel $droppedBelowLevel, '
      'droppedErrorDumps $droppedErrorDumps, droppedByFilter $droppedByFilter, '
      'filterFailures $filterFailures, refusedByNative $refusedByNative, '
      'sendFailures $sendFailures)';
}
