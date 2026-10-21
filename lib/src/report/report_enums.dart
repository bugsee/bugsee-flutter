// The report enums, by VALUE (workbook 7.4). `ReportSeverity` is public (it types the three
// default-priority launch options); `ReportType` is public too (it types `ReportProxy.type`).
//
// Neither enum's `index` ever crosses the bridge: ordinals differ between
// platforms and shift between releases, and Pigeon would send an enum as its
// ordinal, so the bridge declares no enum at all (`test/report_enum_parity_test.dart`
// asserts that). What crosses is the SDK's integer (severity) or string (type).
//
// The values are repeated from the SDK sources, not invented:
// `test/fixtures/report_enums.json` is extracted from Android `IssueSeverity` /
// `IssueType` (v7.4.2) and iOS `BugseeSeverityLevel` (7.0.0-beta7) by
// `scripts/extract_report_enums.dart`, and `test/report_enum_parity_test.dart`
// compares this file with BOTH platforms, so a divergence in either is seen.

import 'package:meta/meta.dart';

/// How severe a report is. The SDK's internal integer is [value].
///
/// Value 1 is `VeryLow` on Android and `Low` on iOS; the names diverge only
/// there (2..5 agree). Dart follows Android's name, like the other Bugsee
/// wrappers, and [low] is the iOS name for the same value. Always map by
/// [value], never by [index] and never by name.
enum ReportSeverity {
  veryLow(1),
  medium(2),
  high(3),
  critical(4),
  blocker(5);

  const ReportSeverity(this.value);

  /// What crosses the bridge and what the backend stores.
  final int value;

  /// iOS's name (`BugseeSeverityLow`) for [veryLow].
  static const ReportSeverity low = veryLow;

  /// The smallest and largest value the SDKs accept. Repeated in Java
  /// (`ReportOps.MIN_SEVERITY`/`MAX_SEVERITY`) and Objective-C
  /// (`BGSFlutterReportOps`); the parity test compares all three.
  @internal
  static const int minValue = 1;
  @internal
  static const int maxValue = 5;

  /// The severity for an SDK value, or `null` for anything else, including the
  /// 0 iOS reads for "never set" (which must not become a level) and values a
  /// future SDK may add.
  static ReportSeverity? fromValue(int? value) {
    for (final s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// What kind of issue a report is: the SDKs' own strings, as the report states them.
///
/// Evidence of nothing else: in particular not of a crash recovered on the next
/// launch, which a handler cannot tell from a live `logException` by type and
/// `isTerminating` (workbook 7.2.3).
enum ReportType {
  bug('bug'),
  crash('crash'),
  error('error');

  const ReportType(this.wire);

  /// Android `IssueType.toString()` and the string iOS `BGSReportContract.type` returns.
  final String wire;

  /// The type for the SDK's string, or `null` for one this version does not know.
  static ReportType? fromWire(String? wire) {
    for (final t in values) {
      if (t.wire == wire) return t;
    }
    return null;
  }
}
