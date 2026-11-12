// The ways the verification app takes itself down or fails (example/lib/crash_lab.dart) and what the
// harness expects of each. One table, compared by test/device_harness_test.dart with the app's list,
// so a kind added on one side only fails a test instead of silently never running.

/// Where the failure happens.
enum CrashLayer {
  /// Native code in the process (FFI into libc raising a signal): the NDK crash handler's job.
  native,

  /// The platform's own language (Java on Android): the SDK's uncaught-exception handler.
  platform,

  /// Dart: the handlers `Bugsee.installErrorHandlers` installs (nothing dies).
  dart,
}

class CrashKind {
  const CrashKind(
    this.name,
    this.layer, {
    this.signal,
    this.marker,
    this.expectReport = true,
    this.alsoContains = const [],
  });

  /// The `crash <name>` command.
  final String name;
  final CrashLayer layer;

  /// The signal number the kernel logs and the minidump records (native kinds).
  final int? signal;

  /// Text that must be in the report's crash entry (the exception's message).
  final String? marker;

  /// False for a failure that, by design, no report records (the harness then proves the absence
  /// against a positive control).
  final bool expectReport;

  /// More text the report must hold (a cause chain).
  final List<String> alsoContains;

  bool get fatal => layer != CrashLayer.dart;
}

const crashKindTable = <CrashKind>[
  CrashKind('ffi-segv', CrashLayer.native, signal: 11),
  CrashKind('ffi-abort', CrashLayer.native, signal: 6),
  CrashKind('ffi-fpe', CrashLayer.native, signal: 8),
  CrashKind('ffi-bus', CrashLayer.native, signal: 7),
  CrashKind('ffi-ill', CrashLayer.native, signal: 4),
  CrashKind('java-main', CrashLayer.platform, marker: 'verify-java-main'),
  CrashKind('java-thread', CrashLayer.platform, marker: 'verify-java-thread'),
  CrashKind(
    'java-nested',
    CrashLayer.platform,
    marker: 'verify-java-outer',
    alsoContains: ['verify-java-cause'],
  ),
  CrashKind(
    'dart-sync-framework',
    CrashLayer.dart,
    marker: 'verify-dart-sync-framework',
  ),
  CrashKind('dart-async', CrashLayer.dart, marker: 'verify-dart-async'),
  CrashKind('dart-zone', CrashLayer.dart, marker: 'verify-dart-zone'),
  CrashKind('dart-isolate', CrashLayer.dart, marker: 'verify-dart-isolate'),
  CrashKind(
    'dart-isolate-unlistened',
    CrashLayer.dart,
    marker: 'verify-dart-isolate-unlistened',
    expectReport: false,
  ),
  CrashKind(
    'dart-platform-dispatcher',
    CrashLayer.dart,
    marker: 'verify-dart-platform-dispatcher',
  ),
  CrashKind('dart-timer', CrashLayer.dart, marker: 'verify-dart-timer'),
  CrashKind('dart-stream', CrashLayer.dart, marker: 'verify-dart-stream'),
];
