// The bookkeeping of a verification run, and the guards workbook 9.1 asks to be DEFAULTS: every scenario
// is run through a [Scenario] that cannot reach its first measurement before the build, the launch, the
// staged precondition and the observed event have been asserted. A guard that is not the default is one
// you forget exactly when you are moving fast.
import 'dart:convert';

enum Status { pass, fail, invalid, notPossible, notCovered }

/// One asserted fact, with the evidence it was read from.
class Check {
  Check(this.name, this.ok, this.evidence, {this.guard = false});
  final String name;
  final bool ok;
  final String evidence;

  /// A 9.1 guard (about the experiment) rather than a result (about the product).
  final bool guard;

  Map<String, Object?> toJson() => {
    'name': name,
    'ok': ok,
    'guard': guard,
    'evidence': evidence,
  };
}

/// An experiment that did not measure what it claims to (9.1): the product is not condemned by it.
class InvalidExperiment implements Exception {
  InvalidExperiment(this.guard, this.problems);
  final String guard;
  final List<String> problems;

  @override
  String toString() => 'invalid experiment ($guard): ${problems.join('; ')}';
}

class ScenarioResult {
  ScenarioResult(this.id, this.title);
  final int id;
  final String title;
  final List<Check> checks = [];
  final List<String> notes = [];
  Status status = Status.pass;
  String? reason;

  /// What a run of this scenario did not cover.
  final List<String> notCovered = [];

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'status': status.name,
    if (reason != null) 'reason': reason,
    'checks': [for (final c in checks) c.toJson()],
    'notes': notes,
    'notCovered': notCovered,
  };

  String get summaryLine {
    final failed = checks.where((c) => !c.ok).length;
    return '${status.name.toUpperCase().padRight(12)} #$id $title'
        ' (${checks.length - failed}/${checks.length} checks${reason == null ? '' : '; $reason'})';
  }
}

/// What a scenario sees while it runs. Everything it asserts is recorded and printed with its
/// evidence; a failed guard stops the scenario as [InvalidExperiment] instead of letting it conclude.
class Run {
  Run(this.result, this.say);
  final ScenarioResult result;
  final void Function(String) say;

  /// A result: [ok] is the product's behaviour.
  bool expect(String name, bool ok, String evidence) {
    result.checks.add(Check(name, ok, evidence));
    say(
      '  ${ok ? 'ok  ' : 'FAIL'} $name${evidence.isEmpty ? '' : ' -- $evidence'}',
    );
    return ok;
  }

  /// A guard (9.1): about the experiment. A failure ends the scenario as invalid.
  void guard(String guardName, List<String> problems, String evidence) {
    final ok = problems.isEmpty;
    result.checks.add(
      Check(
        '[9.1] $guardName',
        ok,
        ok ? evidence : problems.join('; '),
        guard: true,
      ),
    );
    say(
      '  ${ok ? 'ok  ' : 'INVALID'} [9.1] $guardName -- ${ok ? evidence : problems.join('; ')}',
    );
    if (!ok) throw InvalidExperiment(guardName, problems);
  }

  /// A measured number or observation that is not pass/fail.
  void note(String line) {
    result.notes.add(line);
    say('  note $line');
  }
}

/// Runs [body] as scenario [id]: catches an invalid experiment, a thrown error (a failure of the
/// harness is a failure, never a silent pass) and turns the checks into the status.
Future<ScenarioResult> runScenario(
  int id,
  String title,
  void Function(String) say,
  Future<void> Function(Run run) body,
) async {
  final result = ScenarioResult(id, title);
  say('== scenario $id: $title');
  try {
    await body(Run(result, say));
    result.status = result.checks.any((c) => !c.ok) ? Status.fail : Status.pass;
    if (result.checks.isEmpty) {
      result.status = Status.fail;
      result.reason = 'the scenario asserted nothing';
    }
  } on InvalidExperiment catch (e) {
    result.status = Status.invalid;
    result.reason = e.toString();
  } on NotPossible catch (e) {
    // What was measured on the way (the positive controls, the measured cause) still counts: a failed
    // check is a failure, not a "not possible".
    result.status = result.checks.any((c) => !c.ok)
        ? Status.fail
        : Status.notPossible;
    result.reason = e.reason;
  } on Object catch (e, s) {
    result.status = Status.fail;
    result.reason = 'harness error: $e';
    result.notes.add('$s'.split('\n').take(6).join(' | '));
  }
  say(result.summaryLine);
  return result;
}

/// A scenario the platform, simulator or toolchain cannot do, with the reason.
class NotPossible implements Exception {
  NotPossible(this.reason);
  final String reason;
}

String prettyJson(Object? o) => const JsonEncoder.withIndent('  ').convert(o);
