// Runs on a device or simulator (it needs the native SDKs):
//
//   cd example && flutter test integration_test/network_test.dart -d <device> \
//       --dart-define=BUGSEE_ENDPOINT=http://<host>:<port>
//
// Real HTTP requests from Dart through the installed capture, against an in-process server, with
// the SDK launched against a local stand-in for the Bugsee API (the endpoint above), then a real
// report. The SDK's own bundle is the readback: `doc/network.md` says how to read its network.json
// (Android: `adb shell run-as <package> ...`). The test prints one `NET:` line per fact so a run
// can be compared with the bundle.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_example/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void say(String line) => debugPrint('NET: $line');

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real requests are captured, filtered and end up in the report', (
    tester,
  ) async {
    final android = defaultTargetPlatform == TargetPlatform.android;
    // The SDK's own endpoint is the host the stand-in listens on: never captured.
    final ownHost = endpoint.isEmpty ? null : Uri.parse(endpoint).host;
    final loopback = android ? '127.0.0.1' : 'localhost';

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final slowGate = Completer<void>();
    server.listen((request) async {
      final response = request.response;
      try {
        switch (request.uri.path) {
          case '/json':
          case '/json2':
            response
              ..headers.contentType = ContentType.json
              ..headers.set('x-server', 'example')
              ..headers.set('set-cookie', 'sid=SERVERSECRET; HttpOnly')
              ..write(
                jsonEncode({'ok': true, 'token': 'srv-token-1', 'n': 42}),
              );
          case '/echo':
            final bytes = await request.fold<List<int>>(
              <int>[],
              (a, b) => a..addAll(b),
            );
            response
              ..statusCode = 201
              ..headers.contentType = ContentType.json
              ..add(bytes);
          case '/missing':
            response
              ..statusCode = 404
              ..headers.contentType = ContentType.text
              ..write('not found here');
          case '/redirect':
            response
              ..statusCode = 302
              ..headers.set('location', '/redirect2');
          case '/redirect2':
            response
              ..statusCode = 301
              ..headers.set('location', '/json');
          case '/gzip':
            response
              ..headers.contentType = ContentType.text
              ..headers.set('content-encoding', 'gzip')
              ..add(gzip.encode(utf8.encode('compressed hello ' * 20)));
          case '/big':
            response
              ..headers.contentType = ContentType.text
              ..write('B' * 30000);
          case '/png':
            response
              ..headers.contentType = ContentType('image', 'png')
              ..add(List<int>.generate(3000, (i) => i % 256));
          case '/slow':
            response
              ..headers.contentType = ContentType.text
              ..bufferOutput = false
              ..write('first chunk;');
            await response.flush();
            await slowGate.future;
          case '/loc':
            response
              ..headers.contentType = ContentType.text
              ..headers.set('location', '/final?token=LOCSECRET&x=1')
              ..headers.set('content-location', 'http://u:p@h.example/x?a=1')
              ..write('loc');
          case '/secret':
            response
              ..headers.contentType = ContentType.text
              ..write('hidden');
          default:
            response.statusCode = 404;
        }
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    });
    Uri url(String path) => Uri.parse('http://$loopback:${server.port}$path');

    Future<void> call(
      String name,
      String method,
      Uri uri, {
      Map<String, String> headers = const {},
      String? body,
      bool cancelAfterFirstChunk = false,
    }) async {
      final client = HttpClient();
      try {
        final request = await client.openUrl(method, uri);
        headers.forEach(request.headers.set);
        if (body != null) request.write(body);
        final response = await request.close();
        if (cancelAfterFirstChunk) {
          final first = Completer<void>();
          final sub = response.listen((_) => first.complete());
          await first.future;
          await sub.cancel();
          say('$name: cancelled after the first chunk');
          return;
        }
        final bytes = await response.fold<int>(0, (n, c) => n + c.length);
        say('$name: ${response.statusCode} $bytes bytes');
      } on Object catch (e) {
        say('$name: failed with ${e.runtimeType}');
      } finally {
        client.close(force: true);
      }
    }

    // The capture is installed by `main` of the example app; the test installs it itself too
    // (idempotent) because it does not run `main`.
    expect(Bugsee.installNetworkCapture(), isTrue);
    expect(Bugsee.installNetworkCapture(), isTrue);
    expect(Bugsee.networkCaptureInstalled, isTrue);

    // Before launch nothing is captured.
    await call('before-launch', 'GET', url('/json'));

    final launch = await Bugsee.launch(defaultToken, options: exampleOptions());
    say('launch: $launch');
    expect(await Bugsee.waitUntilLaunched(), isTrue);
    final options = await Bugsee.getLaunchOptions();
    say(
      'options: capture.network=${options['com.bugsee.option.capture.network']} '
      'body-size-limit=${options['com.bugsee.option.capture.network.body-size-limit']} '
      'default-sanitizer=${options['com.bugsee.option.capture.network.default-sanitizer']}',
    );
    await Future<void>.delayed(const Duration(seconds: 1));

    // ---- Without a filter: the SDK's own sanitizer is what protects the report ------------
    await call(
      'get-json',
      'GET',
      url('/json?token=abc123&q=hello'),
      headers: {
        'authorization': 'Bearer topsecret',
        'x-session': 's1',
        'accept': 'application/json',
      },
    );
    await call(
      'post-json',
      'POST',
      url('/echo'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'name': 'jo', 'password': 'hunter2'}),
    );
    await call('missing', 'GET', url('/missing'));
    await call('redirects', 'GET', url('/redirect'));
    await call('gzip', 'GET', url('/gzip'));
    await call('big', 'GET', url('/big'));
    await call('png', 'GET', url('/png'));
    await call(
      'slow-cancelled',
      'GET',
      url('/slow'),
      cancelAfterFirstChunk: true,
    );
    slowGate.complete();
    final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port;
    await closed.close(force: true);
    await call(
      'refused',
      'GET',
      Uri.parse('http://$loopback:$closedPort/nobody-home'),
    );
    if (ownHost != null) {
      await call(
        'bugsee-endpoint',
        'GET',
        Uri.parse('$endpoint/v2/not-captured'),
      );
    }

    // URL hygiene (review round): userinfo, URL-valued headers, a redirect the app follows itself.
    await call(
      'userinfo',
      'GET',
      Uri.parse(
        'http://user:pw-SECRET@$loopback:${server.port}/json?token=abc123',
      ),
    );
    await call(
      'location-headers',
      'GET',
      url('/loc'),
      headers: {'referer': 'http://u:p@h.example/p?k=v'},
    );
    final manual = HttpClient();
    try {
      final request = await manual.getUrl(url('/redirect'));
      request.followRedirects = false;
      final first = await request.close();
      await first.drain<void>();
      final next = await first.redirect();
      await next.drain<void>();
      say('manual-redirect: ${first.statusCode} then ${next.statusCode}');
    } finally {
      manual.close(force: true);
    }

    // ---- With a Dart filter: nothing it drops or hides reaches the SDK ---------------------
    Bugsee.setNetworkFilter((event) {
      if (event.url.contains('/secret')) return null;
      event.headers.remove('x-session');
      if (event.body != null && event.body!.contains('hunter2')) {
        event.body = null;
        event.noBodyReason = NoBodyReason.cantReadData;
      }
      return event;
    });
    await call('filtered-secret', 'GET', url('/secret'));
    await call(
      'filtered-json2',
      'GET',
      url('/json2'),
      headers: {'x-session': 'must-not-reach-the-sdk', 'accept': '*/*'},
    );
    await call(
      'filtered-post',
      'POST',
      url('/echo?filtered=1'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'name': 'filtered', 'password': 'hunter2'}),
    );
    Bugsee.setNetworkFilter(null);

    await Future<void>.delayed(const Duration(seconds: 2));
    // Native delivery may still be in flight: wait (bounded) until every captured event is
    // either dropped by the filter or submitted.
    final drainBy = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(drainBy)) {
      final s = Bugsee.networkCaptureStats;
      if (s.submittedToSdk + s.droppedByFilter + s.refusedByNative >=
          s.captured) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final stats = Bugsee.networkCaptureStats;
    say('stats: $stats');
    expect(stats.captured, greaterThan(10));
    // The userinfo never reaches the SDK: the bundle is where that is read.
    expect(stats.droppedQueueFull, 0);
    expect(stats.sendFailures, 0);
    expect(stats.droppedByFilter, greaterThanOrEqualTo(2)); // the /secret pair
    // Every captured event was submitted to the SDK, none refused. (iOS has no redirect stage:
    // the Dart side does not even create those entries there.)
    expect(stats.refusedByNative, 0);
    expect(stats.submittedToSdk, stats.captured - stats.droppedByFilter);

    // A report: this is what the bundle (network.json) is read from.
    await Bugsee.upload('network capture test', 'requests made from Dart');
    say('upload requested');
    await Future<void>.delayed(const Duration(seconds: 12));
    say('done');
    // Time to read the bundle from the device before the harness uninstalls the app (the run
    // is started with --dart-define=NET_HOLD=<seconds> for that).
    const hold = int.fromEnvironment('NET_HOLD');
    if (hold > 0) {
      say('holding for $hold s');
      await Future<void>.delayed(const Duration(seconds: hold));
    }
    await Bugsee.stop();
  });
}
