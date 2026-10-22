// The public feedback API against a fake native side: what reaches native and in what order, how
// each answer maps to a result or a typed exception, and the listener streams.
import 'dart:async';

import 'package:bugsee_flutter/bugsee_flutter.dart' show BugseeException;
import 'package:bugsee_flutter_feedback/bugsee_flutter_feedback.dart';
import 'package:bugsee_flutter_feedback/src/bridge/messages.g.dart';
import 'package:bugsee_flutter_feedback/src/bugsee_feedback.dart'
    show debugSetFeedbackRuntime;
import 'package:bugsee_flutter_feedback/src/feedback_runtime.dart';
import 'package:bugsee_flutter_feedback/src/feedback_version.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_test/flutter_test.dart';

/// A native end that records calls and answers as scripted.
class FakeNative extends FeedbackHostApi {
  final List<String> calls = [];
  bool registered = true;
  PlatformException? failShow;
  PlatformException? failListener;
  PlatformException? failAttach;
  bool throwMissing = false;
  int attachCalls = 0;
  Completer<void>? listenerGate;
  int inFlight = 0;
  int maxInFlight = 0;

  void _missing() {
    if (throwMissing) throw MissingPluginException('no plugin');
  }

  @override
  Future<bool> attach() async {
    _missing();
    attachCalls++;
    calls.add('attach');
    if (failAttach != null) throw failAttach!;
    return registered;
  }

  bool safetyNet = false;

  @override
  Future<bool> registeredBySafetyNet() async {
    _missing();
    calls.add('safetyNet');
    return safetyNet;
  }

  @override
  Future<void> show() async {
    _missing();
    calls.add('show');
    if (failShow != null) throw failShow!;
  }

  @override
  Future<void> setGreeting(String? greeting) async {
    _missing();
    calls.add('greeting:${greeting ?? '(null)'}');
  }

  @override
  Future<void> setListenerEnabled(bool enabled) async {
    _missing();
    calls.add('listener:$enabled');
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await listenerGate?.future;
    } finally {
      inFlight--;
    }
    if (failListener != null) throw failListener!;
  }
}

FeedbackRuntime runtimeOn(
  FakeNative native, {
  TargetPlatform? platform = TargetPlatform.android,
  String ownVersion = '10.0.0',
  String coreVersion = '10.0.0',
  List<String>? warnings,
}) => FeedbackRuntime(
  host: native,
  platform: () => platform,
  warn: (m) => warnings?.add(m),
  ensureBinding: () {},
  ownVersion: ownVersion,
  coreVersion: coreVersion,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('show / setGreeting', () {
    test('attach comes first, once, then the call', () async {
      final native = FakeNative();
      final runtime = runtimeOn(native);
      await runtime.show();
      await runtime.setGreeting('Hi');
      await runtime.setGreeting(null);
      expect(native.calls, [
        'attach',
        'show',
        'greeting:Hi',
        'greeting:(null)',
      ]);
    });

    test('through the public facade', () async {
      final native = FakeNative();
      debugSetFeedbackRuntime(runtimeOn(native));
      await BugseeFeedback.show();
      await BugseeFeedback.setGreeting('Hello');
      expect(await BugseeFeedback.isAvailable(), isTrue);
      expect(native.calls, ['attach', 'show', 'greeting:Hello']);
    });

    test('isAvailable is what native answered at attach', () async {
      final native = FakeNative()..registered = false;
      expect(await runtimeOn(native).isAvailable(), isFalse);
    });

    test('not-registered is a typed failure, not a silent no-op', () async {
      final native = FakeNative()
        ..failShow = PlatformException(
          code: 'not-registered',
          message: 'the SDK has no feedback module registered',
        );
      await expectLater(
        runtimeOn(native).show(),
        throwsA(
          isA<BugseeFeedbackException>()
              .having(
                (e) => e.reason,
                'reason',
                BugseeFeedbackFailure.notRegistered,
              )
              .having((e) => e.message, 'message', contains('show:')),
        ),
      );
    });

    test('an SDK error is nativeError and is a BugseeException', () async {
      final native = FakeNative()
        ..failShow = PlatformException(code: 'sdk-error', message: 'boom');
      await expectLater(
        runtimeOn(native).show(),
        throwsA(
          isA<BugseeException>().having(
            (e) => (e as BugseeFeedbackException).reason,
            'reason',
            BugseeFeedbackFailure.nativeError,
          ),
        ),
      );
    });

    test('a missing native plugin says to rebuild', () async {
      final native = FakeNative()..throwMissing = true;
      await expectLater(
        runtimeOn(native).show(),
        throwsA(
          isA<BugseeFeedbackException>()
              .having(
                (e) => e.reason,
                'reason',
                BugseeFeedbackFailure.nativeError,
              )
              .having((e) => e.message, 'message', contains('rebuild')),
        ),
      );
    });

    test('a failed attach is retried by the next call', () async {
      final native = FakeNative()
        ..failAttach = PlatformException(code: 'sdk-error', message: 'x');
      final runtime = runtimeOn(native);
      await expectLater(
        runtime.show(),
        throwsA(isA<BugseeFeedbackException>()),
      );
      native.failAttach = null;
      await runtime.show();
      expect(native.calls, ['attach', 'attach', 'show']);
      expect(native.attachCalls, 2);
    });

    test(
      'registeredBySafetyNet is what native answered, after attaching',
      () async {
        final native = FakeNative();
        final runtime = runtimeOn(native);
        expect(await runtime.registeredBySafetyNet(), isFalse);
        native.safetyNet = true;
        expect(await runtime.registeredBySafetyNet(), isTrue);
        expect(native.calls, ['attach', 'safetyNet', 'safetyNet']);
        final desktop = runtimeOn(FakeNative(), platform: null);
        expect(await desktop.registeredBySafetyNet(), isFalse);
      },
    );

    test('desktop and web do nothing, with one warning', () async {
      final native = FakeNative();
      final warnings = <String>[];
      final runtime = runtimeOn(native, platform: null, warnings: warnings);
      await runtime.show();
      await runtime.setGreeting('x');
      expect(await runtime.isAvailable(), isFalse);
      expect(native.calls, isEmpty);
      expect(warnings, hasLength(1));
    });
  });

  group('core compatibility', () {
    test('the same major and minor are compatible, anything else is not', () {
      expect(isCompatibleCore('10.0.0', '10.0.0'), isTrue);
      expect(isCompatibleCore('10.0.0-dev.1', '10.0.3'), isTrue);
      expect(isCompatibleCore('10.0.0', '10.1.0'), isFalse);
      expect(isCompatibleCore('10.0.0', '9.0.0'), isFalse);
      expect(isCompatibleCore('10.0.0', '11.0.0'), isFalse);
      expect(isCompatibleCore('10.0.0', 'unknown'), isFalse);
      expect(isCompatibleCore('', '10.0.0'), isFalse);
    });

    test(
      'a core of another minor fails every call before native is touched',
      () async {
        final native = FakeNative();
        final runtime = runtimeOn(native, coreVersion: '10.1.0');
        for (final call in <Future<Object?> Function()>[
          runtime.show,
          () => runtime.setGreeting('x'),
          runtime.isAvailable,
        ]) {
          await expectLater(
            call(),
            throwsA(
              isA<BugseeFeedbackException>()
                  .having(
                    (e) => e.reason,
                    'reason',
                    BugseeFeedbackFailure.incompatibleCore,
                  )
                  .having(
                    (e) => e.message,
                    'message',
                    allOf(contains('10.0.0'), contains('10.1.0')),
                  ),
            ),
          );
        }
        expect(native.calls, isEmpty);
      },
    );

    test('the real versions of the two packages are compatible', () async {
      // FeedbackRuntime's defaults: this package's version against the core's own constant.
      final native = FakeNative();
      final runtime = FeedbackRuntime(
        host: native,
        platform: () => TargetPlatform.iOS,
        ensureBinding: () {},
      );
      await runtime.show();
      expect(native.calls, ['attach', 'show']);
    });
  });

  group('listener streams', () {
    late FakeNative native;
    late FeedbackRuntime runtime;

    setUp(() {
      native = FakeNative();
      runtime = runtimeOn(native);
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test(
      'the native listener is installed on the first listen and removed on the last cancel',
      () async {
        final a = runtime.messagesReceived.listen((_) {});
        await settle();
        expect(native.calls, ['attach', 'listener:true']);
        final b = runtime.messagesSent.listen((_) {});
        await settle();
        expect(native.calls, [
          'attach',
          'listener:true',
        ], reason: 'already installed');
        await a.cancel();
        await settle();
        expect(native.calls.last, 'listener:true', reason: 'one listener left');
        await b.cancel();
        await settle();
        expect(native.calls, ['attach', 'listener:true', 'listener:false']);
      },
    );

    test(
      'received batches arrive in order, empty ones never, and unmodifiable',
      () async {
        final got = <List<String>>[];
        final sub = runtime.messagesReceived.listen(got.add);
        await settle();
        runtime.onMessagesReceived(['a', 'b']);
        runtime.onMessagesReceived([]);
        runtime.onMessagesReceived(['c']);
        await settle();
        expect(got, [
          ['a', 'b'],
          ['c'],
        ]);
        expect(() => got.first.add('x'), throwsUnsupportedError);
        await sub.cancel();
      },
    );

    test('sent messages arrive on their own stream only', () async {
      final sent = <String>[];
      final received = <List<String>>[];
      final s1 = runtime.messagesSent.listen(sent.add);
      final s2 = runtime.messagesReceived.listen(received.add);
      await settle();
      runtime.onMessageSent('hello');
      await settle();
      expect(sent, ['hello']);
      expect(received, isEmpty);
      await s1.cancel();
      await s2.cancel();
    });

    test('an event with nobody listening is dropped, not replayed', () async {
      runtime.onMessageSent('lost');
      runtime.onMessagesReceived(['lost']);
      final got = <String>[];
      final sub = runtime.messagesSent.listen(got.add);
      await settle();
      expect(got, isEmpty);
      await sub.cancel();
    });

    test('listen, cancel, listen quickly ends with the listener on', () async {
      native.listenerGate = Completer<void>();
      final a = runtime.messagesReceived.listen((_) {});
      await a.cancel();
      final b = runtime.messagesReceived.listen((_) {});
      native.listenerGate!.complete();
      await settle();
      await settle();
      // Whatever intermediate calls were made, the last one agrees with the subscribers.
      expect(
        native.calls.where((c) => c.startsWith('listener:')).last,
        'listener:true',
      );
      await b.cancel();
    });

    test(
      'a listener that cannot be installed is an error event for the subscribers',
      () async {
        native.failListener = PlatformException(
          code: 'not-registered',
          message: 'none',
        );
        final errors = <Object>[];
        final sub = runtime.messagesReceived.listen(
          (_) {},
          onError: errors.add,
        );
        await settle();
        await settle();
        expect(errors, hasLength(1));
        expect(
          (errors.single as BugseeFeedbackException).reason,
          BugseeFeedbackFailure.notRegistered,
        );
        await sub.cancel();
      },
    );

    test(
      'the last cancel removes the listener whichever stream it is',
      () async {
        final r = runtime.messagesReceived.listen((_) {});
        await settle();
        await r.cancel();
        await settle();
        expect(native.calls, ['attach', 'listener:true', 'listener:false']);
        final s = runtime.messagesSent.listen((_) {});
        await settle();
        await s.cancel();
        await settle();
        expect(native.calls.skip(3), ['listener:true', 'listener:false']);
      },
    );

    test('setListenerEnabled calls never overlap', () async {
      native.listenerGate = Completer<void>();
      final a = runtime.messagesReceived.listen((_) {});
      await settle();
      await a.cancel();
      final b = runtime.messagesSent.listen((_) {});
      await settle();
      native.listenerGate!.complete();
      await settle();
      await settle();
      expect(native.maxInFlight, 1);
      await b.cancel();
    });

    test('a new isolate attaches again and installs its own listener', () async {
      final first = runtimeOn(native);
      final sub = first.messagesReceived.listen((_) {});
      await settle();
      await sub.cancel();
      await settle();
      // A fresh isolate: a new runtime, native still thinks the old one is installed.
      native.calls.clear();
      final second = runtimeOn(native);
      final again = second.messagesReceived.listen((_) {});
      await settle();
      expect(native.calls, ['attach', 'listener:true']);
      await again.cancel();
    });
  });
}
