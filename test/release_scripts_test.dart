// The two scripts of the release workflow (.github/workflows/release.yml), run for real:
// scripts/check_release.sh (tag == pubspecs == CHANGELOG tops) and scripts/pub_dev_status.sh
// (is a version live on pub.dev), the latter against a local server so nothing reaches pub.dev.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String pubspecVersion() => RegExp(
  r'^version:[ \t]*(\S+)',
  multiLine: true,
).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1)!;

void main() {
  group('check_release.sh', () {
    ProcessResult run(String tag, {String root = '.'}) =>
        Process.runSync('bash', ['$root/scripts/check_release.sh', tag]);

    test('the current tree is releasable under its own version', () {
      final r = run('v${pubspecVersion()}');
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect('${r.stdout}'.trim(), pubspecVersion());
    });

    test('a tag that is not v<semver> is refused', () {
      for (final tag in [
        '10.0.0',
        'v10.0',
        'v10.0.0.1',
        'v10.0.0 ',
        'vX',
        '',
      ]) {
        expect(run(tag).exitCode, isNot(0), reason: "'$tag'");
      }
    });

    test('a tag that names another version is refused, naming each copy', () {
      final r = run('v99.0.0');
      expect(r.exitCode, 1);
      final err = '${r.stderr}';
      for (final what in [
        'pubspec.yaml version',
        'packages/bugsee_flutter_feedback/pubspec.yaml version',
        'CHANGELOG.md top entry',
        'packages/bugsee_flutter_feedback/CHANGELOG.md top entry',
      ]) {
        expect(err, contains(what));
      }
    });

    test('each copy alone is enough to refuse', () {
      final tmp = Directory.systemTemp.createTempSync('rel');
      addTearDown(() => tmp.deleteSync(recursive: true));
      Directory('${tmp.path}/scripts').createSync();
      Directory('${tmp.path}/packages/bugsee_flutter_feedback')
          .createSync(recursive: true);
      File('scripts/check_release.sh')
          .copySync('${tmp.path}/scripts/check_release.sh');
      void lay(Map<String, String> v) {
        File('${tmp.path}/pubspec.yaml')
            .writeAsStringSync('name: a\nversion: ${v['p']}\n');
        File('${tmp.path}/packages/bugsee_flutter_feedback/pubspec.yaml')
            .writeAsStringSync('name: b\nversion: ${v['fp']}\n');
        File('${tmp.path}/CHANGELOG.md')
            .writeAsStringSync('## ${v['c']}\n\ntext\n## 1.0.0\n');
        File('${tmp.path}/packages/bugsee_flutter_feedback/CHANGELOG.md')
            .writeAsStringSync('## ${v['fc']}\n');
      }

      lay({'p': '1.2.3', 'fp': '1.2.3', 'c': '1.2.3', 'fc': '1.2.3'});
      expect(run('v1.2.3', root: tmp.path).exitCode, 0);
      for (final k in ['p', 'fp', 'c', 'fc']) {
        final v = {'p': '1.2.3', 'fp': '1.2.3', 'c': '1.2.3', 'fc': '1.2.3'};
        v[k] = '1.2.4';
        lay(v);
        final r = run('v1.2.3', root: tmp.path);
        expect(r.exitCode, 1, reason: k);
        expect('${r.stderr}', contains("'1.2.4'"), reason: k);
      }
    });
  });

  group('pub_dev_status.sh', () {
    late HttpServer server;
    late String api;
    // path -> status code; anything else is 404, '/boom' paths are 500.
    final known = <String, int>{
      '/api/packages/core': 200,
      '/api/packages/core/versions/1.0.0': 200,
      '/api/packages/err': 500,
      '/api/packages/err/versions/1.0.0': 500,
    };

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      api = 'http://127.0.0.1:${server.port}';
      server.listen((req) {
        req.response.statusCode = known[req.uri.path] ?? 404;
        req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    Future<ProcessResult> run(List<String> args) => Process.run(
      'bash',
      ['scripts/pub_dev_status.sh', ...args],
      environment: {'PUB_DEV_API': api},
    );

    test('live, missing version, missing package', () async {
      expect(
        '${(await run(['status', 'core', '1.0.0'])).stdout}'.trim(),
        'live',
      );
      expect(
        '${(await run(['status', 'core', '2.0.0'])).stdout}'.trim(),
        'missing-version',
      );
      expect(
        '${(await run(['status', 'nope', '1.0.0'])).stdout}'.trim(),
        'missing-package',
      );
    });

    test('a server error is an error, never "not there" (a flaky answer must not skip a publish)', () async {
      final r = await run(['status', 'err', '1.0.0']);
      expect(r.exitCode, 2);
      expect('${r.stdout}'.trim(), isEmpty);
    });

    test('an unreachable server is an error too', () async {
      await server.close(force: true);
      final r = await run(['status', 'core', '1.0.0']);
      expect(r.exitCode, 2);
      server = await HttpServer.bind('127.0.0.1', 0);
    });

    test('wait returns when live and times out when not', () async {
      expect((await run(['wait', 'core', '1.0.0', '5', '1'])).exitCode, 0);
      final r = await run(['wait', 'core', '2.0.0', '2', '1']);
      expect(r.exitCode, 1);
      expect('${r.stderr}', contains('not live on pub.dev after 2s'));
    });

    test('a bad command is a usage error', () async {
      expect((await run(['frobnicate'])).exitCode, 64);
    });
  });

  // scripts/pana_check.sh judges pana's JSON per section: every section full, except the dependencies section,
  // which may lose its allowance (default 10). PANA_REPORT_JSON feeds it a report instead of running pana.
  group('pana_check.sh', () {
    final jqOk = () {
      try {
        return Process.runSync('jq', ['--version']).exitCode == 0;
      } on ProcessException {
        return false;
      }
    }();

    ProcessResult judge(
      Map<String, int> lost, {
      Map<String, String> env = const {},
    }) {
      const max = {
        'Follow Dart file conventions': 30,
        'Provide documentation': 20,
        'Platform support': 20,
        'Pass static analysis': 50,
        'Support up-to-date dependencies': 40,
      };
      final sections = [
        for (final e in max.entries)
          {
            'title': e.key,
            'maxPoints': e.value,
            'grantedPoints': e.value - (lost[e.key] ?? 0),
            'summary': 'details of ${e.key}',
          },
      ];
      final dir = Directory.systemTemp.createTempSync('pana');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/report.json')
        ..writeAsStringSync(
          jsonEncode({
            'scores': {
              'grantedPoints': sections.fold<int>(
                0,
                (a, s) => a + (s['grantedPoints'] as int),
              ),
              'maxPoints': 140,
            },
            'report': {'sections': sections},
          }),
        );
      return Process.runSync(
        'bash',
        ['scripts/pana_check.sh'],
        environment: {'PANA_REPORT_JSON': f.path, ...env},
      );
    }

    test('a full score passes', () {
      if (!jqOk) return markTestSkipped('jq is not installed');
      expect(judge({}).exitCode, 0);
    });

    test('the dependencies section may lose up to its allowance', () {
      if (!jqOk) return markTestSkipped('jq is not installed');
      expect(judge({'Support up-to-date dependencies': 10}).exitCode, 0);
      final r = judge({'Support up-to-date dependencies': 20});
      expect(r.exitCode, 1);
      expect('${r.stderr}', contains('Support up-to-date dependencies'));
      // the allowance is configurable
      expect(
        judge(
          {'Support up-to-date dependencies': 20},
          env: {'PANA_DEPENDENCY_ALLOWANCE': '20'},
        ).exitCode,
        0,
      );
    });

    test('a loss in any other section fails, however small and whatever dependencies scored', () {
      if (!jqOk) return markTestSkipped('jq is not installed');
      for (final section in [
        'Follow Dart file conventions',
        'Provide documentation',
        'Platform support',
        'Pass static analysis',
      ]) {
        // headroom in dependencies must not hide it (a single total would)
        final r = judge({section: 1});
        expect(r.exitCode, 1, reason: section);
        expect('${r.stderr}', contains('details of $section'));
        expect(
          judge({section: 1, 'Support up-to-date dependencies': 10}).exitCode,
          1,
          reason: section,
        );
      }
    });

    test('a bad allowance or a report without sections is an error', () {
      if (!jqOk) return markTestSkipped('jq is not installed');
      expect(judge({}, env: {'PANA_DEPENDENCY_ALLOWANCE': 'ten'}).exitCode, 2);
      final dir = Directory.systemTemp.createTempSync('pana');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/r.json')..writeAsStringSync('{"report":{}}');
      expect(
        Process.runSync(
          'bash',
          ['scripts/pana_check.sh'],
          environment: {'PANA_REPORT_JSON': f.path},
        ).exitCode,
        2,
      );
    });

    test('pana and what it resolves are pinned by a committed lock file', () {
      expect(File('tools/pana/pubspec.lock').existsSync(), isTrue);
      expect(
        File('tools/pana/pubspec.yaml').readAsStringSync(),
        contains(RegExp(r'^  pana: \d+\.\d+\.\d+$', multiLine: true)),
        reason: 'an exact version, not a range',
      );
      final script = File('scripts/pana_check.sh').readAsStringSync();
      expect(script, contains('dart pub get --enforce-lockfile'));
      expect(script, isNot(contains('pub global activate')));
    });
  });
}
