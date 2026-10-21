// Turns a `BugseeOptions` into the ONE flat map both SDKs take. Internal.
//
// Android and iOS share the `com.bugsee.option.*` namespace, so there is no per-platform
// translation: the same keys, the same values. What this does is the checking the SDKs do not:
//
//   * a key neither SDK registers is an error here (both SDKs DROP it without a word, which hides
//     a typo; see the options spec, "Consumer rules");
//   * a hidden (`$$`) key is an error, except the endpoint, which has its own field;
//   * a value of the wrong type is an error (the SDKs drop that silently too, leaving the default);
//   * a key, or an enum constant, that exists on the OTHER platform only is skipped, with a
//     warning: one shared configuration may set platform-specific options;
//   * enums cross as the SDK's INTERNAL value, never the ordinal.
//
// The one platform-specific step is the Android enum conversion (the Android SDK takes an enum
// option as a constant or its name, not as a number), which happens natively
// (`LaunchOptionValues.java`).
import 'bugsee_options.g.dart';
import 'endpoint.dart';
import 'option_registry.dart';
import 'option_registry.g.dart';

/// The result of encoding: what to send, and what was left out and why.
final class EncodedLaunchOptions {
  const EncodedLaunchOptions(this.values, this.warnings);

  /// Flat, keyed by `com.bugsee.option.*`; values are `bool`, `int`, `double` or `String`.
  final Map<String, Object> values;

  /// Human-readable notes about options that were left out (printed in debug builds).
  final List<String> warnings;
}

final Map<String, OptionSpec> _byKey = {
  for (final spec in optionSpecs) spec.key: spec,
};

/// The registered option [key], or `null`.
OptionSpec? optionSpecForKey(String key) => _byKey[key];

String _name(OptionPlatform p) =>
    p == OptionPlatform.android ? 'Android' : 'iOS';

OptionPlatform _otherThan(OptionPlatform p) =>
    p == OptionPlatform.android ? OptionPlatform.ios : OptionPlatform.android;

/// The modules this plugin bundles, per platform (compared with android/build.gradle by
/// test/options_registry_test.dart, and with scripts/generate_options.dart).
const Map<OptionPlatform, Set<String>> bundledModules = {
  OptionPlatform.android: {'bugsee-android', 'bugsee-android-ndk'},
  OptionPlatform.ios: {'Bugsee'},
};

/// Encodes [options] for [platform]. Throws [ArgumentError] for an option that cannot be
/// honoured on ANY platform (unknown key, hidden key, wrong type, bad endpoint, an enum value
/// neither SDK has).
EncodedLaunchOptions encodeLaunchOptions(
  BugseeOptions options,
  OptionPlatform platform,
) {
  final warnings = <String>[];
  final values = <String, Object>{};
  final typed = options.typedEntries();

  /// Adds [value] under [key] unless this platform lacks the option or the enum constant.
  void add(OptionSpec spec, Object value, {required bool custom}) {
    final key = spec.key;
    final here = spec.on(platform);
    if (here == null) {
      warnings.add(
        '$key exists on ${_name(_otherThan(platform))} only: ignored on ${_name(platform)}',
      );
      return;
    }
    if (spec.type == OptionType.enumeration && value is int) {
      if (!here.enumValues!.values.contains(value)) {
        final elsewhere =
            spec.on(_otherThan(platform))?.enumValues?.values.contains(value) ??
            false;
        if (!elsewhere) {
          throw ArgumentError.value(
            value,
            key,
            'is not a value of ${here.enumName} (${here.enumValues})',
          );
        }
        warnings.add(
          '$key = $value is not a value of ${here.enumName} on ${_name(platform)}: ignored, '
          'the platform default applies',
        );
        return;
      }
    }
    if (custom &&
        !spec.typed &&
        !bundledModules[platform]!.contains(here.module)) {
      warnings.add(
        '$key is registered by the ${here.module} module, which this plugin does not bundle: '
        'the SDK ignores it unless the app adds that module',
      );
    }
    final deprecated = here.deprecatedSince;
    if (custom && deprecated != null) {
      warnings.add(
        '$key is deprecated since SDK $deprecated; the SDK still accepts it',
      );
    }
    values[key] = value;
  }

  for (final entry in typed.entries) {
    final value = entry.value;
    if (value is double && !value.isFinite) {
      throw ArgumentError.value(value, entry.key, 'must be a finite number');
    }
    add(_byKey[entry.key]!, value, custom: false);
  }

  for (final entry in options.custom.entries) {
    final key = entry.key;
    final spec = _byKey[key];
    if (spec == null) {
      throw ArgumentError.value(
        key,
        'custom',
        'is not an option either Bugsee SDK registers (the SDKs would drop it without a '
            'word); keys look like com.bugsee.option.capture.logs',
      );
    }
    if (spec.hidden) {
      throw ArgumentError.value(
        key,
        'custom',
        'is an internal option and not part of the public API'
            '${key == endpointOptionKey ? ' (use BugseeOptions.endpoint)' : ''}',
      );
    }
    if (typed.containsKey(key)) {
      throw ArgumentError.value(
        key,
        'custom',
        'is already set by its typed field; set it in one place',
      );
    }
    add(spec, _checkValue(spec, key, entry.value), custom: true);
  }

  final endpoint = normalizeEndpoint(options.endpoint);
  if (endpoint != null) values[endpointOptionKey] = endpoint;

  return EncodedLaunchOptions(
    Map.unmodifiable(values),
    List.unmodifiable(warnings),
  );
}

/// The value as the SDKs want it, or an [ArgumentError] naming the option.
Object _checkValue(OptionSpec spec, String key, Object? value) {
  Never bad(String expected) => throw ArgumentError.value(
    value,
    key,
    'must be $expected (the SDKs drop a value of another type and keep the default)',
  );
  switch (spec.type) {
    case OptionType.boolean:
      if (value is bool) return value;
      bad('a bool');
    case OptionType.int:
      if (value is int) return value;
      bad('an int');
    case OptionType.float:
      if (value is num && value.isFinite) return value.toDouble();
      bad('a finite number');
    case OptionType.string:
      if (value is String) return value;
      bad('a String');
    case OptionType.enumeration:
      // The internal value, never an ordinal.
      if (value is int) return value;
      if (value is String) {
        final names = <String, Object>{
          ...?spec.ios?.enumValues,
          ...?spec.android?.enumValues,
        };
        // A string-valued enum (the leak module's MemoryLeakMode) takes its constant name or
        // wire string as the SDK documents it.
        if (names.values.every((v) => v is String)) {
          if (names.containsKey(value) || names.containsValue(value)) {
            return value;
          }
          bad('one of ${names.keys.toList()}');
        }
        // An int-valued enum is sent as the number: Android resolves a name itself, but iOS
        // reads a string as 0 (KVC), which is a different, sometimes invalid, constant. So the
        // NAME is looked up here, in the manifest, and the number is what crosses.
        final internal = names[value];
        if (internal != null) return internal;
        bad(
          'one of the constant names ${names.keys.toList()}, or the internal int',
        );
      }
      bad('the SDK\'s internal enum value (an int), or a constant name');
    case OptionType.map:
    case OptionType.list:
      throw ArgumentError.value(
        value,
        key,
        'is a ${spec.type.name} option, which this plugin does not set',
      );
  }
}
