// ignore_for_file: avoid_print
// The log pipeline on its own: the line cap, the rate limit, the bounded queue, the filter that fails
// closed, batches. No bridge: `send` records.
import 'dart:async';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:bugsee_flutter/src/logs/log_pipeline.dart';
import 'package:bugsee_flutter/src/logs/log_policy.dart';
import 'package:bugsee_flutter/src/logs/log_suppress.dart';
import 'package:flutter_test/flutter_test.dart';

const accepting = LogPolicy(accepting: true);

class Rig {
  Rig({
    this.policy = accepting,
    int maxQueuedLines = 1000,
    int maxQueuedBytes = 2 * 1024 * 1024,
    int maxBatchLines = 64,
    int maxBatchBytes = 128 * 1024,
    LogRateLimiter? limiter,
    int Function()? clock,
  }) {
    pipeline = LogPipeline(
      send: (batch) async {
        batches.add(batch);
        if (sendThrows) throw StateError('bridge down');
        return handedOverride >= 0 ? handedOverride : batch.length;
      },
      policy: () => policy,
      maxQueuedLines: maxQueuedLines,
      maxQueuedBytes: maxQueuedBytes,
      maxBatchLines: maxBatchLines,
      maxBatchBytes: maxBatchBytes,
      limiter: limiter ?? LogRateLimiter(burst: 1 << 20, perSecond: 1 << 20),
      clockMicros: clock,
      warn: warnings.add,
    );
  }

  late final LogPipeline pipeline;
  LogPolicy policy;
  final List<List<LogLineMessage>> batches = [];
  final List<String> warnings = [];
  bool sendThrows = false;
  int handedOverride = -1;

  List<LogLineMessage> get sent => [for (final b in batches) ...b];
  List<String> get texts => [for (final m in sent) m.message];

  void line(String text, [LogLevel level = LogLevel.info, String? tag]) =>
      pipeline.submit(text, level, tag);
}

void main() {
  group('capLine', () {
    test('a line that fits is returned as it is', () {
      final text = 'a' * 4000;
      expect(identical(capLine(text), text), isTrue);
    });

    test('a longer line is cut at the cap and says how much was cut', () {
      final cut = capLine('a' * 4005);
      expect(cut, '${'a' * 4000} ...[truncated 5]');
    });

    test('never cuts between the halves of a surrogate pair', () {
      // 3999 units, then an emoji (two units) straddling the cap.
      final text = '${'a' * 3999}\u{1F600}tail';
      final cut = capLine(text);
      expect(cut.startsWith('a' * 3999), isTrue);
      expect(cut.contains('\u{1F600}'), isFalse);
      expect(cut, '${'a' * 3999} ...[truncated ${text.length - 3999}]');
      expect(cut.codeUnits.where((u) => u >= 0xD800 && u <= 0xDFFF), isEmpty);
    });

    test('a pair that ends exactly at the cap stays whole', () {
      final text = '${'a' * 3998}\u{1F600}x';
      final cut = capLine(text);
      expect(cut.contains('\u{1F600}'), isTrue);
      expect(cut, '${'a' * 3998}\u{1F600} ...[truncated 1]');
    });
  });

  group('the rate limiter', () {
    test('takes the burst, then refuses', () {
      var now = 0;
      final limiter = LogRateLimiter(
        burst: 3,
        perSecond: 10,
        clockMicros: () => now,
      );
      expect(
        [for (var i = 0; i < 5; i++) limiter.tryTake()],
        [true, true, true, false, false],
      );
    });

    test('refills at the rate and never above the burst', () {
      var now = 0;
      final limiter = LogRateLimiter(
        burst: 3,
        perSecond: 10,
        clockMicros: () => now,
      );
      for (var i = 0; i < 3; i++) {
        limiter.tryTake();
      }
      expect(limiter.tryTake(), isFalse);
      now += 100000; // 0.1 s: one token
      expect(limiter.tryTake(), isTrue);
      expect(limiter.tryTake(), isFalse);
      now += 60 * 1000000; // a minute: still only the burst
      expect(
        [for (var i = 0; i < 5; i++) limiter.tryTake()],
        [true, true, true, false, false],
      );
    });
  });

  group('submit', () {
    test('a line is handed over with its level and tag, in order', () async {
      final rig = Rig();
      rig.line('one', LogLevel.warning, 'print');
      rig.line('two', LogLevel.error);
      rig.line('three', LogLevel.verbose, '');
      await rig.pipeline.flush();
      expect(rig.texts, ['one', 'two', 'three']);
      expect([for (final m in rig.sent) m.level], [2, 1, 5]);
      // An empty tag is no tag.
      expect([for (final m in rig.sent) m.tag], ['print', null, null]);
      expect(rig.pipeline.stats.captured, 3);
      expect(rig.pipeline.stats.submittedToSdk, 3);
    });

    test('an empty line is not recorded and not counted', () async {
      final rig = Rig()..line('');
      await rig.pipeline.flush();
      expect(rig.sent, isEmpty);
      expect(rig.pipeline.stats.captured, 0);
    });

    test(
      'nothing is accepted while the policy says no, and it is counted',
      () async {
        final rig = Rig(policy: LogPolicy.off)..line('early');
        await rig.pipeline.flush();
        expect(rig.sent, isEmpty);
        expect(rig.pipeline.stats.droppedNotAccepting, 1);
        expect(rig.pipeline.stats.captured, 0);
      },
    );

    test('a line queued before a stop is not handed over after it', () async {
      final rig = Rig()..line('queued');
      rig.policy = LogPolicy.off;
      await rig.pipeline.flush();
      expect(rig.sent, isEmpty);
      expect(rig.pipeline.stats.droppedNotAccepting, 1);
    });

    test(
      'a line more verbose than capture.logs.level is dropped, equal is kept',
      () async {
        final rig = Rig(
          policy: const LogPolicy(accepting: true, maxLevel: LogLevel.info),
        );
        rig.line('v', LogLevel.verbose);
        rig.line('d', LogLevel.debug);
        rig.line('i', LogLevel.info);
        rig.line('w', LogLevel.warning);
        await rig.pipeline.flush();
        expect(rig.texts, ['i', 'w']);
        expect(rig.pipeline.stats.droppedBelowLevel, 2);
      },
    );

    test(
      'a line over the cap is cut, counted, and the marker survives the queue',
      () async {
        final rig = Rig()..line('x' * 5000);
        await rig.pipeline.flush();
        expect(rig.sent.single.message, endsWith(' ...[truncated 1000]'));
        expect(rig.sent.single.message.length, lessThan(4100));
        expect(rig.pipeline.stats.truncated, 1);
      },
    );

    test(
      'a flood is rate limited and counted, and a warning is printed once',
      () async {
        var now = 0;
        final rig = Rig(
          limiter: LogRateLimiter(
            burst: 10,
            perSecond: 5,
            clockMicros: () => now,
          ),
        );
        for (var i = 0; i < 25; i++) {
          rig.line('l$i');
        }
        await rig.pipeline.flush();
        expect(rig.texts, [for (var i = 0; i < 10; i++) 'l$i']);
        expect(rig.pipeline.stats.droppedRateLimited, 15);
        expect(rig.warnings, hasLength(1));
      },
    );

    test('a full queue drops the NEW line, counts it, warns once', () async {
      final rig = Rig(maxQueuedLines: 3);
      for (var i = 0; i < 6; i++) {
        rig.line('l$i');
      }
      expect(rig.pipeline.queued, 3);
      await rig.pipeline.flush();
      expect(rig.texts, ['l0', 'l1', 'l2']);
      expect(rig.pipeline.stats.droppedQueueFull, 3);
      expect(rig.pipeline.stats.captured, 3);
      expect(rig.warnings, hasLength(1));
    });

    test('the queue is bounded in bytes too', () async {
      final rig = Rig(maxQueuedBytes: 2000);
      for (var i = 0; i < 10; i++) {
        rig.line('y' * 300);
      }
      // 64 + 600 bytes each: three fit in 2000, the fourth does not.
      expect(rig.pipeline.queued, 3);
      expect(rig.pipeline.stats.droppedQueueFull, 7);
      await rig.pipeline.flush();
      expect(rig.sent, hasLength(3));
    });

    test('the queue accepts again once it drained', () async {
      final rig = Rig(maxQueuedLines: 2);
      rig.line('a');
      rig.line('b');
      rig.line('c');
      await rig.pipeline.flush();
      rig.line('d');
      await rig.pipeline.flush();
      expect(rig.texts, ['a', 'b', 'd']);
    });

    test('submit does not run the filter, send, or anything else inline', () {
      var filtered = 0;
      final rig = Rig();
      rig.pipeline.setFilter((e) {
        filtered++;
        return e;
      }, const Duration(seconds: 1));
      rig.line('x');
      expect(filtered, 0);
      expect(rig.batches, isEmpty);
    });

    test('never throws, whatever the policy does', () {
      final pipeline = LogPipeline(
        send: (_) async => 0,
        policy: () => throw StateError('boom'),
        warn: (_) {},
      );
      expect(() => pipeline.submit('x', LogLevel.info, null), returnsNormally);
    });
  });

  group('batches', () {
    test('at most maxBatchLines lines, order kept across batches', () async {
      final rig = Rig(maxBatchLines: 4);
      for (var i = 0; i < 10; i++) {
        rig.line('l$i');
      }
      await rig.pipeline.flush();
      expect([for (final b in rig.batches) b.length], [4, 4, 2]);
      expect(rig.texts, [for (var i = 0; i < 10; i++) 'l$i']);
    });

    test(
      'a batch stops growing once it holds maxBatchBytes of UTF-8',
      () async {
        final rig = Rig(maxBatchBytes: 1000);
        for (var i = 0; i < 6; i++) {
          rig.line('é' * 200); // 400 bytes + the allowance
        }
        await rig.pipeline.flush();
        expect(rig.batches.length, greaterThan(1));
        expect(rig.texts, everyElement('é' * 200));
        expect(rig.sent, hasLength(6));
      },
    );

    test('one batch is in flight at a time', () async {
      var inFlight = 0;
      var peak = 0;
      final pipeline = LogPipeline(
        send: (batch) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
          return batch.length;
        },
        policy: () => accepting,
        maxBatchLines: 2,
        limiter: LogRateLimiter(burst: 1 << 20, perSecond: 1 << 20),
        warn: (_) {},
      );
      for (var i = 0; i < 12; i++) {
        pipeline.submit('l$i', LogLevel.info, null);
      }
      await pipeline.flush();
      expect(peak, 1);
    });

    test('what native refuses is counted, not retried', () async {
      final rig = Rig()..handedOverride = 1;
      rig.line('a');
      rig.line('b');
      rig.line('c');
      await rig.pipeline.flush();
      expect(rig.pipeline.stats.submittedToSdk, 1);
      expect(rig.pipeline.stats.refusedByNative, 2);
      expect(rig.batches, hasLength(1));
    });

    test(
      'a bridge failure loses the batch, counts it, warns once, and goes on',
      () async {
        final rig = Rig(maxBatchLines: 2)..sendThrows = true;
        for (var i = 0; i < 5; i++) {
          rig.line('l$i');
        }
        await rig.pipeline.flush();
        expect(rig.pipeline.stats.sendFailures, 5);
        expect(rig.warnings, hasLength(1));
        rig.sendThrows = false;
        rig.line('later');
        await rig.pipeline.flush();
        expect(rig.texts.last, 'later');
      },
    );
  });

  group('the filter', () {
    test('redacts: what it returns is what is sent', () async {
      final rig = Rig();
      rig.pipeline.setFilter((e) {
        e.message = e.message.replaceAll('secret', '<redacted>');
        e.level = LogLevel.error;
        e.tag = 'filtered';
        return e;
      }, const Duration(seconds: 1));
      rig.line('token secret here', LogLevel.info, 'print');
      await rig.pipeline.flush();
      expect(rig.sent.single.message, 'token <redacted> here');
      expect(rig.sent.single.level, 1);
      expect(rig.sent.single.tag, 'filtered');
    });

    test('null drops the line and counts it', () async {
      final rig = Rig();
      rig.pipeline.setFilter((e) => null, const Duration(seconds: 1));
      rig.line('x');
      await rig.pipeline.flush();
      expect(rig.sent, isEmpty);
      expect(rig.pipeline.stats.droppedByFilter, 1);
    });

    test('an empty message after the filter drops the line', () async {
      final rig = Rig();
      rig.pipeline.setFilter(
        (e) => e..message = '',
        const Duration(seconds: 1),
      );
      rig.line('x');
      await rig.pipeline.flush();
      expect(rig.sent, isEmpty);
      expect(rig.pipeline.stats.droppedByFilter, 1);
    });

    test(
      'a filter that throws drops the line (fail closed) and warns once',
      () async {
        final rig = Rig();
        rig.pipeline.setFilter(
          (e) => throw StateError('bug'),
          const Duration(seconds: 1),
        );
        rig.line('a');
        rig.line('b');
        await rig.pipeline.flush();
        expect(rig.sent, isEmpty);
        expect(rig.pipeline.stats.filterFailures, 2);
        expect(rig.warnings, hasLength(1));
      },
    );

    test('an asynchronous filter that throws drops the line', () async {
      final rig = Rig();
      rig.pipeline.setFilter(
        (e) async => throw StateError('bug'),
        const Duration(seconds: 1),
      );
      rig.line('a');
      await rig.pipeline.flush();
      expect(rig.sent, isEmpty);
      expect(rig.pipeline.stats.filterFailures, 1);
    });

    test(
      'a filter that never answers drops the line after the timeout',
      () async {
        final rig = Rig();
        rig.pipeline.setFilter(
          (e) => Completer<BugseeLogEvent?>().future,
          const Duration(milliseconds: 20),
        );
        rig.line('a');
        rig.line('b');
        await rig.pipeline.flush();
        expect(rig.sent, isEmpty);
        expect(rig.pipeline.stats.filterFailures, 2);
      },
    );

    test('a wrong return type drops the line', () async {
      final rig = Rig();
      rig.pipeline.setFilter(
        (e) => ('not an event' as Object) as BugseeLogEvent?,
        const Duration(seconds: 1),
      );
      rig.line('a');
      await rig.pipeline.flush();
      expect(rig.sent, isEmpty);
      expect(rig.pipeline.stats.filterFailures, 1);
    });

    test(
      'the filter is handed a copy: changing it changes nothing it does not return',
      () async {
        final rig = Rig();
        rig.pipeline.setFilter((e) {
          e.message = 'tampered';
          return BugseeLogEvent(message: 'replacement');
        }, const Duration(seconds: 1));
        rig.line('original');
        await rig.pipeline.flush();
        expect(rig.sent.single.message, 'replacement');
      },
    );

    test(
      'lines run through it one at a time, in order, even when it is asynchronous',
      () async {
        final rig = Rig();
        var running = 0;
        var peak = 0;
        rig.pipeline.setFilter((e) async {
          running++;
          if (running > peak) peak = running;
          await Future<void>.delayed(
            Duration(milliseconds: e.message == 'a' ? 15 : 1),
          );
          running--;
          return e;
        }, const Duration(seconds: 1));
        rig.line('a');
        rig.line('b');
        rig.line('c');
        await rig.pipeline.flush();
        expect(peak, 1);
        expect(rig.texts, ['a', 'b', 'c']);
      },
    );

    test(
      'the filter in force when the line was captured still applies after it is removed',
      () async {
        final rig = Rig();
        rig.pipeline.setFilter((e) => null, const Duration(seconds: 1));
        rig.line('secret');
        rig.pipeline.setFilter(null, const Duration(seconds: 1));
        await rig.pipeline.flush();
        expect(rig.sent, isEmpty);
        expect(rig.pipeline.stats.droppedByFilter, 1);
      },
    );

    test(
      'a filter set after capture also covers the queued line, after the first',
      () async {
        final rig = Rig();
        rig.line('plain');
        final order = <String>[];
        rig.pipeline.setFilter((e) {
          order.add('late');
          return e..message = '${e.message}!';
        }, const Duration(seconds: 1));
        await rig.pipeline.flush();
        expect(order, ['late']);
        expect(rig.texts, ['plain!']);
      },
    );

    test('a filter that makes a line longer is cut to the cap again', () async {
      final rig = Rig();
      rig.pipeline.setFilter(
        (e) => e..message = 'z' * 5000,
        const Duration(seconds: 1),
      );
      rig.line('a');
      await rig.pipeline.flush();
      expect(rig.sent.single.message, endsWith(' ...[truncated 1000]'));
    });

    test(
      'what the filter prints is not recorded: it runs in the suppressed zone',
      () async {
        final rig = Rig();
        var suppressed = false;
        rig.pipeline.setFilter((e) {
          suppressed = logCaptureSuppressed();
          return e;
        }, const Duration(seconds: 1));
        rig.line('a');
        await rig.pipeline.flush();
        expect(suppressed, isTrue);
      },
    );

    test(
      'and an asynchronous filter stays suppressed after its first await',
      () async {
        final rig = Rig();
        final seen = <bool>[];
        rig.pipeline.setFilter((e) async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          seen.add(logCaptureSuppressed());
          return e;
        }, const Duration(seconds: 1));
        rig.line('a');
        await rig.pipeline.flush();
        expect(seen, [true]);
      },
    );
  });

  group('a filter that keeps timing out', () {
    Future<BugseeLogEvent?> hang(BugseeLogEvent e) =>
        Completer<BugseeLogEvent?>().future;
    const short = Duration(milliseconds: 15);

    test(
      'is switched off after three timeouts in a row: later lines cost nothing',
      () async {
        var now = 0;
        var calls = 0;
        final rig = Rig(clock: () => now);
        rig.pipeline.setFilter((e) {
          calls++;
          return hang(e);
        }, short);
        for (var i = 0; i < 3; i++) {
          rig.line('hung $i');
        }
        await rig.pipeline.flush();
        expect(calls, 3);
        expect(rig.pipeline.stats.filterFailures, 3);
        // The fourth does not even ask the filter, and does not wait for its timeout.
        final watch = Stopwatch()..start();
        rig.line('fourth');
        rig.line('fifth');
        await rig.pipeline.flush();
        expect(calls, 3);
        expect(rig.pipeline.stats.droppedFilterCoolDown, 2);
        expect(rig.sent, isEmpty);
        expect(watch.elapsedMilliseconds, lessThan(short.inMilliseconds * 2));
        expect(
          rig.warnings.where((w) => w.contains('3 times in a row')),
          hasLength(1),
        );
      },
    );

    test('asks again once the cool-down is over', () async {
      var now = 0;
      var calls = 0;
      final rig = Rig(clock: () => now);
      var hanging = true;
      rig.pipeline.setFilter((e) {
        calls++;
        return hanging ? hang(e) : e;
      }, short);
      for (var i = 0; i < 3; i++) {
        rig.line('hung $i');
      }
      await rig.pipeline.flush();
      now += LogWire.filterCoolDown.inMicroseconds - 1;
      rig.line('still cooling');
      await rig.pipeline.flush();
      expect(calls, 3);
      now += 1;
      hanging = false;
      rig.line('recovered');
      await rig.pipeline.flush();
      expect(calls, 4);
      expect(rig.texts, ['recovered']);
    });

    test('an answer in between resets the count', () async {
      var now = 0;
      var n = 0;
      final rig = Rig(clock: () => now);
      rig.pipeline.setFilter((e) {
        n++;
        // timeout, timeout, answer, timeout, timeout: never three in a row
        return n == 3 ? e : hang(e);
      }, short);
      for (var i = 0; i < 5; i++) {
        rig.line('l$i');
      }
      await rig.pipeline.flush();
      expect(n, 5);
      expect(rig.pipeline.stats.droppedFilterCoolDown, 0);
      expect(rig.texts, ['l2']);
    });

    test(
      'a filter that throws is not a timeout: it never cools down',
      () async {
        var now = 0;
        final rig = Rig(clock: () => now);
        var calls = 0;
        rig.pipeline.setFilter((e) {
          calls++;
          throw StateError('bug');
        }, short);
        for (var i = 0; i < 6; i++) {
          rig.line('l$i');
        }
        await rig.pipeline.flush();
        expect(calls, 6);
        expect(rig.pipeline.stats.droppedFilterCoolDown, 0);
      },
    );

    test(
      'lines with no filter in force are not held back by a cool-down',
      () async {
        var now = 0;
        final rig = Rig(clock: () => now);
        rig.pipeline.setFilter(hang, short);
        for (var i = 0; i < 3; i++) {
          rig.line('hung $i');
        }
        await rig.pipeline.flush();
        rig.pipeline.setFilter(null, short);
        rig.line('free');
        await rig.pipeline.flush();
        expect(rig.texts, ['free']);
      },
    );
  });

  group('flush', () {
    test('leaves no timer behind while native does not answer', () async {
      final gate = Completer<int>();
      final pipeline = LogPipeline(
        send: (batch) => gate.future,
        policy: () => accepting,
        limiter: LogRateLimiter(burst: 1 << 20, perSecond: 1 << 20),
        warn: (_) {},
      );
      pipeline.submit('stuck', LogLevel.info, null);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var timers = 0;
      // Reports that give up on it (a time limit) each used to leave a polling loop of timers.
      runZoned(
        () {
          for (var i = 0; i < 30; i++) {
            unawaited(
              pipeline.flush().timeout(
                const Duration(milliseconds: 5),
                onTimeout: () {},
              ),
            );
          }
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, f) {
            if (duration != const Duration(milliseconds: 5)) timers++;
            return parent.createTimer(zone, duration, f);
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(timers, 0);
      gate.complete(1);
      await pipeline.flush();
    });

    test(
      'a waiter is released when the drain ends, even with several waiting',
      () async {
        final rig = Rig(maxBatchLines: 1);
        for (var i = 0; i < 5; i++) {
          rig.line('l$i');
        }
        await Future.wait([for (var i = 0; i < 4; i++) rig.pipeline.flush()]);
        expect(rig.texts, ['l0', 'l1', 'l2', 'l3', 'l4']);
      },
    );
  });

  group('the pipeline is not blocked by a slow filter on the print path', () {
    test(
      'submit returns before any filtering when the filter is slow',
      () async {
        final rig = Rig();
        rig.pipeline.setFilter((e) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return e;
        }, const Duration(seconds: 1));
        final watch = Stopwatch()..start();
        for (var i = 0; i < 50; i++) {
          rig.line('l$i');
        }
        expect(watch.elapsedMilliseconds, lessThan(30));
        await rig.pipeline.flush();
        expect(rig.sent, hasLength(50));
      },
    );
  });
}
