// The wrapper identity on iOS. A SwiftPM manifest cannot read pubspec.yaml, so
// the version is a committed literal; test/wrapper_identity_test.dart fails if
// it drifts from `version:` in pubspec.yaml or from lib/src/wrapper_identity.dart.
enum WrapperIdentity {
  /// The backend's identifier for this wrapper (Dart: `wrapperType`).
  static let type = "flutter"

  /// Must equal `version:` in pubspec.yaml (Dart: `wrapperVersion`).
  static let version = "10.0.0-dev.1"
}
