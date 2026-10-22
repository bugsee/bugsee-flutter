// The version of this package and the rule that decides which core versions it works with.
// Internal: not exported from package:bugsee_flutter_feedback.
//
// Policy (test/feedback_package_drift_test.dart in the repository root asserts every copy):
//  * `bugsee_flutter_feedback` and `bugsee_flutter` are released together with the SAME version;
//  * the feedback package depends on the core with `>=<that version> <next minor>`;
//  * the native pins (Android artifact versions, iOS SwiftPM exact versions) are the same in both
//    packages, because both read native-versions.json at release.

/// Must equal `version:` in pubspec.yaml.
const String feedbackVersion = '10.0.0-dev.1';

/// Whether a core `bugsee_flutter` at [core] can be used with a feedback package at [feedback]:
/// the same major and minor. A patch or pre-release difference is allowed (pub's constraint
/// already decided that at resolution; this is the second line, for a path or git dependency, a
/// dependency override, or a stale build).
///
/// A version that is not `major.minor.patch[-pre][+build]` is not compatible.
bool isCompatibleCore(String feedback, String core) {
  final a = _majorMinor(feedback);
  final b = _majorMinor(core);
  return a != null && b != null && a.$1 == b.$1 && a.$2 == b.$2;
}

(int, int)? _majorMinor(String version) {
  final m = RegExp(
    r'^(\d+)\.(\d+)\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
  ).firstMatch(version);
  if (m == null) return null;
  return (int.parse(m.group(1)!), int.parse(m.group(2)!));
}
