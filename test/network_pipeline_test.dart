// The queue between the capture and the bridge: bounded, ordered, filtered, fail closed.
import 'dart:async';

import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/network/network_event.dart';
import 'package:bugsee_flutter/src/network/network_pipeline.dart';
import 'package:bugsee_flutter/src/network/network_policy.dart';
import 'package:flutter_test/flutter_test.dart';

BugseeNetworkEvent event(
  String id, {
  NetworkStage stage = NetworkStage.before,
  String url = 'https://example.com/a',
  Map<String, String>? headers,
  String? body,
  int status = 0,
}) => BugseeNetworkEvent(
  id: id,
  stage: stage,
  method: 'GET',
  url: url,
  headers: headers,
  body: body,
  statusCode: status,
  size: 3,
);

class Rig {
  Rig({
    this.accepting = true,
    int maxQueuedEvents = 512,
    int maxQueuedBytes = 8 * 1024 * 1024,
    int maxBatchEvents = 32,
    int maxBatchBytes = 512 * 1024,
  }) {
    pipeline = NetworkPipeline(
      send: (batch) async {
        sendStarts++;
        if (inFlight > 0) overlap = true;
        inFlight++;
        batches.add(batch);
        try {
          final gate = this.gate;
          if (gate != null) await gate.future;
          if (sendThrows) throw StateError('bridge down');
          return handedOverride ?? batch.length;
        } finally {
          inFlight--;
        }
      },
      policy: () => NetworkPolicy(accepting: accepting),
      maxQueuedEvents: maxQueuedEvents,
      maxQueuedBytes: maxQueuedBytes,
      maxBatchEvents: maxBatchEvents,
      maxBatchBytes: maxBatchBytes,
      warn: warnings.add,
    );
  }

  late final NetworkPipeline pipeline;
  bool accepting;
  final List<List<NetworkEventMessage>> batches = [];
  final List<String> warnings = [];
  Completer<void>? gate;
  bool sendThrows = false;
  int? handedOverride;
  int inFlight = 0;
  int sendStarts = 0;
  bool overlap = false;

  List<NetworkEventMessage> get sent => [for (final b in batches) ...b];
}

void main() {
  test(
    'submit is synchronous and never blocks: nothing is sent before the caller yields',
    () async {
      final rig = Rig();
      rig.pipeline.submit(event('1'));
      expect(rig.sendStarts, 0);
      expect(rig.pipeline.queued, 1);
      await rig.pipeline.flush();
      expect(rig.sent.map((m) => m.id), ['1']);
    },
  );

  test(
    'events reach the bridge in the order they were captured, across batches',
    () async {
      final rig = Rig(maxBatchEvents: 3);
      for (var i = 0; i < 10; i++) {
        rig.pipeline.submit(event('$i'));
      }
      await rig.pipeline.flush();
      expect(rig.sent.map((m) => m.id), [for (var i = 0; i < 10; i++) '$i']);
      expect(rig.batches.map((b) => b.length), [3, 3, 3, 1]);
    },
  );

  test('one batch is in flight at a time', () async {
    final rig = Rig(maxBatchEvents: 2);
    rig.gate = Completer<void>();
    for (var i = 0; i < 6; i++) {
      rig.pipeline.submit(event('$i'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rig.sendStarts, 1, reason: 'the second batch waits for the first');
    rig.gate!.complete();
    await rig.pipeline.flush();
    expect(rig.overlap, isFalse);
    expect(rig.sent, hasLength(6));
  });

  group('bounded', () {
    test(
      'a full queue drops the new events and counts them, without ever waiting',
      () async {
        final rig = Rig(maxQueuedEvents: 5, maxBatchEvents: 1);
        rig.gate = Completer<void>(); // the platform thread is busy
        for (var i = 0; i < 1000; i++) {
          rig.pipeline.submit(event('$i'));
        }
        expect(rig.pipeline.queued, 5);
        expect(rig.pipeline.stats.captured, 5);
        expect(rig.pipeline.stats.droppedQueueFull, 995);
        expect(
          rig.warnings.where((w) => w.contains('queue is full')),
          hasLength(1),
          reason: 'reported once',
        );
        rig.gate!.complete();
        await rig.pipeline.flush();
        expect(rig.sent.map((m) => m.id), ['0', '1', '2', '3', '4']);
      },
    );

    test('the byte budget bounds it too: a few large bodies fill it', () async {
      final rig = Rig(maxQueuedBytes: 3000);
      rig.gate = Completer<void>();
      final body = 'x' * 1000;
      for (var i = 0; i < 10; i++) {
        rig.pipeline.submit(event('$i', body: body));
      }
      expect(rig.pipeline.stats.captured, lessThan(10));
      expect(rig.pipeline.stats.droppedQueueFull, greaterThan(0));
      expect(
        rig.pipeline.stats.captured + rig.pipeline.stats.droppedQueueFull,
        10,
      );
      rig.gate!.complete();
      await rig.pipeline.flush();
    });

    test('what left the queue frees its byte budget too', () async {
      final rig = Rig(maxQueuedBytes: 2500);
      for (var i = 0; i < 4; i++) {
        rig.pipeline.submit(event('$i', body: 'x' * 1000));
        await rig.pipeline.flush();
      }
      expect(rig.pipeline.stats.droppedQueueFull, 0);
      expect(rig.sent, hasLength(4));
    });

    test('what left the queue frees its room', () async {
      final rig = Rig(maxQueuedEvents: 2, maxBatchEvents: 1);
      rig.pipeline.submit(event('a'));
      rig.pipeline.submit(event('b'));
      await rig.pipeline.flush();
      rig.pipeline.submit(event('c'));
      rig.pipeline.submit(event('d'));
      await rig.pipeline.flush();
      expect(rig.pipeline.stats.droppedQueueFull, 0);
      expect(rig.sent, hasLength(4));
    });
  });

  group('the policy', () {
    test('nothing is queued while the SDK does not accept', () async {
      final rig = Rig(accepting: false);
      rig.pipeline.submit(event('1'));
      expect(rig.pipeline.queued, 0);
      expect(rig.pipeline.stats.droppedNotAccepting, 1);
      await rig.pipeline.flush();
      expect(rig.sent, isEmpty);
    });

    test(
      'what was queued when the SDK stopped is dropped, not handed over',
      () async {
        final rig = Rig();
        rig.pipeline.submit(event('1'));
        rig.pipeline.submit(event('2'));
        rig.accepting = false;
        await rig.pipeline.flush();
        expect(rig.sent, isEmpty);
        expect(rig.pipeline.stats.droppedNotAccepting, 2);
      },
    );
  });

  group('the filter', () {
    test('null drops the event, counted, and the rest go on', () async {
      final rig = Rig();
      rig.pipeline.setFilter(
        (e) => e.id == 'drop' ? null : e,
        const Duration(seconds: 1),
      );
      rig.pipeline.submit(event('a'));
      rig.pipeline.submit(event('drop'));
      rig.pipeline.submit(event('b'));
      await rig.pipeline.flush();
      expect(rig.sent.map((m) => m.id), ['a', 'b']);
      expect(rig.pipeline.stats.droppedByFilter, 1);
    });

    test(
      'redaction in place reaches the bridge, the raw value does not',
      () async {
        final rig = Rig();
        rig.pipeline.setFilter((e) {
          e.headers.remove('authorization');
          e.headers['x-seen'] = '1';
          e.url = e.url.replaceAll('secret', 'REDACTED');
          e.body = null;
          e.noBodyReason = NoBodyReason.cantReadData;
          e.statusText = 'redacted';
          return e;
        }, const Duration(seconds: 1));
        rig.pipeline.submit(
          event(
            'a',
            url: 'https://example.com/p?t=secret',
            headers: {'authorization': 'Bearer SECRET', 'accept': '*/*'},
            body: 'password=hunter2',
          ),
        );
        await rig.pipeline.flush();
        final m = rig.sent.single;
        expect(m.headers, {'accept': '*/*', 'x-seen': '1'});
        expect(m.url, 'https://example.com/p?t=REDACTED');
        expect(m.body, isNull);
        expect(m.noBodyReason, 'cant_read_data');
        expect(m.statusText, 'redacted');
      },
    );

    test('a copy is returned: also fine', () async {
      final rig = Rig();
      rig.pipeline.setFilter((e) {
        final copy = e.copy()..headers.clear();
        return copy;
      }, const Duration(seconds: 1));
      rig.pipeline.submit(event('a', headers: {'cookie': 'c'}));
      await rig.pipeline.flush();
      expect(rig.sent.single.headers, isEmpty);
    });

    test(
      'the filter is handed a copy: it cannot reach what the capture holds',
      () async {
        final rig = Rig();
        final original = event('a', headers: {'cookie': 'c'});
        rig.pipeline.setFilter((e) {
          e.headers.clear();
          return null;
        }, const Duration(seconds: 1));
        rig.pipeline.submit(original);
        await rig.pipeline.flush();
        expect(original.headers, {'cookie': 'c'});
      },
    );

    test(
      'id, stage, method, status and size are the exchange\'s: the filter cannot change them',
      () async {
        final rig = Rig();
        rig.pipeline.setFilter(
          (e) => BugseeNetworkEvent(
            id: 'forged',
            stage: NetworkStage.abort,
            method: 'DELETE',
            url: e.url,
            statusCode: 599,
            size: 12345,
          ),
          const Duration(seconds: 1),
        );
        rig.pipeline.submit(
          event('real', stage: NetworkStage.complete, status: 200),
        );
        await rig.pipeline.flush();
        final m = rig.sent.single;
        expect(m.id, 'real');
        expect(m.stage, 'complete');
        expect(m.method, 'GET');
        expect(m.statusCode, 200);
        expect(m.size, 3);
      },
    );

    test(
      'a filter that throws drops that event (fail closed), warns once, and the rest go on',
      () async {
        final rig = Rig();
        rig.pipeline.setFilter((e) {
          if (e.id != 'ok') throw StateError('bug in the filter');
          return e;
        }, const Duration(seconds: 1));
        rig.pipeline.submit(event('bad1'));
        rig.pipeline.submit(event('ok'));
        rig.pipeline.submit(event('bad2'));
        await rig.pipeline.flush();
        expect(rig.sent.map((m) => m.id), ['ok']);
        expect(rig.pipeline.stats.filterFailures, 2);
        expect(
          rig.warnings.where((w) => w.contains('filter failed')),
          hasLength(1),
        );
      },
    );

    test('an async filter that throws fails closed too', () async {
      final rig = Rig();
      rig.pipeline.setFilter(
        (e) async => throw StateError('async bug'),
        const Duration(seconds: 1),
      );
      rig.pipeline.submit(event('a'));
      await rig.pipeline.flush();
      expect(rig.sent, isEmpty);
      expect(rig.pipeline.stats.filterFailures, 1);
    });

    test(
      'a filter that never answers drops the event after the timeout',
      () async {
        final rig = Rig();
        rig.pipeline.setFilter(
          (e) => Completer<BugseeNetworkEvent?>().future,
          const Duration(milliseconds: 50),
        );
        final started = DateTime.now();
        rig.pipeline.submit(event('a'));
        await rig.pipeline.flush();
        expect(
          DateTime.now().difference(started),
          greaterThanOrEqualTo(const Duration(milliseconds: 45)),
        );
        expect(rig.sent, isEmpty);
        expect(rig.pipeline.stats.filterFailures, 1);
      },
    );

    test(
      'a hung filter never holds the app: submit stays instant and the queue stays bounded',
      () async {
        final rig = Rig(maxQueuedEvents: 10);
        rig.pipeline.setFilter(
          (e) => Completer<BugseeNetworkEvent?>().future,
          const Duration(seconds: 30),
        );
        final watch = Stopwatch()..start();
        for (var i = 0; i < 500; i++) {
          rig.pipeline.submit(event('$i'));
        }
        expect(watch.elapsedMilliseconds, lessThan(200));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(rig.pipeline.stats.captured, 10);
        expect(rig.pipeline.stats.droppedQueueFull, 490);
      },
    );

    test('an async filter keeps the order', () async {
      final rig = Rig();
      rig.pipeline.setFilter((e) async {
        await Future<void>.delayed(
          Duration(milliseconds: e.id == 'slow' ? 30 : 1),
        );
        return e;
      }, const Duration(seconds: 1));
      rig.pipeline.submit(event('slow'));
      rig.pipeline.submit(event('fast'));
      await rig.pipeline.flush();
      expect(rig.sent.map((m) => m.id), ['slow', 'fast']);
    });

    test('a wrong return type is a failure, not a pass-through', () async {
      final rig = Rig();
      rig.pipeline.setFilter(
        (e) => 'oops' as dynamic,
        const Duration(seconds: 1),
      );
      rig.pipeline.submit(event('a'));
      await rig.pipeline.flush();
      expect(rig.sent, isEmpty);
      expect(rig.pipeline.stats.filterFailures, 1);
    });

    test('a filter that blanks the URL drops the event', () async {
      final rig = Rig();
      rig.pipeline.setFilter((e) => e..url = '', const Duration(seconds: 1));
      rig.pipeline.submit(event('a'));
      await rig.pipeline.flush();
      expect(rig.sent, isEmpty);
      expect(rig.pipeline.stats.droppedByFilter, 1);
    });

    test(
      'with no filter every event passes, and removing it removes it',
      () async {
        final rig = Rig();
        rig.pipeline.setFilter((e) => null, const Duration(seconds: 1));
        rig.pipeline.setFilter(null, const Duration(seconds: 1));
        rig.pipeline.submit(event('a'));
        await rig.pipeline.flush();
        expect(rig.sent, hasLength(1));
        expect(rig.pipeline.filter, isNull);
      },
    );

    test(
      'the filter is not called for an event the SDK would not take',
      () async {
        final rig = Rig();
        var calls = 0;
        rig.pipeline.setFilter((e) {
          calls++;
          return e;
        }, const Duration(seconds: 1));
        rig.pipeline.submit(event('a'));
        rig.accepting = false;
        await rig.pipeline.flush();
        expect(calls, 0);
      },
    );
  });

  group('the message', () {
    test('carries everything, with the age from the monotonic clock', () async {
      final rig = Rig();
      final e = BugseeNetworkEvent(
        id: 'a',
        stage: NetworkStage.complete,
        method: 'POST',
        url: 'https://example.com/x',
        headers: {'a': 'b'},
        body: 'text',
        size: 4,
        statusCode: 201,
        statusText: 'Created',
        error: 'short',
        errorDescription: 'long',
        redirectedFrom: 'https://example.com/old',
        timings: {'total': 5.5},
      );
      // The event waits behind a batch the platform thread is still busy with.
      rig.gate = Completer<void>();
      rig.pipeline.submit(event('blocker'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      rig.pipeline.submit(e);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      rig.gate!.complete();
      await rig.pipeline.flush();
      final m = rig.sent.singleWhere((m) => m.id == 'a');
      expect(m.id, 'a');
      expect(m.stage, 'complete');
      expect(m.mechanism, NetworkWire.mechanism);
      expect(m.method, 'POST');
      expect(m.url, 'https://example.com/x');
      expect(m.headers, {'a': 'b'});
      expect(m.body, 'text');
      expect(m.noBodyReason, isNull);
      expect(m.size, 4);
      expect(m.statusCode, 201);
      expect(m.statusText, 'Created');
      expect(m.errorShortMessage, 'short');
      expect(m.errorDescription, 'long');
      expect(m.redirectedFromUrl, 'https://example.com/old');
      expect(m.timings, {'total': 5.5});
      expect(m.ageMs, greaterThanOrEqualTo(35));
      expect(m.ageMs, lessThan(5000));
    });

    test('a body and a reason for its absence never go together', () async {
      final rig = Rig();
      rig.pipeline.setFilter(
        (e) => e
          ..body = 'kept'
          ..noBodyReason = NoBodyReason.sizeTooLarge,
        const Duration(seconds: 1),
      );
      rig.pipeline.submit(event('a'));
      await rig.pipeline.flush();
      expect(rig.sent.single.body, 'kept');
      expect(rig.sent.single.noBodyReason, isNull);
    });

    test('the headers sent are a copy', () async {
      final rig = Rig();
      final headers = {'a': 'b'};
      rig.pipeline.submit(event('a', headers: headers));
      await rig.pipeline.flush();
      headers['a'] = 'changed';
      expect(rig.sent.single.headers, {'a': 'b'});
    });
  });

  group('the message stamps', () {
    test(
      'the age is taken when the batch is sent, not when the event was prepared',
      () async {
        final rig = Rig();
        // Three events through a slow async filter share one batch: the first is ready long before
        // the batch leaves.
        rig.pipeline.setFilter((e) async {
          await Future<void>.delayed(const Duration(milliseconds: 70));
          return e;
        }, const Duration(seconds: 2));
        for (var i = 0; i < 3; i++) {
          rig.pipeline.submit(event('$i'));
        }
        await rig.pipeline.flush();
        expect(rig.batches, hasLength(1));
        final first = rig.sent.first;
        expect(first.id, '0');
        expect(first.ageMs, greaterThanOrEqualTo(190));
      },
    );

    test('a URL leaves without userinfo whatever a filter put in it', () async {
      final rig = Rig();
      rig.pipeline.setFilter(
        (e) => e
          ..url = 'http://user:pw@host/p'
          ..redirectedFrom = 'http://u2:p2@host/old',
        const Duration(seconds: 1),
      );
      rig.pipeline.submit(event('a'));
      await rig.pipeline.flush();
      expect(rig.sent.single.url, 'http://host/p');
      expect(rig.sent.single.redirectedFromUrl, 'http://host/old');
    });
  });

  group('the bridge', () {
    test(
      'a failing send drops that batch, counts it, warns once, and the next batch goes',
      () async {
        final rig = Rig(maxBatchEvents: 1);
        rig.sendThrows = true;
        rig.pipeline.submit(event('a'));
        await rig.pipeline.flush();
        rig.pipeline.submit(event('b'));
        await rig.pipeline.flush();
        expect(rig.pipeline.stats.sendFailures, 2);
        expect(
          rig.warnings.where((w) => w.contains('could not be handed')),
          hasLength(1),
        );
        rig.sendThrows = false;
        rig.pipeline.submit(event('c'));
        await rig.pipeline.flush();
        expect(rig.pipeline.stats.submittedToSdk, 1);
      },
    );

    test(
      'the SDK handing over fewer than were sent is counted as refused',
      () async {
        final rig = Rig();
        rig.handedOverride = 1;
        rig.pipeline.submit(event('a'));
        rig.pipeline.submit(event('b'));
        rig.pipeline.submit(event('c'));
        await rig.pipeline.flush();
        expect(rig.pipeline.stats.submittedToSdk, 1);
        expect(rig.pipeline.stats.refusedByNative, 2);
      },
    );
  });

  test('submit never throws, even when the policy does', () {
    final pipeline = NetworkPipeline(
      send: (_) async => 0,
      policy: () => throw StateError('policy broke'),
    );
    expect(() => pipeline.submit(event('a')), returnsNormally);
  });
}
