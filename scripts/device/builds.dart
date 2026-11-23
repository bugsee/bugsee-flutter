// The builds the scenarios use. One source (example/lib/verify_main.dart), several variants.
class BuildSpec {
  const BuildSpec(
    this.name,
    this.mode, {
    this.buildNumber = 1,
    this.obfuscate = false,
    this.defines = const [],
  });
  final String name;
  final String mode;
  final int buildNumber;
  final bool obfuscate;
  final List<String> defines;
}

/// `debug`: the debuggable build (run-as works). `releaseA`: R8, the Gradle plugin, `--obfuscate
/// --split-debug-info`, versionCode 1. `releaseB`: the same source with a different define (a different
/// Dart snapshot, so a different build id) and versionCode 2: "build N+1", and "another build's symbols".
/// `profile`: the profile mode.
const androidBuildSpecs = <BuildSpec>[
  BuildSpec('debug', 'debug'),
  BuildSpec('releaseA', 'release', obfuscate: true),
  BuildSpec(
    'releaseB',
    'release',
    buildNumber: 2,
    obfuscate: true,
    defines: ['VERIFY_VARIANT=b'],
  ),
  BuildSpec('profile', 'profile'),
];

/// The iOS simulator builds (debug only: the Flutter tool does not build release or profile for a
/// simulator). `debug`: build 1. `debugN2`: build 2 of the same source with a different define, "N+1" of
/// the update scenario.
const iosBuildSpecs = <BuildSpec>[
  BuildSpec('debug', 'debug'),
  BuildSpec('debugN2', 'debug', buildNumber: 2, defines: ['VERIFY_VARIANT=b']),
];
