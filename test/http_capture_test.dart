// The `dart:io` capture against a real local HttpServer: every exchange goes through real sockets
// (no mocked client), so what is recorded is what a real client saw, and what the app sees is
// compared with what an unwrapped client sees for the same request.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bugsee_flutter/src/network/http_capture.dart';
import 'package:bugsee_flutter/src/network/network_event.dart';
import 'package:bugsee_flutter/src/network/network_policy.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Handler = Future<void> Function(HttpRequest request);

/// A local server, a controller that records into [events], a captured client and a raw one.
class Harness {
  Harness._(this.server);

  final HttpServer server;
  final List<BugseeNetworkEvent> events = [];
  NetworkPolicy policy = const NetworkPolicy(accepting: true);
  int recordCalls = 0;
  bool recordThrows = false;
  late final HttpCaptureController controller = HttpCaptureController(
    policy: () => policy,
    record: (event) {
      recordCalls++;
      if (recordThrows) throw StateError('the pipeline broke');
      events.add(event);
    },
  );
  final List<HttpClient> clients = [];

  static Future<Harness> start(Handler handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await handler(request);
      } catch (_) {
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {}
      }
    });
    return Harness._(server);
  }

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  /// A client created by the capture's overrides (chained to [previous]).
  HttpClient captured({HttpOverrides? previous}) {
    final overrides = BugseeHttpOverrides(controller, previous);
    final client = HttpOverrides.runWithHttpOverrides(
      () => HttpClient(),
      overrides,
    );
    clients.add(client);
    return client;
  }

  HttpClient raw() {
    final client = HttpClient();
    clients.add(client);
    return client;
  }

  Future<void> close() async {
    for (final client in clients) {
      client.close(force: true);
    }
    await server.close(force: true);
  }

  List<BugseeNetworkEvent> stage(NetworkStage stage) =>
      events.where((e) => e.stage == stage).toList();
}

/// Everything an app can observe about one request, so two clients can be compared.
class Observed {
  Observed(
    this.status,
    this.reason,
    this.headers,
    this.bytes,
    this.contentLength,
    this.compression,
    this.redirects,
    this.isRedirect,
  );

  final int status;
  final String reason;
  final Map<String, List<String>> headers;
  final List<int> bytes;
  final int contentLength;
  final HttpClientResponseCompressionState compression;
  final List<String> redirects;
  final bool isRedirect;

  @override
  String toString() => '$status $reason $headers ${bytes.length}B $redirects';
}

Future<Observed> observe(
  HttpClient client,
  String method,
  Uri url, {
  List<int>? body,
  Map<String, String> headers = const {},
  bool followRedirects = true,
}) async {
  final request = await client.openUrl(method, url);
  request.followRedirects = followRedirects;
  headers.forEach(request.headers.set);
  if (body != null) request.add(body);
  final response = await request.close();
  final bytes = <int>[];
  await for (final chunk in response) {
    bytes.addAll(chunk);
  }
  final received = <String, List<String>>{};
  response.headers.forEach((name, values) {
    if (name == 'date') return; // differs by the second
    received[name] = List<String>.of(values);
  });
  return Observed(
    response.statusCode,
    response.reasonPhrase,
    received,
    bytes,
    response.contentLength,
    response.compressionState,
    [
      for (final r in response.redirects)
        '${r.statusCode} ${r.method} ${r.location}',
    ],
    response.isRedirect,
  );
}

Future<void> route(HttpRequest request) async {
  final response = request.response;
  switch (request.uri.path) {
    case '/json':
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..headers.set('x-test', '1')
        ..headers.add('x-multi', 'a')
        ..headers.add('x-multi', 'b')
        ..write('{"ok":true}');
    case '/echo':
      final bytes = await request.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );
      response
        ..statusCode = 201
        ..headers.contentType = ContentType.text
        ..headers.set(
          'x-request-content-type',
          request.headers.contentType?.toString() ?? '',
        )
        ..add(bytes);
    case '/r1':
      response
        ..statusCode = 302
        ..headers.set('location', '/r2');
    case '/r2':
      response
        ..statusCode = 301
        ..headers.set('location', '/json');
    case '/gzip':
      response
        ..headers.contentType = ContentType.text
        ..headers.set('content-encoding', 'gzip')
        ..add(gzip.encode(utf8.encode('hello ' * 50)));
    case '/big':
      response
        ..headers.contentType = ContentType.text
        ..add(Uint8List(5 * 1024 * 1024)..fillRange(0, 5 * 1024 * 1024, 0x61));
    case '/png':
      response
        ..headers.contentType = ContentType('image', 'png')
        ..add(List<int>.generate(2000, (i) => i % 256));
    case '/notype':
      response
        ..headers.removeAll(HttpHeaders.contentTypeHeader)
        ..contentLength = 5
        ..write('plain');
    case '/missing':
      response
        ..statusCode = 404
        ..headers.contentType = ContentType.text
        ..write('nope');
    case '/nocontent':
      response.statusCode = 204;
    case '/utf16':
      response
        ..headers.contentType = ContentType('text', 'plain', charset: 'utf-16')
        ..add([0xff, 0xfe, 0x68, 0x00]);
    case '/badutf8':
      response
        ..headers.contentType = ContentType.text
        ..add([0xff, 0xfe, 0xfd]);
    case '/loc':
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.text
        ..headers.set('location', '/final?token=abc&x=1')
        ..headers.set('content-location', 'http://u:p@h.example/x?a=1')
        ..headers.set('refresh', '0; url=/n?s=1')
        ..write('ok');
    case '/hang':
      // Never answers.
      await Completer<void>().future;
    default:
      response.statusCode = 404;
  }
  await response.close();
}

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start(route));
  tearDown(() => h.close());

  group('a plain exchange', () {
    test(
      'records the request and the response, in order, under one id',
      () async {
        final result = await observe(
          h.captured(),
          'GET',
          h.url('/json?a=1'),
          headers: {'accept': 'application/json'},
        );
        expect(result.status, 200);
        expect(
          [for (final e in h.events) e.stage],
          [NetworkStage.before, NetworkStage.complete],
        );
        final before = h.events[0];
        final complete = h.events[1];
        expect(before.id, complete.id);
        expect(before.method, 'GET');
        expect(before.url, h.url('/json?a=1').toString());
        expect(before.headers['accept'], 'application/json');
        expect(before.size, 0);
        expect(before.body, isNull);
        expect(before.noBodyReason, isNull);
        expect(complete.statusCode, 200);
        expect(complete.statusText, 'OK');
        expect(complete.url, before.url);
        expect(complete.body, '{"ok":true}');
        expect(complete.size, 11);
        expect(complete.noBodyReason, isNull);
        expect(complete.headers['x-test'], '1');
        expect(
          complete.headers['content-type'],
          startsWith('application/json'),
        );
      },
    );

    test(
      'header names are lower-case and a repeated header is one joined value',
      () async {
        await observe(h.captured(), 'GET', h.url('/json'));
        expect(h.events[1].headers['x-multi'], 'a, b');
        expect(
          h.events[1].headers.keys.every((k) => k == k.toLowerCase()),
          isTrue,
        );
      },
    );

    test(
      'the complete stage carries ttfb, download and total, in milliseconds',
      () async {
        await observe(h.captured(), 'GET', h.url('/json'));
        final timings = h.events[1].timings!;
        expect(timings.keys, containsAll(['ttfb', 'download', 'total']));
        expect(timings['total']!, greaterThanOrEqualTo(timings['ttfb']!));
        expect(timings.values.every((v) => v >= 0), isTrue);
      },
    );

    test('an HTTP error status is a complete, not an error', () async {
      final result = await observe(h.captured(), 'GET', h.url('/missing'));
      expect(result.status, 404);
      expect(h.stage(NetworkStage.error), isEmpty);
      expect(h.stage(NetworkStage.complete).single.statusCode, 404);
      expect(h.stage(NetworkStage.complete).single.body, 'nope');
    });

    test(
      'a response with no body and HEAD complete with no body and no reason',
      () async {
        await observe(h.captured(), 'GET', h.url('/nocontent'));
        await observe(h.captured(), 'HEAD', h.url('/json'));
        final complete = h.stage(NetworkStage.complete);
        expect(complete, hasLength(2));
        expect(complete[0].statusCode, 204);
        expect(complete[0].body, isNull);
        expect(complete[0].noBodyReason, isNull);
        expect(complete[1].method, 'HEAD');
        expect(complete[1].body, isNull);
      },
    );

    test(
      'the open(host, port, path) and the shortcut methods are recorded too',
      () async {
        final client = h.captured();
        final a = await client.get('127.0.0.1', h.server.port, '/json');
        await (await a.close()).drain<void>();
        final b = await client.postUrl(h.url('/echo'));
        b.headers.contentType = ContentType.text;
        b.write('x');
        await (await b.close()).drain<void>();
        final c = await client.open('PUT', '127.0.0.1', h.server.port, '/echo');
        c.headers.contentType = ContentType.text;
        await (await c.close()).drain<void>();
        final d = await client.deleteUrl(h.url('/json'));
        await (await d.close()).drain<void>();
        final e = await client.patchUrl(h.url('/json'));
        await (await e.close()).drain<void>();
        final f = await client.headUrl(h.url('/json'));
        await (await f.close()).drain<void>();
        expect(
          [for (final e in h.stage(NetworkStage.before)) e.method],
          ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD'],
        );
        expect(h.stage(NetworkStage.complete), hasLength(6));
      },
    );

    test('request.done is the same wrapped response as close()', () async {
      final client = h.captured();
      final request = await client.getUrl(h.url('/json'));
      final done = request.done;
      request.close();
      final response = await done;
      await response.drain<void>();
      expect(h.stage(NetworkStage.complete), hasLength(1));
      expect(identical(await request.close(), response), isTrue);
    });
  });

  group('what the app sees is what an unwrapped client sees', () {
    Future<void> same(
      String path, {
      String method = 'GET',
      List<int>? body,
      Map<String, String> headers = const {},
      bool follow = true,
    }) async {
      final captured = await observe(
        h.captured(),
        method,
        h.url(path),
        body: body,
        headers: headers,
        followRedirects: follow,
      );
      final raw = await observe(
        h.raw(),
        method,
        h.url(path),
        body: body,
        headers: headers,
        followRedirects: follow,
      );
      expect(captured.status, raw.status, reason: path);
      expect(captured.reason, raw.reason, reason: path);
      expect(captured.headers, raw.headers, reason: path);
      expect(captured.bytes, raw.bytes, reason: path);
      expect(captured.contentLength, raw.contentLength, reason: path);
      expect(captured.compression, raw.compression, reason: path);
      expect(captured.redirects, raw.redirects, reason: path);
      expect(captured.isRedirect, raw.isRedirect, reason: path);
    }

    test(
      'json, echo, redirects, gzip, binary, big, no type, 404, 204',
      () async {
        await same('/json');
        await same(
          '/echo',
          method: 'POST',
          body: utf8.encode('payload'),
          headers: {'content-type': 'text/plain'},
        );
        await same('/r1');
        await same('/r1', follow: false);
        await same('/gzip');
        await same('/png');
        await same('/big');
        await same('/notype');
        await same('/missing');
        await same('/nocontent');
      },
    );
  });

  group('request bodies', () {
    Future<BugseeNetworkEvent> send(
      FutureOr<void> Function(HttpClientRequest r) write, {
      String type = 'text/plain',
    }) async {
      h.events.clear();
      final request = await h.captured().postUrl(h.url('/echo'));
      if (type.isNotEmpty) request.headers.set('content-type', type);
      await write(request);
      await (await request.close()).drain<void>();
      return h.stage(NetworkStage.before).single;
    }

    test(
      'add, write, writeAll, writeln and writeCharCode all end up in the body, as sent',
      () async {
        final before = await send((r) {
          r.add(utf8.encode('a'));
          r.write('b');
          r.writeAll(['c', 'd'], '-');
          r.writeln('e');
          r.writeCharCode(0x66);
        });
        expect(
          before.body,
          'ab'
          'c-d'
          'e\nf',
        );
        expect(before.size, 'abc-de\nf'.length);
        // The server received exactly the same bytes.
        final echoed = h.stage(NetworkStage.complete).single;
        expect(echoed.body, before.body);
      },
    );

    test('writeAll walks a one-shot iterable once', () async {
      var walks = 0;
      Iterable<String> once() sync* {
        walks++;
        yield 'x';
        yield 'y';
      }

      final before = await send((r) => r.writeAll(once()));
      expect(walks, 1);
      expect(before.body, 'xy');
    });

    test('addStream is teed and the stream is consumed once', () async {
      final before = await send((r) async {
        await r.addStream(
          Stream.fromIterable([utf8.encode('one'), utf8.encode('two')]),
        );
      });
      expect(before.body, 'onetwo');
      expect(before.size, 6);
    });

    test('a JSON request body is kept with its content type', () async {
      final before = await send(
        (r) => r.write('{"a":1}'),
        type: 'application/json; charset=utf-8',
      );
      expect(before.body, '{"a":1}');
    });

    test(
      'no content type: no body, no_content_type (the option is off by default)',
      () async {
        final before = await send((r) => r.write('secret'), type: '');
        expect(before.body, isNull);
        expect(before.noBodyReason, NoBodyReason.noContentType);
        expect(before.size, 6);
      },
    );

    test('with body-without-type on, a typeless body is kept', () async {
      h.policy = const NetworkPolicy(accepting: true, bodyWithoutType: true);
      final before = await send((r) => r.write('secret'), type: '');
      expect(before.body, 'secret');
    });

    test(
      'a binary request body is counted, not kept: unsupported_content_type',
      () async {
        final before = await send(
          (r) => r.add(List<int>.filled(100, 7)),
          type: 'image/png',
        );
        expect(before.body, isNull);
        expect(before.noBodyReason, NoBodyReason.unsupportedContentType);
        expect(before.size, 100);
      },
    );

    test(
      'over the limit: size_too_large, the size counted in full, nothing kept',
      () async {
        h.policy = const NetworkPolicy(accepting: true, bodySizeLimit: 10);
        final before = await send((r) {
          r.add(List<int>.filled(8, 0x61));
          r.add(List<int>.filled(8, 0x62));
          r.add(List<int>.filled(1000, 0x63));
        });
        expect(before.body, isNull);
        expect(before.noBodyReason, NoBodyReason.sizeTooLarge);
        expect(before.size, 1016);
      },
    );

    test('exactly at the limit is kept, one byte over is not', () async {
      h.policy = const NetworkPolicy(accepting: true, bodySizeLimit: 5);
      expect((await send((r) => r.write('12345'))).body, '12345');
      final over = await send((r) => r.write('123456'));
      expect(over.body, isNull);
      expect(over.noBodyReason, NoBodyReason.sizeTooLarge);
    });

    test(
      'a declared Content-Length over the limit drops the body from the first byte',
      () async {
        h.policy = const NetworkPolicy(accepting: true, bodySizeLimit: 4);
        final before = await send((r) {
          r.contentLength = 6;
          r.write('abcdef');
        });
        expect(before.body, isNull);
        expect(before.noBodyReason, NoBodyReason.sizeTooLarge);
      },
    );

    test('a limit of 0 keeps no body at all', () async {
      h.policy = const NetworkPolicy(accepting: true, bodySizeLimit: 0);
      final before = await send((r) => r.write('x'));
      expect(before.body, isNull);
      expect(before.noBodyReason, NoBodyReason.sizeTooLarge);
    });

    test('the request headers are those set by the app', () async {
      h.events.clear();
      final request = await h.captured().postUrl(h.url('/echo'));
      request.headers.set('authorization', 'Bearer abc');
      request.headers.set('content-type', 'text/plain');
      request.write('x');
      await (await request.close()).drain<void>();
      expect(
        h.stage(NetworkStage.before).single.headers['authorization'],
        'Bearer abc',
      );
    });
  });

  group('response bodies', () {
    test(
      'a 5 MB body with a 1 KiB limit: counted in full, not kept, size_too_large',
      () async {
        h.policy = const NetworkPolicy(accepting: true, bodySizeLimit: 1024);
        await observe(h.captured(), 'GET', h.url('/big'));
        final complete = h.stage(NetworkStage.complete).single;
        expect(complete.size, 5 * 1024 * 1024);
        expect(complete.body, isNull);
        expect(complete.noBodyReason, NoBodyReason.sizeTooLarge);
      },
    );

    test('binary: counted, never kept', () async {
      await observe(h.captured(), 'GET', h.url('/png'));
      final complete = h.stage(NetworkStage.complete).single;
      expect(complete.size, 2000);
      expect(complete.body, isNull);
      expect(complete.noBodyReason, NoBodyReason.unsupportedContentType);
    });

    test('no content type: no_content_type, unless the option is on', () async {
      await observe(h.captured(), 'GET', h.url('/notype'));
      expect(
        h.stage(NetworkStage.complete).single.noBodyReason,
        NoBodyReason.noContentType,
      );
      h.events.clear();
      h.policy = const NetworkPolicy(accepting: true, bodyWithoutType: true);
      await observe(h.captured(), 'GET', h.url('/notype'));
      expect(h.stage(NetworkStage.complete).single.body, 'plain');
    });

    test(
      'gzip: the client decompresses, so the body is the text, not the bytes',
      () async {
        final result = await observe(h.captured(), 'GET', h.url('/gzip'));
        expect(
          result.compression,
          HttpClientResponseCompressionState.decompressed,
        );
        final complete = h.stage(NetworkStage.complete).single;
        expect(complete.body, 'hello ' * 50);
        expect(complete.size, 300);
      },
    );

    test(
      'gzip with autoUncompress off: still compressed, so cant_read_data',
      () async {
        final client = h.captured()..autoUncompress = false;
        final result = await observe(client, 'GET', h.url('/gzip'));
        expect(
          result.compression,
          HttpClientResponseCompressionState.compressed,
        );
        final complete = h.stage(NetworkStage.complete).single;
        expect(complete.body, isNull);
        expect(complete.noBodyReason, NoBodyReason.cantReadData);
        expect(complete.size, greaterThan(0));
      },
    );

    test(
      'an unsupported charset and bytes that are not text are cant_read_data',
      () async {
        await observe(h.captured(), 'GET', h.url('/utf16'));
        await observe(h.captured(), 'GET', h.url('/badutf8'));
        final complete = h.stage(NetworkStage.complete);
        expect(complete[0].noBodyReason, NoBodyReason.cantReadData);
        expect(complete[1].noBodyReason, NoBodyReason.cantReadData);
        expect(complete.every((e) => e.body == null), isTrue);
      },
    );
  });

  group('streaming', () {
    late Completer<void> gate;
    late Harness streaming;

    setUp(() async {
      gate = Completer<void>();
      streaming = await Harness.start((request) async {
        final response = request.response
          ..headers.contentType = ContentType.text
          ..bufferOutput = false;
        response.write('first;');
        await response.flush();
        await gate.future;
        response.write('second;');
        await response.close();
      });
    });
    tearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await streaming.close();
    });

    test(
      'chunks reach the app as they arrive, and the exchange completes only at the end',
      () async {
        final request = await streaming.captured().getUrl(streaming.url('/'));
        final response = await request.close();
        final first = Completer<String>();
        final all = StringBuffer();
        final done = Completer<void>();
        response.transform(utf8.decoder).listen((s) {
          all.write(s);
          if (!first.isCompleted) first.complete(s);
        }, onDone: done.complete);
        // The server is still holding the rest back: the first chunk is already here.
        expect(await first.future, 'first;');
        expect(streaming.stage(NetworkStage.complete), isEmpty);
        expect(streaming.stage(NetworkStage.before), hasLength(1));
        gate.complete();
        await done.future;
        expect(all.toString(), 'first;second;');
        expect(
          streaming.stage(NetworkStage.complete).single.body,
          'first;second;',
        );
      },
    );

    test(
      'pause and resume are forwarded: nothing is lost across them',
      () async {
        final request = await streaming.captured().getUrl(streaming.url('/'));
        final response = await request.close();
        final all = StringBuffer();
        final done = Completer<void>();
        late StreamSubscription<String> sub;
        sub = response.transform(utf8.decoder).listen((s) {
          all.write(s);
          if (s == 'first;') {
            sub.pause();
            Timer(const Duration(milliseconds: 50), () {
              gate.complete();
              sub.resume();
            });
          }
        }, onDone: done.complete);
        await done.future;
        expect(all.toString(), 'first;second;');
      },
    );

    test(
      'cancelling the subscription is an abort with what was seen so far',
      () async {
        final request = await streaming.captured().getUrl(streaming.url('/'));
        final response = await request.close();
        final first = Completer<void>();
        late StreamSubscription<List<int>> sub;
        sub = response.listen((chunk) => first.complete());
        await first.future;
        await sub.cancel();
        expect(streaming.stage(NetworkStage.complete), isEmpty);
        final abort = streaming.stage(NetworkStage.abort).single;
        expect(abort.size, 'first;'.length);
        expect(abort.id, streaming.stage(NetworkStage.before).single.id);
      },
    );

    test(
      'a paused subscription holds the server back: the backpressure reaches the socket',
      () async {
        const chunk = 256 * 1024;
        const chunks = 400; // 100 MB in all
        var written = 0;
        final big = await Harness.start((request) async {
          final response = request.response
            ..headers.contentType = ContentType.text
            ..bufferOutput = false;
          final bytes = Uint8List(chunk);
          try {
            for (var i = 0; i < chunks; i++) {
              response.add(bytes);
              await response.flush();
              written += chunk;
            }
          } catch (_) {}
          await response.close().catchError((_) {});
        });
        addTearDown(big.close);
        final request = await big.captured().getUrl(big.url('/'));
        final response = await request.close();
        var received = 0;
        final done = Completer<void>();
        late StreamSubscription<List<int>> sub;
        sub = response.listen((data) {
          received += data.length;
          if (received == data.length) sub.pause();
        }, onDone: done.complete);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        // Without backpressure the capture would have read all 100 MB into memory by now.
        expect(written, lessThan(50 * 1024 * 1024));
        expect(done.isCompleted, isFalse);
        sub.resume();
        await done.future.timeout(const Duration(seconds: 30));
        expect(received, chunk * chunks);
        expect(big.stage(NetworkStage.complete).single.size, chunk * chunks);
      },
    );

    test('a second listen fails the way the real response does', () async {
      final request = await streaming.captured().getUrl(streaming.url('/'));
      final response = await request.close();
      final sub = response.listen((_) {});
      expect(() => response.listen((_) {}), throwsA(isA<StateError>()));
      gate.complete();
      await sub.cancel();
    });
  });

  group('redirects', () {
    test(
      'every hop is a redirect stage and the final response says where it started',
      () async {
        await observe(h.captured(), 'GET', h.url('/r1'));
        final stages = [for (final e in h.events) e.stage];
        expect(stages, [
          NetworkStage.before,
          NetworkStage.redirect,
          NetworkStage.redirect,
          NetworkStage.complete,
        ]);
        final redirects = h.stage(NetworkStage.redirect);
        expect(redirects[0].url, h.url('/r1').toString());
        expect(redirects[0].statusCode, 302);
        expect(
          redirects[0].headers,
          isEmpty,
          reason:
              'a synthesised location header would carry the next URL, query included',
        );
        expect(redirects[1].url, h.url('/r2').toString());
        expect(redirects[1].statusCode, 301);
        final complete = h.stage(NetworkStage.complete).single;
        expect(complete.url, h.url('/json').toString());
        expect(complete.redirectedFrom, h.url('/r1').toString());
        expect(complete.statusCode, 200);
        expect({for (final e in h.events) e.id}, hasLength(1));
      },
    );

    test(
      'with followRedirects off the redirect response itself is the complete',
      () async {
        await observe(
          h.captured(),
          'GET',
          h.url('/r1'),
          followRedirects: false,
        );
        expect(h.stage(NetworkStage.redirect), isEmpty);
        final complete = h.stage(NetworkStage.complete).single;
        expect(complete.statusCode, 302);
        expect(complete.redirectedFrom, isNull);
      },
    );

    test(
      'a redirect the app follows itself: the 3xx is drained, then the next response is a new exchange that says where it came from',
      () async {
        final request = await h.captured().getUrl(h.url('/r1'));
        request.followRedirects = false;
        final first = await request.close();
        expect(first.isRedirect, isTrue);
        await first.drain<void>();
        final second = await first.redirect();
        await second.drain<void>();
        final third = await second.redirect();
        final body = await third.fold<int>(0, (n, c) => n + c.length);
        expect(body, 11);
        final complete = h.stage(NetworkStage.complete);
        expect([for (final e in complete) e.statusCode], [302, 301, 200]);
        expect(
          [for (final e in complete) e.url],
          [
            h.url('/r1').toString(),
            h.url('/r2').toString(),
            h.url('/json').toString(),
          ],
        );
        expect(complete[0].redirectedFrom, isNull);
        expect(complete[1].redirectedFrom, h.url('/r1').toString());
        expect(complete[2].redirectedFrom, h.url('/r2').toString());
        expect(complete[2].body, '{"ok":true}');
        // Three exchanges, each with its own before, in order.
        expect({for (final e in h.events) e.id}, hasLength(3));
        expect(
          [for (final e in h.events) '${e.stage.name}:${e.statusCode}'],
          [
            'before:0',
            'complete:302',
            'before:0',
            'complete:301',
            'before:0',
            'complete:200',
          ],
        );
        expect(h.stage(NetworkStage.redirect), isEmpty);
      },
    );

    test(
      'a redirect followed without reading the 3xx completes it without a body',
      () async {
        final request = await h.captured().getUrl(h.url('/r1'));
        request.followRedirects = false;
        final first = await request.close();
        final next = await first.redirect();
        await next.drain<void>();
        final complete = h.stage(NetworkStage.complete);
        expect([for (final e in complete) e.statusCode], [302, 301]);
        expect(complete[0].body, isNull);
        expect(complete[1].redirectedFrom, h.url('/r1').toString());
      },
    );
  });

  group('failures', () {
    test(
      'no connection: before and error, and the app gets the same exception',
      () async {
        final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final port = closed.port;
        await closed.close(force: true);
        final url = Uri.parse('http://127.0.0.1:$port/x?token=secret');
        Object? seen;
        try {
          await h.captured().getUrl(url);
        } catch (e) {
          seen = e;
        }
        Object? rawSeen;
        try {
          await h.raw().getUrl(url);
        } catch (e) {
          rawSeen = e;
        }
        expect(seen, isA<SocketException>());
        expect(seen.runtimeType, rawSeen.runtimeType);
        expect(
          [for (final e in h.events) e.stage],
          [NetworkStage.before, NetworkStage.error],
        );
        final error = h.stage(NetworkStage.error).single;
        expect(error.error, startsWith('SocketException'));
        expect(error.errorDescription, isNotEmpty);
        expect(error.url, url.toString());
      },
    );

    test('an error text never carries a query string', () async {
      // HttpException prints `uri = <the URL>`, query included.
      final harness = await Harness.start((request) async {
        final socket = await request.response.detachSocket();
        socket.destroy();
      });
      addTearDown(harness.close);
      try {
        final request = await harness.captured().getUrl(
          harness.url('/p?token=SECRET'),
        );
        await (await request.close()).drain<void>();
      } catch (_) {}
      final errors = harness.stage(NetworkStage.error);
      expect(errors, hasLength(1));
      expect(errors.single.error, isNot(contains('SECRET')));
      expect(errors.single.errorDescription, isNot(contains('SECRET')));
    });

    test('a connection closed in the middle of the body is an error', () async {
      final harness = await Harness.start((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 1000\r\n\r\npartial',
        );
        await socket.flush();
        socket.destroy();
      });
      addTearDown(harness.close);
      final request = await harness.captured().getUrl(harness.url('/'));
      final response = await request.close();
      Object? failure;
      try {
        await response.drain<void>();
      } catch (e) {
        failure = e;
      }
      expect(failure, isNotNull);
      expect(harness.stage(NetworkStage.complete), isEmpty);
      expect(harness.stage(NetworkStage.error).single.error, isNotEmpty);
    });

    test(
      'closing the client with force while a request is in flight is an error',
      () async {
        final client = h.captured();
        final request = await client.getUrl(h.url('/hang'));
        final outcome = request.close().then<Object?>(
          (_) => null,
          onError: (Object e) => e,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        client.close(force: true);
        expect(await outcome, isNotNull);
        expect(h.stage(NetworkStage.error), hasLength(1));
      },
    );

    test(
      'the app timing out and aborting is an abort after the before',
      () async {
        final request = await h.captured().getUrl(h.url('/hang'));
        await expectLater(
          request.close().timeout(const Duration(milliseconds: 100)),
          throwsA(isA<TimeoutException>()),
        );
        expect(h.stage(NetworkStage.before), hasLength(1));
        expect(h.stage(NetworkStage.abort), isEmpty);
        request.abort();
        expect(h.stage(NetworkStage.abort), hasLength(1));
        expect(
          h.stage(NetworkStage.abort).single.id,
          h.stage(NetworkStage.before).single.id,
        );
      },
    );

    test('aborting before close sends the before and the abort', () async {
      final request = await h.captured().postUrl(h.url('/echo'));
      request.headers.set('content-type', 'text/plain');
      request.write('partial');
      request.abort();
      expect(
        [for (final e in h.events) e.stage],
        [NetworkStage.before, NetworkStage.abort],
      );
      expect(h.stage(NetworkStage.abort).single.size, 7);
    });

    test(
      'an exchange ends once: no complete after an abort, no abort after a complete',
      () async {
        await observe(h.captured(), 'GET', h.url('/json'));
        expect(h.stage(NetworkStage.abort), isEmpty);
        final request = await h.captured().getUrl(h.url('/json'));
        final response = await request.close();
        await response.drain<void>();
        request.abort();
        expect(h.stage(NetworkStage.abort), isEmpty);
      },
    );
  });

  group('never into the app', () {
    test('a recorder that throws changes nothing the app sees', () async {
      h.recordThrows = true;
      final result = await observe(h.captured(), 'GET', h.url('/json'));
      expect(result.status, 200);
      expect(utf8.decode(result.bytes), '{"ok":true}');
      expect(h.recordCalls, greaterThanOrEqualTo(2));
    });

    test('the controller swallows a recorder that throws', () {
      final controller = HttpCaptureController(
        policy: () => const NetworkPolicy(accepting: true),
        record: (_) => throw StateError('the pipeline broke'),
      );
      expect(
        () => controller.emit(
          BugseeNetworkEvent(
            id: 'a',
            stage: NetworkStage.before,
            method: 'GET',
            url: 'http://x/',
          ),
        ),
        returnsNormally,
      );
    });

    test(
      'a policy that throws leaves the request unwrapped and working',
      () async {
        final controller = HttpCaptureController(
          policy: () => throw StateError('boom'),
          record: (_) => fail('nothing should be recorded'),
        );
        final client = HttpOverrides.runWithHttpOverrides(
          () => HttpClient(),
          BugseeHttpOverrides(controller, null),
        );
        h.clients.add(client);
        final result = await observe(client, 'GET', h.url('/json'));
        expect(result.status, 200);
      },
    );
  });

  group('credentials and secrets in URL-bearing fields', () {
    Uri withUserInfo(String path) =>
        Uri.parse('http://user:pw-SECRET@127.0.0.1:${h.server.port}$path');

    String everything() => [
      for (final e in h.events)
        [
          e.url,
          e.redirectedFrom,
          e.error,
          e.errorDescription,
          ...e.headers.entries.map((x) => '${x.key}: ${x.value}'),
        ].join(' | '),
    ].join('\n');

    test(
      'userinfo is stripped from every URL field of a plain exchange',
      () async {
        await observe(h.captured(), 'GET', withUserInfo('/json?a=1'));
        expect(h.events, hasLength(2));
        expect(everything(), isNot(contains('pw-SECRET')));
        expect(everything(), isNot(contains('user:')));
        expect(h.events[0].url, h.url('/json?a=1').toString());
      },
    );

    test(
      'also through a redirect chain: hops, final URL and redirectedFrom',
      () async {
        await observe(h.captured(), 'GET', withUserInfo('/r1'));
        expect(h.stage(NetworkStage.redirect), hasLength(2));
        expect(
          h.stage(NetworkStage.complete).single.redirectedFrom,
          h.url('/r1').toString(),
        );
        expect(everything(), isNot(contains('pw-SECRET')));
      },
    );

    test('and through a manual redirect', () async {
      final request = await h.captured().getUrl(withUserInfo('/r1'));
      request.followRedirects = false;
      final first = await request.close();
      await first.drain<void>();
      await (await first.redirect()).drain<void>();
      expect(h.events.length, greaterThanOrEqualTo(4));
      expect(everything(), isNot(contains('pw-SECRET')));
    });

    test('and from an error text, short and long', () async {
      final harness = await Harness.start((request) async {
        (await request.response.detachSocket()).destroy();
      });
      addTearDown(harness.close);
      try {
        final request = await harness.captured().getUrl(
          Uri.parse(
            'http://user:pw-SECRET@127.0.0.1:${harness.server.port}/p?token=QSECRET',
          ),
        );
        await (await request.close()).drain<void>();
      } catch (_) {}
      final failed = harness.stage(NetworkStage.error).single;
      for (final text in [
        failed.error!,
        failed.errorDescription!,
        failed.url,
      ]) {
        expect(text, isNot(contains('pw-SECRET')));
      }
      expect(failed.error, isNot(contains('QSECRET')));
      expect(failed.errorDescription, isNot(contains('QSECRET')));
    });

    test('a connection failure with userinfo in the URL', () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close(force: true);
      try {
        await h.captured().getUrl(
          Uri.parse('http://user:pw-SECRET@127.0.0.1:$port/x'),
        );
      } catch (_) {}
      expect(everything(), isNot(contains('pw-SECRET')));
      expect(h.stage(NetworkStage.error), hasLength(1));
    });

    test(
      'URL-valued headers lose userinfo and query values, others are as sent',
      () async {
        await observe(
          h.captured(),
          'GET',
          h.url('/loc'),
          headers: {'referer': 'http://u:p@h.example/p?k=v', 'x-note': 'a?b=c'},
        );
        final before = h.stage(NetworkStage.before).single;
        expect(before.headers['referer'], 'http://h.example/p?k=<redacted>');
        expect(before.headers['x-note'], 'a?b=c');
        final complete = h.stage(NetworkStage.complete).single;
        expect(
          complete.headers['location'],
          '/final?token=<redacted>&x=<redacted>',
        );
        expect(
          complete.headers['content-location'],
          'http://h.example/x?a=<redacted>',
        );
        expect(complete.headers['refresh'], '0; url=/n?s=<redacted>');
        expect(everything(), isNot(contains('abc')));
        expect(everything(), isNot(contains('u:p')));
      },
    );
  });

  group('the policy', () {
    test(
      'not accepting: nothing is recorded and the request is not even wrapped',
      () async {
        h.policy = NetworkPolicy.off;
        final request = await h.captured().getUrl(h.url('/json'));
        expect(request, isNot(isA<CapturedRequest>()));
        await (await request.close()).drain<void>();
        expect(h.events, isEmpty);
      },
    );

    test(
      'a request that began while accepting is recorded to its end',
      () async {
        final request = await h.captured().getUrl(h.url('/json'));
        expect(request, isA<CapturedRequest>());
        h.policy = NetworkPolicy.off;
        await (await request.close()).drain<void>();
        expect(h.stage(NetworkStage.complete), hasLength(1));
      },
    );

    test(
      'a request that began while not accepting is never recorded',
      () async {
        h.policy = NetworkPolicy.off;
        final request = await h.captured().getUrl(h.url('/json'));
        h.policy = const NetworkPolicy(accepting: true);
        await (await request.close()).drain<void>();
        expect(h.events, isEmpty);
      },
    );

    test('Bugsee\'s own endpoint is never recorded', () async {
      h.policy = const NetworkPolicy(accepting: true, ownHosts: {'127.0.0.1'});
      await observe(h.captured(), 'GET', h.url('/json'));
      expect(h.events, isEmpty);
    });

    test(
      'Bugsee\'s own endpoint failing to connect is not recorded either',
      () async {
        final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final port = closed.port;
        await closed.close(force: true);
        h.policy = const NetworkPolicy(
          accepting: true,
          ownHosts: {'127.0.0.1'},
        );
        await expectLater(
          h.captured().getUrl(Uri.parse('http://127.0.0.1:$port/')),
          throwsA(isA<SocketException>()),
        );
        expect(h.events, isEmpty);
      },
    );

    test(
      'own-traffic matching is by host: bugsee.com and below, the configured host, nothing else',
      () {
        const policy = NetworkPolicy(
          accepting: true,
          ownHosts: {'bugsee.internal.example'},
        );
        expect(
          policy.isOwnTraffic(Uri.parse('https://api.bugsee.com/v2/apps')),
          isTrue,
        );
        expect(policy.isOwnTraffic(Uri.parse('https://BUGSEE.com/')), isTrue);
        expect(
          policy.isOwnTraffic(Uri.parse('https://a.b.bugsee.com:8443/x')),
          isTrue,
        );
        expect(
          policy.isOwnTraffic(Uri.parse('https://bugsee.internal.example/v2')),
          isTrue,
        );
        expect(
          policy.isOwnTraffic(Uri.parse('https://notbugsee.com/')),
          isFalse,
        );
        expect(
          policy.isOwnTraffic(Uri.parse('https://bugsee.com.evil.example/')),
          isFalse,
        );
        expect(
          policy.isOwnTraffic(Uri.parse('https://example.com/bugsee.com')),
          isFalse,
        );
        expect(policy.isOwnTraffic(Uri.parse('/relative')), isFalse);
        // A trailing dot is the same host; userinfo does not make a host.
        expect(policy.isOwnTraffic(Uri.parse('https://bugsee.com./')), isTrue);
        expect(
          policy.isOwnTraffic(Uri.parse('https://API.Bugsee.COM../v2')),
          isTrue,
        );
        expect(
          policy.isOwnTraffic(Uri.parse('https://bugsee.com@evil.example/')),
          isFalse,
        );
        expect(
          policy.isOwnTraffic(
            Uri.parse('https://evil.example@api.bugsee.com/'),
          ),
          isTrue,
        );
        expect(
          policy.isOwnTraffic(
            Uri.parse('https://bugsee.com:8443@evil.example/'),
          ),
          isFalse,
        );
        expect(
          policy.isOwnTraffic(Uri.parse('https://xn--bugsee-9ua.com/')),
          isFalse,
        );
      },
    );
  });

  group('chained to the app\'s own overrides', () {
    test(
      'the client is made by the previous overrides, whose settings stay',
      () async {
        final previous = _RecordingOverrides();
        final client = h.captured(previous: previous) as CapturingHttpClient;
        expect(previous.created, 1);
        expect(identical(client.inner, previous.lastClient), isTrue);
        // What the previous overrides configured is still there, read through the wrapper.
        expect(client.connectionTimeout, const Duration(seconds: 7));
        expect(client.idleTimeout, const Duration(seconds: 3));
        expect((await observe(client, 'GET', h.url('/json'))).status, 200);
        expect(h.stage(NetworkStage.complete), hasLength(1));
      },
    );

    test('proxy resolution is the previous overrides\'', () {
      final previous = _RecordingOverrides()..proxy = 'PROXY corp:3128';
      final overrides = BugseeHttpOverrides(h.controller, previous);
      expect(
        overrides.findProxyFromEnvironment(Uri.parse('https://x/'), null),
        'PROXY corp:3128',
      );
      expect(previous.proxyAsked, 1);
      // And through the platform entry point, once installed in a zone.
      final viaZone = HttpOverrides.runWithHttpOverrides(
        () => HttpClient.findProxyFromEnvironment(Uri.parse('https://x/')),
        overrides,
      );
      expect(viaZone, 'PROXY corp:3128');
    });

    test('with nothing before it the platform default answers', () {
      final overrides = BugseeHttpOverrides(h.controller, null);
      expect(
        overrides.findProxyFromEnvironment(Uri.parse('http://127.0.0.1/'), {}),
        'DIRECT',
      );
    });

    test(
      'the app\'s own settings on the wrapped client reach the real one',
      () async {
        final client = h.captured();
        var proxyAsked = false;
        client.findProxy = (uri) {
          proxyAsked = true;
          return 'DIRECT';
        };
        var certificateAsked = false;
        client.badCertificateCallback = (c, host, port) {
          certificateAsked = true;
          return true;
        };
        client.userAgent = 'my-agent';
        client.autoUncompress = false;
        client.connectionTimeout = const Duration(seconds: 9);
        client.idleTimeout = const Duration(seconds: 4);
        client.maxConnectionsPerHost = 2;
        expect(client.userAgent, 'my-agent');
        expect(client.autoUncompress, isFalse);
        expect(client.connectionTimeout, const Duration(seconds: 9));
        expect(client.idleTimeout, const Duration(seconds: 4));
        expect(client.maxConnectionsPerHost, 2);
        await observe(client, 'GET', h.url('/json'));
        expect(proxyAsked, isTrue);
        expect(
          certificateAsked,
          isFalse,
          reason: 'plain http: no certificate to check',
        );
        expect(
          h.stage(NetworkStage.before).single.headers['user-agent'],
          'my-agent',
        );
      },
    );

    test(
      'a layer further down that already captures is not wrapped twice',
      () async {
        final inner = BugseeHttpOverrides(h.controller, null);
        final outer = BugseeHttpOverrides(h.controller, inner);
        final client = HttpOverrides.runWithHttpOverrides(
          () => HttpClient(),
          outer,
        );
        h.clients.add(client);
        expect(client, isA<CapturingHttpClient>());
        expect(
          (client as CapturingHttpClient).inner,
          isNot(isA<CapturingHttpClient>()),
        );
        await observe(client, 'GET', h.url('/json'));
        expect(h.stage(NetworkStage.before), hasLength(1));
      },
    );

    test(
      'a client made while inactive is not wrapped, and existing ones go quiet',
      () async {
        final client = h.captured();
        h.controller.active = false;
        await observe(client, 'GET', h.url('/json'));
        expect(h.events, isEmpty);
        final fresh = h.captured();
        expect(fresh, isNot(isA<CapturingHttpClient>()));
      },
    );
  });

  group('WebSocket', () {
    test(
      'the handshake is an exchange (101, no body) and the socket still works',
      () async {
        final ws = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => ws.close(force: true));
        ws.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          socket.listen((message) => socket.add('echo:$message'));
        });
        final client = h.captured();
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:${ws.port}/chat',
          customClient: client,
        );
        socket.add('hi');
        expect(await socket.first, 'echo:hi');
        await socket.close();
        final before = h.stage(NetworkStage.before).single;
        expect(before.headers['upgrade'], 'websocket');
        final complete = h.stage(NetworkStage.complete).single;
        expect(complete.statusCode, 101);
        expect(complete.body, isNull);
        expect(complete.noBodyReason, isNull);
      },
    );
  });

  test(
    'the proxy and certificate settings of a client are all forwarded (HttpClient has no member this wrapper skips)',
    () {
      // A compile-time guard is the real one (`CapturingHttpClient implements HttpClient` without
      // noSuchMethod): this exercises the setters that cannot be read back.
      final client = h.captured();
      client.addCredentials(
        h.url('/'),
        'realm',
        HttpClientBasicCredentials('u', 'p'),
      );
      client.addProxyCredentials(
        'proxy',
        3128,
        'realm',
        HttpClientBasicCredentials('u', 'p'),
      );
      client.authenticate = (url, scheme, realm) async => true;
      client.authenticateProxy = (host, port, scheme, realm) async => true;
      client.keyLog = (line) {};
      client.connectionFactory = null;
      client.close();
    },
  );
}

class _RecordingOverrides extends HttpOverrides {
  int created = 0;
  int proxyAsked = 0;
  String proxy = 'DIRECT';
  HttpClient? lastClient;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created++;
    final client = super.createHttpClient(context)
      ..connectionTimeout = const Duration(seconds: 7)
      ..idleTimeout = const Duration(seconds: 3);
    return lastClient = client;
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    proxyAsked++;
    return proxy;
  }
}
