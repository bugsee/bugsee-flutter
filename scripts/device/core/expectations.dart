// What the build under test MUST be (workbook 9.1.1): the pins of native-versions.json, the wrapper
// identity of the package, and the toolchain that built it. A run that cannot show it tested THIS build
// proves nothing about it: a version string alone is not enough (a version range in a dependency graph
// can outrank a local snapshot of the same version, and both call themselves the same thing), so the
// check also takes the SDK's commit from its banner and the artefact set from the build.
import 'dart:convert';
import 'dart:io';

import 'log_parsers.dart';

/// The pins the harness holds the build to. Read from native-versions.json at run time, never repeated
/// here: that file is the single source (the drift guards in test/ read it too).
class Pins {
  Pins({
    required this.androidSdk,
    required this.androidSdkBuild,
    required this.gradlePlugin,
    required this.minSdk,
    required this.iosSdk,
    required this.iosSdkBuild,
    required this.iosSpmRevision,
    required this.iosFeedbackSpmRevision,
    required this.flutterMin,
    required this.dartMin,
  });

  factory Pins.fromJson(Map<String, Object?> json) {
    final android = json['android']! as Map<String, Object?>;
    final ios = json['ios']! as Map<String, Object?>;
    final flutter = json['flutter']! as Map<String, Object?>;
    return Pins(
      androidSdk: android['sdk']! as String,
      androidSdkBuild: android['sdkBuild']! as String,
      gradlePlugin: android['gradlePlugin']! as String,
      minSdk: android['minSdk']! as int,
      iosSdk: ios['sdk']! as String,
      iosSdkBuild: ios['sdkBuild']! as String,
      iosSpmRevision: ios['spmRevision']! as String,
      iosFeedbackSpmRevision: ios['feedbackSpmRevision']! as String,
      flutterMin: flutter['min']! as String,
      dartMin: flutter['dart']! as String,
    );
  }

  factory Pins.read(String repoRoot) => Pins.fromJson(
    jsonDecode(File('$repoRoot/native-versions.json').readAsStringSync())
        as Map<String, Object?>,
  );

  final String androidSdk;

  /// The commit the Android SDK's banner prints for [androidSdk] (`Bugsee Android SDK 7.4.2 [3b7af6371]`).
  final String androidSdkBuild;
  final String gradlePlugin;
  final int minSdk;
  final String iosSdk;

  /// The build the iOS SDK's banner prints for [iosSdk] (`Bugsee IOS SDK ver:7.0.0-beta7 build:...`).
  final String iosSdkBuild;

  /// The git revisions of bugsee/spm and bugsee/feedback-spm at [iosSdk]: what SwiftPM must resolve.
  final String iosSpmRevision;
  final String iosFeedbackSpmRevision;
  final String flutterMin;
  final String dartMin;
}

/// The wrapper identity the package declares and the toolchain it was built with.
class BuildExpectation {
  const BuildExpectation({
    required this.pins,
    required this.wrapperVersion,
    required this.flutterVersion,
    required this.dartVersion,
    required this.engineRevision,
    required this.mode,
  });

  final Pins pins;

  /// pubspec.yaml `version:`.
  final String wrapperVersion;
  final String flutterVersion;
  final String dartVersion;

  /// The engine's short revision (the first ten characters `flutter --version` prints).
  final String engineRevision;

  /// `debug`, `profile` or `release`: what the wrapper reports as `build-configuration`.
  final String mode;

  /// The wrapper identity that must reach the SDK and every report's `environment.sdk.wrapper`.
  Map<String, Object?> get wrapper => {
    'type': 'flutter',
    'version': wrapperVersion,
    'context': {
      'dart': dartVersion,
      'flutter': flutterVersion,
      'flutter-engine': engineRevision,
      'build-configuration': mode,
    },
  };

  /// Problems with an Android launch (empty = this is the build under test). Each is a reason the
  /// experiment is invalid, not a finding.
  List<String> androidProblems(SdkBanner? banner, WrapperLog wrapperLog) {
    final out = <String>[];
    if (banner == null) {
      out.add(
        'no Android SDK banner in the log: the SDK did not start, or the log was cut',
      );
    } else {
      if (banner.version != pins.androidSdk) {
        out.add('banner version ${banner.version}, pinned ${pins.androidSdk}');
      }
      if (banner.build != pins.androidSdkBuild) {
        out.add(
          'banner build ${banner.build}, pinned ${pins.androidSdkBuild}: the same version string can be a different build',
        );
      }
    }
    out.addAll(_wrapperProblems(wrapperLog));
    return out;
  }

  List<String> iosProblems(SdkBanner? banner, WrapperLog wrapperLog) {
    final out = <String>[];
    if (banner == null) {
      out.add(
        'no iOS SDK banner in the log: the SDK did not start, or the log was cut',
      );
    } else {
      if (banner.version != pins.iosSdk) {
        out.add('banner version ${banner.version}, pinned ${pins.iosSdk}');
      }
      if (banner.build != pins.iosSdkBuild) {
        out.add('banner build ${banner.build}, pinned ${pins.iosSdkBuild}');
      }
    }
    out.addAll(_wrapperProblems(wrapperLog));
    return out;
  }

  List<String> _wrapperProblems(WrapperLog log) {
    final out = <String>[];
    final want = 'flutter/$wrapperVersion';
    if (log.registered != want) {
      out.add('wrapper registered as ${log.registered}, expected $want');
    }
    if (log.refined != want) {
      out.add('wrapper refined as ${log.refined}, expected $want');
    }
    final context = (wrapper['context']! as Map).cast<String, String>();
    for (final e in context.entries) {
      if (log.context[e.key] != e.value) {
        out.add(
          'wrapper context ${e.key} is ${log.context[e.key]}, expected ${e.value}',
        );
      }
    }
    return out;
  }

  /// Problems with the identity a REPORT carries (`request.json` `environment.sdk.wrapper`).
  List<String> wrapperInReport(Object? sdkWrapper) {
    if (sdkWrapper is! Map) {
      return ['environment.sdk.wrapper is absent: $sdkWrapper'];
    }
    final out = <String>[];
    if (sdkWrapper['type'] != 'flutter') {
      out.add('wrapper type ${sdkWrapper['type']}');
    }
    if (sdkWrapper['version'] != wrapperVersion) {
      out.add(
        'wrapper version ${sdkWrapper['version']}, expected $wrapperVersion',
      );
    }
    final context = sdkWrapper['context'];
    final want = (wrapper['context']! as Map);
    if (context is! Map) {
      out.add('wrapper context absent');
    } else {
      for (final e in want.entries) {
        if (context[e.key] != e.value) {
          out.add(
            'wrapper context ${e.key} is ${context[e.key]}, expected ${e.value}',
          );
        }
      }
    }
    return out;
  }
}
