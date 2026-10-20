// Guards for how the wrapper is registered before launch (workbook Part 2).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

/// The pattern the Bugsee Gradle plugin strips from the merged manifest.
final strippedByGradlePlugin = RegExp(r'^.*\.Bugsee[A-Za-z0-9_]+InitProvider$');

void main() {
  final manifest = read('android/src/main/AndroidManifest.xml');
  // Declared provider, ignoring comments.
  final live = manifest.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  final provider = RegExp(r'<provider\b[^>]*>', dotAll: true).allMatches(live);

  group('Android provider', () {
    test('exactly one provider, with the required attributes', () {
      expect(provider, hasLength(1));
      final tag = provider.single.group(0)!;
      expect(
        tag,
        contains(
          'android:name="com.bugsee.flutter.FlutterWrapperInitProvider"',
        ),
      );
      expect(tag, contains('android:initOrder="200"'));
      expect(tag, contains('android:directBootAware="true"'));
      expect(tag, contains('android:exported="false"'));
      expect(
        tag,
        contains(
          r'android:authorities="${applicationId}.bugseeflutterwrapperinit"',
        ),
      );
    });

    test('class name is not one the Gradle plugin strips', () {
      final name = RegExp(
        r'android:name="([^"]+)"',
      ).firstMatch(provider.single.group(0)!)!.group(1)!;
      expect(strippedByGradlePlugin.hasMatch(name), isFalse);
      // The regex does catch the trap name (guards the guard).
      expect(
        strippedByGradlePlugin.hasMatch(
          'com.bugsee.flutter.BugseeWrapperInitProvider',
        ),
        isTrue,
      );
      // The same regex is asserted by the JUnit test on the real class.
      expect(
        read(
          'android/src/test/java/com/bugsee/flutter/FlutterWrapperInitProviderTest.java',
        ),
        contains(strippedByGradlePlugin.pattern.replaceAll(r'\', r'\\')),
      );
    });

    test(
      'class exists, extends the SDK base and registers in onExtensionCreate',
      () {
        final java = read(
          'android/src/main/java/com/bugsee/flutter/FlutterWrapperInitProvider.java',
        );
        expect(
          java,
          contains(
            'public final class FlutterWrapperInitProvider extends BugseeExtensionInitProviderBase',
          ),
        );
        expect(
          java,
          contains(
            'import com.bugsee.library.BugseeExtensionInitProviderBase;',
          ),
        );
        expect(
          RegExp(
            r'protected boolean onExtensionCreate\(\) \{[^}]*Bugsee::setWrapper',
          ).hasMatch(java),
          isTrue,
        );
      },
    );

    test('no other provider or Bugsee-named InitProvider class ships', () {
      final files = Directory('android/src/main/java')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.split('/').last);
      for (final f in files) {
        expect(f, isNot(matches(RegExp(r'^Bugsee.+InitProvider\.java$'))));
      }
    });
  });

  group('iOS registration', () {
    test('register(with:) registers the wrapper', () {
      final swift = read(
        'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
      );
      expect(
        RegExp(
          r'static func register\(with registrar: FlutterPluginRegistrar\) \{\s*registerWrapper\(\)',
        ).hasMatch(swift),
        isTrue,
      );
      expect(swift, contains('Bugsee.setWrapper(wrapper)'));
      expect(
        read('ios/bugsee_flutter/Sources/bugsee_flutter/FlutterWrapper.swift'),
        contains('final class FlutterWrapper: NSObject, BugseeWrapper'),
      );
    });
  });
}
