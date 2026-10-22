// Collects the scenario results of one run, prints them, writes `<work>/report-<platform>.json` and
// decides the exit code. The report is what doc/verification.md quotes.
import 'dart:io';

import 'core/experiment.dart';

class Reporter {
  Reporter(
    this.platform,
    this.workDir,
    this.environment, {
    this.tag = '',
    this.allowNotPossible = false,
  }) : started = DateTime.now();
  final String platform;

  /// Appended to the report file names: a run of some scenarios must not overwrite the full run's.
  final String tag;

  /// Without this a NOT POSSIBLE scenario makes the run exit 2: a skipped run must not read as a pass.
  final bool allowNotPossible;
  final String workDir;
  final Map<String, String> environment;
  final DateTime started;
  final List<ScenarioResult> results = [];
  final StringBuffer _log = StringBuffer();

  void say(String line) {
    stdout.writeln(line);
    _log.writeln(line);
  }

  void add(ScenarioResult r) => results.add(r);

  /// Prints the summary; 0 when every scenario passed (or is a recorded KNOWN-GAP, or NOT POSSIBLE with
  /// `allowNotPossible`), 1 when one failed or was invalid, 2 when one was NOT POSSIBLE.
  int finish() {
    say('');
    say(
      '==== $platform: summary (${DateTime.now().difference(started).inMinutes} min)',
    );
    for (final r in results) {
      say(r.summaryLine);
      for (final c in r.checks.where((c) => !c.ok)) {
        say('     FAILED: ${c.name} -- ${c.evidence}');
      }
    }
    File('$workDir/report-$platform$tag.json').writeAsStringSync(
      prettyJson({
        'platform': platform,
        'started': started.toIso8601String(),
        'environment': environment,
        'scenarios': [for (final r in results) r.toJson()],
      }),
    );
    File(
      '$workDir/report-$platform$tag.log',
    ).writeAsStringSync(_log.toString());
    final bad = results.any(
      (r) => r.status == Status.fail || r.status == Status.invalid,
    );
    if (bad) return 1;
    final skipped = results.any((r) => r.status == Status.notPossible);
    if (skipped && !allowNotPossible) {
      say(
        'exit 2: scenarios were NOT POSSIBLE here (pass --allow-not-possible if that is expected, e.g. the iOS simulator)',
      );
      return 2;
    }
    return 0;
  }
}
