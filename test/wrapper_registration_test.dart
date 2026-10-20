// Guards for how the wrapper is registered before launch (workbook Part 2).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

/// Source with `//` and `/* */` comments removed, so a registration call that
/// has only been commented out does not satisfy a guard.
String code(String path) => read(path)
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

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

    test('class exists, extends the SDK base and registers in onExtensionCreate', () {
      final java = code(
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
        contains('import com.bugsee.library.BugseeExtensionInitProviderBase;'),
      );
      // Comments are stripped, so a commented-out call fails these.
      expect(java, contains('sdkSetter = Bugsee::setWrapper;'));
      expect(
        RegExp(
          r'protected boolean onExtensionCreate\(\) \{[^}]*registerEarly\(sdkSetter\)',
        ).hasMatch(java),
        isTrue,
      );
      expect(
        RegExp(
          r'registerEarly\([^)]*\) \{\s*try \{\s*register\.set\(FlutterWrapper\.atProcessStart\(\)\)',
        ).hasMatch(java),
        isTrue,
      );
    });

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
    const base = 'ios/bugsee_flutter/Sources';

    test('wrapper registers at image load, not only from the engine', () {
      final m = code('$base/bugsee_flutter_wrapper/BGSFlutterWrapper.m');
      expect(m, contains('@interface BGSFlutterWrapper () <BugseeWrapper>'));
      expect(
        RegExp(r'\+ \(void\)load \{\s*\[self ensureRegistered\];').hasMatch(m),
        isTrue,
        reason:
            '+load runs before main, so a native launch in '
            'didFinishLaunching still finds a wrapper',
      );
      expect(m, contains('[Bugsee setWrapper:(id<BugseeWrapper>)gWrapper];'));
      expect(
        m,
        contains('gWrapper = [BGSFlutterWrapper wrapperAtProcessStart];'),
      );
    });

    test('secure rectangles stub is empty with the unknown version (0)', () {
      final m = code('$base/bugsee_flutter_wrapper/BGSFlutterWrapper.m');
      expect(m, contains('int32_t ints[2] = {0, 0};'));
    });

    test('Swift plugin class stays thin and references the wrapper target', () {
      final swift = code('$base/bugsee_flutter/BugseeFlutterPlugin.swift');
      expect(swift, contains('import BugseeFlutterWrapper'));
      expect(
        RegExp(
          r'static func register\(with registrar: FlutterPluginRegistrar\) \{\s*BGSFlutterWrapperRegistrar\.ensureRegistered\(\)',
        ).hasMatch(swift),
        isTrue,
        reason: 'also keeps the ObjC object file linked from the archive',
      );
      expect(swift, isNot(contains('Bugsee.setWrapper')));
    });

    test('Package.swift declares the Objective-C target the plugin uses', () {
      final manifest = read('ios/bugsee_flutter/Package.swift');
      expect(manifest, contains('name: "BugseeFlutterWrapper"'));
      expect(manifest, contains('path: "Sources/bugsee_flutter_wrapper"'));
      expect(manifest, contains('"BugseeFlutterWrapper"\n'));
    });
  });
}
