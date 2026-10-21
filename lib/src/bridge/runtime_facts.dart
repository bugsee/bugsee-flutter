// The wrapper identity once the Dart runtime is up (workbook 2.4.2).
// Internal: not exported from package:bugsee_flutter.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FlutterVersion;

import '../wrapper_identity.dart';

/// Reported when a fact is missing, rather than an empty string that reads as
/// "this wrapper has no version" (3.3).
const String unknownFact = 'unknown';

/// How the app was compiled.
enum BuildMode {
  debug,
  profile,
  release;

  static BuildMode get current => kReleaseMode
      ? release
      : kProfileMode
      ? profile
      : debug;
}

/// What only the Dart runtime can know. Every field may be missing:
/// `FlutterVersion` is filled in by the Flutter tool at build time and is absent
/// for a custom embedder or a fork.
final class RuntimeFacts {
  const RuntimeFacts({
    this.flutterVersion,
    this.dartVersion,
    this.engineRevision,
    required this.buildMode,
  });

  /// Read from the running app.
  factory RuntimeFacts.current() => RuntimeFacts(
    flutterVersion: FlutterVersion.version,
    // `Platform.version` is "3.11.0 (stable) (...) on "macos_arm64"".
    dartVersion:
        FlutterVersion.dartVersion ?? Platform.version.split(' ').first,
    engineRevision: FlutterVersion.engineRevision,
    buildMode: BuildMode.current,
  );

  final String? flutterVersion;
  final String? dartVersion;
  final String? engineRevision;
  final BuildMode buildMode;
}

/// The identity sent to native: the same type and version the placeholder was
/// registered with, plus the runtime facts as a string-to-string context.
final class WrapperIdentity {
  const WrapperIdentity({
    required this.type,
    required this.version,
    this.build,
    required this.context,
  });

  factory WrapperIdentity.from(RuntimeFacts facts, {String? build}) =>
      WrapperIdentity(
        type: wrapperType,
        version: wrapperVersion,
        build: build,
        context: {
          'flutter': _orUnknown(facts.flutterVersion),
          'dart': _orUnknown(facts.dartVersion),
          'flutter-engine': _orUnknown(facts.engineRevision),
          'build-configuration': facts.buildMode.name,
        },
      );

  final String type;
  final String version;
  final String? build;
  final Map<String, String> context;

  static String _orUnknown(String? v) =>
      v == null || v.isEmpty ? unknownFact : v;
}
