// Proves that a stack captured from an obfuscated or --split-debug-info build symbolizes with the
// symbols of that build: the check the backend does, offline, with the same tool.
//
//   dart scripts/verify_symbolization.dart --symbols build/symbols/app.android-arm64.symbols \
//       --entry test/fixtures/exceptions/android_7_4_2_obfuscated_entry.json \
//       --expect level3,level2,level1 [--tool /path/to/dart_symbolize]
//
// `--entry` is either the `exception` entry of a bundle's crash.json (name + reason: the Flutter
// document is read out of the reason by the worker's own rules) or a plain text stack. The build id
// printed in the stack's header must be inside the symbols file (that is how the backend finds the
// symbols), and every `--expect` name must come out of the symbolizer. `--tool` is the worker's
// `dart_symbolize` (stack on stdin, symbols file as the argument; dart-symbolize repository, `dist/`);
// without it `package:native_stack_traces` (0.7.1) is used, which decodes the same format. The worker
// strips everything before the first `#00` (header lines included, symbolfiles/flutter.py) before it runs
// `dart_symbolize`; with `--tool` the same is done here. That is not cosmetic: the dart_symbolize built from
// bugsee-symbolication-aux (a 2023 copy of native_stack_traces) crashes on a Dart 3.14 stack that still has
// its header (the header path looks for the `_kDartIsolateSnapshotInstructions` symbol, which Dart 3.14 symbols
// do not have: they carry `_kDartSnapshotText`), and decodes the stripped one by the `virt` address.
//
// The symbols file is NOT committed (it holds the build machine's paths): produce it with
// `flutter build apk --release --obfuscate --split-debug-info=<dir>`. Exit code 0 when it checks out.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  String? option(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  // Absolute, because the decoder runs in the repository root: a relative path would mean two places.
  final symbolsArg = option('--symbols');
  final symbols = symbolsArg == null ? null : File(symbolsArg).absolute.path;
  final entry = option('--entry');
  final expected = (option('--expect') ?? '')
      .split(',')
      .where((e) => e.isNotEmpty)
      .toList();
  final tool = option('--tool');
  if (symbols == null || entry == null) {
    stderr.writeln(
      'usage: --symbols <file.symbols> --entry <entry.json|trace.txt> [--expect a,b] [--tool dart_symbolize]',
    );
    exit(64);
  }

  var stack = File(entry).readAsStringSync();
  if (entry.endsWith('.json')) {
    final exception = (jsonDecode(stack) as Map)['exception'] as Map;
    // The worker's rules (crash/managed/dart.py:159-164): strip the SDK's envelope, then
    // everything before the opening brace.
    var reason = exception['reason'] as String;
    reason = reason.replaceFirst(
      RegExp(r'^\s*.*FlutterManagedException:\s*'),
      '',
    );
    reason = reason.replaceFirst(RegExp(r'^[^{"]+'), '');
    stack = (jsonDecode(reason) as Map)['originalStackTrace'] as String;
  }

  final buildId = RegExp(r"build_id:\s*'([^']+)'").firstMatch(stack)?.group(1);
  if (buildId == null) {
    stderr.writeln('FAIL: no build_id in the stack (not a non-symbolic stack)');
    exit(1);
  }
  final bytes = File(symbols).readAsBytesSync();
  final needle = [
    for (var i = 0; i < buildId.length; i += 2)
      int.parse(buildId.substring(i, i + 2), radix: 16),
  ];
  if (_indexOf(bytes, needle) < 0) {
    stderr.writeln(
      'FAIL: build id $buildId is not in $symbols: it is another build\'s symbols',
    );
    exit(1);
  }
  stdout.writeln('build id $buildId is in the symbols file');

  // Without --tool: `package:native_stack_traces` (a dev dependency, 0.7.1). The decoder `flutter symbolize` wraps
  // is 0.6.1 in Flutter 3.50 and fails on a 3.50 build's symbols with the header ("Cannot locate isolate
  // instructions section in snapshot", measured); 0.7.0 adjusted the readers to Dart 3.12+ snapshots.
  // With --tool: the worker's input, the stack from the first `#00` on.
  if (tool != null) {
    final m = RegExp(r'^(.*?)(\s*#00.*)', dotAll: true).firstMatch(stack);
    if (m != null) stack = m.group(2)!;
  }
  final process = await Process.start(
    tool ?? Platform.resolvedExecutable,
    tool != null
        ? [symbols]
        : ['run', 'native_stack_traces:decode', 'translate', '-d', symbols],
    // `dart run` resolves the package through the workspace of the working directory: the repository root.
    workingDirectory: tool != null
        ? null
        : File.fromUri(Platform.script).parent.parent.path,
  );
  process.stdin.write(stack);
  await process.stdin.close();
  final out = await process.stdout.transform(utf8.decoder).join();
  final err = await process.stderr.transform(utf8.decoder).join();
  stdout.write(out);
  final missing = [
    for (final name in expected)
      if (!out.contains(name)) name,
  ];
  if (await process.exitCode != 0 || missing.isNotEmpty) {
    stderr.writeln(
      'FAIL: missing from the symbolized stack: $missing${err.trim().isEmpty ? '' : '\ndecoder said: ${err.trim()}'}',
    );
    exit(1);
  }
  stdout.writeln('OK: ${expected.length} expected names symbolized');
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
