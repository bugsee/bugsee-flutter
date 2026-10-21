// What the capture does to a response stream, observed with a stream the test controls (no
// socket): pause, resume, cancel and errors reach the real response, data is forwarded in the
// same turn, and each exchange ends exactly once.
import 'dart:async';
import 'dart:io';

import 'package:bugsee_flutter/src/network/http_capture.dart';
import 'package:bugsee_flutter/src/network/network_event.dart';
import 'package:bugsee_flutter/src/network/network_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_http.dart';

void main() {
  late List<BugseeNetworkEvent> events;
  late HttpCaptureController controller;

  setUp(() {
    events = [];
    controller = HttpCaptureController(
      policy: () => const NetworkPolicy(accepting: true),
      record: events.add,
    );
  });

  Future<(FakeRig, HttpClientResponse)> open({
    String? contentType = 'text/plain',
  }) async {
    final rig = await FakeRig.create(controller, contentType: contentType);
    final request = await rig.client.getUrl(Uri.parse('http://example.test/x'));
    final response = await request.close();
    return (rig, response);
  }

  List<NetworkStage> stages() => [for (final e in events) e.stage];

  test(
    'nothing is subscribed to the real response until the app listens',
    () async {
      final (rig, _) = await open();
      expect(rig.response.listens, 0);
      expect(stages(), [NetworkStage.before]);
    },
  );

  test(
    'the app listening subscribes once, and its cancel reaches the real response',
    () async {
      final (rig, response) = await open();
      final sub = response.listen((_) {});
      expect(rig.response.listens, 1);
      expect(rig.response.cancels, 0);
      await sub.cancel();
      expect(rig.response.cancels, 1);
    },
  );

  test('pause and resume reach the real response, once each', () async {
    final (rig, response) = await open();
    final sub = response.listen((_) {});
    sub.pause();
    expect(rig.response.data.isPaused, isTrue);
    expect(rig.response.pauses, 1);
    sub.resume();
    expect(rig.response.data.isPaused, isFalse);
    expect(rig.response.resumes, 1);
    await sub.cancel();
  });

  test('data is forwarded in the same turn it arrives, unchanged', () async {
    final (rig, response) = await open();
    final seen = <List<int>>[];
    response.listen(seen.add);
    final chunk = [1, 2, 3];
    rig.response.data.add(chunk);
    // No await in between: a deferred forward would not be here yet.
    expect(seen, hasLength(1));
    expect(
      identical(seen.single, chunk),
      isTrue,
      reason: 'the very chunk, not a copy',
    );
  });

  test(
    'an error is forwarded with its stack, ends the exchange as an error, and nothing completes after',
    () async {
      final (rig, response) = await open();
      final errors = <Object>[];
      final stacks = <StackTrace>[];
      final done = Completer<void>();
      response.listen(
        (_) {},
        onError: (Object e, StackTrace s) {
          errors.add(e);
          stacks.add(s);
        },
        onDone: done.complete,
      );
      final stack = StackTrace.current;
      rig.response.data.addError(const SocketException('reset by peer'), stack);
      await rig.response.data.close();
      await done.future;
      expect(errors.single, isA<SocketException>());
      expect(stacks.single.toString(), stack.toString());
      expect(stages(), [NetworkStage.before, NetworkStage.error]);
      expect(events.last.error, startsWith('SocketException'));
    },
  );

  test('cancelOnError cancels the real response too', () async {
    final (rig, response) = await open();
    response.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
    rig.response.data.addError(StateError('x'));
    await Future<void>.delayed(Duration.zero);
    expect(rig.response.cancels, 1);
  });

  test('done completes the exchange once, with every chunk', () async {
    final (rig, response) = await open();
    final done = Completer<void>();
    response.listen((_) {}, onDone: done.complete);
    rig.response.data.add([104, 105]);
    rig.response.data.add([33]);
    await rig.response.data.close();
    await done.future;
    expect(stages(), [NetworkStage.before, NetworkStage.complete]);
    expect(events.last.body, 'hi!');
    expect(events.last.size, 3);
  });

  test(
    'a cancel after the end is not an abort, and a done after a cancel is not a complete',
    () async {
      final (rig, response) = await open();
      final sub = response.listen((_) {});
      rig.response.data.add([1]);
      await sub.cancel();
      expect(stages(), [NetworkStage.before, NetworkStage.abort]);
      await rig.response.data.close();
      expect(stages(), [
        NetworkStage.before,
        NetworkStage.abort,
      ], reason: 'no complete after an abort');

      final (rig2, response2) = await open();
      final done = Completer<void>();
      final sub2 = response2.listen((_) {}, onDone: done.complete);
      await rig2.response.data.close();
      await done.future;
      await sub2.cancel();
      expect(
        stages().where((s) => s == NetworkStage.abort),
        hasLength(1),
        reason: 'no abort after a complete',
      );
    },
  );

  test(
    'a request that fails to close is an error with the same exception',
    () async {
      final rig = await FakeRig.create(controller);
      final request = await rig.client.getUrl(
        Uri.parse('http://example.test/x'),
      );
      (rig.fake.request).closeFailure = const HttpException(
        'too many redirects',
      );
      await expectLater(request.close(), throwsA(isA<HttpException>()));
      expect(stages(), [NetworkStage.before, NetworkStage.error]);
    },
  );

  test(
    'a request whose done fails is an error with the same exception',
    () async {
      final rig = await FakeRig.create(controller);
      final request = await rig.client.getUrl(
        Uri.parse('http://example.test/x'),
      );
      rig.fake.request.closeFailure = const HttpException('connection lost');
      await expectLater(request.done, throwsA(isA<HttpException>()));
      expect(stages(), [NetworkStage.before, NetworkStage.error]);
    },
  );

  test(
    'uninstalling while an exchange is in flight stops it recording',
    () async {
      final (rig, response) = await open();
      final done = Completer<void>();
      response.listen((_) {}, onDone: done.complete);
      rig.response.data.add([104, 105]);
      controller.active = false;
      rig.response.data.add([33]);
      await rig.response.data.close();
      await done.future;
      expect(stages(), [
        NetworkStage.before,
      ], reason: 'no complete after the uninstall');
    },
  );

  test(
    'an exchange in flight at an uninstall does not resume after a reinstall',
    () async {
      final (rig, response) = await open();
      final done = Completer<void>();
      response.listen((_) {}, onDone: done.complete);
      // Uninstalled, then installed again, while the exchange was in flight.
      controller.active = false;
      controller.generation++;
      controller.active = true;
      rig.response.data.add([1]);
      await rig.response.data.close();
      await done.future;
      expect(stages(), [NetworkStage.before]);
      // An exchange that starts after the reinstall records.
      final (rig2, response2) = await open();
      final done2 = Completer<void>();
      response2.listen((_) {}, onDone: done2.complete);
      await rig2.response.data.close();
      await done2.future;
      expect(stages().where((s) => s == NetworkStage.complete), hasLength(1));
    },
  );

  test('a cancel after the uninstall records no abort either', () async {
    final (rig, response) = await open();
    final sub = response.listen((_) {});
    controller.active = false;
    await sub.cancel();
    expect(stages(), [NetworkStage.before]);
    expect(
      rig.response.cancels,
      1,
      reason: 'the app\'s cancel still reaches the response',
    );
  });

  test('closing twice answers the same future and sends one before', () async {
    final rig = await FakeRig.create(controller);
    final request = await rig.client.getUrl(Uri.parse('http://example.test/x'));
    final a = request.close();
    final b = request.close();
    expect(identical(a, b), isTrue);
    await a;
    expect(stages(), [NetworkStage.before]);
  });

  test('the request headers are read when the request is closed', () async {
    final rig = await FakeRig.create(controller);
    final request = await rig.client.getUrl(Uri.parse('http://example.test/x'));
    request.headers.set('x-late', 'set just before close');
    await request.close();
    expect(events.first.headers['x-late'], 'set just before close');
  });
}
