// Drift guards for what the exception path repeats across Dart, Java and Objective-C: the name the
// backend routes on, the document and domain limits, which SDK call a handled and an unhandled
// error make, and that both natives gate on the SDK being launched. The natives answer before
// Dart can look at them, so each copy is compared with its source.
import 'dart:io';

import 'package:bugsee_flutter/src/exceptions/exception_payload.dart';
import 'package:flutter_test/flutter_test.dart';

const java = 'android/src/main/java/com/bugsee/flutter';
const objc = 'ios/bugsee_flutter/Sources/bugsee_flutter_wrapper';

String read(String path) => File(path).readAsStringSync();

String stripComments(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

void main() {
  final javaOps = read('$java/ExceptionOps.java');
  final javaCode = stripComments(javaOps);
  final javaSdk = stripComments(read('$java/BugseeExceptionSdk.java'));
  final javaCarrier = read('$java/FlutterManagedException.java');
  final objcOps = read('$objc/BGSFlutterExceptionOps.m');
  final objcCode = stripComments(objcOps);

  group('the name the backend routes on', () {
    test('is FlutterManagedException (worker crash/managed/__init__.py)', () {
      expect(ExceptionWire.managedName, 'FlutterManagedException');
    });

    test('Java: the constant, and the carrier class that bears it', () {
      expect(
        RegExp(r'EXCEPTION_NAME = "([^"]*)";').firstMatch(javaOps)!.group(1),
        ExceptionWire.managedName,
      );
      // The class name is what the SDK records as the exception's name.
      expect(
        javaCarrier,
        contains('final class ${ExceptionWire.managedName} extends Exception'),
      );
      expect(
        File('$java/${ExceptionWire.managedName}.java').existsSync(),
        isTrue,
      );
      expect(
        javaCarrier,
        contains('package com.bugsee.flutter;'),
        reason:
            'top level, in this package: com.bugsee.flutter.FlutterManagedException',
      );
    });

    test(
      'Java: the carrier is what the SDK is handed, with the document as its message',
      () {
        expect(javaCode, contains('new FlutterManagedException(payload)'));
        expect(javaCarrier, contains('super(document)'));
      },
    );

    test(
      'R8 keeps the class name for every app, and the build ships the rule',
      () {
        expect(
          read('android/consumer-rules.pro'),
          contains(
            '-keepnames class com.bugsee.flutter.${ExceptionWire.managedName}',
          ),
        );
        expect(
          read('android/build.gradle'),
          contains('consumerProguardFiles "consumer-rules.pro"'),
        );
      },
    );

    test(
      'Objective-C: the constant, passed as the name to both SDK entry points',
      () {
        expect(
          RegExp(r'kExceptionName = @"([^"]*)";').firstMatch(objcOps)!.group(1),
          ExceptionWire.managedName,
        );
        expect(
          objcCode,
          contains('logHandledName:kExceptionName reason:payload'),
        );
        expect(
          objcCode,
          contains('logUnhandledName:kExceptionName reason:payload'),
        );
      },
    );

    test(
      'the document says it too (a build that renamed the class is still routed by the reason)',
      () {
        final p = buildExceptionPayload(StateError('x'), null);
        expect(
          p.json,
          contains('"internalType":"${ExceptionWire.managedName}"'),
        );
      },
    );
  });

  group('the limits are the same in Dart, Java and Objective-C', () {
    test('the longest document', () {
      expect(ExceptionWire.maxPayloadLength, 262144);
      expect(
        RegExp(r'MAX_PAYLOAD_LENGTH = (\d+);').firstMatch(javaOps)!.group(1),
        '${ExceptionWire.maxPayloadLength}',
      );
      expect(
        RegExp(r'kMaxPayloadLength = (\d+);').firstMatch(objcOps)!.group(1),
        '${ExceptionWire.maxPayloadLength}',
      );
    });

    test('the longest domain', () {
      expect(ExceptionWire.maxDomainLength, 256);
      expect(
        RegExp(r'MAX_DOMAIN_LENGTH = (\d+);').firstMatch(javaOps)!.group(1),
        '${ExceptionWire.maxDomainLength}',
      );
      expect(
        RegExp(r'kMaxDomainLength = (\d+);').firstMatch(objcOps)!.group(1),
        '${ExceptionWire.maxDomainLength}',
      );
    });

    test('the header exposes the same limits and name for the XCTest', () {
      final header = read('$objc/include/BGSFlutterExceptionOps.h');
      for (final name in [
        'exceptionName',
        'maxPayloadLength',
        'maxDomainLength',
      ]) {
        // Each is a CLASS property of its own (a plain method, or one shared declaration, is not).
        expect(
          RegExp(
            r'@property\(class, readonly\)[^;]*\b' + name + r'\s*;',
          ).hasMatch(header),
          isTrue,
          reason: name,
        );
      }
      expect(
        objcOps,
        contains('+ (NSString *)exceptionName { return kExceptionName; }'),
      );
    });
  });

  group('the stack taken at the facade', () {
    test(
      'each method that takes StackTrace.current is never inlined (the plugin\'s frame is exactly one, and dropped by position)',
      () {
        final api = read('lib/src/bugsee.dart');
        for (final name in [
          'logException',
          'logUnhandledException',
          'reportException',
        ]) {
          final match = RegExp(
            r"@pragma\('vm:never-inline'\)\s+static Future<bool> " +
                name +
                r'\(',
          );
          expect(match.hasMatch(api), isTrue, reason: name);
        }
        // Exactly those three take the stack, so exactly those three need the pragma.
        expect(
          RegExp(r'StackTrace\.current').allMatches(stripComments(api)).length,
          3,
          reason:
              'a fourth method that takes the stack needs the pragma, and a test',
        );
      },
    );
  });

  group('which SDK call each path makes', () {
    test(
      'Android: handled is logException, unhandled is logUnhandledException (never onUncaughtException)',
      () {
        expect(
          javaSdk,
          contains('Bugsee.logException(throwable, domain, skipFrames)'),
        );
        expect(
          javaSdk,
          contains('Bugsee.logUnhandledException(throwable, options)'),
        );
        expect(javaSdk, isNot(contains('onUncaughtException')));
        expect(javaCode, contains('if (handled)'));
        expect(javaCode, contains('sdk.logUnhandledException'));
        expect(
          javaCode.indexOf('if (handled)'),
          lessThan(javaCode.indexOf('sdk.logUnhandledException')),
        );
      },
    );

    test(
      'iOS: handled is logException:reason:domain:, unhandled is logUnhandledException:reason:',
      () {
        expect(
          objcCode,
          contains(
            '[Bugsee logException:name reason:reason domain:domain skipFrames:skipFrames completion:nil]',
          ),
        );
        expect(
          objcCode,
          contains(
            '[Bugsee logUnhandledException:name reason:reason completion:nil]',
          ),
        );
      },
    );

    test(
      'both gate on the SDK being launching or launched BEFORE they hand anything over',
      () {
        // The gate must exist (an absent one is index -1, which is "before" everything).
        expect(javaCode, contains('if (!sdk.isLaunchedOrLaunching())'));
        expect(objcCode, contains('if (![sdk isLaunchedOrLaunching])'));
        expect(
          javaCode.indexOf('sdk.isLaunchedOrLaunching()'),
          lessThan(javaCode.indexOf('sdk.logException(')),
        );
        expect(
          javaCode.indexOf('sdk.isLaunchedOrLaunching()'),
          lessThan(javaCode.indexOf('sdk.logUnhandledException(')),
        );
        expect(
          objcCode.indexOf('isLaunchedOrLaunching]'),
          lessThan(objcCode.indexOf('[sdk logHandledName')),
        );
        expect(
          objcCode.indexOf('isLaunchedOrLaunching]'),
          lessThan(objcCode.indexOf('[sdk logUnhandledName')),
        );
      },
    );

    test('both gates are the SDK\'s Launching/Launched pair', () {
      expect(javaSdk, contains('BugseeStatus.Launching'));
      expect(javaSdk, contains('BugseeStatus.Launched'));
      expect(objcCode, contains('BugseeStatusLaunching'));
      expect(objcCode, contains('BugseeStatusLaunched'));
    });

    test(
      'an SDK exception is caught natively (an NSException escaping into Swift crashes the app)',
      () {
        expect(javaCode, contains('catch (final RuntimeException e)'));
        expect(objcCode, contains('@catch (NSException *exception)'));
      },
    );

    test('the plugins hand the call to the ops, and nothing else', () {
      expect(
        read('$java/BugseeFlutterPlugin.java'),
        contains('ExceptionOps.log(current, payload, handled, domain)'),
      );
      expect(
        read(
          'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
        ),
        contains('BGSFlutterExceptionOps.log('),
      );
    });

    test(
      'Android: the SDK call runs on the dispatcher\'s thread, never on the platform thread',
      () {
        final plugin = stripComments(read('$java/BugseeFlutterPlugin.java'));
        // The only call of the ops is inside the lambda handed to the dispatcher.
        expect(plugin, contains('ExceptionDispatcher.shared().submit('));
        expect(
          RegExp(r'\(\) -> ExceptionOps\.log\(').allMatches(plugin).length,
          1,
        );
        expect(
          RegExp(r'ExceptionOps\.log\(').allMatches(plugin).length,
          1,
          reason: 'no second, inline call',
        );
        // The reply goes back to the platform thread.
        expect(plugin, contains('onMain(() -> result.success(handedToSdk))'));
      },
    );

    test(
      'the dispatcher is one daemon thread with a bounded queue that drops',
      () {
        final dispatcher = stripComments(
          read('$java/ExceptionDispatcher.java'),
        );
        expect(dispatcher, contains('new ThreadPoolExecutor(1, 1,'));
        expect(
          dispatcher,
          contains('new ArrayBlockingQueue<Runnable>(capacity)'),
        );
        expect(dispatcher, contains('thread.setDaemon(true)'));
        expect(dispatcher, contains('catch (final RejectedExecutionException'));
        expect(dispatcher, contains('done.success(false)'));
        expect(dispatcher, isNot(contains('LinkedBlockingQueue')));
        expect(dispatcher, isNot(contains('newCachedThreadPool')));
      },
    );

    test(
      'the bridge method is async (the answer comes from another thread) and says why',
      () {
        final bridge = read('pigeons/bridge.dart');
        expect(
          bridge,
          contains(
            '@async\n  bool logException(String payload, bool handled, String? domain);',
          ),
        );
        expect(
          read('$java/Messages.java'),
          contains(
            'void logException(@NonNull String payload, @NonNull Boolean handled, @Nullable String domain, @NonNull Result<Boolean> result);',
          ),
        );
      },
    );

    test(
      'iOS: the SDK call stays on the main queue (it reads UIKit state)',
      () {
        final swift = read(
          'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
        );
        final start = swift.indexOf('func logException(');
        final body = swift.substring(
          start,
          swift.indexOf('// MARK: Report handlers'),
        );
        expect(body, contains('DispatchQueue.main.async'));
      },
    );

    test(
      'nothing blocks and nothing is queued: no wait, no lock, no thread hop',
      () {
        for (final code in [javaCode, objcCode]) {
          for (final banned in [
            'synchronized',
            'wait(',
            'sleep(',
            'dispatch_semaphore',
            'dispatch_async',
            'dispatch_sync',
            'Handler(',
            'Executor',
          ]) {
            expect(code, isNot(contains(banned)), reason: banned);
          }
        }
      },
    );
  });
}
