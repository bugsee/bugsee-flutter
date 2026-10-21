// Fetches the two SDKs' published options manifests (bugsee/specs sdk/options) for the
// versions pinned in native-versions.json and vendors them verbatim under
// test/fixtures/option_manifests/{android,ios}.json.
//
//   dart scripts/sync_option_manifests.dart            # fetch and write
//   dart scripts/sync_option_manifests.dart --check    # fetch and fail if a committed copy differs
//
// Both SDKs publish one immutable manifest per release, generated from their live option
// registry (so it includes options registered with a null default, the extension modules
// and the hidden `$$` options, which a read of the source cannot see completely). The
// manifest is therefore the authority for keys, types, enum values and defaults; the
// source cross-check in scripts/verify_option_manifests.dart is an independent second read.
//
// Network access lives only in this script's `main`; everything else (the registry
// generator, the tests, the weekly-only CI step excepted) reads the committed copies, so
// the checks work offline. A published manifest never changes, so `--check` failing means
// the pin moved without a re-sync (or somebody edited a fixture), never that upstream drifted.
//
// Dart SDK only (dart:io): no `pub get`.
import 'dart:convert';
import 'dart:io';

/// The URL of the manifest for [sdk] (`android` / `ios`) at [version].
String manifestUrl(String template, String sdk, String version) =>
    template.replaceAll('{sdk}', sdk).replaceAll('{version}', version);

/// What a manifest fixture must say about itself for the pin it is vendored for. Returns
/// the problems (empty when fine). Pure: shared with the Dart tests.
List<String> manifestProblems(
  String text, {
  required String sdk,
  required String version,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    return ['not JSON: ${e.message}'];
  }
  if (decoded is! Map<String, dynamic>) return ['not a JSON object'];
  final problems = <String>[];
  if (decoded['manifestVersion'] != 1) {
    problems.add(
      'manifestVersion is ${decoded['manifestVersion']}, this tooling reads 1',
    );
  }
  if (decoded['sdk'] != sdk) {
    problems.add('sdk is ${decoded['sdk']}, expected $sdk');
  }
  if (decoded['sdkVersion'] != version) {
    problems.add(
      'sdkVersion is ${decoded['sdkVersion']}, the pin is $version '
      '(re-run scripts/sync_option_manifests.dart)',
    );
  }
  if (decoded['buildConfiguration'] != 'release') {
    problems.add('buildConfiguration is ${decoded['buildConfiguration']}');
  }
  final options = decoded['options'];
  if (options is! List || options.isEmpty) problems.add('no options');
  return problems;
}

Future<String> fetch(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

Future<void> main(List<String> args) async {
  final root = File.fromUri(Platform.script).parent.parent.path;
  final pins =
      jsonDecode(File('$root/native-versions.json').readAsStringSync())
          as Map<String, dynamic>;
  final config = pins['optionsManifest'] as Map<String, dynamic>;
  final check = args.contains('--check');
  var failed = false;
  for (final sdk in ['android', 'ios']) {
    final version = (pins[sdk] as Map<String, dynamic>)['sdk'] as String;
    final url = manifestUrl(config['urlTemplate'] as String, sdk, version);
    final path = '$root/${config['fixtureDir']}/$sdk.json';
    final String fetched;
    try {
      fetched = await fetch(url);
    } on Object catch (e) {
      stderr.writeln('$sdk: could not fetch $url: $e');
      failed = true;
      continue;
    }
    final problems = manifestProblems(fetched, sdk: sdk, version: version);
    if (problems.isNotEmpty) {
      stderr.writeln('$sdk: the published manifest is unusable: $problems');
      failed = true;
      continue;
    }
    final file = File(path);
    if (check) {
      if (!file.existsSync() || file.readAsStringSync() != fetched) {
        stderr.writeln('$sdk: $path differs from $url; re-run without --check');
        failed = true;
      } else {
        stdout.writeln('$sdk $version: manifest fixture matches $url');
      }
    } else {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(fetched);
      stdout.writeln('$sdk $version: wrote $path');
    }
  }
  if (failed) exit(1);
}
