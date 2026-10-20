// Regenerates the Dart <-> native bridge from pigeons/bridge.dart, or with
// --check verifies the committed outputs are current without leaving changes.
//
// Run: dart scripts/generate_pigeon.dart [--check]   (needs network for pub get)
//
// Pigeon is pinned in native-versions.json (`pigeon.version`) and in
// pigeons/pubspec.yaml; test/native_versions_test.dart compares both. It lives
// in its own pure-Dart package because pigeon needs a newer `meta` than the
// Flutter floor (3.41.0) ships, so it cannot be a dev_dependency of the plugin.
// The generated Dart is then formatted with the `dart` on PATH, so run this on
// the floor Dart (CI does) or the result differs from what CI expects.
import 'dart:convert';
import 'dart:io';

/// The files pigeons/bridge.dart writes, relative to `pigeons/`, read from the
/// definition itself so the list cannot drift from it.
List<String> outputsOf(String definition) => [
  for (final m in RegExp(
    r"^\s*(?:dart|java|swift)Out:\s*'([^']+)'",
    multiLine: true,
  ).allMatches(definition))
    m.group(1)!,
];

Future<void> run(
  String exe,
  List<String> args, {
  required String workingDirectory,
}) async {
  final r = await Process.run(exe, args, workingDirectory: workingDirectory);
  stdout.write(r.stdout);
  stderr.write(r.stderr);
  if (r.exitCode != 0) {
    stderr.writeln('`$exe ${args.join(' ')}` failed (${r.exitCode})');
    exit(r.exitCode);
  }
}

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  final root = File.fromUri(Platform.script).parent.parent.path;
  final pigeons = '$root/pigeons';

  final pinned =
      (jsonDecode(File('$root/native-versions.json').readAsStringSync())
              as Map)['pigeon']['version']
          as String;
  final pubspec = File('$pigeons/pubspec.yaml').readAsStringSync();
  if (!RegExp('^  pigeon: $pinned\$', multiLine: true).hasMatch(pubspec)) {
    stderr.writeln('pigeons/pubspec.yaml does not pin pigeon $pinned');
    exit(1);
  }

  final outputs = outputsOf(
    File('$pigeons/bridge.dart').readAsStringSync(),
  ).map((p) => File('$pigeons/$p')).toList();
  if (outputs.length != 3) {
    stderr.writeln(
      'expected 3 outputs in bridge.dart, found ${outputs.length}',
    );
    exit(1);
  }
  final before = [
    for (final f in outputs) f.existsSync() ? f.readAsBytesSync() : null,
  ];

  await run('dart', [
    'pub',
    'get',
    '--enforce-lockfile',
  ], workingDirectory: pigeons);
  await run('dart', [
    'run',
    'pigeon',
    '--input',
    'bridge.dart',
  ], workingDirectory: pigeons);
  // Pigeon's Dart output is not dart-formatted; the repo's format gate covers lib/.
  await run('dart', ['format', outputs.first.path], workingDirectory: pigeons);

  if (!check) return;
  var stale = false;
  for (var i = 0; i < outputs.length; i++) {
    final now = outputs[i].readAsBytesSync();
    final was = before[i];
    final same = was != null && was.length == now.length && _equal(was, now);
    if (!same) {
      stale = true;
      stderr.writeln('stale generated file: ${outputs[i].path}');
    }
    // --check leaves the tree as it found it.
    if (was != null) outputs[i].writeAsBytesSync(was);
  }
  if (stale) {
    stderr.writeln('Run `dart scripts/generate_pigeon.dart` and commit.');
    exit(1);
  }
  stdout.writeln('generated bridge files are current');
}

bool _equal(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
