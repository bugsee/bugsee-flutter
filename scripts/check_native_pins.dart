// Verifies that the native versions pinned in native-versions.json still exist
// upstream. Network access lives only in main(); the decision logic is pure and
// covered by test/check_native_pins_test.dart.
//
// Run: dart scripts/check_native_pins.dart   (no pub get needed, no secrets)
// Exit 1 when a pin is gone or a source is unreachable; a newer Android 7.x
// release is only reported.
import 'dart:convert';
import 'dart:io';

const mavenCentral = 'https://repo1.maven.org/maven2/com/bugsee';
const gradlePluginMetadata =
    'https://plugins.gradle.org/m2/com/bugsee/android/gradle/'
    'com.bugsee.android.gradle.gradle.plugin/maven-metadata.xml';

/// Versions listed in a Maven `maven-metadata.xml`.
List<String> parseMavenVersions(String xml) => RegExp(
  r'<version>([^<]+)</version>',
).allMatches(xml).map((m) => m.group(1)!.trim()).toList();

/// Tag names from `git ls-remote --tags` output (peeled `^{}` entries folded in).
Set<String> parseLsRemoteTags(String output) {
  final tags = <String>{};
  for (final line in output.split('\n')) {
    final m = RegExp(
      r'\trefs/tags/(\S+?)(\^\{\})?$',
    ).firstMatch(line.trimRight());
    if (m != null) tags.add(m.group(1)!);
  }
  return tags;
}

/// Parses `7.4.2` into [7, 4, 2]; null for anything with a qualifier
/// (`7.0.0-beta7`) or that is not purely numeric.
List<int>? stableParts(String v) {
  if (!RegExp(r'^\d+(\.\d+)*$').hasMatch(v)) return null;
  return v.split('.').map(int.parse).toList();
}

int compareParts(List<int> a, List<int> b) {
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Stable releases in the same major line as [pinned] that are newer than it,
/// oldest first. Empty when [pinned] is not a stable version.
List<String> newerSameMajor(String pinned, Iterable<String> available) {
  final pin = stableParts(pinned);
  if (pin == null) return [];
  final newer = <String>[
    for (final v in available)
      if (stableParts(v) case final p?
          when p.first == pin.first && compareParts(p, pin) > 0)
        v,
  ];
  newer.sort((a, b) => compareParts(stableParts(a)!, stableParts(b)!));
  return newer;
}

class PinReport {
  final errors = <String>[];
  final notes = <String>[];
  bool get ok => errors.isEmpty;
}

/// Pure decision logic: [pins] is native-versions.json; the rest is what the
/// network said. Missing pins are errors; newer releases are notes.
PinReport evaluate(
  Map<String, dynamic> pins, {
  required Iterable<String> androidSdk,
  required Iterable<String> androidNdk,
  required Iterable<String> gradlePlugin,
  required Iterable<String> spmTags,
  required Iterable<String> feedbackSpmTags,
}) {
  final android = pins['android'] as Map<String, dynamic>;
  final ios = pins['ios'] as Map<String, dynamic>;
  final sdk = android['sdk'] as String;
  final plugin = android['gradlePlugin'] as String;
  final tag = ios['sdk'] as String;
  final r = PinReport();

  void require(String what, String version, Iterable<String> available) {
    if (available.contains(version)) {
      r.notes.add('ok: $what $version exists');
    } else {
      r.errors.add('MISSING: $what $version is pinned but not published');
    }
  }

  require('com.bugsee:bugsee-android', sdk, androidSdk);
  require('com.bugsee:bugsee-android-ndk', sdk, androidNdk);
  require('com.bugsee.android.gradle plugin', plugin, gradlePlugin);
  require('${ios['spmUrl']} tag', tag, spmTags);
  require('${ios['feedbackSpmUrl']} tag', tag, feedbackSpmTags);

  final newer = newerSameMajor(sdk, androidSdk);
  if (newer.isNotEmpty) {
    r.notes.add(
      'NEWER: Android ${newer.join(', ')} available (pinned $sdk); '
      'bump native-versions.json deliberately',
    );
  }
  return r;
}

class _Permanent implements Exception {
  _Permanent(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<String> _get(String url) async {
  Object? last;
  for (var attempt = 1; attempt <= 3; attempt++) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      // One timeout over request, headers and body, so a stalled body is retried.
      final (status, body) = await () async {
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close();
        return (res.statusCode, await utf8.decodeStream(res));
      }().timeout(const Duration(seconds: 60));
      if (status == 200) return body;
      // A missing metadata file will not appear by retrying.
      if (status == 404) throw _Permanent('GET $url: HTTP 404');
      last = 'HTTP $status';
    } on _Permanent {
      rethrow;
    } catch (e) {
      last = e;
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(Duration(seconds: 2 * attempt));
  }
  throw Exception('GET $url failed: $last');
}

Future<Set<String>> _tags(String url) async {
  final res = await Process.run(
    'git',
    ['ls-remote', '--tags', url],
    environment: {'GIT_TERMINAL_PROMPT': '0'},
  );
  if (res.exitCode != 0) {
    throw Exception('git ls-remote $url failed: ${res.stderr}');
  }
  return parseLsRemoteTags(res.stdout as String);
}

/// `exit` does not flush; output piped to a log could otherwise be lost.
Future<Never> _exit(int code) async {
  await stdout.flush();
  await stderr.flush();
  exit(code);
}

Future<void> main(List<String> args) async {
  final PinReport report;
  try {
    final pins =
        jsonDecode(
              File(
                args.isNotEmpty ? args.first : 'native-versions.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final ios = pins['ios'] as Map<String, dynamic>;
    report = evaluate(
      pins,
      androidSdk: parseMavenVersions(
        await _get('$mavenCentral/bugsee-android/maven-metadata.xml'),
      ),
      androidNdk: parseMavenVersions(
        await _get('$mavenCentral/bugsee-android-ndk/maven-metadata.xml'),
      ),
      gradlePlugin: parseMavenVersions(await _get(gradlePluginMetadata)),
      spmTags: await _tags(ios['spmUrl'] as String),
      feedbackSpmTags: await _tags(ios['feedbackSpmUrl'] as String),
    );
  } catch (e) {
    stdout.writeln('ERROR: could not verify pins: $e');
    await _exit(1);
  }
  report.notes.forEach(stdout.writeln);
  report.errors.forEach(stdout.writeln);
  await _exit(report.ok ? 0 : 1);
}
