// Drift guards for what is repeated across Dart, Android and iOS for lifecycle
// forwarding (workbook Part 4) and for state that must outlive the wrapper
// object (5.4.2). The behaviour itself is tested by test/bridge_test.dart, the
// JUnit tests (android/src/test) and the XCTests (ios/wrapper_tests).
import 'dart:io';

import 'package:bugsee_flutter/src/bridge/lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

/// Source with comments removed, so a call that is only commented out does not
/// satisfy a guard.
String code(String path) => read(path)
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

const java = 'android/src/main/java/com/bugsee/flutter';
const objc = 'ios/bugsee_flutter/Sources/bugsee_flutter_wrapper';
const swift = 'ios/bugsee_flutter/Sources/bugsee_flutter';

Set<String> quoted(String block) =>
    RegExp(r'"([A-Za-z]+)"').allMatches(block).map((m) => m.group(1)!).toSet();

void main() {
  group('lifecycle names and constants agree', () {
    test('report-id events: Dart == Java == Objective-C', () {
      final j = code('$java/LifecycleHub.java');
      final javaSet = quoted(
        RegExp(
          r'REPORT_ID_EVENTS = [^;]*?asList\(([^;]*?)\)\)\);',
          dotAll: true,
        ).firstMatch(j)!.group(1)!,
      );
      final m = code('$objc/BGSFlutterLifecycleHub.m');
      final objcSet = RegExp(r'@"([A-Za-z]+)"')
          .allMatches(
            RegExp(
              r'events = \[NSSet setWithObjects:(@"BeforeReportAssembled"[^;]*?)nil\];',
              dotAll: true,
            ).firstMatch(m)!.group(1)!,
          )
          .map((x) => x.group(1)!)
          .toSet();
      expect(javaSet, reportIdEvents);
      expect(objcSet, reportIdEvents);
      // Workbook 4.5: exactly these seven.
      expect(reportIdEvents, hasLength(7));
    });

    test('status transition events: Dart == Java == Objective-C', () {
      final j = code('$java/LifecycleHub.java');
      final javaSet = quoted(
        RegExp(
          r'STATUS_EVENTS = [^;]*?asList\(([^;]*?)\)\)\);',
          dotAll: true,
        ).firstMatch(j)!.group(1)!,
      );
      final m = code('$objc/BGSFlutterLifecycleHub.m');
      final objcSet = RegExp(r'@"([A-Za-z]+)"')
          .allMatches(
            RegExp(
              r'events = \[NSSet setWithObjects:@"Launching"([^;]*?)nil\];',
              dotAll: true,
            ).firstMatch(m)!.group(0)!,
          )
          .map((x) => x.group(1)!)
          .toSet();
      expect(javaSet, statusTransitionEvents);
      expect(objcSet, statusTransitionEvents);
      expect(statusTransitionEvents, hasLength(4));
      for (final n in statusTransitionEvents) {
        expect(statusForEvent(LifecycleEvent(n)), isNotNull, reason: n);
      }
    });

    test('the prefix is the SDKs and is stripped natively, once', () {
      final j = read('$java/LifecycleHub.java');
      expect(
        j,
        contains('static final String PREFIX = "com.bugsee.lifecycle.";'),
      );
      expect(
        read('$objc/BGSFlutterLifecycleHub.m'),
        contains('BGSFlutterLifecyclePrefix = @"com.bugsee.lifecycle.";'),
      );
      // Dart never handles the prefix.
      for (final f in Directory(
        'lib/src/bridge',
      ).listSync().whereType<File>()) {
        if (f.path.endsWith('messages.g.dart')) continue;
        expect(
          code(f.path),
          isNot(contains('com.bugsee.lifecycle')),
          reason: '${f.path} must not strip or spell the prefix',
        );
      }
    });

    test('buffer capacity is 64 on both platforms', () {
      expect(
        read('$java/LifecycleHub.java'),
        contains('BUFFER_CAPACITY = 64;'),
      );
      expect(
        read('$objc/BGSFlutterLifecycleHub.m'),
        contains('BGSFlutterLifecycleBufferCapacity = 64;'),
      );
    });

    test('drop logging is rate-limited the same way on both platforms', () {
      expect(
        read('$java/LifecycleHub.java'),
        contains('DROP_LOG_EVERY = 100;'),
      );
      expect(
        read('$objc/BGSFlutterLifecycleHub.m'),
        contains('BGSFlutterLifecycleDropLogEvery = 100;'),
      );
    });

    test('the oldest event is the one dropped', () {
      expect(
        code('$java/LifecycleHub.java'),
        contains('buffer.removeFirst();'),
      );
      expect(
        code('$objc/BGSFlutterLifecycleHub.m'),
        contains('[_buffer removeObjectAtIndex:0];'),
      );
    });
  });

  group('wiring', () {
    test('both wrappers forward lifecycle events to the hub and nothing else', () {
      expect(
        RegExp(
          r'public void onLifecycleEvent\([^)]*\) \{\s*lifecycle\.dispatch\(eventType, data\);\s*\}',
        ).hasMatch(code('$java/FlutterWrapper.java')),
        isTrue,
      );
      expect(
        RegExp(
          r'- \(void\)onLifecycleEvent:\(NSString \*\)eventType data:\(id\)data \{\s*\[_hub dispatchRawName:eventType data:data\];\s*\}',
        ).hasMatch(code('$objc/BGSFlutterWrapper.m')),
        isTrue,
      );
    });

    test('delivery hops to the platform thread before touching Flutter', () {
      expect(
        read('$java/LifecycleHub.java'),
        contains('new android.os.Handler(android.os.Looper.getMainLooper())'),
      );
      expect(
        code('$objc/BGSFlutterLifecycleHub.m'),
        contains('initWithDeliveryQueue:dispatch_get_main_queue()'),
      );
      // The only call into Flutter on the way out is through the sink, which the
      // hub invokes on that thread; the plugin never calls Dart from the wrapper.
      expect(code('$java/FlutterWrapper.java'), isNot(contains('Messages.')));
      for (final f in [
        '$objc/BGSFlutterWrapper.m',
        '$objc/BGSFlutterLifecycleHub.m',
      ]) {
        expect(code(f), isNot(contains('FlutterBinaryMessenger')));
        expect(code(f), isNot(contains('Flutter/Flutter.h')));
      }
    });

    test("the app's own delegate and listener are never taken over (4.6)", () {
      for (final f in [
        '$java/LifecycleHub.java',
        '$java/FlutterWrapper.java',
        '$java/BugseeFlutterPlugin.java',
        '$objc/BGSFlutterLifecycleHub.m',
        '$objc/BGSFlutterWrapper.m',
        '$swift/BugseeFlutterPlugin.swift',
      ]) {
        final c = code(f);
        expect(c, isNot(contains('setLifecycleEventsListener')), reason: f);
        expect(c, isNot(contains('setLifecycleEventListener')), reason: f);
        expect(c, isNot(contains('setDelegate')), reason: f);
        expect(c, isNot(contains('.delegate =')), reason: f);
        expect(c, isNot(contains('bugseeDidChangeStatus')), reason: f);
      }
    });

    test('both wrappers feed the process-wide hub, not one of their own', () {
      expect(
        code('$java/FlutterWrapper.java'),
        contains('LifecycleHub.shared(), SecureRectangleStore.shared()'),
      );
      expect(
        code('$objc/BGSFlutterWrapper.m'),
        contains('hub:[BGSFlutterLifecycleHub shared]'),
      );
      // The plugins attach to that same hub.
      expect(
        code('$java/BugseeFlutterPlugin.java'),
        contains('LifecycleHub.shared().attach(fresh)'),
      );
      expect(
        code('$swift/BugseeFlutterPlugin.swift'),
        contains('BGSFlutterLifecycleHub.shared().attachSink'),
      );
      // Behavioural twins: JUnit everyWrapperFeedsTheSharedHub, XCTest testEveryWrapperFeedsTheSharedHub.
    });

    test('secure rectangles come from the process-wide store (5.4.2)', () {
      expect(
        code('$java/FlutterWrapper.java'),
        contains('return secureRectangles.pull(display);'),
      );
      final store = code('$java/SecureRectangleStore.java');
      expect(store, contains('SECURE_RECTANGLES_VERSION_UNKNOWN'));
      // The Java store is a singleton; the wrapper defaults to it.
      expect(
        code('$java/FlutterWrapper.java'),
        contains('SecureRectangleStore.shared()'),
      );
      expect(
        code('$objc/BGSFlutterWrapper.m'),
        contains('[BGSFlutterSecureRectangleStore shared]'),
      );
    });

    test('identity refinement replaces the wrapper through the SDK setter', () {
      expect(
        code('$java/BugseeFlutterPlugin.java'),
        contains('FlutterWrapperInitProvider.sdkSetter'),
      );
      expect(
        code('$java/FlutterWrapperInitProvider.java'),
        contains('register.set(wrapper);'),
      );
      expect(
        code('$swift/BugseeFlutterPlugin.swift'),
        contains('BGSFlutterWrapperRegistrar.replace('),
      );
      expect(
        code('$objc/BGSFlutterWrapper.m'),
        contains('gWrapper = refined;'),
      );
    });

    test(
      'native identity entry points take the facts from Dart, not from Pigeon types',
      () {
        // Wrapper construction goes through the same cleaning as the placeholder
        // (unknown for missing, non-strings dropped); the plugin passes raw values.
        final p = code('$java/BugseeFlutterPlugin.java');
        expect(p, contains('identity.getType()'));
        expect(p, contains('identity.getContext()'));
      },
    );

    test('the Swift pump sends in order and hands unsent events back', () {
      final s = code('$swift/BugseeFlutterPlugin.swift');
      // One consumer, queue owned by the plugin; not a Task per event.
      expect(s, contains('for await _ in wakeups'));
      expect(s, contains('self.pending.removeFirst()'));
      expect(
        RegExp(r'attachSink \{[^}]*Task').hasMatch(s),
        isFalse,
        reason: 'a Task per event does not promise delivery order',
      );
      // Teardown cancels the pump and gives back what it had not sent.
      expect(s, contains('pumpTask?.cancel()'));
      expect(s, contains('while !Task.isCancelled'));
      expect(
        s,
        contains('detach(token, undelivered: unsent)'),
        reason: 'unsent events must go back to the hub, not be lost or raced',
      );
      // The Swift pump cannot be unit tested without Flutter; the hub half is
      // XCTest testUndeliveredEventsHandedBackAtDetachGoFirstInOrder.
    });
  });

  group('iOS wrapper test package', () {
    test('Sources is a symlink to the shipped Objective-C target', () {
      final link = Link('ios/wrapper_tests/Sources/BugseeFlutterWrapper');
      expect(link.existsSync(), isTrue);
      expect(
        link.targetSync(),
        '../../bugsee_flutter/Sources/bugsee_flutter_wrapper',
      );
      expect(
        File(
          'ios/wrapper_tests/Sources/BugseeFlutterWrapper/BGSFlutterLifecycleHub.m',
        ).existsSync(),
        isTrue,
      );
    });
  });
}
