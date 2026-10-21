// Generates the Dart option surface from the vendored SDK manifests:
//
//   lib/src/options/option_registry.g.dart  every option both SDKs register, per platform
//   lib/src/options/bugsee_options.g.dart   the typed `BugseeOptions` class and its enums
//
//   dart scripts/generate_options.dart            # write
//   dart scripts/generate_options.dart --check    # fail if a committed output is stale
//
// Inputs (all committed, so the check works offline):
//   test/fixtures/option_manifests/android.json  the SDK's published manifest (sync_option_manifests.dart)
//   test/fixtures/option_manifests/ios.json
//   test/fixtures/option_manifests/docs.json     the SDKs' own prose (extract_option_docs.dart)
//
// The manifest is the authority for keys, types, enum values (by INTERNAL value, never by
// ordinal) and defaults. Android and iOS share the `com.bugsee.option.*` namespace, so there is
// no per-platform translation: one flat map goes to both. What differs is which keys each
// platform has, and that is recorded here, not guessed.
//
// Decisions the generator enforces (each fails the run loudly rather than guessing):
//   * a key must have the same `type` on both platforms where both have it;
//   * an enum must have a Dart name below (`enumFamilies`): a NEW SDK enum has to be named;
//   * two platforms' constants with the same value must have the same name, unless listed in
//     `knownNameDivergences` (value 1 of the severity enum: VeryLow on Android, Low on iOS);
//   * hidden (`$$`) options and options of a module this plugin does not bundle get no typed field.
//
// The generated Dart is formatted with the `dart` on PATH, so run it on the floor Flutter's Dart
// (CI does), or the result differs from what CI expects.
import 'dart:convert';
import 'dart:io';

/// The modules this plugin bundles (android/build.gradle: bugsee-android + bugsee-android-ndk;
/// iOS: the Bugsee SPM product). An option of any other module is accepted by the SDK only when
/// the app adds that module itself, so it gets no typed field (test/options_registry_test.dart
/// compares this list with build.gradle).
const bundledModules = {
  'android': {'bugsee-android', 'bugsee-android-ndk'},
  'ios': {'Bugsee'},
};

/// SDK enum name (either platform) -> the Dart type. `ReportSeverity` is hand-written
/// (lib/src/report/report_enums.dart) and not generated here.
const enumFamilies = {
  'LogLevel': 'LogLevel',
  'BugseeLogLevel': 'LogLevel',
  'FrameRate': 'FrameRate',
  'BugseeFrameRate': 'FrameRate',
  'VideoQuality': 'VideoQuality',
  'BugseeVideoQuality': 'VideoQuality',
  'VideoMode': 'VideoMode',
  'IssueSeverity': 'ReportSeverity',
  'BugseeSeverityLevel': 'ReportSeverity',
  'BugseeCrashHandlerType': 'CrashHandlerType',
  'BugseeDataEncryptionMode': 'DataEncryptionMode',
  'BugseeStyle': 'BugseeStyle',
  // Registered by bugsee-android-leak, which this plugin does not bundle: no typed field.
  'MemoryLeakMode': '',
};

/// Dart families that already exist by hand and so are not emitted.
const handWrittenEnums = {'ReportSeverity'};

/// Enum constants whose NAME differs between platforms for the same VALUE, by Dart family.
const knownNameDivergences = {
  'ReportSeverity': {1: 'VeryLow / Low'},
};

const hiddenPrefix = 'com.bugsee.option.\$\$';

const dartReserved = {
  'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch', //
  'class', 'const', 'continue', 'covariant', 'default', 'deferred', 'do',
  'dynamic', 'else', 'enum', 'export', 'extends', 'extension', 'external',
  'factory', 'false', 'final', 'finally', 'for', 'function', 'get', 'hide',
  'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
  'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow',
  'return', 'set', 'show', 'static', 'super', 'switch', 'sync', 'this',
  'throw', 'true', 'try', 'typedef', 'var', 'void', 'while', 'with', 'yield',
};

String lowerFirst(String s) =>
    s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);
String upperFirst(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// `capture.video.frame-rate` -> `captureVideoFrameRate`; `detect.exit.bg_low_memory_as_error`
/// -> `detectExitBgLowMemoryAsError`.
String fieldName(String key) {
  final path = key.substring('com.bugsee.option.'.length);
  final parts = path.split(RegExp(r'[.\-_]')).where((p) => p.isNotEmpty);
  var first = true;
  final out = StringBuffer();
  for (final p in parts) {
    out.write(first ? lowerFirst(p) : upperFirst(p));
    first = false;
  }
  return out.toString();
}

/// An enum constant's Dart name: `Fullscreen` -> `fullscreen`, `V1` -> `v1`; a reserved word
/// (`Default`) gets the enum's name appended (`defaultVideoQuality`).
String constantName(String sdkName, String family) {
  const acronyms = {'BSD': 'bsd', 'MachAndBSD': 'machAndBsd'};
  var n = acronyms[sdkName] ?? lowerFirst(sdkName);
  if (dartReserved.contains(n)) n = '$n$family';
  return n;
}

class PlatformOption {
  PlatformOption(Map<String, dynamic> json)
    : module = json['module'] as String,
      defaultValue = json['default'],
      enumName = (json['enum'] as Map<String, dynamic>?)?['name'] as String?,
      enumValues = ((json['enum'] as Map<String, dynamic>?)?['values'] as Map?)
          ?.cast<String, Object>(),
      deprecatedSince =
          (json['deprecated'] as Map<String, dynamic>?)?['since'] as String?,
      hidden = json['hidden'] == true,
      type = json['type'] as String;

  final String module;
  final Object? defaultValue;
  final String? enumName;
  final Map<String, Object>? enumValues;
  final String? deprecatedSince;
  final bool hidden;
  final String type;
}

class Option {
  Option(this.key, this.android, this.ios);
  final String key;
  final PlatformOption? android;
  final PlatformOption? ios;

  PlatformOption get any => (android ?? ios)!;
  bool get hidden => any.hidden;
  String get type => any.type;
  String? get enumFamily {
    final n = any.enumName;
    return n == null ? null : enumFamilies[n];
  }

  /// Whether the typed class carries this option.
  bool get typed {
    if (hidden) return false;
    final a = android, i = ios;
    final shipsAndroid =
        a != null && bundledModules['android']!.contains(a.module);
    final shipsIos = i != null && bundledModules['ios']!.contains(i.module);
    return shipsAndroid || shipsIos;
  }
}

Map<String, PlatformOption> readManifest(String path, String sdk) {
  final json =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final o in (json['options'] as List).cast<Map<String, dynamic>>())
      o['key'] as String: PlatformOption(o),
  };
}

/// Android and iOS merged by key, sorted by key.
List<Option> mergeManifests(
  Map<String, PlatformOption> android,
  Map<String, PlatformOption> ios,
) {
  final keys = {...android.keys, ...ios.keys}.toList()..sort();
  final out = <Option>[];
  for (final k in keys) {
    final a = android[k], i = ios[k];
    if (a != null && i != null) {
      if (a.type != i.type) {
        throw StateError('$k: type ${a.type} on Android, ${i.type} on iOS');
      }
      if (a.hidden != i.hidden) {
        throw StateError('$k: hidden on one platform only');
      }
      final an = a.enumName, inm = i.enumName;
      if (an != null && inm != null && enumFamilies[an] != enumFamilies[inm]) {
        throw StateError(
          '$k: enum $an (Android) and $inm (iOS) are different Dart families',
        );
      }
    }
    out.add(Option(k, a, i));
  }
  return out;
}

/// One generated enum: constant name -> (value, on Android, on iOS) and the SDK names.
class EnumSpec {
  EnumSpec(this.dartName);
  final String dartName;
  final Map<String, Object> androidValues = {};
  final Map<String, Object> iosValues = {};
  final Set<String> keys = {};
}

Map<String, EnumSpec> collectEnums(List<Option> options) {
  final out = <String, EnumSpec>{};
  for (final o in options) {
    for (final p in [o.android, o.ios]) {
      if (p == null || p.enumName == null) continue;
      final family = enumFamilies[p.enumName];
      if (family == null) {
        throw StateError(
          '${o.key}: the SDK enum ${p.enumName} has no Dart name; add it to enumFamilies '
          'in scripts/generate_options.dart',
        );
      }
      if (family.isEmpty) continue;
      final spec = out.putIfAbsent(family, () => EnumSpec(family));
      spec.keys.add(o.key);
      final target = identical(p, o.android)
          ? spec.androidValues
          : spec.iosValues;
      for (final e in p.enumValues!.entries) {
        final existing = target[e.key];
        if (existing != null && existing != e.value) {
          throw StateError('${p.enumName}.${e.key}: two different values');
        }
        target[e.key] = e.value;
      }
    }
  }
  return out;
}

/// For a generated enum: its members, ordered by value, with the platforms each is on.
class Member {
  Member(this.sdkName, this.value, this.onAndroid, this.onIos);
  final String sdkName;
  final Object value;
  final bool onAndroid;
  final bool onIos;
}

List<Member> membersOf(EnumSpec e) {
  final byValue = <Object, Member>{};
  void add(Map<String, Object> values, bool android) {
    for (final entry in values.entries) {
      final existing = byValue[entry.value];
      if (existing == null) {
        byValue[entry.value] = Member(
          entry.key,
          entry.value,
          android,
          !android,
        );
      } else {
        if (existing.sdkName != entry.key) {
          throw StateError(
            '${e.dartName}: value ${entry.value} is ${existing.sdkName} on Android '
            'and ${entry.key} on iOS; list it in knownNameDivergences if intended',
          );
        }
        byValue[entry.value] = Member(
          existing.sdkName,
          existing.value,
          true,
          true,
        );
      }
    }
  }

  add(e.androidValues, true);
  add(e.iosValues, false);
  final list = byValue.values.toList()
    ..sort((a, b) => (a.value as num).compareTo(b.value as num));
  // A member only the other platform has must not be marked as both.
  return [
    for (final m in list)
      Member(
        m.sdkName,
        m.value,
        e.androidValues.containsValue(m.value),
        e.iosValues.containsValue(m.value),
      ),
  ];
}

// ---- docs

String dartDocLine(String s) => s.isEmpty ? '///' : '/// $s';

/// Greedy word wrap of one paragraph (or one `- ` list item) at [width] columns.
List<String> wrap(String paragraph, {int width = 92}) {
  final words = paragraph.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final isItem = paragraph.startsWith('- ');
  final lines = <String>[];
  var current = '';
  for (final w in words) {
    if (current.isNotEmpty && current.length + 1 + w.length > width) {
      lines.add(current);
      current = isItem ? '  $w' : w;
    } else {
      current = current.isEmpty ? w : '$current $w';
    }
  }
  if (current.isNotEmpty) lines.add(current);
  return lines;
}

/// Escapes what Dart doc markdown would read as a reference or HTML, outside code spans.
String escapeDoc(String text) {
  final parts = text.split('`');
  for (var i = 0; i < parts.length; i += 2) {
    parts[i] = parts[i]
        .replaceAll('[', r'\[')
        .replaceAll(']', r'\]')
        .replaceAll('<', '&lt;');
  }
  return parts.join('`');
}

String describeValue(Option o, Object? v, {String? family}) {
  if (v == null) return 'none';
  if (o.type == 'enum') {
    final name = family == null
        ? v.toString()
        : '$family.${constantName(v.toString(), family)}';
    return name;
  }
  if (v is String) return "'$v'";
  if (v is double && v == v.roundToDouble() && o.type == 'float') {
    return v.toStringAsFixed(1);
  }
  if (o.type == 'float' && v is int) return '$v.0';
  return '$v';
}

String dartType(Option o) {
  switch (o.type) {
    case 'boolean':
      return 'bool';
    case 'int':
      return 'int';
    case 'float':
      return 'double';
    case 'string':
      return 'String';
    case 'enum':
      return o.enumFamily!;
  }
  throw StateError('${o.key}: no typed field for type ${o.type}');
}

String platformsLine(Option o) {
  if (o.android != null && o.ios != null) return 'Android and iOS.';
  if (o.android != null) {
    return 'Android only. On iOS the option is ignored (a debug-mode warning says so).';
  }
  return 'iOS only. On Android the option is ignored (a debug-mode warning says so).';
}

String fieldDoc(
  Option o,
  Map<String, dynamic> docs,
  Map<String, EnumSpec> enums,
) {
  final d = (docs[o.key] as Map<String, dynamic>?) ?? const {};
  final text =
      (d['android'] ??
              d['iosProperty'] ??
              d['iosConstant'] ??
              d['iosNote'] ??
              d['wrapper'])
          as String?;
  final lines = <String>[];
  if (text != null) {
    for (final p in escapeDoc(text).split('\n')) {
      lines.addAll(p.isEmpty ? [''] : wrap(p));
    }
  } else {
    lines.add('The SDK publishes no description for this option.');
  }
  lines.add('');
  lines.add('- Option key: `${o.key}`.');
  final family = o.enumFamily;
  final a = o.android, i = o.ios;
  String def(PlatformOption? p) =>
      describeValue(o, p?.defaultValue, family: family);
  if (a != null && i != null) {
    final da = def(a), di = def(i);
    lines.add(
      da == di
          ? '- SDK default: `$da`.'
          : '- SDK default: `$da` on Android, `$di` on iOS.',
    );
  } else {
    lines.add('- SDK default: `${def(a ?? i)}`.');
  }
  lines.add('- Available on: ${platformsLine(o)}');
  final module = (a ?? i)!.module;
  if (a != null && module == 'bugsee-android-ndk') {
    lines.add(
      'Registered by the `bugsee-android-ndk` module, which this plugin bundles.',
    );
  }
  if (family != null && !handWrittenEnums.contains(family)) {
    final spec = enums[family]!;
    final restricted = [
      for (final m in membersOf(spec))
        if (!(m.onAndroid && m.onIos))
          '`${constantName(m.sdkName, family)}` is ${m.onAndroid ? 'Android' : 'iOS'} only',
    ];
    if (restricted.isNotEmpty) {
      lines.add(
        '${restricted.join('; ')}; on the other platform it is ignored, with a debug-mode warning.',
      );
    }
  }
  final dep = (a ?? i)!.deprecatedSince;
  if (dep != null) {
    lines.add('- Deprecated since SDK $dep; the SDK still honours it.');
  }
  return lines.map((l) => '  ${dartDocLine(l)}').join('\n');
}

// ---- emission

String q(String s) => "'${s.replaceAll(r'$', r'\$').replaceAll("'", r"\'")}'";

String literal(Object? v) {
  if (v == null) return 'null';
  if (v is String) return q(v);
  if (v is bool) return '$v';
  if (v is int) return '$v';
  if (v is double) return '$v';
  throw StateError('cannot emit $v');
}

String emitRegistry(
  List<Option> options,
  Map<String, dynamic> docsFile,
  Map<String, String> manifestMeta,
) {
  final b = StringBuffer()
    ..writeln(
      '// GENERATED by scripts/generate_options.dart from the SDKs\' options manifests',
    )
    ..writeln('// (test/fixtures/option_manifests). Do not edit by hand.')
    ..writeln('//')
    ..writeln('// ${manifestMeta['android']}')
    ..writeln('// ${manifestMeta['ios']}')
    ..writeln()
    ..writeln("import 'option_registry.dart';")
    ..writeln()
    ..writeln(
      '/// Every option either SDK registers, hidden ones included, by key.',
    )
    ..writeln('const List<OptionSpec> optionSpecs = [');
  for (final o in options) {
    b.writeln('  OptionSpec(');
    b.writeln('    key: ${q(o.key)},');
    b.writeln(
      '    type: OptionType.${o.type == 'enum' ? 'enumeration' : o.type},',
    );
    b.writeln('    hidden: ${o.hidden},');
    b.writeln('    typed: ${o.typed},');
    if (o.enumFamily != null) b.writeln('    enumFamily: ${q(o.enumFamily!)},');
    for (final entry in [('android', o.android), ('ios', o.ios)]) {
      final p = entry.$2;
      if (p == null) continue;
      b.writeln('    ${entry.$1}: PlatformOption(');
      b.writeln('      module: ${q(p.module)},');
      b.writeln('      defaultValue: ${literal(p.defaultValue)},');
      if (p.enumName != null) {
        b.writeln('      enumName: ${q(p.enumName!)},');
        b.writeln('      enumValues: {');
        for (final e in p.enumValues!.entries) {
          b.writeln('        ${q(e.key)}: ${literal(e.value)},');
        }
        b.writeln('      },');
      }
      if (p.deprecatedSince != null) {
        b.writeln('      deprecatedSince: ${q(p.deprecatedSince!)},');
      }
      b.writeln('    ),');
    }
    b.writeln('  ),');
  }
  b.writeln('];');
  return b.toString();
}

String emitOptions(
  List<Option> options,
  Map<String, dynamic> docs,
  Map<String, EnumSpec> enums,
) {
  final typed = options.where((o) => o.typed).toList();
  final names = <String, String>{};
  for (final o in typed) {
    final n = fieldName(o.key);
    if (dartReserved.contains(n)) {
      throw StateError('${o.key}: field name $n is reserved');
    }
    final clash = names[n];
    if (clash != null) {
      throw StateError('field name $n for both $clash and ${o.key}');
    }
    names[n] = o.key;
  }
  const reserved = {
    'endpoint',
    'custom',
    'hashCode',
    'runtimeType',
    'toString',
  };
  for (final n in names.keys) {
    if (reserved.contains(n)) {
      throw StateError('generated field $n collides with a member');
    }
  }

  final b = StringBuffer()
    ..writeln(
      '// GENERATED by scripts/generate_options.dart from the SDKs\' options manifests',
    )
    ..writeln(
      '// (test/fixtures/option_manifests) and their docs. Do not edit by hand.',
    )
    ..writeln()
    ..writeln("import 'package:meta/meta.dart';")
    ..writeln()
    ..writeln("import '../report/report_enums.dart';")
    ..writeln();

  // Enums
  for (final family in enums.keys.toList()..sort()) {
    if (handWrittenEnums.contains(family)) continue;
    final spec = enums[family]!;
    final members = membersOf(spec);
    b.writeln(
      '/// The values of the SDK options ${spec.keys.map((k) => '`${k.substring('com.bugsee.option.'.length)}`').join(', ')}.',
    );
    final single =
        !members.any((x) => x.onAndroid && x.onIos) &&
        (members.every((x) => x.onIos) || members.every((x) => x.onAndroid));
    if (single) {
      b.writeln('///');
      b.writeln(
        '/// ${members.every((x) => x.onIos) ? 'iOS' : 'Android'} only: ignored, with a debug-mode warning, on the other platform.',
      );
    }
    b.writeln('///');
    b.writeln(
      '/// Each constant carries the SDK\'s INTERNAL value (what crosses to the SDK), never its',
    );
    b.writeln(
      '/// ordinal: ordinals differ between platforms and shift between releases.',
    );
    b.writeln('enum $family {');
    for (var i = 0; i < members.length; i++) {
      final m = members[i];
      final name = constantName(m.sdkName, family);
      final end = i == members.length - 1 ? ';' : ',';
      // Only a constant that one platform lacks while the enum exists on both is worth a note;
      // an enum of one platform says so once, at the top.
      final spansBoth =
          members.any((x) => x.onAndroid) && members.any((x) => x.onIos);
      final platforms = m.onAndroid && m.onIos || !spansBoth
          ? ''
          : '/// ${m.onAndroid ? 'Android' : 'iOS'} only.\n  ';
      b.writeln(
        '  $platforms$name(${literal(m.value)}, ${m.onAndroid}, ${m.onIos})$end',
      );
    }
    b.writeln('''

  const $family(this.value, this.onAndroid, this.onIos);

  /// The SDK's internal value.
  final int value;

  /// Whether the Android SDK has this value.
  final bool onAndroid;

  /// Whether the iOS SDK has this value.
  final bool onIos;

  /// The constant for an SDK value, or `null` for one this version does not know.
  static $family? fromValue(Object? value) {
    for (final c in values) {
      if (c.value == value) return c;
    }
    return null;
  }
}
''');
  }

  b.writeln('''/// The launch options of the Bugsee SDK.
///
/// Every field is optional: `null` leaves the option at the SDK's own default, which differs
/// between platforms for a few options (each field says which). Android and iOS share one
/// option namespace (`com.bugsee.option.*`), so one object configures both. An option that
/// exists on one platform only is ignored on the other (and a warning is printed in debug
/// builds), so a shared configuration can set platform-specific options.
///
/// The fields are generated from the manifests the two SDKs publish for the pinned versions
/// (`native-versions.json`); `custom` reaches an option this version of the plugin has no
/// field for, by its key. Hidden SDK options (`\$\$ENDPOINT`, `\$\$WRAPPER`, `\$\$DEBUG`) are
/// not part of the public surface; [endpoint] is the one supported override.
@immutable
final class BugseeOptions {
  /// Creates the options; every argument left out keeps the SDK's default.
  const BugseeOptions({
    this.endpoint,
    this.custom = const {},''');
  for (final o in typed) {
    b.writeln('    this.${fieldName(o.key)},');
  }
  b.writeln('  });');
  b.writeln('''
  /// The API endpoint, for an on-premises installation or a test server.
  ///
  /// Give the base URL; a trailing slash and an API version segment (`/v2`) are accepted and
  /// removed, because both SDKs append the version themselves. Not one of the SDKs' public options
  /// (it is hidden in the manifest), so it is neither listed in uploaded reports nor reachable
  /// through [custom].
  final String? endpoint;

  /// Options this version of the plugin has no field for, by their full key
  /// (`com.bugsee.option...`).
  ///
  /// A key neither SDK registers is an [ArgumentError] when the options are used (the SDKs
  /// themselves drop an unknown key without a word, which hides a typo); so is a hidden `\$\$` key
  /// and a value of the wrong type. A key that exists on the other platform only is ignored, like
  /// a typed field of that platform. Enum options take the SDK's internal value (an `int`).
  final Map<String, Object?> custom;
''');
  for (final o in typed) {
    b.writeln(fieldDoc(o, docs['docs'] as Map<String, dynamic>, enums));
    b.writeln('  final ${dartType(o)}? ${fieldName(o.key)};');
    b.writeln();
  }
  b.writeln(
    '''  /// The typed fields that are set, by SDK key, with enums as their internal value.
  ///
  /// Internal: the platform filtering, validation and the endpoint rule are applied by the
  /// encoder (`encodeLaunchOptions`), which is what reaches the SDKs.
  @internal
  Map<String, Object> typedEntries() => {''',
  );
  for (final o in typed) {
    final n = fieldName(o.key);
    final value = o.type == 'enum' ? '$n!.value' : '$n!';
    b.writeln('    if ($n != null) ${q(o.key)}: $value,');
  }
  b.writeln('  };');
  b.writeln('}');
  return b.toString();
}

String formatDart(String source, String name) {
  final dir = Directory.systemTemp.createTempSync('bugsee_gen_');
  try {
    final file = File('${dir.path}/$name')..writeAsStringSync(source);
    final r = Process.runSync(Platform.resolvedExecutable, [
      'format',
      file.path,
    ]);
    if (r.exitCode != 0) throw StateError('dart format failed: ${r.stderr}');
    return file.readAsStringSync();
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main(List<String> args) {
  final root = File.fromUri(Platform.script).parent.parent.path;
  final dir = '$root/test/fixtures/option_manifests';
  final android = readManifest('$dir/android.json', 'android');
  final ios = readManifest('$dir/ios.json', 'ios');
  final docs =
      jsonDecode(File('$dir/docs.json').readAsStringSync())
          as Map<String, dynamic>;
  Map<String, dynamic> meta(String sdk) {
    final j =
        jsonDecode(File('$dir/$sdk.json').readAsStringSync())
            as Map<String, dynamic>;
    return j;
  }

  final am = meta('android'), im = meta('ios');
  final options = mergeManifests(android, ios);
  final enums = collectEnums(options);
  final header = {
    'android':
        'Android ${am['sdkVersion']} (manifest generatedAt ${am['generatedAt']})',
    'ios':
        'iOS ${im['sdkVersion']} (manifest generatedAt ${im['generatedAt']})',
  };
  final outputs = {
    '$root/lib/src/options/option_registry.g.dart': formatDart(
      emitRegistry(options, docs, header),
      'option_registry.g.dart',
    ),
    '$root/lib/src/options/bugsee_options.g.dart': formatDart(
      emitOptions(options, docs, enums),
      'bugsee_options.g.dart',
    ),
  };
  final check = args.contains('--check');
  var stale = false;
  for (final e in outputs.entries) {
    final file = File(e.key);
    if (check) {
      if (!file.existsSync() || file.readAsStringSync() != e.value) {
        stderr.writeln('stale generated file: ${e.key}');
        stale = true;
      }
    } else {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(e.value);
      stdout.writeln('wrote ${e.key}');
    }
  }
  if (stale) {
    stderr.writeln('Run `dart scripts/generate_options.dart` and commit.');
    exit(1);
  }
  if (check) stdout.writeln('generated option files are current');
}
