// Pure parsers and verdicts of the end-to-end symbolication run (scripts/device/e2e_symbolication.dart).
// Each one decides something the run must not take on trust, and `test/device_harness_test.dart` shows
// each failing on the input it exists to refuse.
import 'dart:convert';

import 'log_parsers.dart';

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

/// The unique build string of a run: `9.YYMMDD.HHMMSS` (three integers, valid as an iOS short version and an
/// Android versionName). Two runs in different seconds, days or years never share a build, so a backend row is
/// told apart by its version; the runner also refuses a fresh run whose work directory (named by this id) exists.
String runIdFor(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '9.${two(now.year % 100)}${two(now.month)}${two(now.day)}.'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
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

/// A line of a rendered report that is a symbolicated FRAME: it carries a source position (`file.ext:line`).
/// A name in a summary, a log line or a message has none, so it never counts as evidence.
final _sourceFrame = RegExp(r'\.(dart|java|kt|swift|mm?|cc?|cpp):\d+');

bool _hasFrameWith(String report, String name) {
  for (final l in const LineSplitter().convert(report)) {
    if (l.contains(name) && _sourceFrame.hasMatch(l)) return true;
  }
  return false;
}

/// What the backend's rendering of the run's reports must hold for the run to count as symbolicated.
/// [reports] are the texts of the crash reports found for the run's build. Returns the problems:
/// * no report at all: nothing was verified;
/// * ANY raw frame line in ANY report (`_kDartSnapshotText+0x...`, a frame left as an address) fails the run,
///   whatever else matches;
/// * each expected Dart name must be in a symbolicated frame (a line with a source position), not just mentioned;
/// * each expected native frame ([expectedNativeFrames], a name or a source file such as `crash_lab.dart`) likewise,
///   and each in a report of its OWN (the native-signal report and the platform-language report are different
///   crashes; one report cannot stand for both).
List<String> readbackProblems(
  List<String> reports, {
  required List<String> expectedDartNames,
  required List<String> expectedNativeFrames,
}) {
  final problems = <String>[];
  if (reports.isEmpty) {
    return [
      'the backend returned no report for this build: nothing was verified',
    ];
  }
  for (var i = 0; i < reports.length; i++) {
    final raw = rawFrameLines(reports[i]);
    if (raw.isNotEmpty) {
      problems.add(
        'report ${i + 1} has ${raw.length} raw frame line(s), e.g. "${raw.first}"',
      );
    }
  }
  for (final n in expectedDartNames) {
    if (!reports.any((r) => _hasFrameWith(r, n))) {
      problems.add(
        '"$n" is in no symbolicated frame of the ${reports.length} report(s)',
      );
    }
  }
  // each native frame needs a report of its own: a small backtracking assignment
  final candidates = [
    for (final n in expectedNativeFrames)
      [
        for (var i = 0; i < reports.length; i++)
          if (_hasFrameWith(reports[i], n)) i,
      ],
  ];
  for (var k = 0; k < candidates.length; k++) {
    if (candidates[k].isEmpty) {
      problems.add(
        'native frame "${expectedNativeFrames[k]}" is in no symbolicated frame of the ${reports.length} report(s)',
      );
    }
  }
  if (candidates.every((c) => c.isNotEmpty)) {
    bool assign(int k, Set<int> used) {
      if (k == candidates.length) return true;
      for (final i in candidates[k]) {
        if (used.add(i)) {
          if (assign(k + 1, used)) return true;
          used.remove(i);
        }
      }
      return false;
    }

    if (!assign(0, {})) {
      problems.add(
        'the expected native frames ${expectedNativeFrames.join(', ')} are not in distinct reports (one crash per frame is expected)',
      );
    }
  }
  return problems;
}

/// Whether the poll may stop with a pass: the last two passes both found everything expected AND saw the same
/// number of reports. One good pass is not enough: the crash reports are the last uploaded and symbolicated, and a
/// raw one arriving after a clean pass would be missed.
bool readbackSettled(List<({bool ok, int reports})> passes) {
  if (passes.length < 2) return false;
  final a = passes[passes.length - 2];
  final b = passes.last;
  return a.ok && b.ok && a.reports == b.reports;
}

/// An unexpected failure as text for the log: the exception's message passed through [redact] (a
/// `ProcessException` prints its whole command line, which holds `-t <token>` and the server token).
String failureText(Object error, Iterable<String> secrets) =>
    redact('${error.runtimeType}: $error', secrets);

/// Frames that are still raw addresses in a rendered report (a symbolication that did not happen).
List<String> rawFrameLines(String report) => [
  for (final l in const LineSplitter().convert(report))
    if (RegExp(
      r'_kDart(Isolate)?Snapshot(Text|Instructions)\+0x|^\s*#?\d+\s+abs\s+[0-9a-f]+\s+virt\s',
    ).hasMatch(l))
      l.trim(),
];

/// What is wrong with how an iOS crash launch ended. [crash] is the app's own `crashing` kind (`ffi-segv`, or
/// `objc-main`), [console] the drained devicectl output, [exitCode] devicectl's. A `crashing` line alone proves
/// nothing: the launch could have been ended by anything else (a SIGTERM from the previous console child).
/// `ffi-segv` must have ended with `App terminated due to signal 11`. `objc-main` is an uncaught Objective-C
/// exception, which aborts (signal 6); devicectl may report no signal for it, then a non-zero exit is accepted
/// (measured once: exit 1), but any OTHER signal (15 above all) is a failure.
List<String> iosCrashExitProblems(String crash, String console, int exitCode) {
  final signal = parseTerminatedSignal(console);
  switch (crash) {
    case 'ffi-segv':
      return signal == 11
          ? const []
          : ['ffi-segv ended with ${signal == null ? 'no signal line' : 'signal $signal'}, expected signal 11'];
    case 'objc-main':
      if (signal == 6) return const [];
      if (signal == null && exitCode != 0) return const [];
      return [
        'objc-main ended with ${signal == null ? 'no signal line and devicectl exit 0' : 'signal $signal'}, expected signal 6 (or a non-zero exit without a signal)',
      ];
  }
  return ['unknown crash kind $crash'];
}

/// Whether the app process [pid] is gone, from one `adb shell pidof <package>` answer; `null` when the answer
/// proves nothing (an adb failure: a disconnect, `device offline`, anything on stderr). Only a successful `pidof`
/// that does not list [pid], or its documented "no process" answer (exit 1, nothing at all printed), is "gone".
bool? androidPidGone({
  required int code,
  required String stdout,
  required String stderr,
  required int pid,
}) {
  if (code == 0) {
    return !stdout.trim().split(RegExp(r'\s+')).contains('$pid');
  }
  if (code == 1 && stdout.trim().isEmpty && stderr.trim().isEmpty) return true;
  return null;
}

/// What is wrong with the evidence that process [pid] died of the crash [crash] (`ffi-segv` or `java-main`), from
/// a full `logcat -d`: the kernel/debuggerd line `Fatal signal 11` for THAT pid, or the Java `FATAL EXCEPTION`
/// naming `verify-java-main` for it. A process that merely vanished is not a crash.
List<String> androidCrashProblems(String crash, String logcat, int pid) {
  switch (crash) {
    case 'ffi-segv':
      final f = parseFatalSignal(logcat, pid);
      return f?.number == 11
          ? const []
          : [
              'no "Fatal signal 11" for pid $pid in logcat (${f == null ? 'none' : 'signal ${f.number}'})',
            ];
    case 'java-main':
      return parseFatalException(logcat, pid, 'verify-java-main')
          ? const []
          : ['no FATAL EXCEPTION naming verify-java-main for pid $pid in logcat'];
  }
  return ['unknown crash kind $crash'];
}
