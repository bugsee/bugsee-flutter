// `Bugsee.installNetworkCapture` and friends through the real runtime, with a fake native side and
// real sockets: a request made by the app ends up as `addNetworkEvents` batches.
import 'dart:async';
import 'dart:io';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/bugsee.dart' show debugSetBugseeRuntime;
import 'package:bugsee_flutter/src/bugsee_runtime.dart';
import 'package:bugsee_flutter/src/network/network_policy.dart';
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

class FakeHost extends BugseeBridgeHostApi {
  String statusName = 'launched';
  Map<String, Object> options = {};
  final List<List<NetworkEventMessage>> batches = [];
  bool addThrows = false;
  int handedOverride = -1;
  int statusReads = 0;
  Completer<void>? optionsGate;

  List<NetworkEventMessage> get sent => [for (final b in batches) ...b];

  @override
  Future<void> attachLifecycle() async {}
  @override
  Future<void> resetReportHandlers() async {}
  @override
  Future<void> setReportHandlerPhases(bool before, bool after) async {}
  @override
  Future<void> setWrapperIdentity(WrapperIdentityMessage identity) async {}

  @override
  Future<LaunchOutcomeMessage> launch(
    String token,
    Map<String, Object> options,
  ) async {
    statusName = 'launched';
    return LaunchOutcomeMessage(outcome: 'launched');
  }

  @override
  Future<void> stop() async => statusName = 'stopped';

  @override
  Future<String> status() async {
    statusReads++;
    return statusName;
  }

  @override
  Future<Map<String, Object>> launchOptions(bool hostOnly) async {
    await optionsGate?.future;
    return options;
  }

  @override
  Future<int> addNetworkEvents(List<NetworkEventMessage> events) async {
    if (addThrows) throw PlatformException(code: 'not-attached');
    batches.add(events);
    return handedOverride >= 0 ? handedOverride : events.length;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHost host;
  late BugseeRuntime runtime;
  late List<String> warnings;
  late HttpServer server;
  OptionPlatform? platform;
  bool binding = true;

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  Future<void> get(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url(path));
      headers.forEach(request.headers.set);
      await (await request.close()).drain<void>();
    } finally {
      client.close(force: true);
    }
    await runtime.network.pipeline.flush();
  }

  setUp(() async {
    // The test binding installs mock overrides; the capture is tested against real sockets.
    HttpOverrides.global = null;
    host = FakeHost();
    warnings = [];
    platform = OptionPlatform.android;
    binding = true;
    runtime = BugseeRuntime(
      host: host,
      platform: () => platform,
      warn: warnings.add,
      ensureBinding: () {
        if (!binding) throw StateError('no binding in this isolate');
      },
    );
    debugSetBugseeRuntime(runtime);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"hello":"world"}');
      await request.response.close();
    });
  });

  tearDown(() async {
    Bugsee.uninstallNetworkCapture();
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  test(
    'installs, and a request ends up at native as before and complete',
    () async {
      expect(Bugsee.networkCaptureInstalled, isFalse);
      expect(Bugsee.installNetworkCapture(), isTrue);
      expect(Bugsee.networkCaptureInstalled, isTrue);
      await settle();
      await get('/a?x=1', headers: {'accept': 'application/json'});
      expect(host.sent.map((m) => m.stage), ['before', 'complete']);
      final before = host.sent[0];
      final complete = host.sent[1];
      expect(before.id, complete.id);
      expect(before.method, 'GET');
      expect(before.url, url('/a?x=1').toString());
      expect(before.mechanism, 'dart:io');
      expect(before.headers!['accept'], 'application/json');
      expect(complete.statusCode, 200);
      expect(complete.body, '{"hello":"world"}');
      expect(complete.size, 17);
      expect(Bugsee.networkCaptureStats.captured, 2);
      expect(Bugsee.networkCaptureStats.handedToSdk, 2);
    },
  );

  test('installing twice records once', () async {
    Bugsee.installNetworkCapture();
    Bugsee.installNetworkCapture();
    await settle();
    await get('/a');
    expect(host.sent.where((m) => m.stage == 'before'), hasLength(1));
  });

  test(
    'nothing is recorded before launch, and recording starts when the SDK launches',
    () async {
      host.statusName = 'stopped';
      Bugsee.installNetworkCapture();
      await settle();
      await get('/before-launch');
      expect(host.sent, isEmpty);
      await Bugsee.launch('token');
      await settle();
      await get('/after-launch');
      expect(host.sent.map((m) => m.url).toSet(), {
        url('/after-launch').toString(),
      });
    },
  );

  test(
    'a lifecycle event moves the policy too (a launch the app did not make)',
    () async {
      host.statusName = 'stopped';
      Bugsee.installNetworkCapture();
      await settle();
      host.statusName = 'launched';
      runtime.bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Launched'));
      await settle();
      await get('/a');
      expect(host.sent, isNotEmpty);
    },
  );

  test('stopping the SDK stops recording', () async {
    Bugsee.installNetworkCapture();
    await settle();
    await get('/while-launched');
    final count = host.sent.length;
    await Bugsee.stop();
    await settle();
    await get('/after-stop');
    expect(host.sent, hasLength(count));
  });

  test('a stop event takes effect before the options are read again', () async {
    Bugsee.installNetworkCapture();
    await settle();
    host.optionsGate = Completer<void>(); // the re-read cannot finish
    runtime.bridge.onLifecycleEvent(LifecycleEventMessage(name: 'Stopping'));
    await Future<void>.delayed(Duration.zero);
    expect(runtime.network.policy.accepting, isFalse);
    host.optionsGate!.complete();
  });

  test('capture.network off records nothing', () async {
    host.options = {NetworkOptionKeys.capture: false};
    Bugsee.installNetworkCapture();
    await settle();
    await get('/a');
    expect(host.sent, isEmpty);
  });

  test(
    'the SDK\'s body options apply: a limit, and no body without a type',
    () async {
      host.options = {NetworkOptionKeys.bodySizeLimit: 5};
      Bugsee.installNetworkCapture();
      await settle();
      await get('/a');
      final complete = host.sent.singleWhere((m) => m.stage == 'complete');
      expect(complete.body, isNull);
      expect(complete.noBodyReason, 'size_too_large');
      expect(complete.size, 17);
    },
  );

  test(
    'Bugsee\'s own endpoint is never recorded, and the rest still is',
    () async {
      host.options = {
        'com.bugsee.option.\$\$ENDPOINT': 'http://127.0.0.1:${server.port}',
      };
      Bugsee.installNetworkCapture();
      await settle();
      await get('/a');
      expect(host.sent, isEmpty);
      expect(Bugsee.networkCaptureStats.captured, 0);
    },
  );

  test(
    'uninstall restores the overrides in place before and stops recording',
    () async {
      final app = _Marker();
      HttpOverrides.global = app;
      Bugsee.installNetworkCapture();
      await settle();
      expect(identical(HttpOverrides.current, app), isFalse);
      Bugsee.uninstallNetworkCapture();
      expect(identical(HttpOverrides.current, app), isTrue);
      expect(Bugsee.networkCaptureInstalled, isFalse);
      await get('/a');
      expect(host.sent, isEmpty);
    },
  );

  test('on a platform with no SDK it installs nothing and says so once', () {
    platform = null;
    expect(Bugsee.installNetworkCapture(), isFalse);
    expect(Bugsee.installNetworkCapture(), isFalse);
    expect(HttpOverrides.current, isNull);
    expect(
      warnings.where((w) => w.contains('Android and iOS only')),
      hasLength(1),
    );
  });

  test(
    'from a background isolate it is a BugseeException, not a silent no-op',
    () {
      binding = false;
      expect(Bugsee.installNetworkCapture, throwsA(isA<BugseeException>()));
      expect(HttpOverrides.current, isNull);
    },
  );

  group('the filter', () {
    test(
      'runs before native: it can drop and redact, and native never sees the raw value',
      () async {
        Bugsee.setNetworkFilter((event) {
          if (event.url.contains('/drop')) return null;
          event.headers.remove('authorization');
          event.url = event.url.replaceAll('secret-token', 'REDACTED');
          return event;
        });
        Bugsee.installNetworkCapture();
        await settle();
        await get('/drop');
        await get(
          '/keep?t=secret-token',
          headers: {'authorization': 'Bearer abc'},
        );
        expect(host.sent.every((m) => !m.url.contains('/drop')), isTrue);
        final before = host.sent.singleWhere((m) => m.stage == 'before');
        expect(before.url, endsWith('/keep?t=REDACTED'));
        expect(before.headers!.containsKey('authorization'), isFalse);
        expect(
          host.sent.map((m) => m.url).join(),
          isNot(contains('secret-token')),
        );
        expect(Bugsee.networkCaptureStats.droppedByFilter, 2);
      },
    );

    test(
      'a throwing filter drops the event, never the app\'s request',
      () async {
        Bugsee.setNetworkFilter((event) => throw StateError('filter bug'));
        Bugsee.installNetworkCapture();
        await settle();
        await get('/a');
        expect(host.sent, isEmpty);
        expect(Bugsee.networkCaptureStats.filterFailures, 2);
      },
    );

    test('a filter that hangs drops the event after its timeout', () async {
      Bugsee.setNetworkFilter(
        (event) => Completer<BugseeNetworkEvent?>().future,
        timeout: const Duration(milliseconds: 40),
      );
      Bugsee.installNetworkCapture();
      await settle();
      await get('/a');
      expect(host.sent, isEmpty);
      expect(Bugsee.networkCaptureStats.filterFailures, 2);
    });

    test('is readable back, removable, and validated', () {
      BugseeNetworkEvent? f(BugseeNetworkEvent e) => e;
      Bugsee.setNetworkFilter(f);
      expect(Bugsee.networkFilter, same(f));
      Bugsee.setNetworkFilter(null);
      expect(Bugsee.networkFilter, isNull);
      expect(
        () => Bugsee.setNetworkFilter(f, timeout: Duration.zero),
        throwsA(isA<BugseeArgumentException>()),
      );
      expect(
        Bugsee.networkFilter,
        isNull,
        reason: 'a refused call changes nothing',
      );
    });

    test('set before install, it applies from the first request', () async {
      var seen = 0;
      Bugsee.setNetworkFilter((e) {
        seen++;
        return e;
      });
      Bugsee.installNetworkCapture();
      await settle();
      await get('/a');
      expect(seen, 2);
    });
  });

  group('the bridge', () {
    test(
      'a native failure is counted and the app\'s request is untouched',
      () async {
        host.addThrows = true;
        Bugsee.installNetworkCapture();
        await settle();
        await get('/a');
        expect(Bugsee.networkCaptureStats.sendFailures, 2);
        expect(host.sent, isEmpty);
      },
    );

    test('events native did not take are counted as refused', () async {
      host.handedOverride = 0;
      Bugsee.installNetworkCapture();
      await settle();
      await get('/a');
      expect(Bugsee.networkCaptureStats.handedToSdk, 0);
      expect(Bugsee.networkCaptureStats.refusedByNative, 2);
    });
  });
}

class _Marker extends HttpOverrides {}
