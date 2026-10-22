// The wrapper identity, in one place on the Dart side. Only `bugseeFlutterVersion` is public (the
// feedback package reads it to check it was released with this core).
//
// Both values are also repeated natively, because the native side registers
// the wrapper before any Dart exists (workbook 2.4): Android in
// FlutterWrapper.java (type) and build.gradle (version, read from pubspec.yaml),
// iOS in BGSFlutterWrapper.m. test/wrapper_identity_test.dart compares every
// copy; two spellings would register two different wrappers depending on how
// far start-up got.

/// The backend's identifier for this wrapper (worker `BugseeFrameworkType.FLUTTER`,
/// and what the 9.x Flutter plugin already sent as `'type'`).
const String wrapperType = 'flutter';

/// Must equal `version:` in pubspec.yaml.
const String wrapperVersion = '10.0.0-dev.1';

/// The version of this package (the same string as `version:` in its pubspec).
///
/// Public so that the add-on packages released with it (`bugsee_flutter_feedback`) can check, at
/// run time, that the core they run against is the version they were released with, without
/// reaching into `lib/src`.
const String bugseeFlutterVersion = wrapperVersion;
