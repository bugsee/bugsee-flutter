// Pure parsers and verdicts of the end-to-end symbolication run (scripts/device/e2e_symbolication.dart).
// Each one decides something the run must not take on trust, and `test/device_harness_test.dart` shows
// each failing on the input it exists to refuse.
import 'dart:convert';

/// Replaces every secret in [text] with a marker. Everything the run prints or saves goes through this.
String redact(String text, Iterable<String> secrets) {
  var out = text;
  for (final s in secrets) {
    if (s.length >= 8) out = out.replaceAll(s, '<REDACTED>');
  }
  return out;
}

/// The `E2E|{json}` lines of a console that belong to [runId], in order. A line of another run (an
/// older build still installed, a replay) is dropped, never counted.
List<Map<String, Object?>> e2eEvents(String console, String runId) {
  final out = <Map<String, Object?>>[];
  for (final line in const LineSplitter().convert(console)) {
    final i = line.indexOf('E2E|');
    if (i < 0) continue;
    try {
      final v = jsonDecode(line.substring(i + 4));
      if (v is Map && v['run'] == runId) out.add(v.cast<String, Object?>());
    } on FormatException {
      // a truncated line
    }
  }
  return out;
}

/// What the pinned `symbols.py` did, read from `symbols_logged.py`'s output. `symbols.py` itself exits 0 when
/// the first request fails (it ignores a non-2xx answer), so the exit code proves nothing: the verdict needs the
/// POST (register) and the PUT (the zip to the presigned URL), both 2xx. Returns the problems; empty = uploaded.
List<String> symbolsUploadProblems(String output, int exitCode) {
  final problems = <String>[];
  final http = RegExp(
    r'^HTTP (\w+) (\S+) -> (\d{3})',
    multiLine: true,
  ).allMatches(output).toList();
  String? status(String method, {String? pathHas}) {
    for (final m in http) {
      if (m[1] == method && (pathHas == null || m[2]!.contains(pathHas))) {
        return m[3];
      }
    }
    return null;
  }

  final post = status('POST', pathHas: '/symbols');
  final put = status('PUT');
  if (exitCode != 0) problems.add('symbols.py exited $exitCode');
  if (post == null) {
    problems.add('no POST .../symbols was made (nothing was registered)');
  } else if (!post.startsWith('2')) {
    problems.add('POST .../symbols answered $post');
  }
  if (put == null) {
    problems.add(
      'no PUT of the zip was made (no presigned URL, or it was not used)',
    );
  } else if (!put.startsWith('2')) {
    problems.add('PUT of the zip answered $put');
  }
  if (output.contains('Failed to upload')) {
    problems.add('symbols.py said it failed to upload');
  }
  return problems;
}

/// The phases a device run must have gone through, from the app's events. Empty = the sequence is complete.
List<String> phaseProblems(
  List<Map<String, Object?>> events, {
  required String os,
  required bool release,
}) {
  final problems = <String>[];
  final starts = events.where((e) => e['kind'] == 'start').toList();
  final phases = starts.map((e) => e['phase']).toList();
  if (phases.join(',') != '0,1,2,3') {
    problems.add(
      'the app started phases [${phases.join(',')}], expected 0,1,2,3',
    );
  }
  for (final s in starts) {
    if (s['os'] != os) {
      problems.add('a start event says os ${s['os']}, expected $os');
    }
    if (release && s['mode'] != 'release') {
      problems.add('a start event says mode ${s['mode']}, expected release');
    }
  }
  final launches = events.where((e) => e['kind'] == 'launch').toList();
  if (launches.length != 4 || launches.any((e) => e['result'] != 'launched')) {
    problems.add(
      'launch results: ${launches.map((e) => e['result']).toList()}, expected 4 x launched',
    );
  }
  if (events.any((e) => e['kind'] == 'invalid')) {
    problems.add(
      'the app reported invalid: ${events.where((e) => e['kind'] == 'invalid').toList()}',
    );
  }
  final crashes = events.where((e) => e['kind'] == 'crashing').length;
  if (crashes != 2) {
    problems.add('the app announced $crashes crashes, expected 2');
  }
  if (!events.any((e) => e['kind'] == 'reported')) {
    problems.add('phase 0 never reported its Dart errors');
  }
  return problems;
}

/// The unique build string of a run: `9.MMDD.HHMM` (three integers, valid as an iOS short version and an
/// Android versionName), so two runs in different minutes never share a build, and a backend row is told apart.
String runIdFor(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '9.${two(now.month)}${two(now.day)}.${two(now.hour)}${two(now.minute)}';
}

/// A `.symbols` file's format by magic bytes: `elf` (Android), `macho` (iOS), or null.
String? symbolsFormat(List<int> head) {
  if (head.length < 4) return null;
  if (head[0] == 0x7f &&
      head[1] == 0x45 &&
      head[2] == 0x4c &&
      head[3] == 0x46) {
    return 'elf';
  }
  final m = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
  // MH_MAGIC_64 in either byte order, and the fat magic
  if (m == 0xfeedfacf || m == 0xcffaedfe || m == 0xcafebabe) return 'macho';
  return null;
}

/// What the backend's rendering of the run's reports must hold for the run to count as symbolicated.
/// [reports] are the texts of the crash reports found for the run's build. Returns the problems:
/// each expected readable name must appear, and the readable names must not be the only thing there
/// (an obfuscated build whose frames are still `_kDartSnapshotText+0x...` has failed, whatever else matches).
List<String> readbackProblems(
  List<String> reports, {
  required List<String> expectedDartNames,
  required List<String> expectedNativeNames,
}) {
  final problems = <String>[];
  if (reports.isEmpty) {
    return [
      'the backend returned no report for this build: nothing was verified',
    ];
  }
  final all = reports.join('\n');
  for (final n in [...expectedDartNames, ...expectedNativeNames]) {
    if (!all.contains(n)) {
      problems.add('"$n" is in none of the ${reports.length} report(s)');
    }
  }
  return problems;
}

/// Frames that are still raw addresses in a rendered report (a symbolication that did not happen).
List<String> rawFrameLines(String report) => [
  for (final l in const LineSplitter().convert(report))
    if (RegExp(
      r'_kDart(Isolate)?Snapshot(Text|Instructions)\+0x|^\s*#?\d+\s+abs\s+[0-9a-f]+\s+virt\s',
    ).hasMatch(l))
      l.trim(),
];
