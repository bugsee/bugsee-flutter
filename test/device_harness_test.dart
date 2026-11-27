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
import '../scripts/device/shell.dart';
import '../scripts/device/toolchain.dart';
import '../scripts/device/core/bundle.dart';
import '../scripts/device/core/events.dart';
import '../scripts/device/core/experiment.dart';
import '../scripts/device/core/lan_host.dart';
import '../scripts/device/core/expectations.dart';
import '../scripts/device/core/image.dart';
import '../scripts/device/core/crash_kinds.dart';
import '../scripts/device/core/e2e.dart';
import '../scripts/device/core/props_guard.dart';
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
10-22 11:46:50.276  7138  7138 D Bugsee  : Bugsee Android SDK 7.6.0 [2a88ea7fbf]
10-22 11:44:41.228  6080  6080 W linker64: type=1400 audit(0.0:89): avc: granted { execute } for path="/data/data/x/no_backup/bugsee_crashpad_handler/1792647760186/libbugsee-crashpad-trampoline.so" dev="dm-4"
10-22 11:44:41.228  6080  6080 W linker64: type=1400 audit(0.0:90): avc: granted { execute } for path="/data/data/x/no_backup/bugsee_crashpad_handler/1792647760186/libbugsee-crashpad-handler.so" dev="dm-4"
10-22 11:44:42.228  6080  6080 W linker64: type=1400 audit(0.0:91): avc: granted { execute } for path="/data/data/x/no_backup/bugsee_crashpad_handler/1792647760186/libbugsee-crashpad-trampoline.so" dev="dm-4"
10-22 11:44:41.285  5882  5882 F libc    : Fatal signal 11 (SIGSEGV), code 0 (SI_USER from pid 6078, uid 10166) in tid 5882 (flutter_example), pid 5882 (flutter_example)
''';

void main() {
  group('banners and wrapper identity (9.1.1)', () {
    test('the Android banner and the wrapper lines parse', () {
      final b = parseAndroidBanner(androidLog)!;
      expect([b.version, b.build], ['7.6.0', '2a88ea7fbf']);
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
2026-10-22 11:19:15.375 Df Runner[60233:9e1d3b5] (Bugsee) Bugsee IOS SDK ver:7.1.0 build:b65bdca06-9
''';
      final b = parseIosBanner(log)!;
      expect([b.version, b.build], ['7.1.0', 'b65bdca06-9']);
      final w = parseWrapperLog(log);
      expect(w.context['build-configuration'], 'debug');
      expect(w.context['flutter-engine'], '3452d735bd');
      expect(expectation().iosProblems(b, w), isEmpty);
    });

    test('devicectl\'s terminating signal parses, and only that', () {
      expect(
        parseTerminatedSignal('x\nApp terminated due to signal 11.\n'),
        11,
      );
      expect(parseTerminatedSignal('App terminated due to signal 6.'), 6);
      expect(parseTerminatedSignal('Process exited with status 0'), isNull);
      expect(parseTerminatedSignal('signal 11'), isNull);
    });

    test('the build under test is accepted, and every way of testing another one is refused', () {
      final e = expectation();
      final banner = parseAndroidBanner(androidLog);
      final w = parseWrapperLog(androidLog);
      expect(e.androidProblems(banner, w), isEmpty);
      // The same version string, another build of it (a range outranking a snapshot).
      expect(
        e.androidProblems(const SdkBanner('android', '7.6.0', 'deadbeef0'), w),
        contains(contains('banner build deadbeef0')),
      );
      expect(
        e.androidProblems(const SdkBanner('android', '7.4.3', '2a88ea7fbf'), w),
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
    });

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

    test(
      'an uncaught Java exception is matched to the process and the marker',
      () {
        const log = '''
11-12 10:00:00.000  500  500 E AndroidRuntime: FATAL EXCEPTION: main
11-12 10:00:00.000  500  500 E AndroidRuntime: Process: com.bugsee.bugsee_flutter_example, PID: 500
11-12 10:00:00.000  500  500 E AndroidRuntime: java.lang.IllegalStateException: verify-java-outer
11-12 10:00:00.000  500  500 E AndroidRuntime: \tat com.bugsee.Main.run(MainActivity.kt:1)
11-12 10:00:00.000  500  500 E AndroidRuntime: Caused by: java.lang.RuntimeException: verify-java-cause
''';
        expect(parseFatalException(log, 500, 'verify-java-outer'), isTrue);
        expect(parseFatalException(log, 500, 'verify-java-cause'), isTrue);
        // another process (an earlier run in the same logcat), a marker that is not there
        expect(parseFatalException(log, 501, 'verify-java-outer'), isFalse);
        expect(parseFatalException(log, 500, 'verify-java-main'), isFalse);
        // the old shape: the exception on the line right after FATAL EXCEPTION is not this layout
        expect(
          parseFatalException(
            'E AndroidRuntime: FATAL EXCEPTION: main\nE AndroidRuntime: verify-java-main\n',
            500,
            'verify-java-main',
          ),
          isFalse,
        );
      },
    );

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

    test(
      'a physical device may leave the status 0, nothing else is relaxed',
      () {
        ExitInfo e(String reason, int status) =>
            ExitInfo(pid: 9, reason: reason, status: status);
        const native = '5 (APP CRASH(NATIVE))';
        // The strict rule (emulators): native crash AND status 11.
        expect(exitRecordProblems(e(native, 11), 9), isEmpty);
        expect(exitRecordProblems(e(native, 0), 9), isNotEmpty);
        expect(exitRecordProblems(null, 9), isNotEmpty);
        // The physical-device rule: status 0 is "not reported", measured on a phone that does it
        // for every native crash; the caller holds the kernel's `Fatal signal 11` for the pid.
        expect(
          exitRecordProblems(e(native, 0), 9, statusMayBeUnreported: true),
          isEmpty,
        );
        expect(
          exitRecordProblems(e(native, 11), 9, statusMayBeUnreported: true),
          isEmpty,
        );
        // Still a failure: another signal, an app exit that is not a native crash, no record.
        expect(
          exitRecordProblems(e(native, 6), 9, statusMayBeUnreported: true),
          isNotEmpty,
        );
        expect(
          exitRecordProblems(
            e('10 (USER REQUESTED)', 0),
            9,
            statusMayBeUnreported: true,
          ),
          isNotEmpty,
        );
        expect(
          exitRecordProblems(null, 9, statusMayBeUnreported: true),
          isNotEmpty,
        );
      },
    );

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
    test('Gradle dependencies: the NDK artefact is found, and its absence is reported', () {
      const deps = '''
+--- project :bugsee_flutter
|    +--- com.bugsee:bugsee-android:7.6.0
|    +--- com.bugsee:bugsee-android-ndk:7.6.0
|    |    \\--- com.bugsee:bugsee-android:7.6.0
''';
      expect(parseGradleBugseeArtefacts(deps), {
        'bugsee-android': {'7.6.0'},
        'bugsee-android-ndk': {'7.6.0'},
      });
      expect(
        parseGradleBugseeArtefacts(
          '+--- com.bugsee:bugsee-android:7.4.1 -> 7.6.0',
        ),
        {
          'bugsee-android': {'7.6.0'},
        },
      );
    });

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
              'bugsee-android': {'7.6.0'},
              'bugsee-android-ndk': {'7.6.0'},
            },
        gradlePluginVersions: plugin ?? {'4.1.1'},
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
              'bugsee-android': {'7.6.0'},
            },
          ).artefactProblems(p, 'arm64-v8a'),
          contains(
            contains('bugsee-android-ndk is not in the dependency graph'),
          ),
        );
        expect(
          fakeBuild(
            deps: {
              'bugsee-android': {'7.6.0'},
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
          fakeBuild(plugin: {'4.1.1', '4.0.6'})
              .artefactProblems(p, 'arm64-v8a'),
          isNotEmpty,
        );
        expect(
          fakeBuild(libs: ['native']).artefactProblems(p, 'arm64-v8a'),
          contains(contains('APK (arm64-v8a) carries')),
        );
        expect(
          fakeBuild(
            manifest: '<provider android:name="com.bugsee.library.BugseeInitProvider" android:initOrder="100"/>',
          ).artefactProblems(p, 'arm64-v8a'),
          contains(contains('was stripped')),
        );
        expect(
          fakeBuild(
            manifest: '<provider android:name="com.bugsee.flutter.FlutterWrapperInitProvider" android:initOrder="50"/><provider android:name="com.bugsee.library.BugseeInitProvider" android:initOrder="100"/>',
          ).artefactProblems(p, 'arm64-v8a'),
          contains(contains('initOrder 50, expected 200')),
        );
      },
    );

    test('the iOS build must have resolved the pinned revision, not a path or another tag', () {
      final p = pins();
      IosBuild b(Map<String, String> resolved) => IosBuild(
        name: 'd',
        mode: 'debug',
        app: 'x.app',
        buildNumber: 1,
        resolved: resolved,
        sdkFrameworkVersion: '7.1.0',
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
    });
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
            'version': '7.6.0',
            'build': '2a88ea7fbf',
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

    test('a recovered report WITHOUT the wrapper is caught (the relaunch-after-crash trap)', () {
      final b = bundle(wrapper: null);
      expect(expectation().wrapperInReport(b.wrapper), isNotEmpty);
    });

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

    test('the region is found by its colour and the redaction check passes when it is black', () {
      final off = image(
        100,
        100,
        (x, y, p) => box(x, y, p, region, [255, 0, 255]),
      );
      final on = image(100, 100, (x, y, p) => box(x, y, p, region, [0, 0, 0]));
      expect(
        off.boundingBoxOf(const Rgb(255, 0, 255)).toString(),
        '[20,30,80,70]',
      );
      expect(on.fractionOf(region, const Rgb(0, 0, 0)), 1.0);
      expect(on.fractionOf(region, const Rgb(255, 0, 255)), 0.0);
    });

    test('a redaction that is too small leaves the region showing, and the numbers say so', () {
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
      expect(on.fractionOf(region, const Rgb(255, 0, 255)), greaterThan(0.01));
      final cover = Coverage(region, small);
      expect(cover.areaRatio, closeTo(20 * 20 / (60 * 40), 1e-9));
      expect(cover.uncovered['right'], 40);
    });

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

  group('events and child output', () {
    test('a repeated event (same rid:seq) is dropped, the first copy stays, order is kept', () {
      Map<String, Object?> ev(String k, String rid, int seq) => {
        'kind': k,
        'rid': rid,
        'seq': seq,
      };
      final kept = dropRepeatedEvents([
        ev('main', 'a', 0),
        ev('launch', 'a', 1),
        ev(
          'launch',
          'a',
          1,
        ), // the retry of an event the mock had already stored
        ev('launch', 'b', 1), // another isolate: not a repeat
        {'kind': 'old'}, // no rid/seq: kept
        {'kind': 'old'},
        {'data': ev('handler', 'a', 2)},
        {'data': ev('handler', 'a', 2)},
      ]);
      expect(kept.length, 6);
      expect(kept.map((e) => (e['data'] as Map?)?['kind'] ?? e['kind']), [
        'main',
        'launch',
        'launch',
        'old',
        'old',
        'handler',
      ]);
    });

    test('a launch event satisfies only the launch that carries its token', () {
      expect(eventHasToken({'kind': 'launch', 'token': 't1'}, 't1'), isTrue);
      expect(eventHasToken({'kind': 'launch', 'token': 't0'}, 't1'), isFalse);
      expect(eventHasToken({'kind': 'launch'}, 't1'), isFalse);
      expect(
        eventHasToken({
          'data': {'token': 't1'},
        }, 't1'),
        isTrue,
      );
    });

    test('Child.drained returns the last lines that were still in the pipes at exit', () async {
      final c = await Child.start([
        'bash',
        '-c',
        'head -c 300000 /dev/zero | tr "\\0" x; echo; echo App terminated due to signal 11.; exit 1',
      ]);
      expect(await c.process.exitCode, 1);
      await c.drained();
      expect(c.output.toString(), contains('App terminated due to signal 11.'));
      expect(parseTerminatedSignal(c.output.toString()), 11);
    });

    test(
      'Child.drained is bounded when a grandchild keeps the pipe open',
      () async {
        final c = await Child.start(['bash', '-c', 'sleep 4 & exit 0']);
        await c.process.exitCode;
        final t = Stopwatch()..start();
        await c.drained(timeout: const Duration(milliseconds: 300));
        expect(t.elapsedMilliseconds, lessThan(2500));
      },
    );
  });

  group('the mock host', () {
    test('one IPv4 address of the Mac for a phone; never every interface', () {
      expect(lanHostProblem('192.168.31.104'), isNull);
      for (final bad in [
        '0.0.0.0',
        '::',
        '127.0.0.1',
        '127.0.0.2',
        '::1',
        'fe80::1',
        'localhost',
        '',
      ]) {
        expect(lanHostProblem(bad), isNotNull, reason: bad);
      }
      // The mock itself binds the loopback by default, and still refuses every interface and a name.
      expect(bindHostProblem('127.0.0.1'), isNull);
      expect(bindHostProblem('::1'), isNull);
      expect(bindHostProblem('0.0.0.0'), isNotNull);
      expect(bindHostProblem('::'), isNotNull);
      expect(bindHostProblem('my-mac.local'), isNotNull);
    });

    test('--prompt-wait-minutes without an operand is an error, absent keeps the default', () {
      expect(
        parsePromptWaitArgs(['ios-device']).wait,
        const Duration(minutes: 3),
      );
      expect(
        parsePromptWaitArgs(['--prompt-wait-minutes', '30']).wait,
        const Duration(minutes: 30),
      );
      for (final bad in [
        ['--prompt-wait-minutes'],
        ['--prompt-wait-minutes', '--keep-install'],
        ['--prompt-wait-minutes', 'x'],
      ]) {
        final r = parsePromptWaitArgs(bad);
        expect(r.wait, isNull, reason: '$bad');
        expect(r.problem, contains('--prompt-wait-minutes'), reason: '$bad');
      }
    });

    test('the Local Network prompt wait: 3 minutes by default, bounded, never silent', () {
      expect(parsePromptWait(null).wait, const Duration(minutes: 3));
      expect(parsePromptWait('30').wait, const Duration(minutes: 30));
      for (final bad in ['0', '-1', '241', 'x', '', '2.5']) {
        final r = parsePromptWait(bad);
        expect(r.wait, isNull, reason: bad);
        expect(r.problem, contains('--prompt-wait-minutes'), reason: bad);
      }
    });
  });

  group('the crash lab and the harness agree', () {
    test(
      'every kind the harness runs exists in the app, and no kind is unused',
      () {
        final app = File('example/lib/crash_lab.dart').readAsStringSync();
        final listed = RegExp(
          r"const crashKinds = <String>\[(.*?)\];",
          dotAll: true,
        ).firstMatch(app)!.group(1)!;
        final appKinds = RegExp(r"'([a-z-]+)'")
            .allMatches(listed)
            .map((m) => m.group(1)!)
            .toList();
        expect(
          crashKindTable.map((k) => k.name).toList()..sort(),
          appKinds.toList()..sort(),
        );
        // Each one has a branch in the switch (a listed kind with no case would throw).
        for (final k in appKinds) {
          expect(app, contains("case '$k':"));
        }
      },
    );

    test('no marker is a substring of another, the control included', () {
      final markers = [
        for (final k in crashKindTable)
          if (k.marker != null) k.marker!,
        crashControlMarker,
      ];
      for (final a in markers) {
        for (final b in markers) {
          if (a != b) {
            expect(b.contains(a), isFalse, reason: '$a is inside $b');
          }
        }
      }
      expect(markers.toSet().length, markers.length);
    });

    test(
      'the control the harness sends exists in the app and throws its marker',
      () {
        final app = File('example/lib/crash_lab.dart').readAsStringSync();
        expect(app, contains("case 'control-async':"));
        expect(app, contains("StateError('$crashControlMarker')"));
      },
    );

    test('every iOS native kind has a report signal name; SIGBUS is 10 on Darwin, never 7', () {
      for (final k in crashKindTable.where(
        (k) => k.platforms.contains('ios') && k.signal != null,
      )) {
        expect(iosReportSignalNames[k.signalOnIos], isNotNull, reason: k.name);
      }
      final bus = crashKindTable.firstWhere((k) => k.name == 'ffi-bus');
      expect([bus.signal, bus.signalOnIos], [7, 10]);
      expect(iosReportSignalNames[10], 'SIGBUS');
      // 7 is SIGEMT on Darwin: the table must not call it SIGBUS (the old stimulus raised 7 on iOS).
      expect(iosReportSignalNames.containsKey(7), isFalse);
      // The app raises what the table says, per platform.
      final lab = File('example/lib/crash_lab.dart').readAsStringSync();
      expect(lab, contains('_raise(Platform.isIOS ? 10 : 7)'));
    });

    test('native kinds carry a signal, platform and Dart kinds a marker', () {
      for (final k in crashKindTable) {
        if (k.layer == CrashLayer.native) {
          expect(k.signal, isNotNull, reason: k.name);
        } else {
          expect(k.marker, isNotNull, reason: k.name);
          final source = k.layer != CrashLayer.platform
              ? 'example/lib/crash_lab.dart'
              : k.platforms.contains('android')
              ? 'example/android/app/src/main/java/com/bugsee/bugsee_flutter_example/MainActivity.java'
              : 'example/ios/Runner/AppDelegate.swift';
          // `verify-java-main` etc: the app throws the text the harness looks for.
          expect(
            File(source).readAsStringSync(),
            contains(k.marker!),
            reason: '${k.name}: the app throws the text the harness looks for',
          );
          for (final more in k.alsoContains) {
            expect(File(source).readAsStringSync(), contains(more));
          }
        }
      }
    });
  });

  group('the guards are the default (9.1.5)', () {
    test('an invalid guard ends the scenario as invalid, never as a pass or a product failure', () async {
      final lines = <String>[];
      final r = await runScenario(1, 't', lines.add, (run) async {
        run.expect('before', true, '');
        run.guard('build', ['banner build deadbeef0, pinned 2a88ea7fbf'], '');
        run.expect('after the guard: never reached', true, '');
      });
      expect(r.status, Status.invalid);
      expect(r.checks.map((c) => c.name), ['before', '[9.1] build']);
      expect(r.reason, contains('deadbeef0'));
    });

    test('a failed result is a failure; a thrown error is a failure; a scenario that asserts nothing is a failure', () async {
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
    });

    test('not possible is its own status, and a failure measured on the way still fails it', () async {
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
    });
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

    test('the application id and bundle id the harness drives are the example app\'s', () {
      final gradle = read('example/android/app/build.gradle.kts');
      final android = read('scripts/device/android_scenarios.dart');
      final id = RegExp(r'''applicationId = "([^"]+)"''')
          .firstMatch(gradle)!
          .group(1);
      expect(android, contains("const pkg = '$id'"));
      final pbx = read('example/ios/Runner.xcodeproj/project.pbxproj');
      final bundle = RegExp(
        r'PRODUCT_BUNDLE_IDENTIFIER = (com\.bugsee\.bugseeFlutterExample);',
      ).firstMatch(pbx)!.group(1);
      expect(
        read('scripts/device/ios_scenarios.dart'),
        contains("const bundleId = '$bundle'"),
      );
    });

    test('the build flags the harness passes are the ones the verification app reads', () {
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
    });

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
        'tools/',
        'test/device_harness_test.dart',
        'example/lib/verify_main.dart',
        'example/lib/e2e_main.dart',
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
        'tools/',
        'test/device_harness_test.dart',
        'example/lib/verify_main.dart',
        'example/lib/e2e_main.dart',
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
          Uri.parse('test/x_test.dart')
              .resolve('../scripts/device/core/zip.dart')
              .path,
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

    test('a frame blacked out WHOLE fails (the box is black, so the box test alone would pass)', () async {
      final r = await redaction(frame(200, 200, (x, y) => true), off);
      expect(r.status, Status.fail);
      expect(
        r.checks.where((c) => !c.ok).map((c) => c.name).join(),
        contains('not blacked out whole'),
      );
    });

    test('a redaction that spills over a large ring fails', () async {
      final on = frame(
        200,
        200,
        (x, y) => x >= 20 && x < 130 && y >= 30 && y < 110,
      );
      final r = await redaction(on, off);
      expect(r.status, Status.fail);
    });

    test('a box near the frame edge is judged on the clamped ring (no spurious failure)', () async {
      // The box starts 5 px from the left edge: the 14 px ring runs off the frame.
      RawImage edge(bool secured) {
        final rgb = Uint8List(200 * 200 * 3)..fillRange(0, 200 * 200 * 3, 255);
        for (var y = 50; y < 90; y++) {
          for (var x = 5; x < 65; x++) {
            final i = (y * 200 + x) * 3;
            rgb.setRange(i, i + 3, secured ? [0, 0, 0] : [255, 0, 255]);
          }
        }
        return RawImage(200, 200, rgb);
      }

      expect((await redaction(edge(true), edge(false))).status, Status.pass);
      final c = edge(true)
          .countOf(const Rect(-9, 36, 79, 104), const Rgb(0, 0, 0));
      expect(c.total, (79 - 0) * (104 - 36));
      expect(
        edge(true)
            .countOf(const Rect(190, 190, 230, 230), const Rgb(0, 0, 0))
            .total,
        100,
      );
    });

    test('the dart next to flutter is found from its directory, not by editing the path', () {
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
    });

    test('an unredacted box fails', () async {
      expect(
        (await redaction(
          frame(200, 200, (x, y) => false, magenta: true),
          off,
        )).status,
        Status.fail,
      );
    });

    test('an empty rectangle has no pixels of the colour (a mutation returning 1 is caught)', () {
      final img = frame(10, 10, (x, y) => true);
      expect(img.fractionOf(const Rect(5, 5, 5, 5), const Rgb(0, 0, 0)), 0);
      expect(img.fractionOf(const Rect(50, 50, 60, 60), const Rgb(0, 0, 0)), 0);
      expect(
        img.agreementOutside(
          frame(9, 9, (x, y) => true),
          const Rect(0, 0, 1, 1),
        ),
        0,
      );
    });

    test('a mapping of ANOTHER apk at an offset inside base.apk\'s library range is not a library', () {
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
    });

    test('the iOS banner build, the refined identity and each context field are all compared', () {
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
    });

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

  group('the end-to-end symbolication run (e2e_symbolication.dart)', () {
    const post200 =
        'HTTP POST https://api.bugsee.com/v2/apps/<APP_TOKEN>/symbols -> 200 (request body 90 bytes)\n';

    test('redact removes every secret and ignores trivial ones', () {
      const t = 'GET /apps/app-token-secret/symbols server=SRV-TOKEN-1234';
      final r = redact(t, ['app-token-secret', 'SRV-TOKEN-1234', 'ab']);
      expect(r, isNot(contains('app-token')));
      expect(r, isNot(contains('SRV-TOKEN')));
      expect(r.split('<REDACTED>').length, 3);
    });

    test(
      'events of another run are dropped; a truncated line does not throw',
      () {
        const console =
            'noise\nE2E|{"kind":"start","run":"9.1.1","phase":0}\n'
            'E2E|{"kind":"start","run":"OLD","phase":0}\nE2E|{"kind":"sta';
        final e = e2eEvents(console, '9.1.1');
        expect(e, hasLength(1));
        expect(e.single['phase'], 0);
      },
    );

    test('symbols.py exiting 0 after a refused POST is NOT an upload', () {
      // the pinned script returns None from a non-2xx POST and exits 0
      expect(symbolsUploadProblems('', 0), isNotEmpty);
      expect(
        symbolsUploadProblems(
          'HTTP POST https://x/apps/<APP_TOKEN>/symbols -> 403 (request body 90 bytes)\n',
          0,
        ),
        anyElement(contains('403')),
      );
      expect(symbolsUploadProblems(post200, 0), anyElement(contains('no PUT')));
      expect(
        symbolsUploadProblems(
          '${post200}HTTP PUT https://s3.example/k?<query-dropped> -> 200 (request body 5 bytes)\n',
          0,
        ),
        isEmpty,
      );
      expect(
        symbolsUploadProblems(
          '${post200}HTTP PUT https://s3/k -> 403 (request body 1 bytes)\n',
          0,
        ),
        anyElement(contains('403')),
      );
    });

    test(
      'the device run needs all four phases, launched, release, two crashes',
      () {
        List<Map<String, Object?>> good() => [
          for (var p = 0; p < 4; p++) ...[
            {'kind': 'start', 'phase': p, 'mode': 'release', 'os': 'ios'},
            {'kind': 'launch', 'result': 'launched'},
            if (p == 0) {'kind': 'reported'},
            if (p == 1 || p == 2) {'kind': 'crashing'},
          ],
        ];
        expect(phaseProblems(good(), os: 'ios', release: true), isEmpty);
        expect(
          phaseProblems(good().sublist(4), os: 'ios', release: true),
          isNotEmpty,
        );
        expect(
          phaseProblems(
            good()
                .map((e) => e['kind'] == 'start' ? {...e, 'mode': 'debug'} : e)
                .toList(),
            os: 'ios',
            release: true,
          ),
          anyElement(contains('release')),
        );
        expect(
          phaseProblems(
            good()
                .map(
                  (e) => e['kind'] == 'launch'
                      ? {...e, 'result': 'already-running'}
                      : e,
                )
                .toList(),
            os: 'ios',
            release: true,
          ),
          isNotEmpty,
        );
      },
    );

    test('run ids differ per second, day and year and are valid as an iOS short version', () {
      final a = runIdFor(DateTime(2026, 11, 23, 14, 5, 7));
      expect(a, '9.261123.140507');
      expect(runIdFor(DateTime(2026, 11, 23, 14, 5, 8)), isNot(a));
      expect(runIdFor(DateTime(2027, 11, 23, 14, 5, 7)), isNot(a));
      expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(a), isTrue);
    });

    test('the symbols file must be the platform format', () {
      expect(symbolsFormat([0x7f, 0x45, 0x4c, 0x46, 2, 1]), 'elf');
      expect(symbolsFormat([0xcf, 0xfa, 0xed, 0xfe, 12, 0]), 'macho');
      expect(symbolsFormat([0x50, 0x4b, 3, 4]), isNull);
    });

    group('the read-back verdict', () {
      const dart = ['e2eHandledSite', 'e2eUnhandledSite', 'e2eUncaughtThrower'];
      const native = ['crash_lab.dart', 'AppDelegate.swift'];
      const dartReport =
          '#0 e2eHandledSite (package:x/e2e_main.dart:40:5)\n#1 e2eUnhandledSite (e2e_main.dart:52:16)\n'
          '#2 e2eUncaughtThrower (e2e_main.dart:70:1)';
      const ffiReport = '#0 crash (package:x/crash_lab.dart:54:3)\n#1 UIKit';
      const platformReport =
          '#0 AppDelegate.application (AppDelegate.swift:32)';
      List<String> problems(List<String> reports) => readbackProblems(
        reports,
        expectedDartNames: dart,
        expectedNativeFrames: native,
      );

      test('fully symbolicated reports pass', () {
        expect(problems([dartReport, ffiReport, platformReport]), isEmpty);
      });

      test('every name present but ONE raw frame still fails', () {
        final p = problems([
          '$dartReport\n#3 abs 0000007f virt 12 _kDartSnapshotText+0x42',
          ffiReport,
          platformReport,
        ]);
        expect(p, hasLength(1));
        expect(p.single, contains('raw frame'));
      });

      test(
        'a name in a summary or log line, not in a frame, does not count',
        () {
          final p = problems([
            'summary: e2eHandledSite failed\n#1 e2eUnhandledSite (e2e_main.dart:52:16)\n#2 e2eUncaughtThrower (e2e_main.dart:70:1)',
            ffiReport,
            platformReport,
          ]);
          expect(p, anyElement(contains('"e2eHandledSite"')));
        },
      );

      test('the native frames need a report each; one report cannot be both crashes', () {
        expect(
          problems([dartReport, '$ffiReport\n$platformReport']),
          anyElement(contains('distinct reports')),
        );
        expect(
          problems([dartReport, ffiReport]),
          anyElement(contains('AppDelegate.swift')),
        );
      });

      test('raw addresses without the names, and no reports at all, fail', () {
        expect(
          readbackProblems(
            ['#0 abs 0000 virt 1234 _kDartSnapshotText+0x42'],
            expectedDartNames: ['e2eHandledSite'],
            expectedNativeFrames: [],
          ),
          hasLength(2),
        );
        expect(
          readbackProblems([], expectedDartNames: [], expectedNativeFrames: []),
          anyElement(contains('nothing was verified')),
        );
      });
    });

    group('what ended a crash launch', () {
      test('iOS: ffi-segv needs signal 11; objc-main signal 6 or a non-zero exit with no signal', () {
        const segv = 'App terminated due to signal 11.';
        expect(iosCrashExitProblems('ffi-segv', segv, 1), isEmpty);
        // a `crashing` marker followed by the previous console child's SIGTERM is not a crash
        expect(
          iosCrashExitProblems(
            'ffi-segv',
            'App terminated due to signal 15.',
            1,
          ),
          isNotEmpty,
        );
        expect(iosCrashExitProblems('ffi-segv', '', 0), isNotEmpty);
        expect(
          iosCrashExitProblems(
            'objc-main',
            'App terminated due to signal 6.',
            1,
          ),
          isEmpty,
        );
        // no signal line: a non-zero exit needs the runtime's uncaught-exception line as well
        expect(
          iosCrashExitProblems(
            'objc-main',
            "E2E|{\"kind\":\"crashing\"}\n*** Terminating app due to uncaught exception 'VerifyException', reason: 'verify-objc-main'",
            1,
          ),
          isEmpty,
        );
        // a lost device after the marker: non-zero exit, no termination evidence
        expect(
          iosCrashExitProblems(
            'objc-main',
            'E2E|{"kind":"crashing","crash":"objc-main"}\nThe device was disconnected.',
            1,
          ),
          anyElement(contains('not confirmed')),
        );
        expect(iosCrashExitProblems('objc-main', '', 1), isNotEmpty);
        expect(iosCrashExitProblems('objc-main', '', 0), isNotEmpty);
        expect(
          iosCrashExitProblems(
            'objc-main',
            'App terminated due to signal 15.',
            1,
          ),
          isNotEmpty,
        );
      });

      test('Android: an adb failure is not process death', () {
        bool? gone(int code, String out, String err) =>
            androidPidGone(code: code, stdout: out, stderr: err, pid: 100);
        expect(gone(1, '', ''), isTrue); // pidof: no such process
        expect(gone(0, '200\n', ''), isTrue); // restarted under another pid
        expect(gone(0, '100\n', ''), isFalse); // still alive
        expect(gone(1, '', 'error: device offline'), isNull);
        expect(gone(255, '', 'adb: no devices'), isNull);
        // the harness's own timeout answer (code 124, text on stderr) is a failure, not a dead process
        expect(
          gone(124, '', 'timeout after 0:02:00: adb shell pidof x'),
          isNull,
        );
        // an adb failure with the PID gone from view must never read as "gone"
        expect(gone(1, '', 'error: closed'), isNull);
        expect(gone(0, '', ''), isTrue);
      });

      test('Android: the crash evidence is the pid\'s own', () {
        const segv =
            'F libc    : Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 100 (x), pid 100 (pkg)';
        expect(androidCrashProblems('ffi-segv', segv, 100), isEmpty);
        expect(androidCrashProblems('ffi-segv', segv, 101), isNotEmpty);
        expect(androidCrashProblems('ffi-segv', '', 100), isNotEmpty);
        const java =
            'E AndroidRuntime: FATAL EXCEPTION: main\nE AndroidRuntime: Process: pkg, PID: 100\nE AndroidRuntime: java.lang.IllegalStateException: verify-java-main';
        expect(androidCrashProblems('java-main', java, 100), isEmpty);
        expect(androidCrashProblems('java-main', java, 7), isNotEmpty);
      });
    });

    test('symbols_logged.py: a failed request prints no URL query, token or original message', () {
      try {
        if (Process.runSync('python3', ['--version']).exitCode != 0) {
          markTestSkipped('python3 is not usable here');
          return;
        }
      } on ProcessException {
        markTestSkipped('python3 is not installed');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('symlog');
      addTearDown(() => dir.deleteSync(recursive: true));
      // a stand-in `requests` whose transport failure carries the whole URL, as urllib3's does
      Directory('${dir.path}/requests').createSync();
      File('${dir.path}/requests/__init__.py').writeAsStringSync(
        'class _E:\n'
        '    class RequestException(Exception):\n'
        '        pass\n'
        'exceptions = _E\n'
        'class Session:\n'
        '    def send(self, request, **kw):\n'
        '        raise OSError("connect failed " + request.url)\n',
      );
      File('${dir.path}/fake_symbols.py').writeAsStringSync(
        'import requests\n'
        'class R:\n'
        '    method = "PUT"\n'
        '    url = "https://s3.example/key/APPTOKEN12345?X-Amz-Signature=SIGSECRET"\n'
        '    headers = {}\n'
        'requests.Session().send(R())\n',
      );
      final r = Process.runSync(
        'python3',
        [
          '${Directory.current.path}/scripts/device/symbols_logged.py',
          '${dir.path}/fake_symbols.py',
          '-t',
          'APPTOKEN12345',
        ],
        environment: {'PYTHONPATH': dir.path},
      );
      final all = '${r.stdout}\n${r.stderr}';
      expect(r.exitCode, isNot(0));
      expect(all, contains('FAILED (OSError)'));
      expect(all, isNot(contains('SIGSECRET')));
      expect(all, isNot(contains('APPTOKEN12345')));
      expect(all, isNot(contains('connect failed')));
    });

    test('symbols_logged.py: a non-2xx answer prints the error code only, never the body', () {
      try {
        if (Process.runSync('python3', ['--version']).exitCode != 0) {
          markTestSkipped('python3 is not usable here');
          return;
        }
      } on ProcessException {
        markTestSkipped('python3 is not installed');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('symlog2');
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/requests').createSync();
      File('${dir.path}/requests/__init__.py').writeAsStringSync(
        'class _E:\n'
        '    class RequestException(Exception):\n'
        '        pass\n'
        'exceptions = _E\n'
        'class _Resp:\n'
        '    ok = False\n'
        '    status_code = 403\n'
        '    text = "<Error><Code>SignatureDoesNotMatch</Code><AWSAccessKeyId>AKIAFAKEKEY123</AWSAccessKeyId><StringToSign>STS-SECRET</StringToSign></Error>"\n'
        'class Session:\n'
        '    def send(self, request, **kw):\n'
        '        return _Resp()\n',
      );
      File('${dir.path}/fake_symbols.py').writeAsStringSync(
        'import requests\n'
        'class R:\n'
        '    method = "PUT"\n'
        '    url = "https://s3.example/key?X-Amz-Signature=SIGSECRET"\n'
        '    headers = {}\n'
        'requests.Session().send(R())\n',
      );
      final r = Process.runSync(
        'python3',
        [
          '${Directory.current.path}/scripts/device/symbols_logged.py',
          '${dir.path}/fake_symbols.py',
          '-t',
          'APPTOKEN12345',
        ],
        environment: {'PYTHONPATH': dir.path},
      );
      final all = '${r.stdout}\n${r.stderr}';
      expect(all, contains('403'));
      expect(all, contains('SignatureDoesNotMatch'));
      expect(all, isNot(contains('AKIAFAKEKEY123')));
      expect(all, isNot(contains('STS-SECRET')));
      expect(all, isNot(contains('SIGSECRET')));
    });

    test('readTimeLimit: bounded by the deadline plus a short grace, null after it', () {
      final end = DateTime(2026, 1, 1, 12);
      expect(
        readTimeLimit(end.subtract(const Duration(minutes: 10)), end),
        const Duration(minutes: 2),
      );
      expect(
        readTimeLimit(end.subtract(const Duration(seconds: 31)), end),
        const Duration(seconds: 51),
      );
      expect(
        readTimeLimit(end.add(const Duration(seconds: 5)), end),
        const Duration(seconds: 15),
      );
      expect(readTimeLimit(end.add(const Duration(seconds: 20)), end), isNull);
      expect(readTimeLimit(end.add(const Duration(minutes: 1)), end), isNull);
    });

    test('an unexpected exception is logged redacted (a ProcessException holds the command line)', () {
      const token = 'FAKE-APP-TOKEN-0123456789';
      const server = 'FAKE-SERVER-TOKEN-987654';
      final e = ProcessException('python3', [
        'x.py',
        '-t',
        token,
        '-v',
        '9.1.1',
      ], 'No such file');
      final text = failureText(e, [token, server]);
      expect(text, contains('ProcessException'));
      expect(text, isNot(contains(token)));
      expect(text, contains('<REDACTED>'));
      expect(
        failureText(StateError('key=$server'), [token, server]),
        isNot(contains(server)),
      );
      // and unredacted it WOULD leak, so the test shows what it guards
      expect('$e', contains(token));
    });

    group('a recording of an older run in the same issue is not evidence', () {
      final since = DateTime.utc(2026, 11, 24, 10);
      RecordingScope scope(Map<String, Object?> r) => recordingScope(
        r,
        runId: '9.261124.100500',
        buildNumber: '100500',
        since: since,
      );
      Map<String, Object?> rec(String v, [String? build]) => {
        '_id': 'r',
        'environment': {
          'app': {'version': v, if (build != null) 'build': build},
        },
      };

      test('by app version and build', () {
        expect(scope(rec('9.261124.100500', '100500')), RecordingScope.mine);
        expect(scope(rec('9.261123.200000', '200000')), RecordingScope.other);
        expect(scope(rec('9.261124.100500', '999')), RecordingScope.other);
        expect(scope(rec('9.261124.100500')), RecordingScope.mine);
        // the same version from an earlier attempt of a reused build is not this attempt's
        expect(
          scope({
            ...rec('9.261124.100500', '100500'),
            'created_on': '2026-11-24T08:00:00Z',
          }),
          RecordingScope.other,
        );
        expect(
          scope({
            ...rec('9.261124.100500', '100500'),
            'created_on': '2026-11-24T10:02:00Z',
          }),
          RecordingScope.mine,
        );
      });

      test('without a version, by creation time; with neither, unknown (fail closed)', () {
        expect(
          scope({'created_on': '2026-11-24T10:03:00.000Z'}),
          RecordingScope.mine,
        );
        expect(
          scope({'created_on': '2026-11-23T10:03:00.000Z'}),
          RecordingScope.other,
        );
        expect(scope({'_id': 'r'}), RecordingScope.unknown);
        expect(scope({'created_on': 'garbage'}), RecordingScope.unknown);
        // the version wins over a fresh timestamp
        expect(
          scope({
            ...rec('9.261123.200000'),
            'created_on': '2026-11-24T10:03:00Z',
          }),
          RecordingScope.other,
        );
      });

      test('an old recording, once dropped, can neither satisfy nor fail the verdict', () {
        const frame = '#0 AppDelegate.application (AppDelegate.swift:32)';
        const old = '$frame\n#1 abs 0000007f virt 12 _kDartSnapshotText+0x42';
        const dart =
            '#0 e2eHandledSite (e2e_main.dart:40:5)\n#1 e2eUnhandledSite (e2e_main.dart:52:16)\n#2 e2eUncaughtThrower (e2e_main.dart:70:1)';
        const ffi = '#0 crash (crash_lab.dart:54:3)';
        final mine = [
          for (final r in [
            (rec('9.261124.100500', '100500'), dart),
            (rec('9.261124.100500', '100500'), ffi),
            (rec('9.261123.200000', '200000'), old),
          ])
            if (scope(r.$1) == RecordingScope.mine) r.$2,
        ];
        // an old good frame must not supply the missing platform report: this run's is missing, so it fails
        expect(
          readbackProblems(
            mine,
            expectedDartNames: [
              'e2eHandledSite',
              'e2eUnhandledSite',
              'e2eUncaughtThrower',
            ],
            expectedNativeFrames: ['crash_lab.dart', 'AppDelegate.swift'],
          ),
          anyElement(contains('AppDelegate.swift')),
        );
        // and an old RAW recording does not fail a run whose own reports are clean
        final clean = [
          ...mine,
          '#0 AppDelegate.application (AppDelegate.swift:32)',
        ];
        expect(
          readbackProblems(
            clean,
            expectedDartNames: [
              'e2eHandledSite',
              'e2eUnhandledSite',
              'e2eUncaughtThrower',
            ],
            expectedNativeFrames: ['crash_lab.dart', 'AppDelegate.swift'],
          ),
          isEmpty,
        );
      });
    });

    group('recording scope details', () {
      final since = DateTime.utc(2026, 11, 24, 9);
      Map<String, Object?> rec(String build, {String? created}) => {
        'environment': {
          'app': {'version': '9.261124.093015', 'build': build},
        },
        if (created != null) 'created_on': created,
      };
      RecordingScope scope(Map<String, Object?> r, {bool reuse = false}) =>
          recordingScope(
            r,
            runId: '9.261124.093015',
            buildNumber: '093015',
            since: since,
            requireCreatedOn: reuse,
          );

      test('a build with leading zeros equals the integer Android stores', () {
        expect(scope(rec('93015')), RecordingScope.mine); // versionCode 93015
        expect(scope(rec('093015')), RecordingScope.mine);
        expect(scope(rec('93016')), RecordingScope.other);
        expect(scope(rec('abc')), RecordingScope.unknown); // fail closed
        expect(
          recordingScope(
            rec('93015'),
            runId: '9.261124.093015',
            buildNumber: '93015',
            since: since,
          ),
          RecordingScope.mine,
        );
      });

      test('created_on needs an offset; a reused build needs created_on', () {
        expect(
          scope(rec('93015', created: '2026-11-24T09:05:00')),
          RecordingScope.mine, // no reuse: the version alone decides
        );
        expect(
          scope(rec('93015', created: '2026-11-24T09:05:00'), reuse: true),
          RecordingScope
              .unknown, // an offset-less time would be read as local time
        );
        expect(scope(rec('93015'), reuse: true), RecordingScope.unknown);
        expect(
          scope(rec('93015', created: '2026-11-24T09:05:00.000Z'), reuse: true),
          RecordingScope.mine,
        );
        expect(
          scope(
            rec('93015', created: '2026-11-24T10:05:00+01:00'),
            reuse: true,
          ),
          RecordingScope.mine, // 09:05Z
        );
        expect(
          scope({'created_on': '2026-11-24T09:05:00'}),
          RecordingScope.unknown, // no version and no offset
        );
      });

      test('only an explicit crash_report: false is "no crash report"', () {
        expect(recordingHasCrashReport({'crash_report': false}), isFalse);
        expect(recordingHasCrashReport({'crash_report': true}), isTrue);
        expect(recordingHasCrashReport({'_id': 'x'}), isTrue);
      });
    });

    group('the properties guard', () {
      late Directory dir;
      setUp(() => dir = Directory.systemTemp.createTempSync('props'));
      tearDown(() {
        Process.runSync('chmod', ['-R', 'u+rwx', dir.path]);
        dir.deleteSync(recursive: true);
      });
      String mode(File f) {
        final r = Process.runSync('stat', ['-f', '%Lp', f.path]);
        return r.exitCode == 0
            ? '${r.stdout}'.trim()
            : '${Process.runSync('stat', ['-c', '%a', f.path]).stdout}'.trim();
      }

      test("a developer's file is narrowed while it holds the token, then restored with its mode", () {
        final f = File('${dir.path}/bugsee.properties')
          ..writeAsStringSync('app_token=mine\nother=1\n');
        Process.runSync('chmod', ['644', f.path]);
        final g = PropsGuard(f, File('${dir.path}/orig'), (_) {});
        g.install('app_token=RUN-FAKE\n');
        expect(mode(f), '600');
        expect(f.readAsStringSync(), contains('RUN-FAKE'));
        g.restore();
        expect(f.readAsStringSync(), 'app_token=mine\nother=1\n');
        expect(mode(f), '644');
        expect(File('${dir.path}/orig').existsSync(), isFalse);
      });

      test('a file whose mode cannot be changed aborts before the token is written', () {
        if (Process.runSync('id', ['-u']).stdout.toString().trim() == '0') {
          markTestSkipped('root can chmod anything');
          return;
        }
        // a symlink to a root-owned file: reading works, chmod fails
        final target = File('/etc/hosts');
        if (!target.existsSync()) {
          markTestSkipped('no /etc/hosts');
          return;
        }
        final link = Link('${dir.path}/bugsee.properties')
          ..createSync(target.path);
        final g = PropsGuard(File(link.path), File('${dir.path}/orig'), (_) {});
        final before = target.readAsStringSync();
        expect(
          () => g.install('app_token=RUN-FAKE\n'),
          throwsA(isA<FileSystemException>()),
        );
        expect(target.readAsStringSync(), before);
        expect(target.readAsStringSync(), isNot(contains('RUN-FAKE')));
        g.restore();
        expect(target.readAsStringSync(), before);
      });

      test('a symlinked file: the TARGET mode is captured and restored', () {
        final target = File('${dir.path}/real.properties')
          ..writeAsStringSync('app_token=mine\n');
        Process.runSync('chmod', ['640', target.path]);
        final link = Link('${dir.path}/bugsee.properties')
          ..createSync(target.path);
        final g = PropsGuard(File(link.path), File('${dir.path}/orig'), (_) {});
        g.install('app_token=RUN-FAKE\n');
        expect(mode(target), '600');
        g.restore();
        expect(target.readAsStringSync(), 'app_token=mine\n');
        expect(mode(target), '640');
      });

      test('a file the run created is deleted', () {
        final f = File('${dir.path}/bugsee.properties');
        final g = PropsGuard(f, File('${dir.path}/orig'), (_) {});
        g.install('app_token=RUN-FAKE\n');
        expect(mode(f), '600');
        g.restore();
        expect(f.existsSync(), isFalse);
      });

      test("a developer's file that cannot be read is never deleted", () {
        if (Process.runSync('id', ['-u']).stdout.toString().trim() == '0') {
          markTestSkipped('root can read a mode 000 file');
          return;
        }
        final f = File('${dir.path}/bugsee.properties')
          ..writeAsStringSync('app_token=mine\n');
        Process.runSync('chmod', ['000', f.path]);
        final g = PropsGuard(f, File('${dir.path}/orig'), (_) {});
        expect(
          () => g.install('app_token=RUN-FAKE\n'),
          throwsA(isA<FileSystemException>()),
        );
        g.restore();
        expect(f.existsSync(), isTrue);
        Process.runSync('chmod', ['600', f.path]);
        expect(f.readAsStringSync(), 'app_token=mine\n');
      });
    });

    test('a name is matched whole, not as a prefix of another function', () {
      const helper = '#0 e2eHandledSiteHelper (e2e_main.dart:40:5)';
      expect(
        readbackProblems(
          [helper],
          expectedDartNames: ['e2eHandledSite'],
          expectedNativeFrames: [],
        ),
        anyElement(contains('"e2eHandledSite"')),
      );
      expect(
        readbackProblems(
          ['#0 e2eHandledSite (e2e_main.dart:40:5)'],
          expectedDartNames: ['e2eHandledSite'],
          expectedNativeFrames: [],
        ),
        isEmpty,
      );
    });

    test('a recording that could not be read means no verdict on the rest', () {
      const good = '#0 e2eHandledSite (e2e_main.dart:40:5)';
      expect(
        readbackProblems(
          [good],
          unreadRecordings: 1,
          expectedDartNames: ['e2eHandledSite'],
          expectedNativeFrames: [],
        ),
        anyElement(contains('could not be read')),
      );
      expect(
        readbackProblems(
          [],
          unreadRecordings: 2,
          expectedDartNames: [],
          expectedNativeFrames: [],
        ),
        hasLength(2),
      );
    });

    test('a reused build must be for the same platform, endpoint and app', () {
      const a = {'platform': 'ios', 'endpoint': '', 'app': 'h1'};
      expect(reuseIdentityProblems(a, {...a}), isEmpty);
      expect(reuseIdentityProblems(a, {...a, 'app': 'h2'}), hasLength(1));
      expect(
        reuseIdentityProblems(a, {
          ...a,
          'endpoint': 'https://apidev.bugsee.com',
        }),
        hasLength(1),
      );
      expect(
        reuseIdentityProblems(a, {...a, 'platform': 'android'}),
        hasLength(1),
      );
    });

    test('the Java crash search stops at the next FATAL EXCEPTION block (another process)', () {
      const log =
          'E AndroidRuntime: FATAL EXCEPTION: main\n'
          'E AndroidRuntime: Process: pkg, PID: 100\n'
          'E AndroidRuntime: java.lang.RuntimeException: other\n'
          'E AndroidRuntime: FATAL EXCEPTION: main\n'
          'E AndroidRuntime: Process: pkg, PID: 200\n'
          'E AndroidRuntime: java.lang.IllegalStateException: verify-java-main';
      expect(parseFatalException(log, 200, 'verify-java-main'), isTrue);
      expect(parseFatalException(log, 100, 'verify-java-main'), isFalse);
    });

    test('the Java crash search stops at a header line, not at the words in a message', () {
      const log =
          'E AndroidRuntime: FATAL EXCEPTION: main\n'
          'E AndroidRuntime: Process: pkg, PID: 100\n'
          'E AndroidRuntime: java.lang.RuntimeException: FATAL EXCEPTION in worker\n'
          'E AndroidRuntime: Caused by: java.lang.IllegalStateException: verify-java-main';
      expect(parseFatalException(log, 100, 'verify-java-main'), isTrue);
    });

    test('the unsettled message says which it is', () {
      expect(
        readbackUnsettledWhy([(ok: true, reports: 3), (ok: true, reports: 4)]),
        contains('kept changing'),
      );
      expect(
        readbackUnsettledWhy([(ok: false, reports: 3), (ok: true, reports: 3)]),
        contains('one confirming pass short'),
      );
    });

    test('the read-back stops only after two agreeing good passes', () {
      const ok3 = (ok: true, reports: 3);
      expect(readbackSettled([ok3]), isFalse);
      expect(readbackSettled([ok3, ok3]), isTrue);
      expect(
        readbackSettled([ok3, (ok: true, reports: 4)]),
        isFalse,
      ); // a late report arrived
      expect(readbackSettled([(ok: false, reports: 3), ok3]), isFalse);
      expect(readbackSettled([ok3, (ok: false, reports: 3)]), isFalse);
      expect(readbackSettled([]), isFalse);
    });

    test('raw frame lines are found, symbolicated ones are not', () {
      expect(
        rawFrameLines(
          '    #00 abs 0000007f virt 000000000012 _kDartSnapshotText+0x42 (x)',
        ),
        hasLength(1),
      );
      expect(rawFrameLines('#0 e2eHandledSite (e2e_main.dart:40)'), isEmpty);
    });
  });
}
