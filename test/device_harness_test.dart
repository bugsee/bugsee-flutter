// The CI-safe core of the device verification harness (scripts/device, doc/verification.md). The harness
// itself needs an emulator or simulator and is not run in CI; its parsers, its assertions and its 9.1
// guards are pure functions, and each is tested here against text taken from real runs AND against text
// that must make it fail: a check that cannot fail is not evidence (workbook 9.2).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/device/build.dart';
import '../scripts/device/checks.dart';
import '../scripts/device/report.dart';
import '../scripts/device/toolchain.dart';
import '../scripts/device/core/bundle.dart';
import '../scripts/device/core/experiment.dart';
import '../scripts/device/core/expectations.dart';
import '../scripts/device/core/image.dart';
import '../scripts/device/core/log_parsers.dart';
import '../scripts/device/core/symbols.dart';
import '../scripts/device/core/zip.dart';
import '../scripts/device/ios_build.dart';

/// A zip with stored entries, enough to exercise the readers.
Uint8List storedZip(Map<String, List<int>> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  void u16(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  for (final e in files.entries) {
    final name = utf8.encode(e.key);
    final offset = out.length;
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, 0);
    u16(out, 0); // stored
    u16(out, 0);
    u16(out, 0);
    u32(out, 0); // crc (not checked by the reader)
    u32(out, e.value.length);
    u32(out, e.value.length);
    u16(out, name.length);
    u16(out, 0);
    out.add(name);
    out.add(e.value);
    u32(central, 0x02014b50);
    u16(central, 20);
    u16(central, 20);
    u16(central, 0);
    u16(central, 0); // stored
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, e.value.length);
    u32(central, e.value.length);
    u16(central, name.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, offset);
    central.add(name);
    count++;
  }
  final start = out.length;
  out.add(central.toBytes());
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, count);
  u16(out, count);
  u32(out, central.length);
  u32(out, start);
  u16(out, 0);
  return out.toBytes();
}

Pins pins() => Pins.read('.');

BuildExpectation expectation({String mode = 'debug'}) => BuildExpectation(
  pins: pins(),
  wrapperVersion: '10.0.0-dev.1',
  flutterVersion: '3.41.0',
  dartVersion: '3.11.0',
  engineRevision: '3452d735bd',
  mode: mode,
);

const androidLog = '''
10-22 11:46:48.777  7138  7138 I BugseeFlutter: wrapper registered type=flutter version=10.0.0-dev.1
10-22 11:46:50.229  7138  7138 I BugseeFlutter: wrapper refined type=flutter version=10.0.0-dev.1 context={dart=3.11.0, flutter=3.41.0, flutter-engine=3452d735bd, build-configuration=debug}
10-22 11:46:50.276  7138  7138 D Bugsee  : Bugsee Android SDK 7.4.2 [3b7af6371]
10-22 11:44:41.228  6080  6080 W linker64: type=1400 audit(0.0:89): avc: granted { execute } for path="/data/data/x/no_backup/bugsee_crashpad_handler/1792647760186/libbugsee-crashpad-trampoline.so" dev="dm-4"
10-22 11:44:41.228  6080  6080 W linker64: type=1400 audit(0.0:90): avc: granted { execute } for path="/data/data/x/no_backup/bugsee_crashpad_handler/1792647760186/libbugsee-crashpad-handler.so" dev="dm-4"
10-22 11:44:42.228  6080  6080 W linker64: type=1400 audit(0.0:91): avc: granted { execute } for path="/data/data/x/no_backup/bugsee_crashpad_handler/1792647760186/libbugsee-crashpad-trampoline.so" dev="dm-4"
10-22 11:44:41.285  5882  5882 F libc    : Fatal signal 11 (SIGSEGV), code 0 (SI_USER from pid 6078, uid 10166) in tid 5882 (flutter_example), pid 5882 (flutter_example)
''';

void main() {
  group('banners and wrapper identity (9.1.1)', () {
    test('the Android banner and the wrapper lines parse', () {
      final b = parseAndroidBanner(androidLog)!;
      expect([b.version, b.build], ['7.4.2', '3b7af6371']);
      final w = parseWrapperLog(androidLog);
      expect(w.registered, 'flutter/10.0.0-dev.1');
      expect(w.refined, 'flutter/10.0.0-dev.1');
      expect(w.context, {
        'dart': '3.11.0',
        'flutter': '3.41.0',
        'flutter-engine': '3452d735bd',
        'build-configuration': 'debug',
      });
    });

    test('the iOS banner and the NSDictionary context parse', () {
      const log = '''
2026-10-22 11:19:15.083 Df Runner[60233:9e1d3b5] (Runner.debug.dylib) [BugseeFlutter] wrapper registered type=flutter version=10.0.0-dev.1
2026-10-22 11:19:15.083 Df Runner[60233:9e1d3b5] (Runner.debug.dylib) [BugseeFlutter] wrapper refined type=flutter version=10.0.0-dev.1 context={
    "build-configuration" = debug;
    dart = "3.11.0";
    flutter = "3.41.0";
    "flutter-engine" = 3452d735bd;
}
2026-10-22 11:19:15.375 Df Runner[60233:9e1d3b5] (Bugsee) Bugsee IOS SDK ver:7.0.0-beta7 build:9854b7e50-15
''';
      final b = parseIosBanner(log)!;
      expect([b.version, b.build], ['7.0.0-beta7', '9854b7e50-15']);
      final w = parseWrapperLog(log);
      expect(w.context['build-configuration'], 'debug');
      expect(w.context['flutter-engine'], '3452d735bd');
      expect(expectation().iosProblems(b, w), isEmpty);
    });

    test(
      'the build under test is accepted, and every way of testing another one is refused',
      () {
        final e = expectation();
        final banner = parseAndroidBanner(androidLog);
        final w = parseWrapperLog(androidLog);
        expect(e.androidProblems(banner, w), isEmpty);
        // The same version string, another build of it (a range outranking a snapshot).
        expect(
          e.androidProblems(
            const SdkBanner('android', '7.4.2', 'deadbeef0'),
            w,
          ),
          contains(contains('banner build deadbeef0')),
        );
        expect(
          e.androidProblems(
            const SdkBanner('android', '7.4.3', '3b7af6371'),
            w,
          ),
          contains(contains('banner version 7.4.3')),
        );
        expect(
          e.androidProblems(null, w),
          contains(contains('no Android SDK banner')),
        );
        // The wrapper: not registered, a version of another package, a build mode that is not this build's.
        expect(
          e.androidProblems(banner, const WrapperLog()),
          contains(contains('wrapper registered as null')),
        );
        expect(
          expectation(mode: 'release').androidProblems(banner, w),
          contains(contains('build-configuration is debug, expected release')),
        );
      },
    );

    test('the wrapper identity in a report is compared field by field', () {
      final e = expectation();
      expect(e.wrapperInReport(e.wrapper), isEmpty);
      expect(e.wrapperInReport(null), isNotEmpty);
      expect(
        e.wrapperInReport({
          'type': 'flutter',
          'version': '9.9.9',
          'context': (e.wrapper['context']),
        }),
        contains(contains('wrapper version 9.9.9')),
      );
      expect(
        e.wrapperInReport({'type': 'flutter', 'version': e.wrapperVersion}),
        contains('wrapper context absent'),
      );
    });

    test(
      'native-versions.json carries the banner builds the harness matches',
      () {
        final p = pins();
        expect(p.androidSdkBuild, matches(RegExp(r'^[0-9a-f]{7,}$')));
        expect(p.iosSdkBuild, isNotEmpty);
        expect(p.iosSpmRevision, hasLength(40));
        expect(p.iosFeedbackSpmRevision, hasLength(40));
      },
    );
  });

  group('libraries (1.2.3, 1.4.2)', () {
    test('distinct, not occurrences', () {
      expect(distinctBugseeLibs(androidLog), {
        'libbugsee-crashpad-trampoline.so',
        'libbugsee-crashpad-handler.so',
      });
      expect(distinctBugseeLibs('no libraries here'), isEmpty);
    });

    test('a library mapped from base.apk is recognised by its offset', () {
      final entries = [
        const ZipEntry(
          name: 'lib/arm64-v8a/libbugsee-crashcp.so',
          method: 0,
          dataStart: 0x23f8000,
          compressedSize: 1884672,
          size: 1884672,
        ),
        const ZipEntry(
          name: 'lib/arm64-v8a/libbugsee-native.so',
          method: 0,
          dataStart: 0x26cc000,
          compressedSize: 497744,
          size: 497744,
        ),
        const ZipEntry(
          name: 'lib/arm64-v8a/libflutter.so',
          method: 0,
          dataStart: 0x2748000,
          compressedSize: 37162160,
          size: 37162160,
        ),
        const ZipEntry(
          name: 'lib/x86_64/libbugsee-native.so',
          method: 0,
          dataStart: 0x9000000,
          compressedSize: 10,
          size: 10,
        ),
      ];
      const maps = '''
76c83c5000-76c8583000 r-xp 023f8000 fd:04 40963                          /data/app/~~x==/pkg-y==/base.apk
76c9717000-76c978f000 r-xp 026cc000 fd:04 40963                          /data/app/~~x==/pkg-y==/base.apk
76e3ca3000-76e5f87000 r-xp 02748000 fd:04 40963                          /data/app/~~x==/pkg-y==/base.apk
76e5f96000-76e6020000 r--p 025b5000 fd:04 40963                          /data/app/~~x==/pkg-y==/base.apk
79ee7ef000-79ee7f0000 r--p 00000000 00:00 0                              [anon:dalvik-classes5.dex extracted in memory from /data/app/~~x==/pkg-y==/base.apk!classes5.dex]
''';
      expect(
        mappedBugseeLibs(
          maps,
          entries,
          'arm64-v8a',
          apkPath: '/data/app/~~x==/pkg-y==/base.apk',
        ),
        {'libbugsee-native.so', 'libbugsee-crashcp.so'},
      );
      // Nothing mapped, nothing found; another ABI's entries never match.
      expect(
        mappedBugseeLibs(
          '',
          entries,
          'arm64-v8a',
          apkPath: '/data/app/~~x==/pkg-y==/base.apk',
        ),
        isEmpty,
      );
      expect(
        mappedBugseeLibs(
          maps,
          entries,
          'x86_64',
          apkPath: '/data/app/~~x==/pkg-y==/base.apk',
        ),
        isEmpty,
      );
    });

    test(
      'the central directory gives the offset where an entry\'s data starts',
      () {
        final bytes = storedZip({
          'a.txt': utf8.encode('hello'),
          'lib/arm64-v8a/libbugsee-native.so': List.filled(10, 7),
        });
        final entries = zipEntries(bytes);
        expect(entries.map((e) => e.name), [
          'a.txt',
          'lib/arm64-v8a/libbugsee-native.so',
        ]);
        expect(utf8.decode(zipRead(bytes, entries.first)), 'hello');
        expect(entries.last.contains(entries.last.dataStart + 9), isTrue);
        expect(entries.last.contains(entries.last.dataStart + 10), isFalse);
        expect(apkBugseeLibs(entries, 'arm64-v8a'), {'libbugsee-native.so'});
        expect(
          () => zipEntries(Uint8List.fromList([1, 2, 3])),
          throwsFormatException,
        );
      },
    );
  });

  group('the event happened (9.1.4)', () {
    test('signal 11, for this pid and no other', () {
      final s = parseFatalSignal(androidLog, 5882)!;
      expect([s.number, s.name], [11, 'SIGSEGV']);
      expect(parseFatalSignal(androidLog, 1234), isNull);
      expect(
        parseFatalSignal(
          'F libc: Fatal signal 6 (SIGABRT), code -6 (SI_TKILL) in tid 1 (x), pid 77 (x)',
          77,
        )!.number,
        6,
      );
    });

    test('the exit record must say native crash, status 11', () {
      const dump = '''
        ApplicationExitInfo #1:
          pid=100
          reason=10 (USER REQUESTED)
          status=0
        ApplicationExitInfo #0:
          pid=5882
          reason=5 (APP CRASH(NATIVE))
          status=11
''';
      final e = parseExitInfo(dump, 5882)!;
      expect(e.isNativeCrash, isTrue);
      expect(e.status, 11);
      expect(parseExitInfo(dump, 100)!.isNativeCrash, isFalse);
      expect(parseExitInfo(dump, 7), isNull);
    });

    test('launchd\'s account of an iOS simulator process', () {
      const log =
          '2026-10-22 11:18:46.122 Df launchd_sim[84036:9e1bdb6] [user/501/UIKitApplication:com.bugsee.bugseeFlutterExample[404c][rb-legacy] [58975]:] exited due to SIGSEGV | sent by zsh[58925], ran for 25033ms';
      final x = parseIosExit(log, 58975)!;
      expect([x.signal, x.sentBy], ['SIGSEGV', 'zsh[58925]']);
      expect(parseIosExit(log, 1), isNull);
    });
  });

  group('the iOS release link (dead strip)', () {
    test('classes with a +load are read out of __objc_nlclslist', () {
      const otool = '''
example/build/ios/iphoneos/Runner.app/Runner:
Contents of (__DATA_CONST,__objc_nlclslist) section
0000000100092d58	000a11b0 00100000 000a12f0 00100000 
0000000100092d68	000a2940 00100000 
''';
      final s = parseNonLazyClassList(otool);
      expect(s, {0x1000a11b0, 0x1000a12f0, 0x1000a2940});
      expect(
        parseNonLazyClassList(
          'Contents of (__DATA_CONST,__objc_nlclslist) section\n',
        ),
        isEmpty,
      );
    });

    test('a class symbol is found by its exact name', () {
      const nm = '''
00000001000a12f0 S _OBJC_CLASS_\$_BGSFlutterFeedbackRegistrar
00000001000a2940 S _OBJC_CLASS_\$_BGSFlutterWrapperRegistrar
00000001000a11b0 S _OBJC_CLASS_\$_BugseeFeedbackAutoRegister
00000001000a1000 S _OBJC_CLASS_\$_BugseeFeedbackAutoRegisterOther
''';
      expect(objcClassAddress(nm, 'BugseeFeedbackAutoRegister'), 0x1000a11b0);
      expect(objcClassAddress(nm, 'BGSFlutterFeedbackRegistrar'), 0x1000a12f0);
      expect(objcClassAddress(nm, 'Missing'), isNull);
      // A stripped registrar is absent from nlclslist: the check is the pair of facts.
      final withLoad = parseNonLazyClassList(
        '0000000100092d58\t000a11b0 00100000\n',
      );
      expect(
        withLoad.contains(objcClassAddress(nm, 'BGSFlutterFeedbackRegistrar')),
        isFalse,
      );
    });
  });

  group('artefacts (1.2.2, 1.4.1)', () {
    test(
      'Gradle dependencies: the NDK artefact is found, and its absence is reported',
      () {
        const deps = '''
+--- project :bugsee_flutter
|    +--- com.bugsee:bugsee-android:7.4.2
|    +--- com.bugsee:bugsee-android-ndk:7.4.2
|    |    \\--- com.bugsee:bugsee-android:7.4.2
''';
        expect(parseGradleBugseeArtefacts(deps), {
          'bugsee-android': {'7.4.2'},
          'bugsee-android-ndk': {'7.4.2'},
        });
        expect(
          parseGradleBugseeArtefacts(
            '+--- com.bugsee:bugsee-android:7.4.1 -> 7.4.2',
          ),
          {
            'bugsee-android': {'7.4.2'},
          },
        );
      },
    );

    test('the merged manifest\'s providers', () {
      const xml = '''
        <provider
            android:name="com.bugsee.flutter.FlutterWrapperInitProvider"
            android:exported="false"
            android:initOrder="200"
            android:directBootAware="true" />
        <provider
            android:name="com.bugsee.library.BugseeInitProvider"
            android:exported="false"
            android:initOrder="100" />
''';
      final p = parseProviders(xml);
      expect(p.map((x) => '${x.name}:${x.initOrder}'), [
        'com.bugsee.flutter.FlutterWrapperInitProvider:200',
        'com.bugsee.library.BugseeInitProvider:100',
      ]);
    });

    AndroidBuild fakeBuild({
      Map<String, Set<String>>? deps,
      Set<String>? plugin,
      String? manifest,
      List<String>? libs,
    }) {
      final entries = [
        for (final l
            in libs ??
                [
                  'crashcp',
                  'crashpad-handler',
                  'crashpad-trampoline',
                  'native',
                ])
          ZipEntry(
            name: 'lib/arm64-v8a/libbugsee-$l.so',
            method: 0,
            dataStart: 0,
            compressedSize: 1,
            size: 1,
          ),
      ];
      return AndroidBuild(
        name: 'x',
        mode: 'release',
        apk: 'x.apk',
        buildNumber: 1,
        obfuscated: false,
        entries: entries,
        apkBytes: Uint8List(0),
        manifestXml:
            manifest ??
            '<provider android:name="com.bugsee.flutter.FlutterWrapperInitProvider" android:initOrder="200"/>'
                '<provider android:name="com.bugsee.library.BugseeInitProvider" android:initOrder="100"/>',
        gradleDependencies:
            deps ??
            {
              'bugsee-android': {'7.4.2'},
              'bugsee-android-ndk': {'7.4.2'},
            },
        gradlePluginVersions: plugin ?? {'4.0.8'},
        buildUuid: 'id',
      );
    }

    test(
      'the pinned artefact set passes; each way of missing it fails the guard',
      () {
        final p = pins();
        expect(fakeBuild().artefactProblems(p, 'arm64-v8a'), isEmpty);
        expect(
          fakeBuild(
            deps: {
              'bugsee-android': {'7.4.2'},
            },
          ).artefactProblems(p, 'arm64-v8a'),
          contains(
            contains('bugsee-android-ndk is not in the dependency graph'),
          ),
        );
        expect(
          fakeBuild(
            deps: {
              'bugsee-android': {'7.4.2'},
              'bugsee-android-ndk': {'7.4.1'},
            },
          ).artefactProblems(p, 'arm64-v8a'),
          contains(contains('resolved to {7.4.1}')),
        );
        expect(
          fakeBuild(plugin: {'4.0.6'}).artefactProblems(p, 'arm64-v8a'),
          contains(contains('Gradle plugin versions in use {4.0.6}')),
        );
        expect(
          fakeBuild(
            plugin: {'4.0.8', '4.0.6'},
          ).artefactProblems(p, 'arm64-v8a'),
          isNotEmpty,
        );
        expect(
          fakeBuild(libs: ['native']).artefactProblems(p, 'arm64-v8a'),
          contains(contains('APK (arm64-v8a) carries')),
        );
        expect(
          fakeBuild(
            manifest:
                '<provider android:name="com.bugsee.library.BugseeInitProvider" android:initOrder="100"/>',
          ).artefactProblems(p, 'arm64-v8a'),
          contains(contains('was stripped')),
        );
        expect(
          fakeBuild(
            manifest:
                '<provider android:name="com.bugsee.flutter.FlutterWrapperInitProvider" android:initOrder="50"/><provider android:name="com.bugsee.library.BugseeInitProvider" android:initOrder="100"/>',
          ).artefactProblems(p, 'arm64-v8a'),
          contains(contains('initOrder 50, expected 200')),
        );
      },
    );

    test(
      'the iOS build must have resolved the pinned revision, not a path or another tag',
      () {
        final p = pins();
        IosBuild b(Map<String, String> resolved) => IosBuild(
          name: 'd',
          mode: 'debug',
          app: 'x.app',
          buildNumber: 1,
          resolved: resolved,
          sdkFrameworkVersion: '7.0.0',
        );
        final ok = {
          'spm': '${p.iosSdk}@${p.iosSpmRevision}',
          'feedback-spm': '${p.iosSdk}@${p.iosFeedbackSpmRevision}',
        };
        expect(b(ok).artefactProblems(p), isEmpty);
        expect(
          b({...ok, 'spm': '${p.iosSdk}@${'0' * 40}'}).artefactProblems(p),
          isNotEmpty,
        );
        expect(
          b({...ok, 'spm': 'fileSystem:/tmp/spm'}).artefactProblems(p),
          isNotEmpty,
        );
        expect(
          b({'feedback-spm': ok['feedback-spm']!}).artefactProblems(p),
          isNotEmpty,
        );
      },
    );
  });

  group('verification app output', () {
    test(
      'VERIFY lines are read out of a log and a malformed one is skipped',
      () {
        const log = '''
I flutter : VERIFY|{"kind":"main","ms":0,"mode":"debug","pid":1}
I flutter : VERIFY|{not json}
Runner[1:2] (Flutter) flutter: VERIFY|{"kind":"handler","phase":"before","type":"crash"}
''';
        final e = parseVerifyEvents(log);
        expect(e.map((x) => x.kind), ['main', 'handler']);
        expect(e.last['phase'], 'before');
      },
    );

    test('the managed exception document is read with the worker\'s rules', () {
      const reason =
          'com.bugsee.flutter.FlutterManagedException: {"internalType":"FlutterManagedException","name":"StateError","reason":"x","signature":"s","frames":[],"originalStackTrace":"t"}';
      final doc = parseManagedDocument(reason)!;
      expect(doc.keys.toSet(), managedDocumentKeys);
      expect(parseManagedDocument('not a document'), isNull);
    });
  });

  group('bundles', () {
    Bundle bundle({String? identitySource = 'session', Object? wrapper}) {
      final request = {
        'type': 'crash',
        'summary': 'Native crash',
        'labels': ['verify-after'],
        'environment': {
          'app': {'build': '1', 'version': '1.0.1'},
          'sdk': {
            'version': '7.4.2',
            'build': '3b7af6371',
            'wrapper': ?wrapper,
          },
          'identity_source': ?identitySource,
        },
      };
      final manifest = {
        'files': [
          {'filename': 'crash.json', 'type': 'crash'},
          {
            'filename': 'a.attachment.bgsfile',
            'type': 'attachment',
            'name': 'verify-enrichment',
          },
        ],
        'attrs': {'verify.before': '{}'},
      };
      return Bundle.fromZip(
        't',
        storedZip({
          'request.json': utf8.encode(jsonEncode(request)),
          'manifest.json': utf8.encode(jsonEncode(manifest)),
          'crash.json': utf8.encode(
            jsonEncode({
              'ndkCrash': true,
              'signal': {'number': 11},
            }),
          ),
          'a.attachment.bgsfile': utf8.encode('enrichment'),
        }),
      );
    }

    test('identity, marker, entries and the crash are read', () {
      final b = bundle(wrapper: expectation().wrapper);
      expect(b.type, 'crash');
      expect(b.identitySource, 'session');
      expect(b.app['build'], '1');
      expect(expectation().wrapperInReport(b.wrapper), isEmpty);
      expect(b.crash!['ndkCrash'], isTrue);
      expect(b.entriesOfType('attachment').single['name'], 'verify-enrichment');
      expect(
        utf8.decode(b.content(b.entriesOfType('attachment').single)),
        'enrichment',
      );
      expect(b.attributes.keys, ['verify.before']);
    });

    test(
      'a recovered report WITHOUT the wrapper is caught (the relaunch-after-crash trap)',
      () {
        final b = bundle(wrapper: null);
        expect(expectation().wrapperInReport(b.wrapper), isNotEmpty);
      },
    );

    test('a zip that is not a bundle is refused', () {
      expect(
        () => Bundle.fromZip(
          't',
          storedZip({
            'x': [1],
          }),
        ),
        throwsFormatException,
      );
    });
  });

  group('pixels', () {
    RawImage image(
      int w,
      int h,
      void Function(int x, int y, List<int> px) paint,
    ) {
      final rgb = Uint8List(w * h * 3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final px = [255, 255, 255];
          paint(x, y, px);
          rgb.setRange((y * w + x) * 3, (y * w + x) * 3 + 3, px);
        }
      }
      return RawImage(w, h, rgb);
    }

    void box(int x, int y, List<int> px, Rect r, List<int> color) {
      if (x >= r.left && x < r.right && y >= r.top && y < r.bottom) {
        px
          ..[0] = color[0]
          ..[1] = color[1]
          ..[2] = color[2];
      }
    }

    const region = Rect(20, 30, 80, 70);

    test(
      'the region is found by its colour and the redaction check passes when it is black',
      () {
        final off = image(
          100,
          100,
          (x, y, p) => box(x, y, p, region, [255, 0, 255]),
        );
        final on = image(
          100,
          100,
          (x, y, p) => box(x, y, p, region, [0, 0, 0]),
        );
        expect(
          off.boundingBoxOf(const Rgb(255, 0, 255)).toString(),
          '[20,30,80,70]',
        );
        expect(on.fractionOf(region, const Rgb(0, 0, 0)), 1.0);
        expect(on.fractionOf(region, const Rgb(255, 0, 255)), 0.0);
      },
    );

    test(
      'a redaction that is too small leaves the region showing, and the numbers say so',
      () {
        const small = Rect(
          20,
          30,
          40,
          50,
        ); // a third of the area: the "wrong unit" failure
        final on = image(100, 100, (x, y, p) {
          box(x, y, p, region, [255, 0, 255]);
          box(x, y, p, small, [0, 0, 0]);
        });
        expect(on.fractionOf(region, const Rgb(0, 0, 0)), lessThan(0.97));
        expect(
          on.fractionOf(region, const Rgb(255, 0, 255)),
          greaterThan(0.01),
        );
        final cover = Coverage(region, small);
        expect(cover.areaRatio, closeTo(20 * 20 / (60 * 40), 1e-9));
        expect(cover.uncovered['right'], 40);
      },
    );

    test(
      'a frame with no such colour has no box, and a flat frame is flat',
      () {
        final white = image(10, 10, (x, y, p) {});
        expect(white.boundingBoxOf(const Rgb(255, 0, 255)), isNull);
        expect(white.isUniform(), isTrue);
        expect(
          image(
            10,
            10,
            (x, y, p) => box(x, y, p, const Rect(0, 0, 2, 2), [0, 0, 0]),
          ).isUniform(),
          isFalse,
        );
      },
    );

    test('a binary PPM is parsed', () {
      final header = utf8.encode('P6\n# comment\n2 1\n255\n');
      final ppm = Uint8List.fromList([...header, 255, 0, 0, 0, 255, 0]);
      final img = RawImage.fromPpm(ppm);
      expect([img.width, img.height], [2, 1]);
      expect(img.at(1, 0).g, 255);
      expect(
        () => RawImage.fromPpm(
          Uint8List.fromList(utf8.encode('P5\n1 1\n255\n0')),
        ),
        throwsFormatException,
      );
    });
  });

  group('the guards are the default (9.1.5)', () {
    test(
      'an invalid guard ends the scenario as invalid, never as a pass or a product failure',
      () async {
        final lines = <String>[];
        final r = await runScenario(1, 't', lines.add, (run) async {
          run.expect('before', true, '');
          run.guard('build', ['banner build deadbeef0, pinned 3b7af6371'], '');
          run.expect('after the guard: never reached', true, '');
        });
        expect(r.status, Status.invalid);
        expect(r.checks.map((c) => c.name), ['before', '[9.1] build']);
        expect(r.reason, contains('deadbeef0'));
      },
    );

    test(
      'a failed result is a failure; a thrown error is a failure; a scenario that asserts nothing is a failure',
      () async {
        expect(
          (await runScenario(
            1,
            't',
            (_) {},
            (run) async => run.expect('x', false, 'e'),
          )).status,
          Status.fail,
        );
        expect(
          (await runScenario(
            1,
            't',
            (_) {},
            (run) async => throw StateError('boom'),
          )).status,
          Status.fail,
        );
        expect(
          (await runScenario(1, 't', (_) {}, (run) async {})).status,
          Status.fail,
        );
        expect(
          (await runScenario(
            1,
            't',
            (_) {},
            (run) async => run.expect('x', true, ''),
          )).status,
          Status.pass,
        );
      },
    );

    test(
      'not possible is its own status, and a failure measured on the way still fails it',
      () async {
        final r = await runScenario(2, 't', (_) {}, (run) async {
          run.expect('control', true, '');
          throw NotPossible('no crash reporter in the simulator slice');
        });
        expect(r.status, Status.notPossible);
        expect(r.reason, contains('simulator slice'));
        final failed = await runScenario(2, 't', (_) {}, (run) async {
          run.expect('control', false, 'the control did not work');
          throw NotPossible('x');
        });
        expect(failed.status, Status.fail);
      },
    );
  });

  test('the report is JSON a person and a tool can read', () async {
    final r = await runScenario(3, 'title', (_) {}, (run) async {
      run.expect('a', true, 'evidence');
      run.note('measured 42');
      run.result.notCovered.add('x');
    });
    final json = jsonDecode(jsonEncode(r.toJson())) as Map;
    expect(json['status'], 'pass');
    expect((json['checks'] as List).single['evidence'], 'evidence');
    expect(json['notes'], ['measured 42']);
    expect(json['notCovered'], ['x']);
  });

  group('drift: what the harness repeats is compared to its source', () {
    String read(String p) => File(p).readAsStringSync();

    test(
      'the application id and bundle id the harness drives are the example app\'s',
      () {
        final gradle = read('example/android/app/build.gradle.kts');
        final android = read('scripts/device/android_scenarios.dart');
        final id = RegExp(
          r'''applicationId = "([^"]+)"''',
        ).firstMatch(gradle)!.group(1);
        expect(android, contains("const pkg = '$id'"));
        final pbx = read('example/ios/Runner.xcodeproj/project.pbxproj');
        final bundle = RegExp(
          r'PRODUCT_BUNDLE_IDENTIFIER = (com\.bugsee\.bugseeFlutterExample);',
        ).firstMatch(pbx)!.group(1);
        expect(
          read('scripts/device/ios_scenarios.dart'),
          contains("const bundleId = '$bundle'"),
        );
      },
    );

    test(
      'the build flags the harness passes are the ones the verification app reads',
      () {
        final app = read('example/lib/verify_main.dart');
        final android = read('scripts/device/build.dart');
        final ios = read('scripts/device/ios_build.dart');
        for (final define in ['VERIFY_SERVER', 'BUGSEE_ENDPOINT']) {
          expect(app, contains("fromEnvironment('$define'"));
          expect(android, contains('--dart-define=$define='));
          expect(ios, contains('--dart-define=$define='));
        }
        final builds = read('scripts/device/builds.dart');
        for (final m in RegExp(r'VERIFY_[A-Z]+(?==)').allMatches(builds)) {
          expect(
            app,
            contains("fromEnvironment('${m.group(0)}'"),
            reason: m.group(0),
          );
        }
      },
    );

    test(
      'every command the scenarios send is one the verification app handles',
      () {
        final app = read('example/lib/verify_main.dart');
        final handled = {
          for (final m in RegExp(r"case '([\w-]+)':").allMatches(app))
            m.group(1)!,
        };
        final sent = <String>{};
        for (final f in ['android_scenarios.dart', 'ios_scenarios.dart']) {
          final src = read('scripts/device/$f');
          // The formatter puts arguments on their own lines: \s* spans them.
          for (final m in RegExp(
            r"(?:command|_report|report|_product|product)\(\s*(?:run,\s*)?(?:name,\s*)?'([\w-]+)",
          ).allMatches(src)) {
            sent.add(m.group(1)!);
          }
        }
        // The scan itself must not rot: the scenarios send these today.
        expect(
          sent,
          containsAll([
            'upload',
            'upload-with-file',
            'create-report',
            'log-handled',
            'log-unhandled',
            'throw-async',
            'secure',
            'geometry',
            'vh',
            'net',
            'print',
          ]),
        );
        expect(
          handled.containsAll(sent),
          isTrue,
          reason: 'sent but not handled: ${sent.difference(handled)}',
        );
      },
    );

    test('the mock API serves every endpoint the harness uses', () {
      final mock = read('example/integration_test/support/mock_api.py');
      for (final path in [
        '/__cmd',
        '/__event',
        '/__events',
        '/__bundles',
        '/__reset',
        '/__mode',
      ]) {
        expect(mock, contains("'$path'"));
      }
    });

    test('the scripts and the verification app stay out of the published archives', () {
      // scripts/ is published today (the pins check lives there); the harness is dev tooling and must not be.
      final ignore = read('.pubignore');
      final check = read('scripts/check_pub_archive.sh');
      for (final path in [
        'scripts/device/',
        'test/device_harness_test.dart',
        'example/lib/verify_main.dart',
      ]) {
        expect(ignore, contains('/$path'), reason: '.pubignore: $path');
        expect(
          check,
          contains(path.replaceAll('.', r'\.')),
          reason: 'check_pub_archive.sh: $path',
        );
      }
      // And nothing that IS published may import something that is not: a published test or script
      // with broken imports (the harness test imported ../scripts/device/...).
      const excluded = [
        'scripts/device/',
        'test/device_harness_test.dart',
        'example/lib/verify_main.dart',
        'packages/',
        'pigeons/',
        'ios/wrapper_tests/',
      ];
      bool isExcluded(String p) => excluded.any(p.startsWith);
      final published = [
        for (final root in [
          'lib',
          'test',
          'scripts',
          'example/lib',
          'example/integration_test',
        ])
          for (final f in Directory(root).listSync(recursive: true))
            if (f is File && f.path.endsWith('.dart') && !isExcluded(f.path))
              f.path,
      ];
      expect(published, isNotEmpty);
      for (final file in published) {
        for (final m in RegExp(
          r'''^\s*(?:import|export)\s+'([^']+)';''',
          multiLine: true,
        ).allMatches(read(file))) {
          final target = m.group(1)!;
          String? resolved;
          if (target.startsWith('package:bugsee_flutter_example/')) {
            resolved =
                'example/lib/${target.substring('package:bugsee_flutter_example/'.length)}';
          } else if (!target.contains(':')) {
            resolved = Uri.parse(file).resolve(target).path;
          }
          expect(
            resolved != null && isExcluded(resolved),
            isFalse,
            reason: '$file imports $target, which is not published',
          );
        }
      }
      // The scan itself can fail: a synthetic importer of an excluded path is caught.
      expect(
        isExcluded(
          Uri.parse(
            'test/x_test.dart',
          ).resolve('../scripts/device/core/zip.dart').path,
        ),
        isTrue,
      );
    });
  });

  group('mutation checks of the assertions themselves', () {
    RawImage frame(
      int w,
      int h,
      bool Function(int x, int y) black, {
      bool magenta = false,
    }) {
      final rgb = Uint8List(w * h * 3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 3;
          final inBox = x >= 40 && x < 100 && y >= 50 && y < 90;
          final c = black(x, y)
              ? [0, 0, 0]
              : (inBox && magenta ? [255, 0, 255] : [255, 255, 255]);
          rgb.setRange(i, i + 3, c);
        }
      }
      return RawImage(w, h, rgb);
    }

    Future<ScenarioResult> redaction(RawImage on, RawImage off) => runScenario(
      1,
      't',
      (_) {},
      (run) async => checkRedaction(run, 'x', on, off),
    );

    final off = frame(200, 200, (x, y) => false, magenta: true);

    test('a correct redaction passes', () async {
      final on = frame(
        200,
        200,
        (x, y) => x >= 38 && x < 102 && y >= 48 && y < 92,
      );
      expect((await redaction(on, off)).status, Status.pass);
    });

    test(
      'a frame blacked out WHOLE fails (the box is black, so the box test alone would pass)',
      () async {
        final r = await redaction(frame(200, 200, (x, y) => true), off);
        expect(r.status, Status.fail);
        expect(
          r.checks.where((c) => !c.ok).map((c) => c.name).join(),
          contains('not blacked out whole'),
        );
      },
    );

    test('a redaction that spills over a large ring fails', () async {
      final on = frame(
        200,
        200,
        (x, y) => x >= 20 && x < 130 && y >= 30 && y < 110,
      );
      final r = await redaction(on, off);
      expect(r.status, Status.fail);
    });

    test(
      'a box near the frame edge is judged on the clamped ring (no spurious failure)',
      () async {
        // The box starts 5 px from the left edge: the 14 px ring runs off the frame.
        RawImage edge(bool secured) {
          final rgb = Uint8List(200 * 200 * 3)
            ..fillRange(0, 200 * 200 * 3, 255);
          for (var y = 50; y < 90; y++) {
            for (var x = 5; x < 65; x++) {
              final i = (y * 200 + x) * 3;
              rgb.setRange(i, i + 3, secured ? [0, 0, 0] : [255, 0, 255]);
            }
          }
          return RawImage(200, 200, rgb);
        }

        expect((await redaction(edge(true), edge(false))).status, Status.pass);
        final c = edge(
          true,
        ).countOf(const Rect(-9, 36, 79, 104), const Rgb(0, 0, 0));
        expect(c.total, (79 - 0) * (104 - 36));
        expect(
          edge(
            true,
          ).countOf(const Rect(190, 190, 230, 230), const Rgb(0, 0, 0)).total,
          100,
        );
      },
    );

    test(
      'the dart next to flutter is found from its directory, not by editing the path',
      () {
        Toolchain tc(String flutter) => Toolchain(
          repoRoot: '.',
          workDir: '.',
          flutter: flutter,
          javaHome: null,
          gradleHome: '.',
          androidHome: '.',
        );
        expect(
          tc('/Users/x/flutter/bin/flutter').dartExecutable,
          '/Users/x/flutter/bin/dart',
        );
        expect(tc('flutter').dartExecutable, 'dart');
      },
    );

    test('an unredacted box fails', () async {
      expect(
        (await redaction(
          frame(200, 200, (x, y) => false, magenta: true),
          off,
        )).status,
        Status.fail,
      );
    });

    test(
      'an empty rectangle has no pixels of the colour (a mutation returning 1 is caught)',
      () {
        final img = frame(10, 10, (x, y) => true);
        expect(img.fractionOf(const Rect(5, 5, 5, 5), const Rgb(0, 0, 0)), 0);
        expect(
          img.fractionOf(const Rect(50, 50, 60, 60), const Rgb(0, 0, 0)),
          0,
        );
        expect(
          img.agreementOutside(
            frame(9, 9, (x, y) => true),
            const Rect(0, 0, 1, 1),
          ),
          0,
        );
      },
    );

    test(
      'a mapping of ANOTHER apk at an offset inside base.apk\'s library range is not a library',
      () {
        final entries = [
          const ZipEntry(
            name: 'lib/arm64-v8a/libbugsee-native.so',
            method: 0,
            dataStart: 0x26cc000,
            compressedSize: 497744,
            size: 497744,
          ),
        ];
        const base = '/data/app/~~x==/pkg-y==/base.apk';
        const other = '/system/framework/framework-res.apk';
        const framework = '7000000000-7000100000 r--p 026cc000 fd:00 10 $other';
        const own =
            '76c9717000-76c978f000 r-xp 026cc000 fd:04 40963                          $base';
        expect(
          mappedBugseeLibs(framework, entries, 'arm64-v8a', apkPath: base),
          isEmpty,
        );
        expect(
          mappedBugseeLibs(
            '$framework\n$own',
            entries,
            'arm64-v8a',
            apkPath: base,
          ),
          {'libbugsee-native.so'},
        );
      },
    );

    test(
      'the iOS banner build, the refined identity and each context field are all compared',
      () {
        final e = expectation();
        final w = parseWrapperLog(
          'wrapper registered type=flutter version=10.0.0-dev.1\n'
          'wrapper refined type=flutter version=10.0.0-dev.1 context={dart=3.11.0, flutter=3.41.0, flutter-engine=3452d735bd, build-configuration=debug}',
        );
        final good = SdkBanner('ios', pins().iosSdk, pins().iosSdkBuild);
        expect(e.iosProblems(good, w), isEmpty);
        expect(
          e.iosProblems(SdkBanner('ios', pins().iosSdk, 'other-1'), w),
          contains(contains('banner build other-1')),
        );
        expect(
          e.iosProblems(
            good,
            WrapperLog(
              registered: w.registered,
              refined: 'flutter/0.0.1',
              context: w.context,
            ),
          ),
          contains(contains('wrapper refined as flutter/0.0.1')),
        );
        final ctx = e.wrapper['context']! as Map;
        for (final key in ctx.keys) {
          final changed = {...ctx, key: 'x'};
          expect(
            e.wrapperInReport({
              'type': 'flutter',
              'version': e.wrapperVersion,
              'context': changed,
            }),
            contains(contains('wrapper context $key is x')),
            reason: key as String,
          );
        }
      },
    );

    test(
      'exit codes: a skipped run is not a pass, a known gap is not a failure',
      () async {
        final dir = Directory.systemTemp.createTempSync('p7-report');
        addTearDown(() => dir.deleteSync(recursive: true));
        Future<int> exitFor(Status status, {bool allow = false}) async {
          final r = Reporter('t', dir.path, {}, allowNotPossible: allow);
          final result = ScenarioResult(1, 't')..status = status;
          r.add(result);
          return r.finish();
        }

        expect(await exitFor(Status.pass), 0);
        expect(await exitFor(Status.knownGap), 0);
        expect(await exitFor(Status.fail), 1);
        expect(await exitFor(Status.invalid), 1);
        expect(await exitFor(Status.notPossible), 2);
        final allowed = Reporter('t', dir.path, {}, allowNotPossible: true)
          ..add(ScenarioResult(1, 't')..status = Status.notPossible);
        expect(allowed.finish(), 0);
      },
    );

    test(
      'a known gap is visible, does not fail, and flips to pass when closed',
      () async {
        final open = await runScenario(9, 't', (_) {}, (run) async {
          run.expect('ok', true, '');
          run.knownGap('screenshot has content', false, 'all black');
        });
        expect(open.status, Status.knownGap);
        expect(open.summaryLine, startsWith('KNOWN-GAP'));
        final closed = await runScenario(9, 't', (_) {}, (run) async {
          run.knownGap('screenshot has content', true, 'content');
        });
        expect(closed.status, Status.pass);
        final failing = await runScenario(9, 't', (_) {}, (run) async {
          run.expect('x', false, '');
          run.knownGap('g', false, '');
        });
        expect(failing.status, Status.fail);
      },
    );
  });
}
