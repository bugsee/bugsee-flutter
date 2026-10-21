// Extracts the SDKs' own descriptions of every launch option from their SOURCE into
// test/fixtures/option_manifests/docs.json, from which scripts/generate_options.dart writes the
// doc comments of the typed `BugseeOptions` class. The manifests carry key, type, enum values
// and defaults but no prose; the prose lives in the SDKs' option declarations:
//
//   Android  `Options.java` / `NdkOptions.java` / `LeakOptions.java`: the javadoc on each key constant
//   iOS      `BugseeOptions.h`: the block comment / trailing `///<` comment on each
//            `BugseeOption...` constant, and the doc of the matching `BugseeOptions`
//            property (`propertyKeyMap` in `BugseeOptions.m` maps one to the other)
//
//   dart scripts/extract_option_docs.dart --android-repo <android/sdk> --android-ref v7.4.2 \
//        --ios-repo <ios/sdk> --ios-ref origin/nextgen [--check]
//
// `--check` compares with the committed fixture instead of writing it. Needs the (private) SDK
// checkouts, so it is a local check; the fixture records the refs it was read from, and the
// generator's `--check` (offline, in CI) keeps the generated Dart in step with the fixture.
// Reads files with `git show <ref>:<path>`; never switches a branch. Dart SDK only.
import 'dart:convert';
import 'dart:io';

const androidFiles = [
  'library/src/main/java/com/bugsee/library/contracts/options/Options.java',
  'ndk/src/main/java/com/bugsee/library/contracts/options/NdkOptions.java',
  'leak/src/main/java/com/bugsee/library/contracts/options/LeakOptions.java',
];
const iosHeader = 'BugseeDev/BugseeLib/BugseeLib/BugseeOptions.h';
const iosSource = 'BugseeDev/BugseeLib/BugseeLib/BugseeOptions.m';

/// A comment body with the comment markers and the leading `*` of each line removed.
String uncomment(String body) => body
    .split('\n')
    .map((l) => l.replaceFirst(RegExp(r'^\s*\*? ?'), '').trimRight())
    .join('\n')
    .trim();

/// Android javadoc as plain text with Dart-doc markup (`code` in backticks).
String javadocToText(
  String javadoc, {
  required Map<String, String> constantKeys,
}) {
  var t = uncomment(javadoc);
  t = t.replaceAllMapped(
    RegExp(r'\{@link\s+#(\w+)[^}]*\}'),
    (m) => '`${_short(constantKeys[m.group(1)] ?? m.group(1)!)}`',
  );
  t = t.replaceAllMapped(RegExp(r'\{@(?:code|literal)\s+([^}]*)\}'), (m) {
    return '`${m.group(1)}`';
  });
  t = t.replaceAllMapped(
    RegExp(r'\{@link\s+([\w.#()]+)(?:\s+[^}]*)?\}'),
    (m) => '`${m.group(1)!.split(RegExp(r'[.#]')).last.replaceAll('()', '')}`',
  );
  t = t.replaceAll(RegExp(r'</?(?:em|b|i|strong)>'), '');
  t = t.replaceAll(RegExp(r'<p>\s*'), '\n\n');
  t = t.replaceAll(RegExp(r'</?ul>\s*'), '\n');
  t = t.replaceAll(RegExp(r'<li>\s*'), '\n- ').replaceAll('</li>', '');
  t = t
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
  t = _dropNoise(t);
  return _paragraphs(t);
}

String _short(String key) => key.startsWith('com.bugsee.option.')
    ? key.substring('com.bugsee.option.'.length)
    : key;

/// Markup and boilerplate that carries no information here: line breaks, the "Option has
/// value of X type." sentence, and a closing "Default ..." sentence (the manifest carries the
/// defaults, so a prose copy could only drift from them).
String _dropNoise(String text) {
  var t = text.replaceAll(RegExp(r'<br\s*/?>'), ' ').replaceAll('</p>', '');
  t = t.replaceAllMapped(
    RegExp(
      r'Option has (?:a )?value of (?:`?\w+`? )?type(?: and ([a-z]))?\.?',
      caseSensitive: false,
    ),
    (m) => m.group(1) == null ? '' : m.group(1)!.toUpperCase(),
  );
  // A paragraph that only states the default.
  t = t
      .split(RegExp(r'\n\s*\n'))
      .where(
        (p) =>
            !RegExp(r'^\s*Default(?: value is|:)?\s+[^\n]{0,40}$').hasMatch(p),
      )
      .join('\n\n');
  // A "Default value is `X`." sentence, wherever it stands.
  t = t.replaceAll(RegExp(r'\s*Default value is\s+`[^`]*`\.?'), '');
  t = t.replaceAll(
    RegExp(r'\s*Default value is\s+[^\s.][^\s]*?\.(?=\s|$)'),
    '',
  );
  t = t.replaceAll(RegExp(r'\s*\bDefault:?\s+[\w.]+\s*$'), '');
  return t;
}

/// Joins the soft-wrapped lines of each paragraph; keeps `- ` list items on their own lines.
String _paragraphs(String text) {
  final out = <String>[];
  var current = <String>[];
  void flush() {
    if (current.isNotEmpty) out.add(current.join(' ').trim());
    current = [];
  }

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      flush();
    } else if (line.startsWith('- ')) {
      flush();
      current.add(line);
    } else {
      current.add(line);
    }
  }
  flush();
  return out.where((p) => p.isNotEmpty).join('\n\n');
}

/// iOS header comments as plain text.
String objcDocToText(String body) {
  var t = uncomment(body);
  t = t.replaceAll('``', '`');
  t = t.replaceAll('⚠️', 'Warning:').replaceAll('⚠', 'Warning:');
  t = t.replaceAll('—', '-');
  t = _dropNoise(t);
  return _paragraphs(t);
}

/// The text of an iOS trailing `///< BOOL, default YES (iOS-only)` comment without the type
/// and default, which the manifest carries; what is left (a unit, a caveat) is kept.
String trailingToText(String trailing) {
  var t = trailing.trim();
  t = t.replaceFirst(
    RegExp(
      r'^(?:BOOL|float|uint|int|NSString)\b(?:\s+(?:Bugsee\w+|bytes|seconds|ms|MB))?(?:\s+bit-set)?',
    ),
    '',
  );
  t = t.replaceAll(RegExp(r',?\s*default\s+[^\s(—]+(?:\s+\([^)]*\))?'), '');
  t = t.replaceAll('—', '-').trim();
  t = t.replaceFirst(RegExp(r'^[,.;\s-]+'), '').trim();
  return t;
}

/// Android: key -> doc text.
Map<String, String> androidDocs(List<String> sources) {
  final constants = <String, String>{};
  final decl = RegExp(
    r'(?:/\*\*((?:(?!\*/)[\s\S])*)\*/\s*)?(?:@\w+(?:\([^)]*\))?\s*)*(?:public\s+static\s+final\s+)?String\s+(\w+)\s*=\s*"(com\.bugsee\.option\.[^"]+)"',
  );
  for (final s in sources) {
    for (final m in decl.allMatches(s)) {
      constants[m.group(2)!] = m.group(3)!;
    }
  }
  final docs = <String, String>{};
  for (final s in sources) {
    for (final m in decl.allMatches(s)) {
      final javadoc = m.group(1);
      if (javadoc == null) continue;
      final text = javadocToText(javadoc, constantKeys: constants);
      if (text.isNotEmpty) docs[m.group(3)!] = text;
    }
  }
  return docs;
}

class IosDocs {
  IosDocs(this.constant, this.property, this.trailing);
  final Map<String, String> constant;
  final Map<String, String> property;
  final Map<String, String> trailing;
}

/// iOS: key -> the three kinds of description.
IosDocs iosDocs(String header, String source) {
  final keys = <String, String>{
    for (final m in RegExp(
      r'NSString\s*\*const\s+(Bugsee\w+)\s*=\s*@"(com\.bugsee\.option\.[^"]+)"',
    ).allMatches(source))
      m.group(1)!: m.group(2)!,
  };
  final constant = <String, String>{};
  final trailing = <String, String>{};
  final decl = RegExp(
    r'(?:/\*\*((?:(?!\*/)[\s\S])*)\*/\s*)?FOUNDATION_EXPORT\s+NSString\s*\*const\s+_Nonnull\s+(\w+);[ \t]*(?:///<[ \t]*([^\n]*))?',
  );
  for (final m in decl.allMatches(header)) {
    final key = keys[m.group(2)!];
    if (key == null) continue;
    final block = m.group(1);
    // A block that introduces a whole group (it names no single option) is not a description.
    if (block != null && !block.contains('String keys for')) {
      final t = objcDocToText(block);
      if (t.isNotEmpty) constant[key] = t;
    }
    final tr = m.group(3);
    if (tr != null) {
      final t = trailingToText(tr);
      if (t.isNotEmpty) trailing[key] = t;
    }
  }
  // Property -> key, from `propertyKeyMap`: `@"CaptureAVPlayer": BugseeOptionCaptureAVPlayer,`.
  final propertyKey = <String, String>{};
  for (final m in RegExp(
    r'@"(\w+)"\s*:\s*(Bugsee\w+)\s*,',
  ).allMatches(source)) {
    final key = keys[m.group(2)!];
    if (key != null) {
      final n = m.group(1)!;
      propertyKey[n.toLowerCase()] = key;
    }
  }
  final property = <String, String>{};
  for (final m in RegExp(
    r'/\*\*((?:(?!\*/)[\s\S])*)\*/\s*@property\s*\([^)]*\)\s*[\w *<>]+?\b(\w+);',
  ).allMatches(header)) {
    final key = propertyKey[m.group(2)!.toLowerCase()];
    if (key == null) continue;
    final t = objcDocToText(m.group(1)!);
    if (t.isNotEmpty) property[key] = t;
  }
  return IosDocs(constant, property, trailing);
}

String show(String repo, String ref, String path) {
  final r = Process.runSync('git', ['-C', repo, 'show', '$ref:$path']);
  if (r.exitCode != 0) throw StateError('git show $ref:$path: ${r.stderr}');
  return r.stdout as String;
}

/// `ref@<commit>`: a moving ref (`origin/nextgen`) is recorded with what it pointed at.
String pinned(String repo, String ref) {
  final r = Process.runSync('git', ['-C', repo, 'rev-parse', '--short=9', ref]);
  if (r.exitCode != 0) throw StateError('git rev-parse $ref: ${r.stderr}');
  return '$ref@${(r.stdout as String).trim()}';
}

String arg(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) {
    stderr.writeln('missing $name');
    exit(2);
  }
  return args[i + 1];
}

/// Descriptions the SDK sources do not carry. Written here, each derived from the SDK source named
/// with it, and stored in the fixture under `wrapper` so they are never mistaken for the SDK's words.
const supplemental = {
  'com.bugsee.option.capture.video.max-frame-rate':
      'The highest frame rate the video is recorded at, in frames per second, from 0 to 30 (the '
      'SDK clamps it to that range). `0`, the default, applies the SDK\'s own limit. '
      '(BugseeOptions.m `-validate`.)',
  'com.bugsee.option.capture.video.min-frame-rate':
      'The lowest frame rate the video is recorded at, in frames per second, from 0 to 30 (the SDK '
      'clamps it to that range and lowers it to the maximum when it is above it). `0`, the default, '
      'applies the SDK\'s own limit. (BugseeOptions.m `-validate`.)',
  'com.bugsee.option.config.data-encryption':
      'Whether, and how, the data the SDK keeps on the device is encrypted: not at all, with a key '
      'kept on the device, or end to end, where only the server can decrypt it. '
      '(Bugsee.m `-initializeDataEncryption`.)',
};

/// The fixture: per key, the description of each platform that has one, in order of
/// preference for a shared key (Android's javadoc is the fuller text).
Map<String, Object?> build({
  required Map<String, String> android,
  required IosDocs ios,
  required String androidRef,
  required String iosRef,
}) {
  final keys = {
    ...android.keys,
    ...ios.constant.keys,
    ...ios.property.keys,
    ...ios.trailing.keys,
    ...supplemental.keys,
  }.toList()..sort();
  return {
    '_comment':
        'Extracted from the native SDK sources by scripts/extract_option_docs.dart; do not '
        'edit by hand. The prose of the typed BugseeOptions doc comments '
        '(scripts/generate_options.dart).',
    'sources': {'android': androidRef, 'ios': iosRef},
    'docs': {
      for (final k in keys)
        k: {
          if (android[k] != null) 'android': android[k],
          if (ios.property[k] != null) 'iosProperty': ios.property[k],
          if (ios.constant[k] != null) 'iosConstant': ios.constant[k],
          if (ios.trailing[k] != null) 'iosNote': ios.trailing[k],
          if (supplemental[k] != null) 'wrapper': supplemental[k],
        },
    },
  };
}

void main(List<String> args) {
  final root = File.fromUri(Platform.script).parent.parent.path;
  final androidRepo = arg(args, '--android-repo');
  final androidRef = arg(args, '--android-ref');
  final iosRepo = arg(args, '--ios-repo');
  final iosRef = arg(args, '--ios-ref');
  final fixture = build(
    android: androidDocs([
      for (final f in androidFiles) show(androidRepo, androidRef, f),
    ]),
    ios: iosDocs(
      show(iosRepo, iosRef, iosHeader),
      show(iosRepo, iosRef, iosSource),
    ),
    androidRef: pinned(androidRepo, androidRef),
    iosRef: pinned(iosRepo, iosRef),
  );
  final text = '${const JsonEncoder.withIndent('  ').convert(fixture)}\n';
  final path = '$root/test/fixtures/option_manifests/docs.json';
  if (args.contains('--check')) {
    if (!File(path).existsSync() || File(path).readAsStringSync() != text) {
      stderr.writeln('$path is stale; re-run without --check');
      exit(1);
    }
    stdout.writeln('option docs fixture is current');
    return;
  }
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  stdout.writeln('wrote $path');
}
