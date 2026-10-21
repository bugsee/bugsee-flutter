// The wrapper identity, in one place on the Dart side. Not exported from
// package:bugsee_flutter; Phase 4 decides what is public.
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
