// What the SDK would do with a log line, as far as the wrapper needs to know before it sends one
// (doc/logs.md). Internal.
import '../options/bugsee_options.g.dart' show LogLevel;
import '../status.dart';

/// The option keys the policy reads, registered by both SDKs (the vendored manifests; a test
/// compares the key, the type and the default).
abstract final class LogOptionKeys {
  static const capture = 'com.bugsee.option.capture.logs';
  static const level = 'com.bugsee.option.capture.logs.level';
}

/// What the log capture may do right now. Immutable; replaced as the SDK's status changes.
final class LogPolicy {
  const LogPolicy({this.accepting = false, this.maxLevel = LogLevel.verbose});

  /// Nothing is captured: the SDK is neither launching nor launched, or `capture.logs` is off.
  static const LogPolicy off = LogPolicy();

  /// The SDK is `launching` or `launched` and `capture.logs` is on. Both SDKs take a wrapper
  /// channel line in both states (Android `BugseeInternal.log`: `isStartedOrStarting`; iOS
  /// `bugseeAvailableForUserDumps`), keep it in a buffer while the provider starts, and the channel
  /// drops it with `capture.logs` off.
  final bool accepting;

  /// `capture.logs.level`: the most verbose level that is recorded. iOS enforces it on the
  /// channel's lines; Android's provider only applies it to what it reads from logcat, so Dart
  /// applies it for both: the wrapper's lines follow the option like the SDK's automatic capture.
  final LogLevel maxLevel;

  /// The same policy with nothing accepted: the SDK stopped or is stopping.
  LogPolicy notAccepting() => LogPolicy(maxLevel: maxLevel);

  /// Reads the options the SDK reports ([options]: what `getLaunchOptions` returned) and the status.
  factory LogPolicy.from(
    Map<String, Object?> options, {
    required String status,
  }) {
    final capture = options[LogOptionKeys.capture];
    final level = options[LogOptionKeys.level];
    final LogLevel maxLevel =
        (level is int ? LogLevel.fromValue(level) : null) ??
        (level is String
            ? LogLevel.values
                  .where((l) => l.name == level.toLowerCase())
                  .firstOrNull
            : null) ??
        LogLevel.verbose;
    return LogPolicy(
      // The option's own default is on.
      accepting:
          (status == BugseeStatus.launched.name ||
              status == BugseeStatus.launching.name) &&
          (capture is! bool || capture),
      maxLevel: maxLevel,
    );
  }
}
