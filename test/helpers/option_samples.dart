// Shared by the option tests: a sample value for each typed option, and a way to build a
// BugseeOptions with one field set by its generated name.
import 'package:bugsee_flutter/src/options/bugsee_options.g.dart';
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:bugsee_flutter/src/report/report_enums.dart';

import '../../scripts/generate_options.dart' as gen;

/// A sample value of the right type for [spec]'s typed field, and what `typedEntries()` must
/// carry for it.
({Object value, Object entry}) sample(OptionSpec spec) {
  switch (spec.type) {
    case OptionType.boolean:
      return (value: true, entry: true);
    case OptionType.int:
      return (value: 7, entry: 7);
    case OptionType.float:
      return (value: 0.25, entry: 0.25);
    case OptionType.string:
      return (value: 'x', entry: 'x');
    case OptionType.enumeration:
      final constant = switch (spec.enumFamily) {
        'LogLevel' => LogLevel.info,
        'FrameRate' => FrameRate.medium,
        'VideoQuality' => VideoQuality.medium,
        'VideoMode' => VideoMode.v2,
        'ReportSeverity' => ReportSeverity.high,
        'CrashHandlerType' => CrashHandlerType.mach,
        'DataEncryptionMode' => DataEncryptionMode.onDevice,
        'BugseeStyle' => BugseeStyle.dusk,
        _ => throw StateError('no sample for ${spec.enumFamily}'),
      };
      final internal = switch (constant) {
        final LogLevel c => c.value,
        final FrameRate c => c.value,
        final VideoQuality c => c.value,
        final VideoMode c => c.value,
        final ReportSeverity c => c.value,
        final CrashHandlerType c => c.value,
        final DataEncryptionMode c => c.value,
        final BugseeStyle c => c.value,
        _ => throw StateError('unreachable'),
      };
      return (value: constant, entry: internal);
    case OptionType.map:
    case OptionType.list:
      throw StateError('${spec.key} has no typed field');
  }
}

/// A BugseeOptions with only [spec]'s typed field set, to [value].
BugseeOptions withField(OptionSpec spec, Object value) =>
    Function.apply(BugseeOptions.new, [], {
          Symbol(gen.fieldName(spec.key)): value,
        })
        as BugseeOptions;
