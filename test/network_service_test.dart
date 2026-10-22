// Install, uninstall and the policy of the capture, against fakes for everything native.
import 'dart:async';
import 'dart:io';

import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/network/http_capture.dart';
import 'package:bugsee_flutter/src/network/network_policy.dart';
import 'package:bugsee_flutter/src/network/network_service.dart';
import 'package:bugsee_flutter/src/status.dart';
import 'package:bugsee_flutter/src/errors.dart';
import 'package:bugsee_flutter/src/launch.dart' show BugseeException;
import 'package:bugsee_flutter/src/network/network_event.dart';
import 'package:flutter_test/flutter_test.dart';

class Rig {
  Rig({this.supported = true}) {
    service = NetworkCaptureService(
      send: (batch) async {
        sent.addAll(batch);
        return batch.length;
      },
      loadPolicy: () async {
        loads++;
        // What the SDK said when it was asked, however long the answer takes to arrive.
        final answer = policy;
        final gate = loadGate;
        if (gate != null) await gate.future;
        if (loadThrows) throw StateError('cannot read');
        return answer;
      },
      ensureAttached: () => attaches++,
      statuses: () => statuses.stream,
      supported: () => supported,
      warn: warnings.add,
    );
  }

  late final NetworkCaptureService service;
  bool supported;
  NetworkPolicy policy = const NetworkPolicy(accepting: true);
  final statuses = StreamController<BugseeStatus>.broadcast(sync: true);
  final List<NetworkEventMessage> sent = [];
  final List<String> warnings = [];
  int loads = 0;
  int attaches = 0;
  Completer<void>? loadGate;
  bool loadThrows = false;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));
}

class _AppOverrides extends HttpOverrides {
  int created = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created++;
    return super.createHttpClient(context);
  }
}

void main() {
  setUp(() => HttpOverrides.global = null);
  tearDown(() => HttpOverrides.global = null);

  group('install', () {
    test(
      'puts the capture in front, attaches to native and reads the policy',
      () async {
        final rig = Rig();
        expect(rig.service.installed, isFalse);
        expect(rig.service.install(), isTrue);
        expect(rig.service.installed, isTrue);
        expect(isHttpCaptureInEffect(), isTrue);
        expect(rig.attaches, 1);
        await rig.settle();
        expect(rig.loads, 1);
        expect(rig.service.policy.accepting, isTrue);
      },
    );

    test(
      'is idempotent: a second call neither stacks overrides nor reads again',
      () async {
        final rig = Rig();
        rig.service.install();
        final first = HttpOverrides.current;
        await rig.settle();
        expect(rig.service.install(), isTrue);
        expect(identical(HttpOverrides.current, first), isTrue);
        await rig.settle();
        expect(rig.loads, 1);
        expect(rig.attaches, 1);
      },
    );

    test(
      'an exchange in flight at an uninstall does not record after a reinstall',
      () async {
        final gate = Completer<void>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((r) async {
          r.response
            ..headers.contentType = ContentType.text
            ..bufferOutput = false
            ..write('first;');
          await r.response.flush();
          await gate.future;
          r.response.write('second');
          await r.response.close();
        });
        final rig = Rig();
        rig.service.install();
        await rig.settle();
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/'),
        );
        final response = await request.close();
        final first = Completer<void>();
        final done = Completer<void>();
        response.listen((_) {
          if (!first.isCompleted) first.complete();
        }, onDone: done.complete);
        await first.future;
        rig.service.uninstall();
        rig.service.install();
        await rig.settle();
        gate.complete();
        await done.future;
        await rig.service.pipeline.flush();
        expect(rig.sent.map((m) => m.stage), ['before']);
      },
    );

    test('chains to the overrides the app already installed', () async {
      final app = _AppOverrides();
      HttpOverrides.global = app;
      final rig = Rig();
      rig.service.install();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      expect(client, isA<CapturingHttpClient>());
      expect(app.created, 1, reason: 'the app\'s overrides made the client');
    });

    test(
      'on a platform with no SDK nothing is installed, with one warning',
      () {
        final rig = Rig(supported: false);
        expect(rig.service.install(), isFalse);
        expect(rig.service.install(), isFalse);
        expect(rig.service.installed, isFalse);
        expect(HttpOverrides.current, isNull);
        expect(rig.warnings, hasLength(1));
      },
    );

    test(
      'after the app replaced the overrides without chaining, installing again puts it back in front',
      () async {
        final rig = Rig();
        rig.service.install();
        final mine = HttpOverrides.current;
        final replacement = _AppOverrides();
        HttpOverrides.global = replacement;
        expect(isHttpCaptureInEffect(), isFalse);
        expect(rig.service.install(), isTrue);
        expect(isHttpCaptureInEffect(), isTrue);
        expect(identical(HttpOverrides.current, mine), isFalse);
        final madeBefore = replacement.created;
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        expect(client, isA<CapturingHttpClient>());
        expect(
          replacement.created,
          madeBefore + 1,
          reason: 'now chained to the replacement',
        );
      },
    );

    test(
      'a capture that is installed twice by chain does not record twice',
      () async {
        final rig = Rig();
        rig.service.install();
        // The app chains its own overrides over ours (the usual way to compose).
        final app = _AppOverrides();
        HttpOverrides.global = _Chained(app, HttpOverrides.current!);
        expect(rig.service.install(), isTrue);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((r) => r.response.close());
        await rig.settle();
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        await (await (await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/'),
        )).close()).drain<void>();
        await rig.service.pipeline.flush();
        expect(rig.sent.where((m) => m.stage == 'before'), hasLength(1));
      },
    );
  });

  group('uninstall', () {
    test('restores the overrides that were there before', () {
      final app = _AppOverrides();
      HttpOverrides.global = app;
      final rig = Rig();
      rig.service.install();
      expect(identical(HttpOverrides.current, app), isFalse);
      rig.service.uninstall();
      expect(identical(HttpOverrides.current, app), isTrue);
      expect(rig.service.installed, isFalse);
    });

    test('with nothing before, leaves no overrides', () {
      final rig = Rig();
      rig.service.install();
      rig.service.uninstall();
      expect(HttpOverrides.current, isNull);
    });

    test(
      'when the app chained over it, the capture stays in the chain and records nothing',
      () async {
        final rig = Rig();
        rig.service.install();
        final app = _Chained(_AppOverrides(), HttpOverrides.current!);
        HttpOverrides.global = app;
        rig.service.uninstall();
        expect(
          identical(HttpOverrides.current, app),
          isTrue,
          reason: 'not ours to remove',
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((r) => r.response.close());
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        expect(
          client,
          isNot(isA<CapturingHttpClient>()),
          reason: 'a client made after the uninstall is not wrapped',
        );
        await (await (await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/'),
        )).close()).drain<void>();
        await rig.service.pipeline.flush();
        expect(rig.sent, isEmpty);
      },
    );

    test(
      'a reinstall accepts nothing until the policy is read again',
      () async {
        final rig = Rig();
        rig.service.install();
        await rig.settle();
        expect(rig.service.policy.accepting, isTrue);
        rig.service.uninstall();
        rig.policy = NetworkPolicy.off; // the SDK stopped meanwhile
        rig.loadGate = Completer<void>();
        rig.service.install();
        expect(rig.service.policy.accepting, isFalse);
        rig.loadGate!.complete();
        await rig.settle();
        expect(
          rig.service.policy.accepting,
          isFalse,
          reason: 'the read said stopped',
        );
        rig.policy = const NetworkPolicy(accepting: true);
        await rig.service.refreshPolicy();
        expect(rig.service.policy.accepting, isTrue);
      },
    );

    test('can be installed again afterwards', () async {
      final rig = Rig();
      rig.service.install();
      rig.service.uninstall();
      expect(rig.service.install(), isTrue);
      expect(rig.service.installed, isTrue);
      expect(isHttpCaptureInEffect(), isTrue);
      await rig.settle();
      expect(rig.service.policy.accepting, isTrue);
    });

    test('is harmless when nothing was installed', () {
      Rig().service.uninstall();
    });
  });

  group('install in unusual places', () {
    test('inside a zone that scopes its own overrides it refuses, clearly', () {
      final rig = Rig();
      expect(
        () => HttpOverrides.runWithHttpOverrides(
          rig.service.install,
          _AppOverrides(),
        ),
        throwsA(
          isA<BugseeException>().having(
            (e) => e.message,
            'message',
            contains('zone'),
          ),
        ),
      );
      expect(rig.service.installed, isFalse);
      expect(HttpOverrides.current, isNull, reason: 'nothing was made global');
    });

    test(
      'a repeated install does not create a client through the app\'s overrides again',
      () {
        final app = _AppOverrides();
        HttpOverrides.global = app;
        final rig = Rig();
        rig.service.install();
        rig.service.install(); // the first probe
        final made = app.created;
        rig.service.install();
        rig.service.install();
        expect(
          app.created,
          made,
          reason: 'answered from the probe already made',
        );
      },
    );

    test('after the overrides changed it probes again', () {
      final app = _AppOverrides();
      HttpOverrides.global = app;
      final rig = Rig();
      rig.service.install();
      rig.service.install();
      final other = _AppOverrides();
      HttpOverrides.global = other;
      expect(rig.service.install(), isTrue);
      expect(isHttpCaptureInEffect(), isTrue);
    });
  });

  group('uninstall and what was already captured', () {
    test('events captured before the uninstall are still submitted', () async {
      final rig = Rig();
      rig.service.install();
      await rig.settle();
      rig.service.pipeline.submit(
        BugseeNetworkEvent(
          id: 'a',
          stage: NetworkStage.before,
          method: 'GET',
          url: 'http://x/',
        ),
      );
      rig.service.uninstall();
      await rig.service.pipeline.flush();
      expect(rig.sent.map((m) => m.id), ['a']);
    });
  });

  group('the policy follows the SDK', () {
    test(
      'a status that is not launched stops capture at once, before the options are read again',
      () async {
        final rig = Rig();
        rig.service.install();
        await rig.settle();
        expect(rig.service.policy.accepting, isTrue);
        rig.loadGate = Completer<void>();
        rig.statuses.add(BugseeStatus.stopping);
        expect(
          rig.service.policy.accepting,
          isFalse,
          reason: 'no waiting for the read',
        );
        rig.loadGate!.complete();
      },
    );

    test('a launch is believed once the options say so', () async {
      final rig = Rig();
      rig.policy = NetworkPolicy.off;
      rig.service.install();
      await rig.settle();
      expect(rig.service.policy.accepting, isFalse);
      rig.policy = const NetworkPolicy(accepting: true, bodySizeLimit: 77);
      rig.statuses.add(BugseeStatus.launched);
      await rig.settle();
      expect(rig.service.policy.accepting, isTrue);
      expect(rig.service.policy.bodySizeLimit, 77);
    });

    test('a newer read supersedes an older one that finishes later', () async {
      final rig = Rig();
      rig.service.install();
      await rig.settle();
      final slow = Completer<void>();
      rig.loadGate = slow;
      rig.policy = const NetworkPolicy(accepting: true, bodySizeLimit: 1);
      final older = rig.service.refreshPolicy();
      rig.loadGate = null;
      rig.policy = const NetworkPolicy(accepting: true, bodySizeLimit: 2);
      await rig.service.refreshPolicy();
      slow.complete();
      await older;
      expect(rig.service.policy.bodySizeLimit, 2);
    });

    test('a failure to read leaves nothing accepted (fail closed)', () async {
      final rig = Rig();
      rig.service.install();
      await rig.settle();
      expect(rig.service.policy.accepting, isTrue);
      rig.loadThrows = true;
      await rig.service.refreshPolicy();
      expect(rig.service.policy.accepting, isFalse);
    });

    test('a read that finishes after uninstall changes nothing', () async {
      final rig = Rig();
      rig.loadGate = Completer<void>();
      rig.service.install();
      rig.service.uninstall();
      rig.loadGate!.complete();
      await rig.settle();
      expect(rig.service.policy.accepting, isFalse);
    });

    test('nothing is read while not installed', () async {
      final rig = Rig();
      await rig.service.refreshPolicy();
      expect(rig.loads, 0);
    });
  });

  group('the options', () {
    test(
      'read from what the SDK reports, with the SDK defaults for what is absent',
      () {
        final p = NetworkPolicy.from({}, launched: true);
        expect(p.accepting, isTrue);
        expect(p.bodySizeLimit, 20480);
        expect(p.bodyWithoutType, isFalse);
        expect(p.ownHosts, isEmpty);
        final q = NetworkPolicy.from({
          NetworkOptionKeys.capture: false,
          NetworkOptionKeys.bodySizeLimit: 100,
          NetworkOptionKeys.bodyWithoutType: true,
          'com.bugsee.option.\$\$ENDPOINT':
              'https://bugsee.internal.example:8443/base',
        }, launched: true);
        expect(q.accepting, isFalse);
        expect(q.bodySizeLimit, 100);
        expect(q.bodyWithoutType, isTrue);
        expect(q.ownHosts, {'bugsee.internal.example'});
      },
    );

    test('a body-size limit above the cap is capped, one below is kept', () {
      expect(
        NetworkPolicy.from({
          NetworkOptionKeys.bodySizeLimit: 100 * 1024 * 1024,
        }, launched: true).bodySizeLimit,
        NetworkPolicy.maxBodyBytes,
      );
      expect(
        NetworkPolicy.from({
          NetworkOptionKeys.bodySizeLimit: NetworkPolicy.maxBodyBytes,
        }, launched: true).bodySizeLimit,
        NetworkPolicy.maxBodyBytes,
      );
      expect(
        NetworkPolicy.from({
          NetworkOptionKeys.bodySizeLimit: 1000,
        }, launched: true).bodySizeLimit,
        1000,
      );
    });

    test('not launched is never accepting, whatever the options say', () {
      expect(
        NetworkPolicy.from({
          NetworkOptionKeys.capture: true,
        }, launched: false).accepting,
        isFalse,
      );
    });

    test('a value of the wrong type falls back to the default', () {
      final p = NetworkPolicy.from({
        NetworkOptionKeys.capture: 'yes',
        NetworkOptionKeys.bodySizeLimit: '5',
        NetworkOptionKeys.bodyWithoutType: 1,
        'com.bugsee.option.\$\$ENDPOINT': 5,
      }, launched: true);
      expect(p.accepting, isTrue);
      expect(p.bodySizeLimit, 20480);
      expect(p.bodyWithoutType, isFalse);
      expect(p.ownHosts, isEmpty);
    });
  });

  group('the filter', () {
    test(
      'a timeout that is not positive or is over five minutes is refused',
      () {
        final rig = Rig();
        for (final bad in [
          Duration.zero,
          const Duration(seconds: -1),
          const Duration(minutes: 5, milliseconds: 1),
        ]) {
          expect(
            () => rig.service.setFilter((e) => e, bad),
            throwsA(isA<BugseeArgumentException>()),
          );
        }
        expect(rig.service.pipeline.filter, isNull);
        rig.service.setFilter((e) => e, const Duration(minutes: 5));
        expect(rig.service.pipeline.filter, isNotNull);
      },
    );
  });
}

/// The app's way of composing: its own overrides in front, the capture behind.
class _Chained extends HttpOverrides {
  _Chained(this.app, this.next);
  final _AppOverrides app;
  final HttpOverrides next;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    app.created++;
    return next.createHttpClient(context);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      next.findProxyFromEnvironment(url, environment);
}
